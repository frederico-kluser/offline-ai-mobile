/// Testes do piloto d1 e das ferramentas do browser.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_ai_mobile/src/agent/tools.dart';
import 'package:offline_ai_mobile/src/browser/browser_action.dart';
import 'package:offline_ai_mobile/src/browser/browser_controller.dart';
import 'package:offline_ai_mobile/src/browser/browser_page_state.dart';
import 'package:offline_ai_mobile/src/browser/browser_pilot.dart';
import 'package:offline_ai_mobile/src/browser/browser_tools.dart';
import 'package:offline_ai_mobile/src/domain/d1_decision_types.dart';
import 'package:offline_ai_mobile/src/domain/llm_config.dart';
import 'package:offline_ai_mobile/src/engines/d1_engine.dart';

class FakeD1Engine implements D1Engine {
  final D1Response Function(D1Request) onDecide;
  FakeD1Engine(this.onDecide);

  @override
  bool get isLoaded => true;

  @override
  String get modelId => 'fake-d1';

  @override
  D1BackendKind get backend => D1BackendKind.onnx;

  @override
  D1Capabilities get capabilities => D1Capabilities.onnxFull;

  @override
  String? get loadError => null;

  @override
  Future<void> load({
    required D1ModelPaths paths,
    required D1Config config,
  }) async {}

  @override
  Future<D1Response> decide(D1Request request) async => onDecide(request);

  @override
  Future<void> unload() async {}
}

D1ChoiceAnswer choice(String id, String value, double confidence) =>
    D1ChoiceAnswer(
      id: id,
      choice: value,
      confidence: confidence,
      probabilities: {
        for (final k in const ['sim', 'nao'])
          k: k == value ? confidence : 1 - confidence,
      },
    );

D1Response responseWith({
  String next = 'tap:e1',
  String goal = 'nao',
  String stuck = 'nao',
  String injection = 'nao',
  String irreversible = 'nao',
  String goalAllows = 'nao',
  double confidence = 0.9,
}) =>
    D1Response(
      answers: {
        'next_action': choice('next_action', next, confidence),
        'goal': choice('goal', goal, 0.95),
        'stuck': choice('stuck', stuck, 0.95),
        'injection': choice('injection', injection, 0.95),
        'irreversible': choice('irreversible', irreversible, 0.95),
        'goal_allows': choice('goal_allows', goalAllows, 0.95),
      },
      inputTokens: 10,
      latencyMs: 4,
    );

PageSnapshot page() => const PageSnapshot(
      url: 'https://example.com',
      title: 'Example',
      text: 'checkout',
      elements: [
        PageElement(
            ref: 'e1', tag: 'button', role: 'button', name: 'Confirmar'),
        PageElement(ref: 'e2', tag: 'input', role: 'textbox', name: 'Email'),
      ],
    );

class FakeBrowserController implements BrowserController {
  final _events = StreamController<BrowserEvent>.broadcast();
  final List<BrowserAction> executed = [];

  @override
  Widget buildView() => const SizedBox.shrink();

  @override
  bool get isReady => true;

  @override
  String? get currentUrl => 'https://example.com';

  @override
  Stream<BrowserEvent> get events => _events.stream;

  @override
  Future<ActionResult> execute(BrowserAction action) async {
    executed.add(action);
    if (action is BrowserTap && action.ref == 'missing') {
      return ActionResult.error('ref-not-found', 'ref não existe');
    }
    if (action is BrowserType && action.text.isEmpty) {
      return ActionResult.error('bad-args', 'texto vazio');
    }
    return ActionResult.ok('ok: ${action.kind}', snapshot: page());
  }

  @override
  Future<PageSnapshot> snapshot() async => page();

  @override
  Future<void> loadUrl(String url) async {}

  @override
  Future<void> dispose() async => _events.close();
}

void main() {
  final pilot = BrowserPilot(engine: FakeD1Engine((_) => responseWith()));

  test('plano tem 6 perguntas e candidatos fechados', () {
    final plan = pilot.buildPlan(
      objective: 'confirmar a encomenda',
      page: page(),
    );
    expect(plan.request.questions, hasLength(6));
    expect(plan.candidates.keys, contains('tap:e1'));
    expect(plan.candidates.keys, contains('type:e2'));
    expect(plan.candidates.keys, contains('done'));
  });

  test('confiança alta executa a ação', () async {
    final d = await pilot.run(objective: 'confirmar', page: page());
    expect(d.disposition, PilotDisposition.act);
    expect(d.action, isA<BrowserTap>());
    expect(d.confidence, 0.9);
  });

  test('confidence média escala para o LFM3', () async {
    final p = BrowserPilot(
      engine: FakeD1Engine((_) => responseWith(confidence: 0.6)),
    );
    final d = await p.run(objective: 'confirmar', page: page());
    expect(d.disposition, PilotDisposition.escalate);
  });

  test('confidence baixa abstém-se', () async {
    final p = BrowserPilot(
      engine: FakeD1Engine((_) => responseWith(confidence: 0.2)),
    );
    final d = await p.run(objective: 'confirmar', page: page());
    expect(d.disposition, PilotDisposition.abstain);
  });

  test('prompt injection bloqueia', () async {
    final p = BrowserPilot(
      engine: FakeD1Engine((_) => responseWith(injection: 'sim')),
    );
    final d = await p.run(objective: 'confirmar', page: page());
    expect(d.disposition, PilotDisposition.abstain);
    expect(d.note, contains('injection'));
  });

  test('ação irreversível não autorizada bloqueia', () async {
    final p = BrowserPilot(
      engine: FakeD1Engine((_) => responseWith(irreversible: 'sim')),
    );
    final d = await p.run(objective: 'confirmar', page: page());
    expect(d.disposition, PilotDisposition.abstain);
    expect(d.note, contains('irreversível'));
  });

  test('goal=sim termina', () async {
    final p = BrowserPilot(
      engine: FakeD1Engine((_) => responseWith(goal: 'sim')),
    );
    final d = await p.run(objective: 'confirmar', page: page());
    expect(d.disposition, PilotDisposition.done);
  });

  test('escolha fora do leque abstém-se', () async {
    final p = BrowserPilot(
      engine: FakeD1Engine((_) => responseWith(next: 'tap:inventado')),
    );
    final d = await p.run(objective: 'confirmar', page: page());
    expect(d.disposition, PilotDisposition.abstain);
  });

  test('browserTools tem 7 ferramentas e devolve status explícito', () async {
    final controller = FakeBrowserController();
    final tools = browserTools(controller);
    expect(tools, hasLength(7));
    final tap = tools.firstWhere((t) => t.spec.name == 'browser_click');
    final r = await runTool(tap, {'ref': 'missing'});
    expect(r.ok, isFalse);
    expect(r.output, contains('ref-not-found'));
    final type = tools.firstWhere((t) => t.spec.name == 'browser_type');
    final r2 = await runTool(type, {'ref': 'e2', 'text': 'a@b.c'});
    expect(r2.ok, isTrue);
  });
}
