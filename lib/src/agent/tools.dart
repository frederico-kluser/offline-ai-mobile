/// Ferramentas locais do exemplo de tool calling (100% offline).
///
/// Regras (dossiê Q7): resultados NUNCA vazios nem ambíguos — status
/// explícito `ok`/`no_results`/`error` + motivo —, e truncagem com marcador
/// explícito para não dominar o contexto.
library;

import 'dart:async';
import 'dart:math';

import '../domain/tool_spec.dart';

/// Truncagem com marcador explícito (nunca corte silencioso).
String truncateToolOutput(String output, {int maxChars = 4096}) {
  if (output.length <= maxChars) return output;
  final omitted = output.length - maxChars;
  return '${output.substring(0, maxChars)}\n[...truncado: $omitted caracteres omitidos]';
}

typedef ToolHandler = Future<String> Function(Map<String, dynamic> args);

class LocalTool {
  final ToolSpec spec;
  final ToolHandler handler;
  final Duration timeout;

  const LocalTool({
    required this.spec,
    required this.handler,
    this.timeout = const Duration(seconds: 5),
  });
}

/// Catálogo de demonstração: determinístico, offline, sem efeitos colaterais
/// externos. `calculator` + `note_save`/`note_read` bastam para um exemplo
/// básico de tool calling multi-passo.
List<LocalTool> demoTools(Map<String, String> noteStore) => [
      LocalTool(
        spec: const ToolSpec(
          name: 'calculator',
          description:
              'Calcula uma expressão aritmética com números, + - * / % ( ) e '
              'devolve o resultado. Usa-a para qualquer conta exata.',
          params: [
            ParamSpec(
              name: 'expression',
              type: 'string',
              description: 'Expressão a calcular, ex.: "17*23+5"',
            ),
          ],
        ),
        handler: (args) async {
          final expr = args['expression'] as String;
          final value = _safeEval(expr);
          if (value.startsWith('error')) return value;
          return 'ok: $expr = $value';
        },
      ),
      LocalTool(
        spec: const ToolSpec(
          name: 'note_save',
          description: 'Guarda uma nota curta com uma chave, para recordar '
              'informação entre passos.',
          params: [
            ParamSpec(name: 'key', type: 'string', description: 'Chave da nota'),
            ParamSpec(name: 'value', type: 'string', description: 'Conteúdo'),
          ],
        ),
        handler: (args) async {
          final key = args['key'] as String;
          noteStore[key] = args['value'] as String;
          return 'ok: nota "$key" guardada';
        },
      ),
      LocalTool(
        spec: const ToolSpec(
          name: 'note_read',
          description: 'Lê uma nota guardada pela chave. Se não existir, '
              'devolve no_results.',
          params: [
            ParamSpec(name: 'key', type: 'string', description: 'Chave da nota'),
          ],
        ),
        handler: (args) async {
          final key = args['key'] as String;
          final v = noteStore[key];
          if (v == null) return 'no_results: nota "$key" não existe';
          return 'ok: $v';
        },
      ),
    ];

/// Avaliador aritmético SEGURO e determinístico (parser recursivo descendente
/// mínimo — sem `eval`, sem regex ambíguas). Erros devolvem `error:` com
/// motivo explícito (nunca exceção para o modelo "adivinhar").
String _safeEval(String expression) {
  try {
    final p = _ExprParser(expression.replaceAll(',', '.'));
    final value = p.parse();
    if (!p.atEnd) {
      return 'error: símbolo inesperado na posição ${p.pos} ("${expression.substring(p.pos)}")';
    }
    // Formatação determinística: inteiros sem casas decimais.
    if (value == value.roundToDouble() && value.abs() < 1e15) {
      return value.round().toString();
    }
    return value.toStringAsFixed(6).replaceAll(RegExp(r'0+$'), '');
  } on FormatException catch (e) {
    return 'error: ${e.message}';
  }
}

class _ExprParser {
  final String src;
  int pos = 0;
  _ExprParser(this.src);

  bool get atEnd => _skipWs() >= src.length;

