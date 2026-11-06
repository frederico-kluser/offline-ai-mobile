/// Loop de agente determinístico para a família LFM3.
///
/// Máquina de estados explícita: MODELO → TOOL(s) → MODELO → … → RESPOSTA
/// FINAL, com corte obrigatório por qualquer guardrail do [LoopGuard]
/// (max steps, max tool calls, ciclos A→A, ping-pong A→B→A→B, SER@4,
/// orçamento de tokens, teto de `<think>` e timeout).
///
/// Deferred Tool Loading: o system prompt leva apenas as ferramentas ativas
/// (normalmente `search_tools`). Quando o modelo chama `search_tools`, o
/// resultado inclui referências + esquemas; o loop injeta os esquemas na
/// mensagem `tool` em `<additional_tools>` e o modelo pode chamar a ferramenta
/// descoberta no passo seguinte. O prefixo do system prompt nunca muda, o que
/// permite reutilizar o KV cache.
library;

import 'dart:async';
import 'dart:convert';

import '../domain/llm_config.dart';
import '../domain/tool_spec.dart';
import '../engines/llm_engine.dart';
import '../guardrails/loop_guard.dart';
import 'lfm3_chat.dart';
import 'tools.dart';

/// Eventos do loop (para a UI mostrar a timeline).
sealed class ToolLoopEvent {
  const ToolLoopEvent();
}

class LoopText extends ToolLoopEvent {
  final String text;

  /// `true` quando o texto pertence ao bloco `<think>`.
  final bool thinking;

  const LoopText(this.text, {this.thinking = false});
}

class LoopToolCall extends ToolLoopEvent {
  final ToolCall call;
  final int step;
  const LoopToolCall(this.call, this.step);
}

class LoopToolResult extends ToolLoopEvent {
  final ToolResult result;
  final int step;

  /// Esquemas descobertos por `search_tools` neste resultado.
  final List<Map<String, dynamic>> discoveredSchemas;

  const LoopToolResult(
    this.result,
    this.step, {
    this.discoveredSchemas = const [],
  });
}

class LoopGuardTrip extends ToolLoopEvent {
  final StopReason reason;
  final String detail;
  const LoopGuardTrip(this.reason, this.detail);
}

class LoopEnd extends ToolLoopEvent {
  final ToolLoopResult result;
  const LoopEnd(this.result);
}

class ToolLoopResult {
  final String answer;
  final String thinking;
  final StopReason stopReason;
  final List<LoopStep> log;
  final List<ToolResult> toolResults;

  /// Ferramentas descobertas por `search_tools` (nomes únicos, por ordem).
  final List<String> discoveredTools;

  /// Queries canónicas de `search_tools` (auditoria).
  final List<String> searchQueries;

  final int promptTokens;
  final int outputTokens;
  final int thinkingTokens;
  final int latencyMs;

  const ToolLoopResult({
    required this.answer,
    required this.stopReason,
    required this.log,
    required this.toolResults,
    this.thinking = '',
    this.discoveredTools = const [],
    this.searchQueries = const [],
    required this.promptTokens,
    required this.outputTokens,
    this.thinkingTokens = 0,
    required this.latencyMs,
  });
}

/// Fallback estático quando nem a resposta forçada sai.
const String kLoopFallbackAnswer =
    'Não consegui concluir dentro dos limites de segurança (passos/tokens). '
    'Reformula a tarefa ou aumenta os limites em Configurações.';

class ToolLoop {
  final LlmEngine llm;
  final ToolCatalog catalog;
  final LoopGuardConfig guardConfig;

  ToolLoop({
    required this.llm,
    required this.catalog,
    this.guardConfig = const LoopGuardConfig(),
  });

  /// Conveniência: todas as ferramentas ficam ativas (ex.: browser).
  factory ToolLoop.fromTools({
    required LlmEngine llm,
    required List<LocalTool> tools,
    LoopGuardConfig guardConfig = const LoopGuardConfig(),
  }) =>
      ToolLoop(
        llm: llm,
        catalog: ToolCatalog.allActive(tools),
        guardConfig: guardConfig,
      );

