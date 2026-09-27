/// Loop de agente determinístico para o exemplo de tool calling do
/// MiniCPM5-2B, com guardrails anti-loop em runtime (dossiê Q7).
///
/// Máquina de estados explícita: MODELO → TOOL(s) → MODELO → … → RESPOSTA
/// FINAL, com corte obrigatório por qualquer guardrail do [LoopGuard]
/// (max steps, max tool calls, ciclos A→A, ping-pong A→B→A→B, SER@4,
/// orçamento de tokens, timeout). Quando um guardrail corta, faz-se UMA
/// tentativa de resposta final forçada (sem tools) e, falhando essa, devolve-se
/// um fallback estático determinístico — o utilizador recebe sempre algo e o
/// motivo de paragem fica registado.
library;

import 'dart:async';

import '../domain/llm_config.dart';
import '../domain/tool_spec.dart';
import '../engines/llm_engine.dart';
import '../guardrails/loop_guard.dart';
import 'minicpm5_chat.dart';
import 'tools.dart';

/// Eventos do loop (para a UI mostrar a timeline).
sealed class ToolLoopEvent {
  const ToolLoopEvent();
}

class LoopText extends ToolLoopEvent {
  final String text;
  const LoopText(this.text);
}

class LoopToolCall extends ToolLoopEvent {
  final ToolCall call;
  final int step;
  const LoopToolCall(this.call, this.step);
}

class LoopToolResult extends ToolLoopEvent {
  final ToolResult result;
  final int step;
  const LoopToolResult(this.result, this.step);
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
  final StopReason stopReason;
  final List<LoopStep> log;
  final List<ToolResult> toolResults;
  final int promptTokens;
  final int outputTokens;
  final int latencyMs;

  const ToolLoopResult({
    required this.answer,
    required this.stopReason,
    required this.log,
    required this.toolResults,
    required this.promptTokens,
    required this.outputTokens,
    required this.latencyMs,
  });
}

/// Fallback estático quando nem a resposta forçada sai (dossiê Q7: fallback
/// determinístico, nunca crash nem loop).
const String kLoopFallbackAnswer =
    'Não consegui concluir dentro dos limites de segurança (passos/tokens). '
    'Reformula a tarefa ou aumenta os limites em Configurações.';

class ToolLoop {
  final LlmEngine llm;
  final List<LocalTool> tools;
  final LoopGuardConfig guardConfig;

  ToolLoop({
    required this.llm,
    required this.tools,
    this.guardConfig = const LoopGuardConfig(),
  });