  double parse() {
    final v = _expr();
    return v;
  }

  int _skipWs() {
    while (pos < src.length && src[pos] == ' ') {
      pos++;
    }
    return pos;
  }

  double _expr() {
    var v = _term();
    while (true) {
      final i = _skipWs();
      if (i < src.length && (src[i] == '+' || src[i] == '-')) {
        pos++;
        final r = _term();
        v = (src[i] == '+') ? v + r : v - r;
      } else {
        return v;
      }
    }
  }

  double _term() {
    var v = _factor();
    while (true) {
      final i = _skipWs();
      if (i < src.length && (src[i] == '*' || src[i] == '/' || src[i] == '%')) {
        pos++;
        final r = _factor();
        if ((src[i] == '/' || src[i] == '%') && r == 0) {
          throw const FormatException('divisão por zero');
        }
        v = switch (src[i]) {
          '*' => v * r,
          '/' => v / r,
          _ => v % r,
        };
      } else {
        return v;
      }
    }
  }

  double _factor() {
    final i = _skipWs();
    if (i >= src.length) throw const FormatException('expressão incompleta');
    if (src[i] == '(') {
      pos++;
      final v = _expr();
      if (_skipWs() >= src.length || src[pos] != ')') {
        throw const FormatException('parêntese sem fecho');
      }
      pos++;
      return v;
    }
    if (src[i] == '-') {
      pos++;
      return -_factor();
    }
    final start = pos;
    while (pos < src.length &&
        (RegExp(r'[0-9.]').hasMatch(src[pos]))) {
      pos++;
    }
    if (pos == start) {
      throw FormatException(
          'símbolo inesperado "${src[pos]}" na posição $pos');
    }
    return double.parse(src.substring(start, pos));
  }
}

/// Executa uma ferramenta com timeout (2–5 s em Android; dossiê Q7) e devolve
/// SEMPRE um [ToolResult] estruturado — nunca exceção para o modelo.
Future<ToolResult> runTool(
  LocalTool tool,
  Map<String, dynamic> args, {
  void Function(ToolValidationError)? onValidationError,
}) async {
  final sw = Stopwatch()..start();
  try {
    validateToolArgs(tool.spec, args);
  } on ToolValidationError catch (e) {
    onValidationError?.call(e);
    return ToolResult(
      name: tool.spec.name,
      ok: false,
      output: 'error: ${e.message}',
      durationMs: sw.elapsedMilliseconds,
      errorKind: 'schema-invalid',
    );
  }
  try {
    final raw = await tool.handler(args).timeout(tool.timeout);
    return ToolResult(
      name: tool.spec.name,
      ok: !raw.startsWith('error') && !raw.startsWith('no_results'),
      output: truncateToolOutput(raw),
      durationMs: sw.elapsedMilliseconds,
    );
  } on TimeoutException {
    return ToolResult(
      name: tool.spec.name,
      ok: false,
      output: 'error: timeout após ${tool.timeout.inSeconds}s',
      durationMs: sw.elapsedMilliseconds,
      errorKind: 'timeout',
    );
  } catch (e) {
    return ToolResult(
      name: tool.spec.name,
      ok: false,
      output: 'error: falha na execução ($e)',
      durationMs: sw.elapsedMilliseconds,
      errorKind: 'tool-error',
    );
  }
}

/// Ferramenta de CONCLUSÃO (dossiê Q7): sinal explícito de saída — o modelo
/// termina o loop canonicamente em vez de "acabar por acaso".
const ToolSpec finalAnswerSpec = ToolSpec(
  name: 'final_answer',
  description:
      'Termina a tarefa e entrega a resposta final ao utilizador. Chama-a '
      'quando tiveres a resposta — é a ÚLTIMA ação.',
  params: [
    ParamSpec(
      name: 'answer',
      type: 'string',
      description: 'A resposta final para o utilizador',
    ),
  ],
);

/// Seed determinística auxiliar (para qualquer aleatoriedade futura).
final Random deterministicRandom = Random(0);