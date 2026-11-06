/// Chat template ChatML da família Liquid LFM3 e parser do tool calling XML.
///
/// O template segue o formato oficial:
///  - `<|startoftext|>` no início;
///  - `<|im_start|>role\n…<|im_end|>\n` por turno;
///  - raciocínio `<think>…</think>` (LFM3-1.7B e VL-2B; o Omni não usa);
///  - marcadores multimodais `<|vision_start|><|image|><|vision_end|>`,
///    `<|vision_start|><|video|><|vision_end|>`, `<|audio_start|>` e
///    `<|mixed_start|>`;
///  - tool calls no superset XML do qwen3_coder:
///    `<tool_call><function=nome><parameter=chave>valor</parameter></function></tool_call>`;
///  - resultados de ferramenta no papel `tool` dentro de `<tool_response>`,
///    com ferramentas descobertas em `<additional_tools>`.
///
/// O parser é determinístico (regex não-guloso + `jsonDecode` dos valores) e
/// separa sempre `thinking`, texto visível e tool calls.
library;

import 'dart:convert';

import '../domain/tool_spec.dart';
import '../engines/llm_engine.dart' show ChatMessage;

/// Marcadores e helpers de markup do LFM3.
class Lfm3Markup {
  static const String startOfText = '<|startoftext|>';
  static const String imStart = '<|im_start|>';
  static const String imEnd = '<|im_end|>';
  static const String thinkStart = '<think>';
  static const String thinkEnd = '</think>';
  static const String visionStart = '<|vision_start|>';
  static const String image = '<|image|>';
  static const String video = '<|video|>';
  static const String visionEnd = '<|vision_end|>';
  static const String audioStart = '<|audio_start|>';
  static const String mixedStart = '<|mixed_start|>';
  static const String audioEnd = '<|audio_end|>';

  /// Marcador que o libmtmd substitui pelo chunk de mídia.
  static const String mediaMarker = '<__media__>';

  static String imageBlock() => '$visionStart$image$visionEnd';
  static String videoBlock() => '$visionStart$video$visionEnd';
}

/// Instrução recomendada pela Liquid AI para Deferred Tool Loading.
const String kDeferredToolsInstruction =
    'You only have one tool right now: search_tools, which searches a catalog '
    'of many more tools. If none of your current tools can handle a request, '
    'call search_tools to find one, then call the tool it returns.';

/// Renderiza o catálogo de ferramentas no system prompt.
String renderToolDefinitions(
  List<ToolSpec> tools, {
  bool deferredInstruction = false,
}) {
  final buf = StringBuffer()
    ..writeln('# Tools')
    ..writeln()
    ..writeln('You are provided with function signatures within <tools> '
        '</tools> XML tags:')
    ..writeln('<tools>');
  for (final tool in tools) {
    buf.writeln(_jsonCompact(tool.toOpenAiSchema()));
  }
  buf.writeln('</tools>');
  if (deferredInstruction) {
    buf
      ..writeln()
      ..writeln(kDeferredToolsInstruction);
  }
  return buf.toString();
}

/// JSON compacto e determinístico (ordem de inserção), sem dependências.
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
  throw ArgumentError('tipo não suportado em JSON: ${value.runtimeType}');
}

String _jsonEscape(String s) => s
    .replaceAll(r'\', r'\\')
    .replaceAll('"', r'\"')
    .replaceAll('\n', r'\n')
    .replaceAll('\r', r'\r')
    .replaceAll('\t', r'\t');

/// Remove blocos `<think>` de um texto (histórico multi-turno).
String stripThinking(String text) =>
    text.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '').trim();

