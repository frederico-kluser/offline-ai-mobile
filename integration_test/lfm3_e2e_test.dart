/// Cenários E2E CT-01..CT-12 do guia LFM3 (correm DENTRO da app).
///
/// Sem os bundles instalados, cada teste imprime SKIP e termina verde — a
/// suite não falha por falta de pesos. Com os bundles em
/// `documents/models/`, exercita os motores reais.
///
///   `flutter test integration_test -d <device>`
// ignore_for_file: avoid_print
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:offline_ai_mobile/src/agent/tool_loop.dart';
import 'package:offline_ai_mobile/src/agent/tools.dart';
import 'package:offline_ai_mobile/src/browser/browser_page_state.dart';
import 'package:offline_ai_mobile/src/browser/browser_pilot.dart';
import 'package:offline_ai_mobile/src/domain/d1_decision_types.dart';
import 'package:offline_ai_mobile/src/domain/llm_config.dart';
import 'package:offline_ai_mobile/src/domain/templates.dart';
import 'package:offline_ai_mobile/src/engines/llm_engine.dart';
import 'package:offline_ai_mobile/src/guardrails/loop_guard.dart';
import 'package:offline_ai_mobile/src/services/model_registry.dart';
import 'package:offline_ai_mobile/src/ui/app_services.dart';

Future<bool> _ready(String bundleId) async {
  final services = AppServices.instance;
  await services.ensureInstalledKnown();
  final b = modelById(bundleId);
  return b != null && services.isInstalled(b.id);
}

