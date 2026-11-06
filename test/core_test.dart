/// Testes do núcleo determinístico LFM3: chat template, parser XML, guardrails,
/// catálogo de ferramentas e presets de amostragem.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_ai_mobile/src/agent/lfm3_chat.dart';
import 'package:offline_ai_mobile/src/agent/tools.dart';
import 'package:offline_ai_mobile/src/domain/llm_config.dart';
import 'package:offline_ai_mobile/src/domain/tool_spec.dart';
import 'package:offline_ai_mobile/src/engines/llm_engine.dart';
import 'package:offline_ai_mobile/src/guardrails/loop_guard.dart';

class _Key implements ToolCallKey {
  @override
  final String canonicalKey;
  const _Key(this.canonicalKey);
}

String toolCallXml(String fn, Map<String, String> args) {
  final buf = StringBuffer('<tool_call><function=$fn>');
  args.forEach((k, v) {
    buf.write('<parameter=$k>$v</parameter>');
  });
  buf.write('</function></tool_call>');
  return buf.toString();
}

void main() {
  group('Lfm3OutputParser', () {
    test('separa <think>, texto visível e tool call com JSON tipado', () {
      final raw = '<think>Vou calcular.</think>'
          '${toolCallXml('calc_expression', {'expression': '"17*23+109"'})}'
          'depois guardo.';
      final parsed = Lfm3OutputParser.parse(raw);
      expect(parsed.thinkingContent, 'Vou calcular.');
      expect(parsed.visibleContent, 'depois guardo.');
      expect(parsed.toolCalls, hasLength(1));
      expect(parsed.toolCalls.first.name, 'calc_expression');
      expect(parsed.toolCalls.first.arguments['expression'], '17*23+109');
    });

    test('múltiplos tool calls e valores não-JSON ficam texto', () {
      final raw = toolCallXml('note_save', {'key': 'res', 'value': '500'}) +
          toolCallXml('set_alarm', {'time': '15:00'});
      final parsed = Lfm3OutputParser.parse(raw);
      expect(parsed.toolCalls, hasLength(2));
      expect(parsed.toolCalls[1].arguments['time'], '15:00');
      expect(parsed.visibleContent, isEmpty);
    });

    test('additional_tools é extraído do tool response', () {
      final raw = '<tool_response>ok<additional_tools>'
          '{"type":"function","function":{"name":"calc_expression"}}'
          '</additional_tools></tool_response>';
      final parsed = Lfm3OutputParser.parse(raw);
      expect(parsed.additionalTools, hasLength(1));
      expect(parsed.additionalTools.first['function']['name'],
          'calc_expression');
    });

    test('formatToolResponse embrulha em <tool_response>', () {
      final out = formatToolResponse(
        {'status': 'ok'},
        newlyDiscoveredToolSchemas: [
          {'type': 'function', 'function': {'name': 'x'}}
        ],
      );
      expect(out, contains('<|im_start|>tool'));
      expect(out, contains('<tool_response>'));
      expect(out, contains('<additional_tools>'));
      expect(out, contains('</tool_response>'));
    });
  });

  group('renderChat (ChatML LFM3)', () {
    test('system + tools + generation prompt com <think>', () {
      final prompt = renderChat(
        const [
          ChatMessage('system', 'És um agente.'),
          ChatMessage('user', 'Olá'),
        ],
        tools: const [
          ToolSpec(
            name: 'search_tools',
            description: 'procura',
            params: [
              ParamSpec(name: 'query', type: 'string', description: 'query'),
            ],
          ),
        ],
        enableThinking: true,
        deferredTools: true,
      );
      expect(prompt, startsWith('<|startoftext|>'));
      expect(prompt, contains('<|im_start|>system'));
      expect(prompt, contains('<tools>'));
      expect(prompt, contains(kDeferredToolsInstruction));
      expect(prompt, contains('<|im_start|>user\nOlá<|im_end|>'));
      expect(prompt, endsWith('<|im_start|>assistant\n<think>\n'));
    });

    test('enableThinking=false pré-preenche <think></think>', () {
      final prompt = renderChat(
        const [ChatMessage('user', 'Olá')],
        enableThinking: false,
      );
      expect(prompt, contains('<think></think>'));
      expect(prompt, isNot(endsWith('<think>\n')));
    });

    test('tool message usa role tool e additional_tools', () {
      final prompt = renderChat(
        const [
          ChatMessage('user', 'faz'),
          ChatMessage('tool', 'ok',
              toolName: 'x',
              additionalTools: [
                {'type': 'function', 'function': {'name': 'y'}}
              ]),
        ],
        enableThinking: false,
      );
      expect(prompt, contains('<|im_start|>tool'));
      expect(prompt, contains('<tool_response>'));
      expect(prompt, contains('<additional_tools>'));
    });
  });

  group('LoopGuard', () {
    test('corta no maxSteps com motivo explícito', () {
      final g = LoopGuard(config: const LoopGuardConfig(maxSteps: 3));
      for (var i = 0; i < 3; i++) {
        expect(g.beforeModelStep(tokensSoFar: 0), isTrue);
      }
      expect(g.beforeModelStep(tokensSoFar: 0), isFalse);
      expect(g.state.stop, StopReason.maxSteps);
    });

    test('corta ciclo A→A→A na 3.ª repetição', () {
      final g = LoopGuard(config: const LoopGuardConfig(maxToolCalls: 10));
      expect(g.beforeToolCall(const _Key('calc({"x":1})')), isTrue);
      expect(g.beforeToolCall(const _Key('calc({"x":1})')), isTrue);
      expect(g.beforeToolCall(const _Key('calc({"x":1})')), isFalse);
      expect(g.state.stop, StopReason.cycleDetected);
    });

    test('corta ping-pong A→B→A→B', () {
      final g = LoopGuard(
          config:
              const LoopGuardConfig(maxIdenticalCalls: 5, maxToolCalls: 20));
      expect(g.beforeToolCall(const _Key('A(1)')), isTrue);
      expect(g.beforeToolCall(const _Key('B(1)')), isTrue);
      expect(g.beforeToolCall(const _Key('A(1)')), isTrue);
      expect(g.beforeToolCall(const _Key('B(1)')), isFalse);
      expect(g.state.stop, StopReason.cycleDetected);
    });

    test('search_tools → tool_X é permitido', () {
      final g = LoopGuard(
          config: const LoopGuardConfig(maxIdenticalCalls: 2, maxToolCalls: 10));
      expect(g.beforeToolCall(const _Key('search_tools({"query":"calc"})')),
          isTrue);
      expect(g.beforeToolCall(const _Key('calc({"x":1})')), isTrue);
      expect(g.state.stop, isNull);
    });

    test('search_tools com a mesma query duas vezes corta', () {
      final g = LoopGuard(config: const LoopGuardConfig(maxToolCalls: 10));
      const key = 'search_tools({"query":"calc"})';
      expect(g.beforeToolCall(const _Key(key)), isTrue);
      expect(g.beforeToolCall(const _Key('calc({"x":1})')), isTrue);
      expect(g.beforeToolCall(const _Key(key)), isFalse);
      expect(g.state.stop, StopReason.cycleDetected);
    });

    test('teto de raciocínio corta', () {
      final g = LoopGuard(
          config: const LoopGuardConfig(maxThinkingTokens: 10));
      expect(g.addThinkingTokens(6), isTrue);
      expect(g.addThinkingTokens(5), isFalse);
      expect(g.state.stop, StopReason.thinkingBudgetExhausted);
    });

    test('deteta repetição degenerada SER@4', () {
      final g = LoopGuard(
          config: const LoopGuardConfig(
              repetitionWindow: 64, repetitionLimit: 3));
      const unit = 'as informações são as informações são';
      expect(g.checkTextRepetition('$unit $unit $unit $unit'), isFalse);
      expect(g.state.stop, StopReason.repetitionDetected);
    });
  });

  group('catálogo de ferramentas', () {
    test('50+ ferramentas deferidas + search_tools ativa', () {
      final catalog = buildAgentCatalog(noteStore: {});
      expect(catalog.deferred.length, greaterThanOrEqualTo(50));
      expect(catalog.active.map((t) => t.spec.name), contains('search_tools'));
      expect(catalog.active.map((t) => t.spec.name), contains('final_answer'));
    });

    test('search_tools devolve schemas para o próximo passo', () async {
      final catalog = buildAgentCatalog(noteStore: {});
      final search =
          catalog.active.firstWhere((t) => t.spec.name == 'search_tools');
      final r = await runTool(search, {'query': 'calculator note save'});
      expect(r.ok, isTrue);
      expect(r.output, contains('calc_expression'));
      expect(r.output, contains('note_save'));
      expect(r.output, contains('"schemas"'));
    });

    test('calculadora segura', () async {
      final catalog = buildAgentCatalog(noteStore: {});
      final calc = catalog.byName('calc_expression')!;
      final r = await runTool(calc, {'expression': '(17*23)+109'});
      expect(r.output, 'ok: (17*23)+109 = 500');
    });

    test('notas save/read/no_results', () {
      final store = <String, String>{};
      final catalog = buildAgentCatalog(noteStore: store);
      final save = catalog.byName('note_save')!;
      final read = catalog.byName('note_read')!;
      return Future(() async {
        final r1 = await runTool(save, {'key': 'res', 'value': '500'});
        expect(r1.output, contains('guardada'));
        final r2 = await runTool(read, {'key': 'res'});
        expect(r2.output, 'ok: 500');
        final r3 = await runTool(read, {'key': 'outra'});
        expect(r3.output, startsWith('no_results'));
      });
    });

    test('validação de schema rejeita argumentos inválidos', () {
      const spec = ToolSpec(
        name: 'calculator',
        description: 'calcula',
        params: [
          ParamSpec(name: 'expression', type: 'string', description: 'expr'),
        ],
      );
      expect(() => validateToolArgs(spec, {'expression': '1+1'}),
          returnsNormally);
      expect(() => validateToolArgs(spec, {'expression': 1}),
          throwsA(isA<ToolValidationError>()));
    });
  });

  group('LlmConfig LFM3', () {
    test('defaults do perfil de agente', () {
      const c = LlmConfig();
      expect(c.profile, Lfm3Profile.agent);
      expect(c.temperature, 0.1);
      expect(c.topK, 50);
      expect(c.topP, 1.0);
      expect(c.minP, 0.0);
      expect(c.repeatPenalty, 1.1);
      expect(c.seed, 42);
      expect(c.enableThinking, isTrue);
      expect(c.validate(), isEmpty);
    });

    test('perfis oficiais', () {
      final math = LlmConfig.forProfile(Lfm3Profile.math);
      expect(math.temperature, 1.0);
      expect(math.topK, 20);
      expect(math.topP, 0.95);
      final asr = LlmConfig.forProfile(Lfm3Profile.audioAsr);
      expect(asr.temperature, 0.0);
      expect(asr.enableThinking, isFalse);
      expect(asr.suppressMixed, isTrue);
      final omni = LlmConfig.forProfile(Lfm3Profile.omni);
      expect(omni.enableThinking, isFalse);
      expect(omni.audioTemperature, 0.4);
    });

    test('estimativa de KV cache a 32K', () {
      const c = LlmConfig();
      final bytes = c.estimatedKvBytes(contextTokens: 32768);
      // 6 camadas globais × 4 KV heads × 128 dim × 2 × 32768 × 2 bytes
      // + estado fixo de convolução/SWA ≈ 403 MB.
      expect(bytes, greaterThan(380 * 1024 * 1024));
      expect(bytes, lessThan(410 * 1024 * 1024));
      final q8 = c.estimatedKvBytes(
          contextTokens: 32768, type: KvCacheType.q8_0);
      expect(q8, lessThan(bytes));
    });

    test('validação bloqueia configs perigosas', () {
      const bad = LlmConfig(seed: -1, maxTokens: 0, repeatPenalty: 2);
      expect(bad.validate(), hasLength(greaterThanOrEqualTo(3)));
    });

    test('fingerprint estável e sensível', () {
      const a = LlmConfig();
      const b = LlmConfig(seed: 43);
      expect(a.fingerprint, const LlmConfig().fingerprint);
      expect(a.fingerprint, isNot(b.fingerprint));
    });
  });
}