/// Renderiza o prompt completo segundo o template LFM3.
///
/// [messages] segue a ordem cronológica. As definições de ferramentas entram
/// no system prompt; [deferred] ativa a instrução de `search_tools`.
/// [audioOutput] pré-preenche `<|audio_start|>` (TTS) ou `<|mixed_start|>`
/// (texto+fala entrelaçados).
String renderChat(
  List<ChatMessage> messages, {
  List<ToolSpec> tools = const [],
  required bool enableThinking,
  bool preserveThinking = false,
  bool deferredTools = false,
  bool audioOutput = false,
  bool interleavedAudio = false,
  String? responseJsonSchema,
  bool jsonResponse = false,
}) {
  final buf = StringBuffer(Lfm3Markup.startOfText);

  // ---- system prompt (com definições de tools) ----------------------------
  final firstSystem =
      messages.isNotEmpty && messages.first.role == 'system' ? messages.first : null;
  final toolBlock = tools.isEmpty
      ? ''
      : renderToolDefinitions(tools, deferredInstruction: deferredTools);
  final jsonInstruction = jsonResponse
      ? '\n\nRespond with a single valid JSON object and nothing else.'
          '${responseJsonSchema == null ? '' : ' The object must validate against this JSON Schema: $responseJsonSchema'}'
      : '';
  final systemContent = [
    if (firstSystem != null) firstSystem.content,
    if (toolBlock.isNotEmpty) toolBlock,
    if (jsonInstruction.isNotEmpty) jsonInstruction,
  ].where((s) => s.isNotEmpty).join('\n\n');
  if (systemContent.isNotEmpty) {
    buf.write('${Lfm3Markup.imStart}system\n$systemContent${Lfm3Markup.imEnd}\n');
  }

  final lastAssistantIndex = messages.lastIndexWhere((m) => m.role == 'assistant');

  for (var i = 0; i < messages.length; i++) {
    final m = messages[i];
    if (m.role == 'system' && identical(m, firstSystem)) continue;
    switch (m.role) {
      case 'system':
      case 'user':
        buf.write('${Lfm3Markup.imStart}${m.role}\n${m.content}${Lfm3Markup.imEnd}\n');
      case 'assistant':
        var content = m.content;
        var thinking = m.thinking;
        final includeThinking = preserveThinking || i == lastAssistantIndex;
        if (!includeThinking) {
          content = stripThinking(content);
          thinking = null;
        }
        final hasThinkTag = content.contains(Lfm3Markup.thinkStart);
        buf.write('${Lfm3Markup.imStart}assistant\n');
        if (thinking != null && thinking.trim().isNotEmpty && !hasThinkTag) {
          buf.write('${Lfm3Markup.thinkStart}\n${thinking.trim()}\n'
              '${Lfm3Markup.thinkEnd}\n');
        } else if (!hasThinkTag && !enableThinking) {
          buf.write('${Lfm3Markup.thinkStart}${Lfm3Markup.thinkEnd}\n');
        }
        buf.write('$content${Lfm3Markup.imEnd}\n');
      case 'tool':
        // O conteúdo já pode vir embrulhado por formatToolResponse; nesse
        // caso não duplicamos os marcadores.
        final wrapped = m.content.contains('<tool_response>');
        buf.write('${Lfm3Markup.imStart}tool\n');
        if (!wrapped) {
          buf.write('<tool_response>\n${m.content}\n');
          if (m.additionalTools.isNotEmpty) {
            buf.write('<additional_tools>\n');
            for (final schema in m.additionalTools) {
              buf.writeln(_jsonCompact(schema));
            }
            buf.write('</additional_tools>\n');
          }
          buf.write('</tool_response>');
        } else {
          buf.write(m.content);
        }
        buf.write('${Lfm3Markup.imEnd}\n');
      default:
        // Papel desconhecido: não inventar markup; ignorar.
        break;
    }
  }

  // ---- generation prompt --------------------------------------------------
  buf.write('${Lfm3Markup.imStart}assistant\n');
  if (!enableThinking) {
    buf.write('${Lfm3Markup.thinkStart}${Lfm3Markup.thinkEnd}\n');
  } else {
    buf.write('${Lfm3Markup.thinkStart}\n');
  }
  if (audioOutput) {
    buf.write(interleavedAudio ? Lfm3Markup.mixedStart : Lfm3Markup.audioStart);
  }
  return buf.toString();
}

/// Um tool call extraído da saída do LFM3.
class Lfm3ToolCall {
  final String name;
  final Map<String, dynamic> arguments;
  final String raw;

  const Lfm3ToolCall({
    required this.name,
    required this.arguments,
    this.raw = '',
  });

  ToolCall toToolCall() =>
      ToolCall(name: name, args: arguments, raw: raw);

  Map<String, dynamic> toJson() =>
      {'name': name, 'arguments': arguments, 'raw': raw};
}

/// Turno parseado: raciocínio, texto visível, tool calls e ferramentas
/// descobertas.
class Lfm3ParsedTurn {
  final String? thinkingContent;
  final String visibleContent;
  final List<Lfm3ToolCall> toolCalls;
  final List<Map<String, dynamic>> additionalTools;

  const Lfm3ParsedTurn({
    this.thinkingContent,
    required this.visibleContent,
    required this.toolCalls,
    this.additionalTools = const [],
  });

  bool get hasCalls => toolCalls.isNotEmpty;

  Map<String, dynamic> toJson() => {
        if (thinkingContent != null) 'thinking': thinkingContent,
        'content': visibleContent,
        'tool_calls': [for (final c in toolCalls) c.toJson()],
        if (additionalTools.isNotEmpty) 'additional_tools': additionalTools,
      };
}

