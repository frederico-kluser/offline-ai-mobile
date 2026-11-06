/// Contrato dos motores geradores LFM3.
///
/// Os motores concretos são:
///  - [LlamaLfm3FfiEngine] (llama.cpp + libmtmd) para LFM3-1.7B, VL-2B,
///    Audio-2B e Omni-2B;
///  - implementações falsas/injetáveis nos testes.
///
/// O contrato é intencionalmente pequeno: carregar/descarregar, gerar em
/// streaming com eventos explícitos de fim e nunca bloquear a UI thread.
library;

import '../domain/llm_config.dart';
import '../domain/media_attachment.dart';

/// Família do modelo carregado (decide o template e as capacidades).
enum Lfm3ModelKind { text, vision, audio, omni }

extension Lfm3ModelKindX on Lfm3ModelKind {
  String get wire => name;

  bool get supportsVision => this == Lfm3ModelKind.vision || this == Lfm3ModelKind.omni;
  bool get supportsAudio => this == Lfm3ModelKind.audio || this == Lfm3ModelKind.omni;
  bool get supportsThinking => this == Lfm3ModelKind.text || this == Lfm3ModelKind.vision;
  bool get supportsVideo => this == Lfm3ModelKind.vision || this == Lfm3ModelKind.omni;
}

/// Mensagem de chat no formato que o template LFM3 espera.
class ChatMessage {
  final String role; // 'system' | 'user' | 'assistant' | 'tool'
  final String content;

  /// Nome da ferramenta (role == 'tool' ou assistant com tool call).
  final String? toolName;

  /// Esquemas descobertos por `search_tools`, injetados em `<additional_tools>`
  /// na mensagem de tool response.
  final List<Map<String, dynamic>> additionalTools;

  /// Conteúdo de raciocínio separado (quando o chamador já o isolou).
  final String? thinking;

  const ChatMessage(
    this.role,
    this.content, {
    this.toolName,
    this.additionalTools = const [],
    this.thinking,
  });

  Map<String, dynamic> toJson() => {
        'role': role,
        'content': content,
        if (toolName != null) 'tool_name': toolName,
        if (additionalTools.isNotEmpty) 'additional_tools': additionalTools,
        if (thinking != null) 'thinking': thinking,
      };
}

/// Entrada multimodal para o motor (os caminhos são ficheiros locais).
class LlmMediaInput {
  final MediaKind kind;

  /// Imagem: PNG/JPEG; áudio: WAV PCM 16 kHz mono; vídeo: MP4.
  final String path;

  /// Para vídeo: frames já extraídos (2 fps) em RGB/JPEG, por ordem.
  final List<String> videoFramePaths;

  /// Para vídeo: WAV PCM 16 kHz da banda sonora (Omni).
  final String? soundtrackPath;

  const LlmMediaInput({
    required this.kind,
    required this.path,
    this.videoFramePaths = const [],
    this.soundtrackPath,
  });

  Map<String, dynamic> toJson() => {
        'kind': kind.wire,
        'path': path,
        if (videoFramePaths.isNotEmpty) 'video_frames': videoFramePaths,
        if (soundtrackPath != null) 'soundtrack': soundtrackPath,
      };
}

/// Eventos de geração. O fim é SEMPRE explícito (nunca implícito por timeout
/// silencioso) — determinismo e auditoria.
sealed class GenEvent {
  const GenEvent();
}

class GenDelta extends GenEvent {
  final String text;

  /// `true` quando o delta pertence ao bloco `<think>`.
  final bool thinking;

  const GenDelta(this.text, {this.thinking = false});
}

class GenEnd extends GenEvent {
  final int promptTokens;
  final int outputTokens;
  final int latencyMs;

  /// `eos` | `max_tokens` | `stop_string` | `aborted` | `error`
  final String stopReason;
  final String? error;

  /// Tokens gastos dentro de `<think>` (orçamento separado).
  final int thinkingTokens;

  /// Tempos medidos no motor nativo (prefill/decode).
  final int prefillMs;
  final int decodeMs;

  /// Amostras PCM F32 a 24 kHz produzidas pelo LiquidCodec (TTS/voz).
  final int audioSamples;

  const GenEnd({
    required this.promptTokens,
    required this.outputTokens,
    required this.latencyMs,
    required this.stopReason,
    this.error,
    this.thinkingTokens = 0,
    this.prefillMs = 0,
    this.decodeMs = 0,
    this.audioSamples = 0,
  });
}

/// Informação do modelo carregado (para a UI e para o perfilador).
class Lfm3ModelInfo {
  final String modelId;
  final Lfm3ModelKind kind;
  final int nCtx;
  final int nEmbd;
  final int nVocab;
  final bool multimodal;
  final bool mmap;
  final String? mmprojPath;

  const Lfm3ModelInfo({
    required this.modelId,
    required this.kind,
    required this.nCtx,
    required this.nEmbd,
    required this.nVocab,
    this.multimodal = false,
    this.mmap = true,
    this.mmprojPath,
  });
}

abstract class LlmEngine {
  bool get isLoaded;
  String get modelId;
  Lfm3ModelKind get kind;
  Lfm3ModelInfo? get info;

  /// Carrega o modelo (mmap dos pesos) e, opcionalmente, o projetor mmproj.
  Future<void> load({
    required String modelPath,
    required LlmConfig config,
    String? mmprojPath,
    Lfm3ModelKind kind = Lfm3ModelKind.text,
  });

  /// Gera em streaming. [media] deve estar na mesma ordem dos marcadores
  /// multimodais no prompt (o template insere-os no último turno do user).
  Stream<GenEvent> generate({
    required List<ChatMessage> messages,
    required LlmConfig config,
    List<LlmMediaInput> media = const [],
    int? maxTokensOverride,
    String? systemPromptOverride,
  });

  /// Contagem de tokens do prompt (via tokenizer do modelo, sem geração).
  Future<int> countTokens(String text);

  /// Libertação "a sério" do handle nativo (nunca manter 2 modelos em RAM).
  Future<void> unload();
}