  /// Corre o agente até à resposta final (ou até um guardrail cortar).
  Stream<ToolLoopEvent> run({
    required String userPrompt,
    String? systemPrompt,
    required LlmConfig config,
    List<LlmMediaInput> media = const [],
  }) {
    late StreamController<ToolLoopEvent> ctrl;
    ctrl = StreamController<ToolLoopEvent>(onListen: () async {
      final sw = Stopwatch()..start();
      final guard = LoopGuard(config: guardConfig);
      final toolResults = <ToolResult>[];
      final discoveredSchemas = <String, Map<String, dynamic>>{};
      final discoveredOrder = <String>[];
      final searchQueries = <String>[];
      var promptTokens = 0;
      var outputTokens = 0;
      var thinkingTokens = 0;
      var answer = '';
      var thinking = '';
      var step = 0;

      final activeSpecs = [for (final t in catalog.active) t.spec];
      final toolBlock = activeSpecs.isEmpty
          ? ''
          : renderToolDefinitions(
              activeSpecs,
              deferredInstruction: catalog.deferred.isNotEmpty,
            );
      final baseSystem = systemPrompt ?? kDefaultAgentSystemPrompt;
      final messages = <ChatMessage>[
        ChatMessage(
          'system',
          toolBlock.isEmpty ? baseSystem : '$baseSystem\n\n$toolBlock',
        ),
        ChatMessage('user', userPrompt),
      ];

      try {
        while (true) {
          step++;
          if (!guard.beforeModelStep(tokensSoFar: outputTokens)) {
            ctrl.add(LoopGuardTrip(
                guard.state.stop!, guard.state.stop!.explanation));
            break;
          }
          guard.log('model', 'passo $step: geração do modelo');

          // ---- geração (com uma repetição sem <think> se o teto estourar) --
          var effectiveConfig = config;
          var outcome = _Generation.empty();
          for (var attempt = 0; attempt < 2; attempt++) {
            outcome = await _generate(
              messages: messages,
              config: effectiveConfig,
              media: media,
              guard: guard,
              onDelta: (text, isThinking) {
                ctrl.add(LoopText(text, thinking: isThinking));
              },
            );
            if (outcome.thinkingBudgetHit &&
                effectiveConfig.enableThinking &&
                attempt == 0) {
              ctrl.add(LoopGuardTrip(
                StopReason.thinkingBudgetExhausted,
                'teto de <think> (${config.maxThinkingTokens} tokens) — '
                'a repetir o passo com raciocínio desligado',
              ));
              effectiveConfig = effectiveConfig.copyWith(enableThinking: false);
              continue;
            }
            break;
          }

          promptTokens += outcome.end?.promptTokens ?? 0;
          outputTokens += outcome.outputTokens;
          thinkingTokens += outcome.thinkingTokens;
          thinking += outcome.thinkingText;

          if (outcome.thinkingBudgetHit && !effectiveConfig.enableThinking) {
            guard.addThinkingTokens(outcome.thinkingTokens);
            ctrl.add(LoopGuardTrip(
                guard.state.stop!, guard.state.stop!.explanation));
            break;
          }
          guard.noteThinking(outcome.thinkingTokens);

          if (guard.state.finished &&
              guard.state.stop != StopReason.finalAnswer) {
            break;
          }
          if (outcome.end?.stopReason == 'error') {
            guard.fail();
            ctrl.add(LoopGuardTrip(
                StopReason.engineError, 'erro do motor: ${outcome.end?.error}'));
            break;
          }

          final parsed = Lfm3OutputParser.parse(outcome.raw);
          messages.add(ChatMessage('assistant', outcome.raw));

          // Resposta final canónica: ferramenta final_answer.
          final fin = parsed.toolCalls.where((c) => c.name == 'final_answer');
          if (fin.isNotEmpty) {
            answer = (fin.first.arguments['answer'] ?? '').toString();
            guard.finish();
            break;
          }

          if (parsed.hasCalls) {
            var cut = false;
            for (final call in parsed.toolCalls) {
              final key = call.toToolCall().canonicalKey;
              if (!guard.beforeToolCall(_Key(key))) {
                ctrl.add(LoopGuardTrip(
                    guard.state.stop!,
                    '${guard.state.stop!.explanation} ($key)'));
                cut = true;
                break;
              }
              ctrl.add(LoopToolCall(call.toToolCall(), step));
              final tool = catalog.byName(call.name);
              final ToolResult result;
              if (tool == null) {
                result = ToolResult(
                  name: call.name,
                  ok: false,
                  output: 'error: ferramenta desconhecida "${call.name}"',
                  durationMs: 0,
                  errorKind: 'unknown-tool',
                );
              } else {
                result = await runTool(tool, call.arguments);
              }
              toolResults.add(result);
              if (call.name == 'search_tools' && result.ok) {
                searchQueries.add(key);
                final schemas = _extractSchemas(result.output);
                for (final schema in schemas) {
                  final name = _schemaName(schema);
                  if (name == null) continue;
                  if (!discoveredSchemas.containsKey(name)) {
                    discoveredOrder.add(name);
                  }
                  discoveredSchemas[name] = schema;
                }
              }
              ctrl.add(LoopToolResult(
                result,
                step,
                discoveredSchemas: call.name == 'search_tools'
                    ? _extractSchemas(result.output)
                    : const [],
              ));
              messages.add(ChatMessage(
                'tool',
                result.output,
                toolName: result.name,
                additionalTools: call.name == 'search_tools'
                    ? _extractSchemas(result.output)
                    : const [],
              ));
            }
            if (cut || guard.state.finished) break;
            continue; // volta ao modelo com os resultados
          }

          // Sem tool calls: o texto visível é a resposta final.
          answer = parsed.visibleContent;
          guard.finish();
          break;
        }

        // Resposta final FORÇADA quando o loop cortou sem resposta.
        if (answer.isEmpty && guard.state.stop != StopReason.finalAnswer) {
          answer = await _forcedFinal(messages, config, guard);
        }

        ctrl.add(LoopEnd(ToolLoopResult(
          answer: answer.isEmpty ? kLoopFallbackAnswer : answer,
          thinking: thinking.trim(),
          stopReason: guard.state.stop ?? StopReason.finalAnswer,
          log: List.unmodifiable(guard.state.log),
          toolResults: List.unmodifiable(toolResults),
          discoveredTools: List.unmodifiable(discoveredOrder),
          searchQueries: List.unmodifiable(searchQueries),
          promptTokens: promptTokens,
          outputTokens: outputTokens,
          thinkingTokens: thinkingTokens,
          latencyMs: sw.elapsedMilliseconds,
        )));
      } catch (e) {
        guard.fail();
        ctrl.add(
            LoopGuardTrip(StopReason.engineError, 'erro inesperado: $e'));
        ctrl.add(LoopEnd(ToolLoopResult(
          answer: kLoopFallbackAnswer,
          thinking: thinking,
          stopReason: StopReason.engineError,
          log: List.unmodifiable(guard.state.log),
          toolResults: List.unmodifiable(toolResults),
          discoveredTools: List.unmodifiable(discoveredOrder),
          searchQueries: List.unmodifiable(searchQueries),
          promptTokens: promptTokens,
          outputTokens: outputTokens,
          thinkingTokens: thinkingTokens,
          latencyMs: sw.elapsedMilliseconds,
        )));
      }
      await ctrl.close();
    });
    return ctrl.stream;
  }