  /// Corre o agente até à resposta final (ou até um guardrail cortar).
  Stream<ToolLoopEvent> run({
    required String userPrompt,
    String? systemPrompt,
    required LlmConfig config,
  }) {
    late StreamController<ToolLoopEvent> ctrl;
    ctrl = StreamController<ToolLoopEvent>(onListen: () async {
      final sw = Stopwatch()..start();
      final guard = LoopGuard(config: guardConfig);
      final toolResults = <ToolResult>[];
      var promptTokens = 0;
      var outputTokens = 0;
      var answer = '';
      var step = 0;

      final catalog = [...tools.map((t) => t.spec), finalAnswerSpec];
      // As definições de tools entram no CONTEÚDO do system message (como o
      // Jinja oficial faz); o engine renderiza o template SEM catálogo.
      final messages = <ChatMessage>[
        ChatMessage(
            'system',
            '${systemPrompt ?? kDefaultAgentSystemPrompt}\n\n'
            '${renderToolDefinitions(catalog)}'),
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

          // Geração com supervisão anti-loop (o engine renderiza o template
          // oficial do MiniCPM5 sobre as mensagens).
          final buf = StringBuffer();
          GenEnd? end;
          final sub = llm
              .generate(
                messages: messages,
                config: config,
                maxTokensOverride: config.maxTokens,
              )
              .listen((ev) {
            if (ev is GenDelta) {
              buf.write(ev.text);
              outputTokens += 1;
              guard.addTokens(1);
              // SER@4 em runtime: corta geração degenerada a meio.
              if (!guard.checkTextRepetition(buf.toString())) {
                ctrl.add(LoopGuardTrip(guard.state.stop!,
                    '${guard.state.stop!.explanation} (a meio da geração)'));
              }
              ctrl.add(LoopText(ev.text));
            } else if (ev is GenEnd) {
              end = ev;
              promptTokens += ev.promptTokens;
            }
          });
          await sub.asFuture<void>().catchError((_) {});
          await sub.cancel();

          if (guard.state.finished &&
              guard.state.stop != StopReason.finalAnswer) {
            break; // corte anti-loop a meio da geração
          }
          if (end?.stopReason == 'error') {
            guard.fail();
            ctrl.add(LoopGuardTrip(
                StopReason.engineError, 'erro do motor: ${end?.error}'));
            break;
          }

          final raw = buf.toString();
          messages.add(ChatMessage('assistant', raw));
          final parsed = parseToolCalls(raw, specs: catalog);

          // Resposta final canónica: ferramenta final_answer.
          final fin = parsed.calls.where((c) => c.name == 'final_answer');
          if (fin.isNotEmpty) {
            answer = (fin.first.args['answer'] ?? '').toString();
            guard.finish();
            break;
          }

          if (parsed.hasCalls) {
            for (final call in parsed.calls) {
              if (!guard.beforeToolCall(_Key(call.canonicalKey))) {
                ctrl.add(LoopGuardTrip(guard.state.stop!,
                    '${guard.state.stop!.explanation} (${call.canonicalKey})'));
                break;
              }
              ctrl.add(LoopToolCall(call, step));
              final tool = _toolByName(call.name);
              final ToolResult result;
              if (tool == null) {
                result = ToolResult(
                  name: call.name,
                  ok: false,
                  output: 'error: ferramenta desconhecida "$call.name"',
                  durationMs: 0,
                  errorKind: 'unknown-tool',
                );
              } else {
                result = await runTool(tool, call.args);
              }
              toolResults.add(result);
              ctrl.add(LoopToolResult(result, step));
              messages.add(ChatMessage('tool', result.output,
                  toolName: result.name));
            }
            if (guard.state.finished) break;
            continue; // volta ao modelo com os resultados
          }

          // Sem tool calls: texto corrido é a resposta final.
          answer = parsed.text;
          guard.finish();
          break;
        }

        // Resposta final FORÇADA quando o loop cortou sem resposta
        // (dossiê Q7: uma última chamada sem tools, senão fallback estático).
        if (answer.isEmpty && guard.state.stop != StopReason.finalAnswer) {
          answer = await _forcedFinal(messages, config, guard);
        }

        ctrl.add(LoopEnd(ToolLoopResult(
          answer: answer.isEmpty ? kLoopFallbackAnswer : answer,
          stopReason: guard.state.stop ?? StopReason.finalAnswer,
          log: List.unmodifiable(guard.state.log),
          toolResults: List.unmodifiable(toolResults),
          promptTokens: promptTokens,
          outputTokens: outputTokens,
          latencyMs: sw.elapsedMilliseconds,
        )));
      } catch (e) {
        guard.fail();
        ctrl.add(LoopGuardTrip(
            StopReason.engineError, 'erro inesperado: $e'));
        ctrl.add(LoopEnd(ToolLoopResult(
          answer: kLoopFallbackAnswer,
          stopReason: StopReason.engineError,
          log: List.unmodifiable(guard.state.log),
          toolResults: List.unmodifiable(toolResults),
          promptTokens: promptTokens,
          outputTokens: outputTokens,
          latencyMs: sw.elapsedMilliseconds,
        )));
      }
      await ctrl.close();
    });
    return ctrl.stream;
  }

  /// Última tentativa: geração curta SEM catálogo de tools (a ausência de
  /// tools elimina a possibilidade de novo ciclo).
  Future<String> _forcedFinal(List<ChatMessage> messages, LlmConfig config,
      LoopGuard guard) async {
    final forced = <ChatMessage>[
      const ChatMessage('system', kDefaultAgentSystemPrompt), // sem tools
      ...messages.skip(1), // histórico sem o system com tools
      const ChatMessage('user', kForceFinalInstruction),
    ];
    final buf = StringBuffer();
    try {
      final done = Completer<void>();
      llm
          .generate(
            messages: forced,
            config: config,
            maxTokensOverride: 160,
          )
          .listen((ev) {
        if (ev is GenDelta) buf.write(ev.text);
        if (ev is GenEnd && !done.isCompleted) done.complete();
      }, onError: (_) {
        if (!done.isCompleted) done.complete();
      }, onDone: () {
        if (!done.isCompleted) done.complete();
      });
      await done.future.timeout(const Duration(seconds: 60),
          onTimeout: () {});
    } catch (_) {
      return kLoopFallbackAnswer;
    }
    final text = buf.toString().trim();
    if (text.isEmpty) return kLoopFallbackAnswer;
    final parsed = parseToolCalls(text);
    return parsed.text.isEmpty ? kLoopFallbackAnswer : parsed.text;
  }

  LocalTool? _toolByName(String name) {
    for (final t in tools) {
      if (t.spec.name == name) return t;
    }
    return null;
  }
}

/// Instrução da resposta final forçada (dossiê Q7: `early_stopping generate`).
const String kForceFinalInstruction =
    'Responde AGORA ao utilizador com a melhor resposta possível, em português, '
    'sem chamadas de ferramentas.';

/// System prompt por defeito do agente de demonstração: few-shot estrito do
/// formato XML (o prompt é orientação; o enforcement é o LoopGuard).
const String kDefaultAgentSystemPrompt =
    'És um assistente local com ferramentas. Usa as ferramentas quando '
    'ajudarem a responder com exatidão; quando tiveres a resposta, chama '
    'final_answer uma única vez. Nunca repitas a mesma chamada com os mesmos '
    'argumentos. Responde em português.';

/// Adaptador mínimo para o [LoopGuard] (chave canónica).
class _Key implements ToolCallKey {
  @override
  final String canonicalKey;
  const _Key(this.canonicalKey);
}