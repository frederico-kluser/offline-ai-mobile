/// Testes do browser embutido: vocabulário de ações, snapshot/refs, ponte JS
/// (contrato), piloto Laya (bandas + gates) e tools do agente.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_ai_mobile/src/browser/browser_action.dart';
import 'package:offline_ai_mobile/src/browser/browser_bridge_js.dart';
import 'package:offline_ai_mobile/src/browser/browser_controller.dart';
import 'package:offline_ai_mobile/src/browser/browser_page_state.dart';
import 'package:offline_ai_mobile/src/browser/browser_pilot.dart';
import 'package:offline_ai_mobile/src/browser/browser_tools.dart';
import 'package:offline_ai_mobile/src/domain/laya_types.dart';
import 'package:offline_ai_mobile/src/domain/llm_config.dart';
import 'package:offline_ai_mobile/src/engines/laya_engine.dart';

class _FakeBrowser implements BrowserController {
  final List<BrowserAction> executed = [];
  PageSnapshot page;
  _FakeBrowser(this.page);

  @override
  Widget buildView() => const SizedBox();

  @override
  bool get isReady => true;

  @override
  String? get currentUrl => page.url;

  @override
  Stream<BrowserEvent> get events => const Stream.empty();

  @override
  Future<void> loadUrl(String url) => execute(BrowserNavigate(url));

  @override
  Future<PageSnapshot> snapshot() async => page;

  @override
  Future<ActionResult> execute(BrowserAction action) async {
    executed.add(action);
    switch (action) {
      case BrowserTap(:final ref):
        if (!page.elements.any((e) => e.ref == ref)) {
          return ActionResult.error('ref-not-found', 'elemento "$ref" não existe');
        }
        return ActionResult.ok('clicado em $ref', snapshot: page);
      case BrowserNavigate(:final url):
        return ActionResult.ok('navegado para $url');
      default:
        return ActionResult.ok('ok ${action.kind}', snapshot: page);
    }
  }

  @override
  Future<void> dispose() async {}
}

PageSnapshot _page() => const PageSnapshot(
      url: 'https://example.com',
      title: 'Exemplo',
      text: 'Bem-vindo à página de exemplo',
      elements: [
        PageElement(ref: 'e1', tag: 'button', role: 'button', name: 'Enviar'),
        PageElement(ref: 'e2', tag: 'input', role: 'textbox', name: 'Pesquisa',
            inputType: 'text'),
      ],
      docId: 'd1',
      refEpoch: 3,
    );