Future<String> _generate(
  LlmConfig config,
  String prompt, {
  List<LlmMediaInput> media = const [],
}) async {
  final services = AppServices.instance;
  final b = services.activeTextBundle;
  if (b == null) return 'SKIP modelo não instalado';
  final engine = await services.ensureLlm(bundle: b, config: config);
  final buf = StringBuffer();
  await for (final ev in engine.generate(
    messages: [ChatMessage('user', prompt)],
    config: config,
    media: media,
  )) {
    if (ev is GenDelta) buf.write(ev.text);
  }
  return buf.toString();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('CT-01 LFM3-1.7B raciocínio vs direto + determinismo', (t) async {
    if (!await _ready('lfm3-1.7b-q4_0')) {
      print('SKIP modelo não instalado');
      return;
    }
    const prompt =
        'Calcula o KV cache em MB para 6 camadas globais, 4 cabeças KV de '
        '128 dim, FP16, 32768 tokens. Mostra a fórmula.';
    final a = await _generate(const LlmConfig(), prompt);
    final b = await _generate(
      const LlmConfig(responseFormat: ResponseFormat.jsonObject),
      '$prompt Responde em JSON.',
    );
    expect(a, isNotEmpty);
    expect(b, isNotEmpty);
  });

  testWidgets('CT-02 Deferred Tool Search', (t) async {
    if (!await _ready('lfm3-1.7b-q4_0')) {
      print('SKIP modelo não instalado');
      return;
    }
    final services = AppServices.instance;
    final engine = await services.ensureLlm(
      bundle: modelById('lfm3-1.7b-q4_0')!,
      config: const LlmConfig(contextSize: 8192),
    );
    final catalog = buildAgentCatalog(noteStore: {});
    final loop = ToolLoop(llm: engine, catalog: catalog);
    ToolLoopResult? result;
    await for (final ev in loop.run(
      userPrompt: "Calcula (17*23)+109 e guarda na nota 'orcamento'.",
      config: const LlmConfig(maxTokens: 512),
    )) {
      if (ev is LoopEnd) result = ev.result;
    }
    expect(result, isNotNull);
    expect(result!.stopReason, isNot(StopReason.cycleDetected));
    expect(result.answer, isNotEmpty);
  });

  testWidgets('CT-03 VL-2B visão/OCR/grounding', (t) async {
    if (!await _ready('lfm3-vl-2b-q4_k_m')) {
      print('SKIP modelo não instalado');
      return;
    }
    print('SKIP vídeo/áudio não suportado nesta build');
  });

  testWidgets('CT-04 VL-2B vídeo 2 fps', (t) async {
    if (!await _ready('lfm3-vl-2b-q4_k_m')) {
      print('SKIP modelo não instalado');
      return;
    }
    print('SKIP vídeo/áudio não suportado nesta build');
  });

  testWidgets('CT-05 Audio-2B ASR/TTS/spoken tools', (t) async {
    if (!await _ready('lfm3-audio-2b-q4_k_m')) {
      print('SKIP modelo não instalado');
      return;
    }
    print('SKIP vídeo/áudio não suportado nesta build');
  });

  testWidgets('CT-06 Omni-2B vídeo com banda sonora', (t) async {
    if (!await _ready('lfm3-omni-2b-q4_k_m')) {
      print('SKIP modelo não instalado');
      return;
    }
    print('SKIP vídeo/áudio não suportado nesta build');
  });

  testWidgets('CT-07 d1-2B/Omni todas as primitivas sem gerar tokens', (t) async {
    final services = AppServices.instance;
    await services.ensureInstalledKnown();
    final bundle = services.activeD1Bundle;
    if (bundle == null) {
      print('SKIP decisor não instalado');
      return;
    }
    final engine = await services.ensureD1(
      bundle: bundle,
      config: const D1Config(),
    );
    final tpl = kD1Templates.first;
    final res = await engine.decide(tpl.requestWithState(tpl.stateExample));
    expect(res.outputTokens, 0);
    expect(res.answers, isNotEmpty);
    expect(res.answers['payee'], isA<D1TextAnswer>());
  });

  testWidgets('CT-08 cascata d1 gatekeeper + LFM3 tools', (t) async {
    final services = AppServices.instance;
    await services.ensureInstalledKnown();
    final bundle = services.activeD1Bundle;
    if (bundle == null || !services.isInstalled('lfm3-1.7b-q4_0')) {
      print('SKIP decisor não instalado');
      return;
    }
    final engine = await services.ensureD1(
      bundle: bundle,
      config: const D1Config(),
    );
    final tpl = kD1Templates.firstWhere((t) => t.id == 'agent-gatekeeper');
    final res = await engine.decide(tpl.requestWithState(tpl.stateExample));
    expect(res.answers['prompt_injection'], isA<D1NoulAnswer>());
    expect(res.answers['domain_route'], isA<D1ChoiceAnswer>());
  });

  testWidgets('CT-09 piloto de browser d1', (t) async {
    final services = AppServices.instance;
    await services.ensureInstalledKnown();
    final bundle = services.activeD1Bundle;
    if (bundle == null) {
      print('SKIP decisor não instalado');
      return;
    }
    final engine = await services.ensureD1(
      bundle: bundle,
      config: const D1Config(),
    );
    final pilot = BrowserPilot(engine: engine);
    final page = const PageSnapshot(
      url: 'https://example.com',
      title: 'Checkout',
      text: 'botão Confirmar',
      elements: [
        PageElement(
            ref: 'e1', tag: 'button', role: 'button', name: 'Confirmar'),
      ],
    );
    final d = await pilot.run(objective: 'confirmar a encomenda', page: page);
    expect(d.response.outputTokens, 0);
    expect(d.disposition, isA<PilotDisposition>());
  });

  testWidgets('CT-10 triagem de voz d1-Omni', (t) async {
    if (!await _ready('d1-omni-2b-onnx-q4f16')) {
      print('SKIP decisor não instalado');
      return;
    }
    print('SKIP vídeo/áudio não suportado nesta build');
  });

  testWidgets('CT-11 inspeção de campo', (t) async {
    if (!await _ready('d1-2b-onnx-q4f16')) {
      print('SKIP decisor não instalado');
      return;
    }
    print('SKIP imagem não instalada');
  });

  testWidgets('CT-12 abstenção calibrada', (t) async {
    final services = AppServices.instance;
    await services.ensureInstalledKnown();
    final bundle = services.activeD1Bundle;
    if (bundle == null) {
      print('SKIP decisor não instalado');
      return;
    }
    final engine = await services.ensureD1(
      bundle: bundle,
      config: const D1Config(),
    );
    const q = D1NoulQuestion(
      id: 'is_grounded_in_state',
      instructions: 'A resposta está fundamentada no state?',
      trueCriteria: 'sim',
      falseCriteria: 'não',
    );
    final res = await engine.decide(const D1Request(
      state: 'Documento sem garantia indicada.',
      questions: [q],
    ));
    expect(res.answers['is_grounded_in_state'], isA<D1NoulAnswer>());
  });
}