  /// Uma geração supervisionada. Devolve o texto bruto, o texto de raciocínio
  /// e o evento final.
  Future<_Generation> _generate({
    required List<ChatMessage> messages,
    required LlmConfig config,
    required List<LlmMediaInput> media,
    required LoopGuard guard,
    required void Function(String text, bool thinking) onDelta,
  }) async {
    final raw = StringBuffer();
    final think = StringBuffer();
    GenEnd? end;
    var outputTokens = 0;
    var thinkingTokens = 0;
    var thinkingBudgetHit = false;

    final stream = llm.generate(
      messages: messages,
      config: config,
      media: media,
      maxTokensOverride: config.maxTokens,
    );
    await for (final ev in stream) {
      if (ev is GenDelta) {
        raw.write(ev.text);
        outputTokens++;
        if (!guard.addTokens(1)) break;
        if (ev.thinking) {
          think.write(ev.text);
          thinkingTokens++;
          if (config.maxThinkingTokens > 0 &&
              thinkingTokens > config.maxThinkingTokens) {
            thinkingBudgetHit = true;
            break;
          }
        }
        onDelta(ev.text, ev.thinking);
        if (!guard.checkTextRepetition(raw.toString())) {
          break;
        }
      } else if (ev is GenEnd) {
        end = ev;
        if (ev.stopReason == 'thinking_budget') thinkingBudgetHit = true;
      }
    }

    // Se o motor não separou o raciocínio, o parser ainda o extrai.
    if (think.isEmpty) {
      final parsed = Lfm3OutputParser.parse(raw.toString());
      final t = parsed.thinkingContent;
      if (t != null && t.isNotEmpty) {
        think.write(t);
        thinkingTokens =
            t.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
      }
    }

    return _Generation(
      raw: raw.toString(),
      thinkingText: think.toString(),
      end: end,
      outputTokens: outputTokens,
      thinkingTokens: thinkingTokens,
      thinkingBudgetHit: thinkingBudgetHit,
    );
  }