void main() {
  group('BrowserAction (vocabulário fechado)', () {
    test('round-trip JSON de todas as ações', () {
      final actions = <BrowserAction>[
        const BrowserNavigate('https://x.dev'),
        const BrowserBack(),
        const BrowserForward(),
        const BrowserReload(),
        const BrowserTap('e3'),
        const BrowserTapAt(0.5, 0.25),
        const BrowserType(ref: 'e2', text: 'olá', submit: true),
        const BrowserScroll(0, 0.6),
        const BrowserSelect('e4', 'pt'),
        const BrowserSnapshot(),
        const BrowserExtract(),
        const BrowserEval('1+1'),
        const BrowserStop(),
      ];
      for (final a in actions) {
        final back = BrowserAction.fromJson(
            Map<String, dynamic>.from(jsonDecode(a.encode()) as Map));
        expect(back.kind, a.kind, reason: a.toString());
        expect(back.canonicalKey, a.canonicalKey);
      }
    });

    test('kind desconhecido lança FormatException', () {
      expect(() => BrowserAction.fromJson(const {'kind': 'hack'}),
          throwsFormatException);
    });

    test('canonicalKey é estável e distingue argumentos', () {
      const a = BrowserTap('e1');
      const b = BrowserTap('e2');
      expect(a.canonicalKey, 'tap(e1)');
      expect(a.canonicalKey, isNot(b.canonicalKey));
    });

    test('vocabulário do agente exclui eval/stop', () {
      expect(kAgentActionKinds, isNot(contains('eval')));
      expect(kAgentActionKinds, isNot(contains('stop')));
    });
  });

  group('PageSnapshot (refs + compactação)', () {
    test('round-trip JSON preserva docId/refEpoch', () {
      final s = PageSnapshot.decode(_page().encode());
      expect(s.docId, 'd1');
      expect(s.refEpoch, 3);
      expect(s.elements, hasLength(2));
    });

    test('toCompactText lista refs e trunca texto', () {
      final t = _page().toCompactText();
      expect(t, contains('e1 button "Enviar"'));
      expect(t, contains('e2 textbox "Pesquisa"'));
      expect(t, contains('URL: https://example.com'));
    });
  });

  group('Ponte JS (contrato)', () {
    test('expõe window.__oai com snapshot/act/ping', () {
      expect(kBrowserBridgeJs, contains('window.__oai'));
      expect(kBrowserBridgeJs, contains('snapshot'));
      expect(kBrowserBridgeJs, contains('act'));
      expect(kBrowserBridgeJs, contains('ping'));
    });

    test('tem guardas stale-doc e mascaramento de password', () {
      expect(kBrowserBridgeJs, contains('stale-doc'));
      expect(kBrowserBridgeJs, contains('stale-ref'));
      expect(kBrowserBridgeJs, contains("'•••'"));
    });

    test('usa native setter para inputs reativos e requestSubmit', () {
      expect(kBrowserBridgeJs, contains('Object.getOwnPropertyDescriptor'));
      expect(kBrowserBridgeJs, contains('requestSubmit'));
    });
  });

  group('BrowserPilot (decisor tipado + gates)', () {
    LayaResponse respond({
      String choice = 'tap:e1',
      double conf = 0.9,
      double act = 0.9,
      String goal = 'nao',
      String stuck = 'nao',
      String injection = 'nao',
      String irreversible = 'nao',
      String goalAllows = 'nao',
    }) {
      ChoiceAnswer ans(String id, String pick, double c) => ChoiceAnswer(
            id: id,
            choice: pick,
            probabilities: {pick: c},
            confidence: c,
            answerConfidence: c,
            actProbability: act,
          );
      return LayaResponse(
        answers: {
          'next_action': ans('next_action', choice, conf),
          'goal': ans('goal', goal, 0.9),
          'stuck': ans('stuck', stuck, 0.9),
          'injection': ans('injection', injection, 0.9),
          'irreversible': ans('irreversible', irreversible, 0.9),
          'goal_allows': ans('goal_allows', goalAllows, 0.9),
        },
        inputTokens: 10,
        latencyMs: 1,
      );
    }

    test('candidatos são fechados e concretos (sem refs inventáveis)', () {
      final pilot = BrowserPilot(engine: _UnusedLaya());
      final plan = pilot.buildPlan(objective: 'enviar formulário', page: _page());
      expect(plan.candidates.keys, contains('tap:e1'));
      expect(plan.candidates.keys, contains('type:e2'));
      expect(plan.candidates.keys, contains('done'));
      expect(plan.candidates.keys, contains('ask_user'));
      expect(plan.request.questions, hasLength(6));
    });

    test('confiança alta → act; média → escalate; baixa → abstain', () {
      final pilot = BrowserPilot(engine: _UnusedLaya());
      final plan = pilot.buildPlan(objective: 'x', page: _page());
      expect(pilot.mapDecision(respond(conf: 0.9), plan).disposition,
          PilotDisposition.act);
      expect(pilot.mapDecision(respond(conf: 0.6), plan).disposition,
          PilotDisposition.escalate);
      expect(pilot.mapDecision(respond(conf: 0.3), plan).disposition,
          PilotDisposition.abstain);
    });

    test('gate de prompt injection bloqueia a ação', () {
      final pilot = BrowserPilot(engine: _UnusedLaya());
      final plan = pilot.buildPlan(objective: 'x', page: _page());
      final d = pilot.mapDecision(respond(injection: 'sim'), plan);
      expect(d.disposition, PilotDisposition.abstain);
      expect(d.note, contains('injection'));
    });

    test('gate irreversível sem autorização → handoff', () {
      final pilot = BrowserPilot(engine: _UnusedLaya());
      final plan = pilot.buildPlan(objective: 'x', page: _page());
      final blocked = pilot.mapDecision(
          respond(irreversible: 'sim', goalAllows: 'nao'), plan);
      expect(blocked.disposition, PilotDisposition.abstain);
      expect(blocked.note, contains('irreversível'));
      final allowed = pilot.mapDecision(
          respond(irreversible: 'sim', goalAllows: 'sim'), plan);
      expect(allowed.disposition, PilotDisposition.act);
    });

    test('goal=sim termina; stuck=sim abstém-se', () {
      final pilot = BrowserPilot(engine: _UnusedLaya());
      final plan = pilot.buildPlan(objective: 'x', page: _page());
      expect(pilot.mapDecision(respond(goal: 'sim'), plan).disposition,
          PilotDisposition.done);
      expect(pilot.mapDecision(respond(stuck: 'sim'), plan).disposition,
          PilotDisposition.abstain);
    });

    test('escolha fora do leque → abstain (nunca inventa refs)', () {
      final pilot = BrowserPilot(engine: _UnusedLaya());
      final plan = pilot.buildPlan(objective: 'x', page: _page());
      final d = pilot.mapDecision(respond(choice: 'tap:e999'), plan);
      expect(d.disposition, PilotDisposition.abstain);
    });
  });

  group('browserTools (contrato de tools)', () {
    test('catálogo tem 7 tools com nomes estáveis', () async {
      final tools = browserTools(_FakeBrowser(_page()));
      expect(tools.map((t) => t.spec.name).toList(), [
        'browser_snapshot',
        'browser_goto',
        'browser_click',
        'browser_type',
        'browser_select',
        'browser_scroll',
        'browser_extract',
      ]);
    });

    test('browser_click com ref inexistente → error com motivo', () async {
      final browser = _FakeBrowser(_page());
      final tools = browserTools(browser);
      final click = tools.firstWhere((t) => t.spec.name == 'browser_click');
      final out = await click.handler({'ref': 'e999'});
      expect(out, startsWith('error'));
      expect(out, contains('e999'));
    });

    test('browser_type sem text usa o texto do utilizador', () async {
      final browser = _FakeBrowser(_page());
      final tools = browserTools(browser, typeText: () => 'do utilizador');
      final type = tools.firstWhere((t) => t.spec.name == 'browser_type');
      final out = await type.handler({'ref': 'e2'});
      expect(out, startsWith('ok'));
      final sent = browser.executed.single as BrowserType;
      expect(sent.text, 'do utilizador');
      expect(sent.submit, isFalse);
    });

    test('browser_goto sem url → error de argumentos', () async {
      final tools = browserTools(_FakeBrowser(_page()));
      final go = tools.firstWhere((t) => t.spec.name == 'browser_goto');
      final out = await go.handler(const {});
      expect(out, startsWith('error'));
    });

    test('todos os handlers devolvem prefixo de status explícito', () async {
      final tools = browserTools(_FakeBrowser(_page()));
      for (final t in tools) {
        final Map<String, dynamic> args = switch (t.spec.name) {
          'browser_goto' => {'url': 'https://x.dev'},
          'browser_click' => {'ref': 'e1'},
          'browser_type' => {'ref': 'e2', 'text': 'olá'},
          'browser_select' => {'ref': 'e1', 'value': 'a'},
          'browser_scroll' => {'direction': 'down'},
          _ => <String, dynamic>{},
        };
        final out = await t.handler(args);
        expect(out, matches(RegExp(r'^(ok|no_results|error)')),
            reason: '${t.spec.name} → $out');
      }
    });

    test('validação de schema rejeita argumentos ausentes', () async {
      final tools = browserTools(_FakeBrowser(_page()));
      final click = tools.firstWhere((t) => t.spec.name == 'browser_click');
      expect(click.spec.params.single.required, isTrue);
    });
  });
}

/// Motor Laya que NUNCA deve ser chamado (testes puros de mapeamento).
class _UnusedLaya implements LayaEngine {
  @override
  bool get isLoaded => false;

  @override
  String get modelId => 'unused';

  @override
  Future<void> load({
    required String modelPath,
    required String tokenizerPath,
    required LayaConfig config,
  }) async {}

  @override
  Future<LayaResponse> decide(LayaRequest request) =>
      throw UnsupportedError('o motor não deve ser chamado em testes puros');

  @override
  Future<void> unload() async {}
}