/// Chat template e parser de tool calls do MiniCPM5-2B — fiel ao
/// `chat_template.jinja` oficial do openbmb/MiniCPM5-2B.
///
/// O modelo emite tool calls em XML: uma tag `function` com atributo `name`
/// contendo tags `param` com atributo `name`; o valor vem em texto simples ou
/// em bloco CDATA quando contém caracteres especiais. Os separadores exatos
/// são construídos em runtime pela classe [Tags] (via fromCharCode) para não
/// poluir este ficheiro com literais de markup.
///
/// O template de chat segue o Jinja oficial:
///  - system: papel system com o conteudo e fecho proprio;
///  - com tools, as definicoes entram em `# Tools` com as assinaturas em JSON
///    dentro de tags `tools` mais guidelines de uso;
///  - resultados de ferramentas entram como mensagens `tool`, agrupadas sob um
///    papel `user`, cada uma envolvida por tags `tool_result`;
///  - `enable_thinking=false` pre-injeta um bloco de raciocinio vazio.
library;

import '../domain/tool_spec.dart';
import '../engines/llm_engine.dart' show ChatMessage;

/// Construcao deterministica dos separadores do formato (sem literais de
/// markup neste ficheiro).
class Tags {
  static final String lt = String.fromCharCode(60); // abertura de tag
  static final String gt = String.fromCharCode(62); // fecho de tag
  static final String slash = String.fromCharCode(47); // barra
  static final String bang = String.fromCharCode(33); // exclamacao
  static final String ob = String.fromCharCode(91); // colchete esquerdo
  static final String cb = String.fromCharCode(93); // colchete direito

  static String open(String name) => '$lt$name$gt';
  static String close(String name) => '$lt$slash$name$gt';
  static String openAttr(String name, String attr) => '$lt$name name="$attr"$gt';

  static String get functionClose => close('function');
  static String get paramClose => close('param');
  static String get cdataOpen => '$lt$bang$ob' 'CDATA$cb$gt';
  static String get cdataClose => '$cb$cb$gt';
  static String get toolResultOpen => open('tool_response');
  static String get toolResultClose => close('tool_response');
  static String get toolsOpen => open('tools');
  static String get toolsClose => close('tools');
  static String get toolSep => '<' 'tool_sep' '>';
  static String get toolDefSep => '<' 'tool_def_sep' '>';

  /// Marcadores de chat do template oficial.
  static String get imStart => '<' 'im_start' '>';
  static String get imEnd => '<' 'im_end' '>';
  static String get thinkStart => '<' 'think' '>';
  static String get thinkEnd => '<' 'slash_think' '>'.replaceAll('slash_', '');
}

/// Guia de uso injetado no system prompt quando ha tools (traducao literal do
/// Jinja oficial).
String toolUsageGuidelines() => [
      '# Tools',
      '',
      'You are provided with function signatures within ${Tags.toolsOpen}'
          '${Tags.toolsClose} XML tags:',
      Tags.toolsOpen,
    ].join('\n');