  /// Última tentativa: geração curta SEM catálogo de tools e sem `<think>`.
  Future<String> _forcedFinal(
    List<ChatMessage> messages,
    LlmConfig config,
    LoopGuard guard,
  ) async {
    final forced = <ChatMessage>[
      const ChatMessage('system', kDefaultAgentSystemPrompt),
      ...messages.skip(1),
      const ChatMessage('user', kForceFinalInstruction),
    ];
    final buf = StringBuffer();
    try {
      final done = Completer<void>();
      llm
          .generate(
            messages: forced,
            config: config.copyWith(enableThinking: false),
            maxTokensOverride: 192,
          )
          .listen((ev) {
        if (ev is GenDelta) buf.write(ev.text);
        if (ev is GenEnd && !done.isCompleted) done.complete();
      }, onError: (_) {
        if (!done.isCompleted) done.complete();
      }, onDone: () {
        if (!done.isCompleted) done.complete();
      });
      await done.future.timeout(const Duration(seconds: 90), onTimeout: () {});
    } catch (_) {
      return kLoopFallbackAnswer;
    }
    final text = buf.toString().trim();
    if (text.isEmpty) return kLoopFallbackAnswer;
    final parsed = Lfm3OutputParser.parse(text);
    return parsed.visibleContent.isEmpty
        ? kLoopFallbackAnswer
        : parsed.visibleContent;
  }

  static List<Map<String, dynamic>> _extractSchemas(String output) {
    try {
      final decoded = jsonDecode(output);
      if (decoded is Map && decoded['schemas'] is List) {
        return [
          for (final s in decoded['schemas'] as List)
            if (s is Map) Map<String, dynamic>.from(s),
        ];
      }
    } catch (_) {
      // Resultado não-JSON: não há schemas.
    }
    return const [];
  }

  static String? _schemaName(Map<String, dynamic> schema) {
    final fn = schema['function'];
    if (fn is Map && fn['name'] is String) return fn['name'] as String;
    if (schema['name'] is String) return schema['name'] as String;
    return null;
  }
}

class _Generation {
  final String raw;
  final String thinkingText;
  final GenEnd? end;
  final int outputTokens;
  final int thinkingTokens;
  final bool thinkingBudgetHit;

  const _Generation({
    required this.raw,
    required this.thinkingText,
    required this.end,
    required this.outputTokens,
    required this.thinkingTokens,
    required this.thinkingBudgetHit,
  });

  factory _Generation.empty() => const _Generation(
        raw: '',
        thinkingText: '',
        end: null,
        outputTokens: 0,
        thinkingTokens: 0,
        thinkingBudgetHit: false,
      );
}

/// Instrução da resposta final forçada.
const String kForceFinalInstruction =
    'Responde AGORA ao utilizador com a melhor resposta possível, em português, '
    'sem chamadas de ferramentas e sem bloco <think>.';

/// System prompt por defeito do agente de demonstração.
const String kDefaultAgentSystemPrompt =
    'És um assistente local com ferramentas. Só tens carregada a ferramenta '
    'search_tools; se precisares de outra, procura-a no catálogo. Quando '
    'tiveres a resposta, chama final_answer uma única vez. Nunca repitas a '
    'mesma chamada com os mesmos argumentos. Responde em português.';

/// Adaptador mínimo para o [LoopGuard] (chave canónica).
class _Key implements ToolCallKey {
  @override
  final String canonicalKey;
  const _Key(this.canonicalKey);
}
