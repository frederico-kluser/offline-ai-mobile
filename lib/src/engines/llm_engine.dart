/// Interface do motor do LLM (MiniCPM5-2B via llama.cpp).
///
/// Contrato mínimo e determinístico: carregar/descarregar, gerar em streaming
/// com eventos explícitos de fim (contagem de tokens e motivo de paragem) e
/// nunca inferir na UI thread. A implementação concreta (dart:ffi sobre
/// libllama) vive em `llm_engine_llama.dart`.
library;

import '../domain/llm_config.dart';

/// Mensagem de chat no formato que o chat template do MiniCPM5 espera.
class ChatMessage {
  final String role; // 'system' | 'user' | 'assistant' | 'tool'
  final String content;

  /// Nome da ferramenta (role == 'tool' ou assistant com tool call).
  final String? toolName;

  const ChatMessage(this.role, this.content, {this.toolName});

  Map<String, dynamic> toJson() => {
        'role': role,
        'content': content,
        if (toolName != null) 'tool_name': toolName,
      };
}

/// Eventos de geração. O fim é SEMPRE explícito (nunca implícito por timeout
/// silencioso) — determinismo e auditoria.
sealed class GenEvent {
  const GenEvent();
}

class GenDelta extends GenEvent {
  final String text;
  const GenDelta(this.text);
}

class GenEnd extends GenEvent {
  final int promptTokens;
  final int outputTokens;
  final int latencyMs;

  /// `eos` | `max_tokens` | `stop_string` | `aborted` | `error`
  final String stopReason;
  final String? error;

  const GenEnd({
    required this.promptTokens,
    required this.outputTokens,
    required this.latencyMs,
    required this.stopReason,
    this.error,
  });
}

abstract class LlmEngine {
  bool get isLoaded;
  String get modelId;

  /// Carrega o modelo (mmap dos pesos) e aplica a configuração.
  Future<void> load({required String modelPath, required LlmConfig config});

  /// Gera em streaming. A configuração é re-aplicada por chamada (seed
  /// incluída) para que cada execução seja reprodutível.
  ///
  /// CONTRATO DE RENDERIZAÇÃO: o engine renderiza o chat template oficial do
  /// MiniCPM5 sobre [messages] (ver `renderChat` em
  /// `lib/src/agent/minicpm5_chat.dart`) SEM catálogo de tools — quando há
  /// ferramentas, as definições já vêm dentro do conteúdo do system message.
  Stream<GenEvent> generate({
    required List<ChatMessage> messages,
    required LlmConfig config,
    int? maxTokensOverride,
  });

  /// Contagem de tokens do prompt (via tokenizer do modelo, sem geração).
  Future<int> countTokens(String text);

  /// Libertação "a sério" do handle nativo (nunca manter 2 modelos em memória).
  Future<void> unload();
}