/// Parser determinístico do formato XML do LFM3.
class Lfm3OutputParser {
  static final RegExp _thinkRe =
      RegExp(r'<think>([\s\S]*?)</think>', dotAll: true);
  static final RegExp _callRe = RegExp(
    r'<tool_call>\s*<function=([^>\n]+)>([\s\S]*?)</function>\s*</tool_call>',
    dotAll: true,
  );
  static final RegExp _paramRe = RegExp(
    r'<parameter=([^>\n]+)>\n?([\s\S]*?)\n?</parameter>',
    dotAll: true,
  );
  static final RegExp _additionalRe =
      RegExp(r'<additional_tools>([\s\S]*?)</additional_tools>', dotAll: true);

  static Lfm3ParsedTurn parse(String rawOutput) {
    String? thinking;
    var remaining = rawOutput;

    final thinkMatches = _thinkRe.allMatches(rawOutput).toList();
    if (thinkMatches.isNotEmpty) {
      thinking = thinkMatches
          .map((m) => m.group(1)?.trim() ?? '')
          .where((s) => s.isNotEmpty)
          .join('\n\n');
      remaining = rawOutput.replaceAll(_thinkRe, '').trim();
    }

    final additional = <Map<String, dynamic>>[];
    final addMatch = _additionalRe.firstMatch(remaining);
    if (addMatch != null) {
      for (final line in addMatch.group(1)!.split('\n')) {
        final t = line.trim();
        if (t.isEmpty) continue;
        try {
          final decoded = jsonDecode(t);
          if (decoded is Map<String, dynamic>) additional.add(decoded);
        } catch (_) {
          // linha inválida: ignorar (o parser nunca "inventa" schemas)
        }
      }
      remaining = remaining.replaceFirst(_additionalRe, '').trim();
    }

    final calls = <Lfm3ToolCall>[];
    for (final match in _callRe.allMatches(remaining)) {
      final fnName = match.group(1)!.trim();
      final body = match.group(2)!;
      final args = <String, dynamic>{};

      for (final pMatch in _paramRe.allMatches(body)) {
        final key = pMatch.group(1)!.trim();
        final rawVal = pMatch.group(2)!.trim();
        args[key] = _decodeValue(rawVal);
      }
      calls.add(Lfm3ToolCall(
        name: fnName,
        arguments: args,
        raw: match.group(0)!,
      ));
    }

    final visible = remaining.replaceAll(_callRe, '').trim();
    return Lfm3ParsedTurn(
      thinkingContent: thinking,
      visibleContent: visible,
      toolCalls: calls,
      additionalTools: additional,
    );
  }

  /// A especificação LFM3 aplica `json.loads()` aos valores dos parâmetros;
  /// se o valor não for JSON válido, fica como texto.
  static Object? _decodeValue(String raw) {
    if (raw.isEmpty) return '';
    try {
      return jsonDecode(raw);
    } catch (_) {
      return raw;
    }
  }
}

/// Formata o resultado de uma ferramenta para o histórico ChatML do LFM3.
/// Devolve o bloco completo (com `<|im_start|>tool`), como no contrato oficial.
String formatToolResponse(
  Object resultJson, {
  List<Map<String, dynamic>>? newlyDiscoveredToolSchemas,
}) {
  final buffer = StringBuffer('<|im_start|>tool\n<tool_response>\n');
  buffer.writeln(resultJson is String ? resultJson : jsonEncode(resultJson));
  if (newlyDiscoveredToolSchemas != null &&
      newlyDiscoveredToolSchemas.isNotEmpty) {
    buffer.writeln('<additional_tools>');
    for (final schema in newlyDiscoveredToolSchemas) {
      buffer.writeln(jsonEncode(schema));
    }
    buffer.writeln('</additional_tools>');
  }
  buffer.write('</tool_response><|im_end|>\n');
  return buffer.toString();
}

/// Compatibilidade com o contrato antigo: devolve `ToolCall` do domínio.
class ParsedToolCalls {
  final List<ToolCall> calls;
  final String text;
  const ParsedToolCalls({required this.calls, required this.text});

  bool get hasCalls => calls.isNotEmpty;
}

ParsedToolCalls parseToolCalls(String output, {List<ToolSpec> specs = const []}) {
  final parsed = Lfm3OutputParser.parse(output);
  return ParsedToolCalls(
    calls: [for (final c in parsed.toolCalls) c.toToolCall()],
    text: parsed.visibleContent,
  );
}