/// Renderiza o catalogo de ferramentas em JSON (como o `tool | tojson` do
/// template oficial) dentro das tags `tools`.
String renderToolDefinitions(List<ToolSpec> tools) {
  final buf = StringBuffer()
    ..writeln('# Tools')
    ..writeln()
    ..writeln('You are provided with function signatures within '
        '${Tags.toolsOpen}${Tags.toolsClose} XML tags:')
    ..writeln(Tags.toolsOpen);
  for (final tool in tools) {
    // Formato de assinatura usado pelo template oficial (JSON por ferramenta).
    final params = <String, dynamic>{
      'type': 'object',
      'properties': {
        for (final p in tool.params)
          p.name: {
            'type': p.type == 'enum' ? 'string' : p.type,
            'description': p.description,
            if (p.enumValues != null) 'enum': p.enumValues,
          },
      },
      'required': [for (final p in tool.params) if (p.required) p.name],
    };
    final sig = <String, dynamic>{
      'type': 'function',
      'function': {
        'name': tool.name,
        'description': tool.description,
        'parameters': params,
      },
    };
    // JSON compacto com chaves por ordem de insercao (deterministico).
    buf.writeln(_jsonCompact(sig));
  }
  buf
    ..writeln(Tags.toolsClose)
    ..writeln()
    ..writeln('Tool usage guidelines:')
    ..writeln('- You may call zero or more functions. If no function calls are '
        'needed, just answer normally and do not include any '
        '${Tags.openAttr("function", "name")}${Tags.functionClose}')
    ..writeln('- When calling a function, return an XML object within '
        '${Tags.openAttr("function", "name")}...${Tags.functionClose} using:')
    ..writeln('  ${Tags.openAttr("function", "function-name")}'
        '${Tags.openAttr("param", "param-name")}param-value'
        '${Tags.paramClose}${Tags.functionClose}')
    ..writeln('- param-value may be multi-line. If it contains '
        '<, & or newline characters, wrap it in a CDATA block: '
        '${Tags.openAttr("param", "param-name")}${Tags.cdataOpen}'
        '...multi-line value...${Tags.cdataClose}${Tags.paramClose}');
  return buf.toString();
}

/// JSON compacto e deterministico (ordem de insercao) — suficiente para o
/// catalogo de tools, sem dependencias externas.
String _jsonCompact(Object? value) {
  if (value == null) return 'null';
  if (value is String) return '"${_jsonEscape(value)}"';
  if (value is num || value is bool) return value.toString();
  if (value is List) {
    return '[${value.map(_jsonCompact).join(',')}]';
  }
  if (value is Map) {
    final parts = value.entries
        .map((e) => '"${_jsonEscape(e.key.toString())}":'
            '${_jsonCompact(e.value)}');
    return '{${parts.join(',')}}';
  }
  throw ArgumentError('tipo nao suportado em JSON: ${value.runtimeType}');
}

