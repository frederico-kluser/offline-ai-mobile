/// E2E de inferência no dispositivo/simulador — corre DENTRO da app.
///
/// Fecha a lacuna registada: inferência real dos dois motores no iOS (e no
/// Android, quando correr lá). Usa os modelos instalados em
/// `<documents>/models/` (ver Modelos). Correr com:
///
///   flutter test integration_test -d `<sim-udid>`
///
/// Asserções determinísticas onde possível (Laya = validado 8/8 contra
/// oráculo); para o LLM (Metal/CPU difere de Android) as asserções são de
/// contrato, não de texto exato.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:offline_ai_mobile/src/agent/tool_loop.dart';
import 'package:offline_ai_mobile/src/agent/tools.dart';
import 'package:offline_ai_mobile/src/domain/laya_types.dart';
import 'package:offline_ai_mobile/src/domain/llm_config.dart';
import 'package:offline_ai_mobile/src/domain/templates.dart';
import 'package:offline_ai_mobile/src/engines/laya_engine_onnx.dart';
import 'package:offline_ai_mobile/src/engines/llm_engine.dart';
import 'package:offline_ai_mobile/src/engines/llm_engine_llama.dart';
import 'package:offline_ai_mobile/src/guardrails/loop_guard.dart';
import 'package:path_provider/path_provider.dart';

Future<String> _modelsDir() async {
  final docs = await getApplicationDocumentsDirectory();
  return '${docs.path}/models';
}

/// Caminhos de fallback do host (o iOS Simulator partilha o filesystem do
/// Mac — os modelos pré-descarregados em dev servem de fonte sem cópias).
const String _hostModels = '/Volumes/Ext2TB/tmp-models';

/// Resolve um modelo: primeiro o instalado na app (`<documents>/models/...`),
/// depois o fallback do host. `null` = não disponível (o teste salta).
Future<String?> _modelPath(String rel, String hostFallback) async {
  final dir = await _modelsDir();
  final inApp = '$dir/$rel';
  if (File(inApp).existsSync()) return inApp;
  if (File(hostFallback).existsSync()) return hostFallback;
  return null;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Laya decide em dispositivo (valores do oráculo)', (t) async {
    final model = await _modelPath('laya-typed-onnx/model_q4.onnx',
        '$_hostModels/laya/model_q4.onnx');
    final tokenizer = await _modelPath('laya-typed-onnx/tokenizer.json',
        '$_hostModels/laya/tokenizer.json');
    if (model == null || tokenizer == null) {
      // ignore: avoid_print
      print('SKIP laya: modelo não instalado');
      return;
    }
    final engine = LayaOnnxEngine();
    await engine.load(
      modelPath: model,
      tokenizerPath: tokenizer,
      config: const LayaConfig(),
    );
    final tpl = kLayaTemplates.first; // Roteamento de ticket (PT)
    final res = await engine
        .decide(tpl.requestWithState(tpl.stateExample))
        .timeout(const Duration(minutes: 2));
    await engine.unload();

    expect(res.answers.length, 3);
    final dep = res.answers['department'] as ChoiceAnswer;
    expect(dep.choice, 'billing',
        reason: 'oráculo Python: billing 0.94 (doc: 0.9364)');
    final urg = res.answers['urgency'] as ChoiceAnswer;
    expect(urg.choice, 'urgent',
        reason: 'oráculo Python: urgent 0.83 (doc: 0.8307)');
    final fr = res.answers['frustration'] as ScoreAnswer;
    // O ARGMAX é estável entre plataformas (department/urgency passam); o
    // valor esperado do score deriva com o drift numérico FP entre kernels
    // (Android x86_64 vs iOS arm64/Accelerate) — documento §Q6: 2,2% de
    // amostras divergem mesmo em FP32. Tolerância ampla + modo estável.
    expect(fr.score, inInclusiveRange(0.9, 1.9),
        reason: 'oráculo 1.37 · iOS 1.21 · drift FP entre plataformas');
    expect(fr.probabilities['2'], greaterThan(fr.probabilities['0'] ?? 1),
        reason: 'modo = Muito furioso, como no oráculo');
    expect(res.outputTokens, 0);
  });

  testWidgets('MiniCPM5-2B gera texto com a receita anti-loop', (t) async {
    final model = await _modelPath('minicpm5-q4km/MiniCPM5-2B-Q4_K_M.gguf',
        '$_hostModels/MiniCPM5-2B-Q4_K_M.gguf');
    if (model == null) {
      // ignore: avoid_print
      print('SKIP llm: modelo não instalado');
      return;
    }
    final LlmEngine engine = LlamaFfiEngine();
    await engine
        .load(modelPath: model, config: const LlmConfig())
        .timeout(const Duration(minutes: 3));

    const cfg = LlmConfig(seed: 42, maxTokens: 48);
    final events = <GenEvent>[];
    await for (final ev in engine.generate(
      messages: const [
        ChatMessage('system', 'Responde em português, muito em breve.'),
        ChatMessage('user', 'Diz apenas: sistema pronto.'),
      ],
      config: cfg,
    )) {
      events.add(ev);
    }
    await engine.unload();

    final deltas =
        events.whereType<GenDelta>().map((e) => e.text).join().trim();
    final end = events.whereType<GenEnd>().single;
    expect(deltas, isNotEmpty, reason: 'o modelo tem de gerar texto');
    expect(end.stopReason, anyOf('eos', 'max_tokens', 'stop_string'));
    expect(end.outputTokens, lessThanOrEqualTo(48),
        reason: 'max_tokens é teto rígido');
  });

  testWidgets('ToolLoop completa SEM loop (guardrails)', (t) async {
    final model = await _modelPath('minicpm5-q4km/MiniCPM5-2B-Q4_K_M.gguf',
        '$_hostModels/MiniCPM5-2B-Q4_K_M.gguf');
    if (model == null) {
      // ignore: avoid_print
      print('SKIP toolloop: modelo não instalado');
      return;
    }
    final LlmEngine engine = LlamaFfiEngine();
    await engine
        .load(modelPath: model, config: const LlmConfig())
        .timeout(const Duration(minutes: 3));

    final loop = ToolLoop(
      llm: engine,
      tools: demoTools({}),
      guardConfig: const LoopGuardConfig(maxSteps: 6, tokenBudget: 1024),
    );
    ToolLoopResult? result;
    await for (final ev in loop.run(
      userPrompt: 'Calcula 17*23+5 e guarda o resultado na nota "res".',
      config: const LlmConfig(seed: 42, maxTokens: 256),
    )) {
      if (ev is LoopEnd) result = ev.result;
    }
    await engine.unload();

    expect(result, isNotNull, reason: 'o loop tem de terminar sempre');
    final r = result!;
    // Contrato anti-loop: termina com motivo explícito e nunca em ciclo.
    expect(r.stopReason, isNot(StopReason.cycleDetected));
    expect(r.stopReason, isNot(StopReason.repetitionDetected));
    expect(r.stopReason, isNot(StopReason.maxSteps));
    expect(r.answer, isNotEmpty);
    // ignore: avoid_print
    print('TOOLLOOP: stop=${r.stopReason.wire} passos=${r.log.length} '
        'tools=${r.toolResults.map((e) => e.name).toList()} resposta=${r.answer}');
  });
}