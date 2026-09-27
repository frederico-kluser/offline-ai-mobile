/// Testes do núcleo determinístico: guardrails anti-loop, parser de tool
/// calls do MiniCPM5, validação de schema, calculadora segura e configuração.
library;

import 'package:flutter_test/flutter_test.dart' hide Tags;
import 'package:offline_ai_mobile/src/agent/minicpm5_chat.dart';
import 'package:offline_ai_mobile/src/agent/tools.dart';
import 'package:offline_ai_mobile/src/domain/llm_config.dart';
import 'package:offline_ai_mobile/src/domain/tool_spec.dart';
import 'package:offline_ai_mobile/src/guardrails/loop_guard.dart';

class _Key implements ToolCallKey {
  @override
  final String canonicalKey;
  const _Key(this.canonicalKey);
}

/// Constrói o XML de um tool call SEM literais de markup (usa [Tags]).
String toolCallXml(String fn, Map<String, String> args) {
  final buf = StringBuffer(Tags.openAttr('function', fn));
  args.forEach((k, v) {
    buf.write(Tags.openAttr('param', k));
    buf.write(v);
    buf.write(Tags.paramClose);
  });
  buf.write(Tags.functionClose);
  return buf.toString();
}

void main() {
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
          config: const LoopGuardConfig(
              maxIdenticalCalls: 5, maxToolCalls: 20));
      expect(g.beforeToolCall(const _Key('A(1)')), isTrue);
      expect(g.beforeToolCall(const _Key('B(1)')), isTrue);
      expect(g.beforeToolCall(const _Key('A(1)')), isTrue);
      expect(g.beforeToolCall(const _Key('B(1)')), isFalse);
      expect(g.state.stop, StopReason.cycleDetected);
    });

    test('deteta repetição degenerada SER@4', () {
      final g = LoopGuard(
          config: const LoopGuardConfig(
              repetitionWindow: 64, repetitionLimit: 3));
      const unit = 'as informações são as informações são';
      expect(g.checkTextRepetition('$unit $unit $unit $unit'), isFalse);
      expect(g.state.stop, StopReason.repetitionDetected);
    });

    test('texto normal não dispara o corte', () {
      final g = LoopGuard();
      expect(
          g.checkTextRepetition(
              'O resultado do cálculo é 391 e fica guardado na nota res.'),
          isTrue);
    });

    test('orçamento de tokens corta com motivo', () {
      final g = LoopGuard(config: const LoopGuardConfig(tokenBudget: 10));
      expect(g.addTokens(6), isTrue);
      expect(g.addTokens(5), isFalse);
      expect(g.state.stop, StopReason.tokenBudgetExhausted);
    });
  });

  group('parseToolCalls (formato MiniCPM5)', () {
    test('extrai function/param simples', () {
      final raw =
          'Vou calcular: ${toolCallXml('calculator', {'expression': '17*23+5'})} '
          'e depois respondo.';
      final parsed = parseToolCalls(raw);
      expect(parsed.calls, hasLength(1));
      expect(parsed.calls.first.name, 'calculator');
      expect(parsed.calls.first.args['expression'], '17*23+5');
      expect(parsed.text, contains('Vou calcular'));
      expect(parsed.text, contains('depois respondo'));
    });

    test('extrai múltiplos tool calls com coerção de tipos', () {
      final spec = const ToolSpec(
        name: 'note_save',
        description: 'guarda nota',
        params: [
          ParamSpec(name: 'key', type: 'string', description: 'chave'),
          ParamSpec(name: 'value', type: 'string', description: 'valor'),
        ],
      );
      final raw = toolCallXml('note_save', {'key': 'res', 'value': '391'}) +
          toolCallXml('calculator', {'expression': '2+2'});
      final parsed = parseToolCalls(raw, specs: const []);
      expect(parsed.calls, hasLength(2));
      expect(parsed.calls[0].name, 'note_save');
      expect(parsed.calls[1].args['expression'], '2+2');
      expect(spec.canonicalSig, 'key:string,value:string');
    });

    test('CDATA é desembrulhado', () {
      final lt = Tags.lt;
      final raw = toolCallXml('note_save', {
        'key': 'k',
        'value':
            '${Tags.cdataOpen}linha1${Tags.lt}b${Tags.gt}\nlinha2${Tags.cdataClose}',
      });
      final parsed = parseToolCalls(raw);
      expect(parsed.calls.first.args['value'],
          contains('linha1${lt}b${Tags.gt}\nlinha2'));
    });

    test('texto sem tool calls passa integro', () {
      final parsed = parseToolCalls('A resposta é 391.');
      expect(parsed.hasCalls, isFalse);
      expect(parsed.text, 'A resposta é 391.');
    });
  });

  group('validateToolArgs', () {
    const spec = ToolSpec(
      name: 'calculator',
      description: 'calcula',
      params: [
        ParamSpec(name: 'expression', type: 'string', description: 'expr'),
      ],
    );

    test('aceita argumentos válidos', () {
      expect(() => validateToolArgs(spec, {'expression': '1+1'}),
          returnsNormally);
    });

    test('rejeita parâmetro desconhecido', () {
      expect(
          () => validateToolArgs(spec, {'expression': '1', 'hack': 'x'}),
          throwsA(isA<ToolValidationError>()));
    });

    test('rejeita obrigatório em falta', () {
      expect(() => validateToolArgs(spec, {}),
          throwsA(isA<ToolValidationError>()));
    });

    test('rejeita tipo errado (não conserta em silêncio)', () {
      expect(() => validateToolArgs(spec, {'expression': 42}),
          throwsA(isA<ToolValidationError>()));
    });
  });

  group('ferramentas locais', () {
    test('calculadora: aritmética exata', () async {
      final tools = demoTools({});
      final calc = tools.first;
      final r = await runTool(calc, {'expression': '17*23+5'});
      expect(r.ok, isTrue);
      expect(r.output, 'ok: 17*23+5 = 396');
    });

    test('calculadora: erro determinístico sem rebentar', () async {
      final calc = demoTools({}).first;
      final r = await runTool(calc, {'expression': '1/0'});
      expect(r.output, startsWith('error:'));
      expect(r.errorKind, isNull); // erro da ferramenta, não de schema
    });

    test('calculadora: rejeita símbolo estranho (sem eval)', () async {
      final calc = demoTools({}).first;
      final r = await runTool(calc, {'expression': 'system("rm")'});
      expect(r.output, startsWith('error:'));
    });

    test('notas: save/read/no_results', () async {
      final store = <String, String>{};
      final tools = demoTools(store);
      final save = tools[1];
      final read = tools[2];
      final r1 = await runTool(save, {'key': 'res', 'value': '391'});
      expect(r1.output, contains('guardada'));
      final r2 = await runTool(read, {'key': 'res'});
      expect(r2.output, 'ok: 391');
      final r3 = await runTool(read, {'key': 'outra'});
      expect(r3.output, startsWith('no_results'));
    });

    test('argumento inválido vira resultado estruturado', () async {
      final calc = demoTools({}).first;
      final r = await runTool(calc, {});
      expect(r.ok, isFalse);
      expect(r.errorKind, 'schema-invalid');
    });

    test('truncagem com marcador explícito', () {
      final out = truncateToolOutput('x' * 5000, maxChars: 100);
      expect(out.length, lessThan(200));
      expect(out, contains('truncado'));
    });
  });

  group('LlmConfig (determinismo)', () {
    test('defaults seguem a receita oficial anti-loop', () {
      const c = LlmConfig();
      expect(c.minP, 0.0);
      expect(c.temperature, 1.0);
      expect(c.topP, 0.95);
      expect(c.seed, 42);
      expect(c.dryEnabled, isTrue);
      expect(c.validate(), isEmpty);
    });

    test('validação bloqueia configurações que causam loops', () {
      const bad = LlmConfig(minP: 0.05, seed: -1, maxTokens: 0);
      final problems = bad.validate();
      expect(problems, hasLength(greaterThanOrEqualTo(3)));
    });

    test('fingerprint é estável e sensível a mudanças', () {
      const a = LlmConfig();
      const b = LlmConfig(seed: 43);
      expect(a.fingerprint, const LlmConfig().fingerprint);
      expect(a.fingerprint, isNot(b.fingerprint));
    });
  });
}