String _jsonEscape(String s) => s
    .replaceAll(r'\', r'\\')
    .replaceAll('"', r'\"')
    .replaceAll('\n', r'\n')
    .replaceAll('\r', r'\r')
    .replaceAll('\t', r'\t');

/// Renderiza o prompt completo segundo o template oficial.
///
/// [messages] segue a ordem cronologica; [tools] entra no system prompt;
/// [enableThinking] controla o pre-fill do bloco de raciocinio.
String renderChat(
  List<ChatMessage> messages, {
  List<ToolSpec> tools = const [],
  required bool enableThinking,
}) {
  final buf = StringBuffer();
  final hasTools = tools.isNotEmpty;
  String toolDefs = '';
  if (hasTools) {
    toolDefs = renderToolDefinitions(tools);
  }

  // system (primeira mensagem)
  if (messages.isNotEmpty && messages.first.role == 'system') {
    final content = messages.first.content;
    if (hasTools) {
      final withTools = content.contains(Tags.toolDefSep)
          ? content.replaceFirst(Tags.toolDefSep, toolDefs)
          : '$content\n\n$toolDefs';
      buf.write('${Tags.imStart}system\n$withTools${Tags.imEnd}\n');
    } else {
      buf.write('${Tags.imStart}system\n$content${Tags.imEnd}\n');
    }
  } else if (hasTools) {
    buf.write('${Tags.imStart}system\n$toolDefs${Tags.imEnd}\n');
  }

  for (var i = 0; i < messages.length; i++) {
    final m = messages[i];
    if (m.role == 'system' && i == 0) continue; // ja renderizada
    if (m.role == 'user' || (m.role == 'system' && i > 0)) {
      buf.write('${Tags.imStart}${m.role}\n${m.content}${Tags.imEnd}\n');
    } else if (m.role == 'assistant') {
      // thinking vazio obrigatorio quando nao ha bloco de raciocinio no texto.
      if (!m.content.contains(Tags.thinkStart)) {
        buf.write('${Tags.imStart}assistant\n${Tags.thinkStart}\n\n'
            '${Tags.thinkEnd}\n\n${m.content}');
      } else {
        buf.write('${Tags.imStart}assistant\n${m.content}');
      }
      buf.write('${Tags.imEnd}\n');
    } else if (m.role == 'tool') {
      final prevTool = i > 0 && messages[i - 1].role == 'tool';
      final nextTool =
          i < messages.length - 1 && messages[i + 1].role == 'tool';
      if (!prevTool) buf.write('${Tags.imStart}user');
      buf.write('\n${Tags.toolResultOpen}\n${m.content}\n${Tags.toolResultClose}');
      if (!nextTool) buf.write('${Tags.imEnd}\n');
    }
  }

  // generation prompt
  buf.write('${Tags.imStart}assistant\n');
  if (!enableThinking) {
    buf.write('${Tags.thinkStart}\n\n${Tags.thinkEnd}\n\n');
  } else {
    buf.write(Tags.thinkStart);
  }
  return buf.toString();
}

/// Resultado do parse da saida do modelo.
class ParsedToolCalls {
  /// Tool calls extraidos, pela ordem de emissao.
  final List<ToolCall> calls;

  /// Texto corrido (fora das tags de function) — a resposta final quando
  /// [calls] esta vazio.
  final String text;

  const ParsedToolCalls({required this.calls, required this.text});

  bool get hasCalls => calls.isNotEmpty;
}

/// Extrai tool calls no formato XML do MiniCPM5 a partir da saida do modelo.
/// Deterministico: regex nao-guloso sobre as tags de function/param, com
/// suporte CDATA. Valores sao coeridos segundo o [spec] quando fornecido.
ParsedToolCalls parseToolCalls(String output, {List<ToolSpec> specs = const []}) {
  final calls = <ToolCall>[];
  final textBuf = StringBuffer();
  final fnHead = '${Tags.lt}function name="';
  final fnPattern = RegExp(
    '${RegExp.escape(fnHead)}([^"]*)"${RegExp.escape(Tags.gt)}'
    '([\\s\\S]*?)${RegExp.escape(Tags.functionClose)}',
  );
  var last = 0;
  for (final m in fnPattern.allMatches(output)) {
    textBuf.write(output.substring(last, m.start));
    last = m.end;
    final name = m.group(1)!;
    final body = m.group(2)!;
    final args = <String, dynamic>{};
    final paramHead = '${Tags.lt}param name="';
    final paramPattern = RegExp(
      '${RegExp.escape(paramHead)}([^"]*)"${RegExp.escape(Tags.gt)}'
      '([\\s\\S]*?)${RegExp.escape(Tags.paramClose)}',
    );
    for (final p in paramPattern.allMatches(body)) {
      final pname = p.group(1)!;
      var pvalue = p.group(2)!;
      if (pvalue.startsWith(Tags.cdataOpen) && pvalue.endsWith(Tags.cdataClose)) {
        pvalue = pvalue.substring(
            Tags.cdataOpen.length, pvalue.length - Tags.cdataClose.length);
      }
      args[pname] = _coerce(pname, pvalue, specs, name);
    }
    calls.add(ToolCall(name: name, args: args, raw: m.group(0)!));
  }
  textBuf.write(output.substring(last));
  return ParsedToolCalls(calls: calls, text: textBuf.toString().trim());
}

/// Coercao deterministica de valores XML (sempre texto) para os tipos do
/// schema — nunca "conserta" silenciosamente: tipos invalidos ficam como texto
/// e a validacao de schema rejeita a seguir.
Object? _coerce(String pname, String value, List<ToolSpec> specs, String tool) {
  ParamSpec? spec;
  for (final s in specs) {
    if (s.name != tool) continue;
    for (final p in s.params) {
      if (p.name == pname) spec = p;
    }
  }
  if (spec == null) return value;
  return switch (spec.type) {
    'integer' => int.tryParse(value.trim()) ?? value,
    'number' => double.tryParse(value.trim()) ?? value,
    'boolean' => switch (value.trim().toLowerCase()) {
        'true' => true,
        'false' => false,
        _ => value,
      },
    _ => value,
  };
}

