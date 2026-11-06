/// Configuração determinística dos motores Liquid AI LFM3 e d1.
///
/// A receita de amostragem segue os model cards oficiais da família LFM3
/// (outubro de 2026): perfis separados para agente/tool calling, matemática,
/// visão, ASR, TTS/voz entrelaçada e omni-modal. Tudo o que altera a saída
/// entra no [fingerprint] — a mesma impressão deve produzir a mesma resposta
/// no mesmo dispositivo/runtime.
///
/// O motor de decisão d1 não amostra: um único forward pass devolve
/// probabilidades calibradas. A configuração dele vive em [D1Config].
library;

import 'dart:convert';

/// Perfil de execução LFM3 (preset de amostragem + modo de raciocínio).
enum Lfm3Profile {
  /// LFM3-1.7B para agentes, chat, tool calling e código.
  agent,

  /// LFM3-1.7B para matemática/ciência/STEM.
  math,

  /// LFM3-VL-2B para visão, vídeo, OCR e grounding.
  vision,

  /// LFM3-Audio-2B para ASR/compreensão de áudio (saída texto).
  audioAsr,

  /// LFM3-Audio-2B para TTS e voice chat entrelaçado.
  audioTts,

  /// LFM3-Omni-2B para compreensão omni-modal (sem raciocínio).
  omni,

  /// Valores editados manualmente (sem preset).
  custom,
}

extension Lfm3ProfileWire on Lfm3Profile {
  String get wire => name;

  String get label => switch (this) {
        Lfm3Profile.agent => 'Agente / tools',
        Lfm3Profile.math => 'Matemática / STEM',
        Lfm3Profile.vision => 'Visão / vídeo',
        Lfm3Profile.audioAsr => 'Áudio ASR (texto)',
        Lfm3Profile.audioTts => 'Áudio TTS / voz',
        Lfm3Profile.omni => 'Omni-modal',
        Lfm3Profile.custom => 'Personalizado',
      };

  static Lfm3Profile fromWire(String? s) => Lfm3Profile.values.firstWhere(
        (p) => p.wire == s,
        orElse: () => Lfm3Profile.agent,
      );
}

/// Tipo do KV cache (F16 = 12,29 KB/token; Q8_0 = 6,53 KB/token no LFM3).
enum KvCacheType { f16, q8_0 }

extension KvCacheTypeX on KvCacheType {
  String get wire => switch (this) {
        KvCacheType.f16 => 'f16',
        KvCacheType.q8_0 => 'q8_0',
      };

  /// Valor de `enum ggml_type` no llama.cpp.
  /// `GGML_TYPE_F16 = 1`, `GGML_TYPE_Q8_0 = 8`.
  int get ggmlType => switch (this) {
        KvCacheType.f16 => 1,
        KvCacheType.q8_0 => 8,
      };

  static KvCacheType fromWire(String? s) =>
      s == 'q8_0' ? KvCacheType.q8_0 : KvCacheType.f16;
}

/// Formato de resposta pedido ao modelo.
enum ResponseFormat { text, jsonObject, jsonSchema }

extension ResponseFormatWire on ResponseFormat {
  String get wire => switch (this) {
        ResponseFormat.text => 'text',
        ResponseFormat.jsonObject => 'json_object',
        ResponseFormat.jsonSchema => 'json_schema',
      };

  static ResponseFormat fromWire(String? s) => switch (s) {
        'json_object' => ResponseFormat.jsonObject,
        'json_schema' => ResponseFormat.jsonSchema,
        _ => ResponseFormat.text,
      };
}

/// Configuração do motor gerador (LFM3-1.7B / VL / Audio / Omni).
class LlmConfig {
  /// Seed fixa (determinismo). NUNCA -1 (no llama.cpp -1 = aleatória).
  final int seed;

  /// Perfil que originou os valores (auditoria/UI).
  final Lfm3Profile profile;

  /// Temperatura de texto. 0.0 = greedy (recomendado para ASR/Omni).
  final double temperature;
  final int topK;

  /// `top_p` do LFM3: 1.0 no perfil de agente, 0.95 em matemática.
  final double topP;

  /// `min_p` do LFM3: 0.0 em todos os perfis móveis.
  final double minP;

  /// `repeat_penalty` do LFM3: 1.1 no agente/visão, 1.0 em matemática.
  final double repeatPenalty;
  final int repeatLastN;

  /// Presença/frequência: 0.0 = desligadas (não reordenam candidatos).
  final double presencePenalty;
  final double frequencyPenalty;

  /// DRY opcional (defesa adicional anti-loop). Desligado por omissão na
  /// receita LFM3; pode ser ligado sem alterar o fingerprint da receita.
  final bool dryEnabled;
  final double dryMultiplier;
  final double dryBase;
  final int dryAllowedLength;
  final int dryPenaltyLastN;

  /// Teto EXPLÍCITO de tokens por resposta (o llama.cpp tem -1 = infinito).
  final int maxTokens;

  /// Teto do bloco `<think>` (o raciocínio pode consumir o orçamento todo
  /// antes de emitir um `<tool_call>`; 1024 é o default móvel).
  final int maxThinkingTokens;

  /// Ativa o raciocínio (`<think>`). LFM3-1.7B e VL-2B suportam; o Omni não.
  final bool enableThinking;

  /// Preserva `<think>` de turnos antigos no histórico (gasta contexto).
  final bool preserveThinking;

  /// Threads de CPU: núcleos de performance − 2 em mobile.
  final int threads;

  /// Contexto. O LFM3 suporta 256K, mas o KV cresce 12,29 KB/token em FP16
  /// (6,53 KB/token em Q8_0). Em 8 GB de RAM: 8K–32K.
  final int contextSize;

  /// Camadas na GPU. Semântica llama.cpp: 0 = CPU; N = N camadas; negativo =
  /// todas (Metal em Apple físico; Android usa 0 por omissão).
  final int gpuLayers;

  /// Reutilização do prefixo KV (essencial com Deferred Tool Loading: o
  /// system prompt inicial fica imutável).
  final bool cachePrompt;

  /// `use_mmap = true` — os pesos são páginas de ficheiro geridas pelo SO,
  /// não inflacionam a RSS da app perante Jetsam/LMK.
  final bool useMmap;

  final KvCacheType kvTypeK;
  final KvCacheType kvTypeV;

  /// Flash Attention (Metal/CPU). Auto no llama.cpp quando true.
  final bool flashAttn;

  /// Batch lógico/físico do prefill.
  final int nBatch;
  final int nUbatch;

  /// Limite de tokens visuais por imagem (acelera o prefill em mobile).
  final int imageMaxTokens;

  /// Taxa de amostragem de vídeo nativo (2 fps na família LFM3).
  final double videoFps;

  /// Parâmetros de fala (LiquidCodec, 24 kHz na saída).
  final double audioTemperature;
  final int audioTopK;
  final double audioRepeatPenalty;
  final int audioWindow;
  final bool suppressMixed;
  final bool suppressAudioOut;

  /// Formato de resposta estruturada.
  final ResponseFormat responseFormat;
  final String? responseJsonSchema;

  /// Ordem explícita de samplers (determinismo/auditoria).
  static const String samplersOrder =
      'penalties;dry;top_k;top_p;min_p;temperature';

  const LlmConfig({
    this.seed = 42,
    this.profile = Lfm3Profile.agent,
    this.temperature = 0.1,
    this.topK = 50,
    this.topP = 1.0,
    this.minP = 0.0,
    this.repeatPenalty = 1.1,
    this.repeatLastN = 64,
    this.presencePenalty = 0.0,
    this.frequencyPenalty = 0.0,
    this.dryEnabled = false,
    this.dryMultiplier = 0.8,
    this.dryBase = 1.75,
    this.dryAllowedLength = 2,
    this.dryPenaltyLastN = 1024,
    this.maxTokens = 1024,
    this.maxThinkingTokens = 1024,
    this.enableThinking = true,
    this.preserveThinking = false,
    this.threads = 7,
    this.contextSize = 8192,
    this.gpuLayers = -1,
    this.cachePrompt = true,
    this.useMmap = true,
    this.kvTypeK = KvCacheType.f16,
    this.kvTypeV = KvCacheType.f16,
    this.flashAttn = true,
    this.nBatch = 2048,
    this.nUbatch = 512,
    this.imageMaxTokens = 1024,
    this.videoFps = 2.0,
    this.audioTemperature = 1.0,
    this.audioTopK = 128,
    this.audioRepeatPenalty = 1.1,
    this.audioWindow = 4096,
    this.suppressMixed = false,
    this.suppressAudioOut = false,
    this.responseFormat = ResponseFormat.text,
    this.responseJsonSchema,
  });

  /// Preset oficial por perfil.
  factory LlmConfig.forProfile(Lfm3Profile profile) => switch (profile) {
        Lfm3Profile.agent => const LlmConfig(),
        Lfm3Profile.math => const LlmConfig(
            profile: Lfm3Profile.math,
            temperature: 1.0,
            topK: 20,
            topP: 0.95,
            minP: 0.0,
            repeatPenalty: 1.0,
            maxTokens: 2048,
            maxThinkingTokens: 2048,
            enableThinking: true,
          ),
        Lfm3Profile.vision => const LlmConfig(
            profile: Lfm3Profile.vision,
            temperature: 0.1,
            topK: 50,
            topP: 1.0,
            minP: 0.0,
            repeatPenalty: 1.1,
            enableThinking: true,
            contextSize: 16384,
            imageMaxTokens: 1024,
          ),
        Lfm3Profile.audioAsr => const LlmConfig(
            profile: Lfm3Profile.audioAsr,
            temperature: 0.0,
            topK: 0,
            topP: 1.0,
            minP: 0.0,
            repeatPenalty: 1.0,
            enableThinking: false,
            maxTokens: 1024,
            maxThinkingTokens: 0,
            contextSize: 8192,
            suppressMixed: true,
            suppressAudioOut: true,
          ),
        Lfm3Profile.audioTts => const LlmConfig(
            profile: Lfm3Profile.audioTts,
            temperature: 0.0,
            topK: 0,
            topP: 1.0,
            minP: 0.0,
            repeatPenalty: 1.0,
            enableThinking: false,
            maxTokens: 2048,
            maxThinkingTokens: 0,
            contextSize: 8192,
            audioTemperature: 1.0,
            audioTopK: 128,
            audioRepeatPenalty: 1.1,
            audioWindow: 4096,
          ),
        Lfm3Profile.omni => const LlmConfig(
            profile: Lfm3Profile.omni,
            temperature: 0.0,
            topK: 0,
            topP: 1.0,
            minP: 0.0,
            repeatPenalty: 1.0,
            enableThinking: false,
            maxTokens: 2048,
            maxThinkingTokens: 0,
            contextSize: 16384,
            audioTemperature: 0.4,
            audioTopK: 128,
            audioRepeatPenalty: 1.2,
            audioWindow: 4096,
          ),
        Lfm3Profile.custom => const LlmConfig(profile: Lfm3Profile.custom),
      };

  LlmConfig copyWith({
    int? seed,
    Lfm3Profile? profile,
    double? temperature,
    int? topK,
    double? topP,
    double? minP,
    double? repeatPenalty,
    int? repeatLastN,
    double? presencePenalty,
    double? frequencyPenalty,
    bool? dryEnabled,
    double? dryMultiplier,
    double? dryBase,
    int? dryAllowedLength,
    int? dryPenaltyLastN,
    int? maxTokens,
    int? maxThinkingTokens,
    bool? enableThinking,
    bool? preserveThinking,
    int? threads,
    int? contextSize,
    int? gpuLayers,
    bool? cachePrompt,
    bool? useMmap,
    KvCacheType? kvTypeK,
    KvCacheType? kvTypeV,
    bool? flashAttn,
    int? nBatch,
    int? nUbatch,
    int? imageMaxTokens,
    double? videoFps,
    double? audioTemperature,
    int? audioTopK,
    double? audioRepeatPenalty,
    int? audioWindow,
    bool? suppressMixed,
    bool? suppressAudioOut,
    ResponseFormat? responseFormat,
    String? responseJsonSchema,
  }) =>
      LlmConfig(
        seed: seed ?? this.seed,
        profile: profile ?? this.profile,
        temperature: temperature ?? this.temperature,
        topK: topK ?? this.topK,
        topP: topP ?? this.topP,
        minP: minP ?? this.minP,
        repeatPenalty: repeatPenalty ?? this.repeatPenalty,
        repeatLastN: repeatLastN ?? this.repeatLastN,
        presencePenalty: presencePenalty ?? this.presencePenalty,
        frequencyPenalty: frequencyPenalty ?? this.frequencyPenalty,
        dryEnabled: dryEnabled ?? this.dryEnabled,
        dryMultiplier: dryMultiplier ?? this.dryMultiplier,
        dryBase: dryBase ?? this.dryBase,
        dryAllowedLength: dryAllowedLength ?? this.dryAllowedLength,
        dryPenaltyLastN: dryPenaltyLastN ?? this.dryPenaltyLastN,
        maxTokens: maxTokens ?? this.maxTokens,
        maxThinkingTokens: maxThinkingTokens ?? this.maxThinkingTokens,
        enableThinking: enableThinking ?? this.enableThinking,
        preserveThinking: preserveThinking ?? this.preserveThinking,
        threads: threads ?? this.threads,
        contextSize: contextSize ?? this.contextSize,
        gpuLayers: gpuLayers ?? this.gpuLayers,
        cachePrompt: cachePrompt ?? this.cachePrompt,
        useMmap: useMmap ?? this.useMmap,
        kvTypeK: kvTypeK ?? this.kvTypeK,
        kvTypeV: kvTypeV ?? this.kvTypeV,
        flashAttn: flashAttn ?? this.flashAttn,
        nBatch: nBatch ?? this.nBatch,
        nUbatch: nUbatch ?? this.nUbatch,
        imageMaxTokens: imageMaxTokens ?? this.imageMaxTokens,
        videoFps: videoFps ?? this.videoFps,
        audioTemperature: audioTemperature ?? this.audioTemperature,
        audioTopK: audioTopK ?? this.audioTopK,
        audioRepeatPenalty: audioRepeatPenalty ?? this.audioRepeatPenalty,
        audioWindow: audioWindow ?? this.audioWindow,
        suppressMixed: suppressMixed ?? this.suppressMixed,
        suppressAudioOut: suppressAudioOut ?? this.suppressAudioOut,
        responseFormat: responseFormat ?? this.responseFormat,
        responseJsonSchema: responseJsonSchema ?? this.responseJsonSchema,
      );

  Map<String, dynamic> toJson() => {
        'seed': seed,
        'profile': profile.wire,
        'temperature': temperature,
        'top_p': topP,
        'top_k': topK,
        'min_p': minP,
        'repeat_penalty': repeatPenalty,
        'repeat_last_n': repeatLastN,
        'presence_penalty': presencePenalty,
        'frequency_penalty': frequencyPenalty,
        'dry': {
          'enabled': dryEnabled,
          'multiplier': dryMultiplier,
          'base': dryBase,
          'allowed_length': dryAllowedLength,
          'penalty_last_n': dryPenaltyLastN,
        },
        'samplers': samplersOrder,
        'max_tokens': maxTokens,
        'max_thinking_tokens': maxThinkingTokens,
        'enable_thinking': enableThinking,
        'preserve_thinking': preserveThinking,
        'threads': threads,
        'context_size': contextSize,
        'gpu_layers': gpuLayers,
        'cache_prompt': cachePrompt,
        'use_mmap': useMmap,
        'kv_type_k': kvTypeK.wire,
        'kv_type_v': kvTypeV.wire,
        'flash_attn': flashAttn,
        'n_batch': nBatch,
        'n_ubatch': nUbatch,
        'image_max_tokens': imageMaxTokens,
        'video_fps': videoFps,
        'audio': {
          'temperature': audioTemperature,
          'top_k': audioTopK,
          'repetition_penalty': audioRepeatPenalty,
          'window': audioWindow,
          'suppress_mixed': suppressMixed,
          'suppress_audio_out': suppressAudioOut,
        },
        'response_format': responseFormat.wire,
        if (responseJsonSchema != null) 'json_schema': responseJsonSchema,
      };

  factory LlmConfig.fromJson(Map<String, dynamic> j) {
    final dry = (j['dry'] as Map?)?.cast<String, dynamic>() ?? const {};
    final audio = (j['audio'] as Map?)?.cast<String, dynamic>() ?? const {};
    return LlmConfig(
      seed: (j['seed'] as num?)?.toInt() ?? 42,
      profile: Lfm3ProfileWire.fromWire(j['profile'] as String?),
      temperature: (j['temperature'] as num?)?.toDouble() ?? 0.1,
      topP: (j['top_p'] as num?)?.toDouble() ?? 1.0,
      topK: (j['top_k'] as num?)?.toInt() ?? 50,
      minP: (j['min_p'] as num?)?.toDouble() ?? 0.0,
      repeatPenalty: (j['repeat_penalty'] as num?)?.toDouble() ?? 1.1,
      repeatLastN: (j['repeat_last_n'] as num?)?.toInt() ?? 64,
      presencePenalty: (j['presence_penalty'] as num?)?.toDouble() ?? 0.0,
      frequencyPenalty: (j['frequency_penalty'] as num?)?.toDouble() ?? 0.0,
      dryEnabled: dry['enabled'] as bool? ?? false,
      dryMultiplier: (dry['multiplier'] as num?)?.toDouble() ?? 0.8,
      dryBase: (dry['base'] as num?)?.toDouble() ?? 1.75,
      dryAllowedLength: (dry['allowed_length'] as num?)?.toInt() ?? 2,
      dryPenaltyLastN: (dry['penalty_last_n'] as num?)?.toInt() ?? 1024,
      maxTokens: (j['max_tokens'] as num?)?.toInt() ?? 1024,
      maxThinkingTokens: (j['max_thinking_tokens'] as num?)?.toInt() ?? 1024,
      enableThinking: j['enable_thinking'] as bool? ?? true,
      preserveThinking: j['preserve_thinking'] as bool? ?? false,
      threads: (j['threads'] as num?)?.toInt() ?? 7,
      contextSize: (j['context_size'] as num?)?.toInt() ?? 8192,
      gpuLayers: (j['gpu_layers'] as num?)?.toInt() ?? -1,
      cachePrompt: j['cache_prompt'] as bool? ?? true,
      useMmap: j['use_mmap'] as bool? ?? true,
      kvTypeK: KvCacheTypeX.fromWire(j['kv_type_k'] as String?),
      kvTypeV: KvCacheTypeX.fromWire(j['kv_type_v'] as String?),
      flashAttn: j['flash_attn'] as bool? ?? true,
      nBatch: (j['n_batch'] as num?)?.toInt() ?? 2048,
      nUbatch: (j['n_ubatch'] as num?)?.toInt() ?? 512,
      imageMaxTokens: (j['image_max_tokens'] as num?)?.toInt() ?? 1024,
      videoFps: (j['video_fps'] as num?)?.toDouble() ?? 2.0,
      audioTemperature: (audio['temperature'] as num?)?.toDouble() ?? 1.0,
      audioTopK: (audio['top_k'] as num?)?.toInt() ?? 128,
      audioRepeatPenalty:
          (audio['repetition_penalty'] as num?)?.toDouble() ?? 1.1,
      audioWindow: (audio['window'] as num?)?.toInt() ?? 4096,
      suppressMixed: audio['suppress_mixed'] as bool? ?? false,
      suppressAudioOut: audio['suppress_audio_out'] as bool? ?? false,
      responseFormat: ResponseFormatWire.fromWire(j['response_format'] as String?),
      responseJsonSchema: j['json_schema'] as String?,
    );
  }

  /// Impressão canónica determinística (JSON com chaves ordenadas).
  String get fingerprint {
    final sorted = Map<String, dynamic>.fromEntries(
        toJson().entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
    return jsonEncode(sorted);
  }

  /// Estimativa do KV cache em bytes, segundo a arquitetura tri-híbrida do
  /// LFM3: 13 camadas de convolução curta (estado fixo), 5 SWA de 256 tokens
  /// e apenas 6 camadas de atenção global lineares.
  int estimatedKvBytes({int? contextTokens, KvCacheType? type}) {
    final ctx = contextTokens ?? contextSize;
    final t = type ?? kvTypeK;
    final bytesPerElement = t == KvCacheType.f16 ? 2 : 1;
    const globalLayers = 6;
    const kvHeads = 4;
    const headDim = 128;
    const convLayers = 13;
    const convChannels = 2048;
    const convKernel = 7;
    const swaLayers = 5;
    const swaWindow = 256;
    final linear = globalLayers * kvHeads * headDim * 2 * ctx;
    final conv = convLayers * convKernel * convChannels;
    final swa = swaLayers * kvHeads * headDim * 2 * swaWindow;
    return (linear + conv + swa) * bytesPerElement;
  }

  /// Validação: bloqueia configurações que sabidamente causam loops,
  /// não-determinismo ou OOM. Devolve a lista de violações (vazia = ok).
  List<String> validate() {
    final problems = <String>[];
    if (seed == -1) {
      problems.add('seed -1 = aleatória no llama.cpp; use seed fixa (ex.: 42)');
    }
    if (maxTokens < 1) {
      problems.add('max_tokens tem de ser um teto explícito ≥ 1');
    }
    if (maxThinkingTokens < 0 || maxThinkingTokens > maxTokens) {
      problems.add('max_thinking_tokens deve estar entre 0 e max_tokens');
    }
    if (temperature < 0 || temperature > 2) {
      problems.add('temperature fora do intervalo [0, 2]');
    }
    if (topP <= 0 || topP > 1) {
      problems.add('top_p fora do intervalo (0, 1]');
    }
    if (topK < 0) {
      problems.add('top_k não pode ser negativo (0 = desligado)');
    }
    if (minP < 0 || minP > 1) {
      problems.add('min_p fora do intervalo [0, 1]');
    }
    if (repeatPenalty < 1.0) {
      problems.add('repeat_penalty < 1.0 incentiva repetição (mínimo 1.0)');
    }
    if (repeatPenalty > 1.5) {
      problems.add('repeat_penalty > 1.5 corrompe JSON/tool calls');
    }
    if (contextSize < 512 || contextSize > 262144) {
      problems.add('context_size fora do intervalo [512, 262144]');
    }
    if (threads < 1) {
      problems.add('threads tem de ser ≥ 1');
    }
    if (gpuLayers < -1) {
      problems.add('gpu_layers: -1 = todas, 0 = CPU, N = N camadas');
    }
    if (imageMaxTokens < 0) {
      problems.add('image_max_tokens não pode ser negativo');
    }
    if (videoFps <= 0 || videoFps > 30) {
      problems.add('video_fps fora do intervalo (0, 30]');
    }
    if (audioTemperature < 0) {
      problems.add('audio_temperature não pode ser negativa');
    }
    if (responseFormat == ResponseFormat.jsonSchema &&
        (responseJsonSchema == null || responseJsonSchema!.trim().isEmpty)) {
      problems.add('response_format json_schema exige um schema não vazio');
    }
    if (profile == Lfm3Profile.omni && enableThinking) {
      problems.add('LFM3-Omni-2B não tem modo <think>; desativa o raciocínio');
    }
    return problems;
  }
}

/// Configuração do motor de decisão d1 (ONNX Runtime).
class D1Config {
  /// Threads de CPU para o ONNX Runtime.
  final int threads;

  /// `cpu` (ground truth de determinismo) | `xnnpack` (mais rápido) |
  /// `coreml` (iOS/macOS, fp16).
  final String executionProvider;

  /// Comprimento máximo da sequência de estado + perguntas.
  final int maxStateTokens;

  /// Máximo de perguntas empacotadas num único forward pass (o limite do
  /// contrato d1 é 16).
  final int maxQuestions;

  /// Limite de tokens visuais por imagem.
  final int imageMaxTokens;

  /// Taxa de amostragem de áudio exigida pelo d1-Omni (16 kHz).
  final int audioSampleRate;

  /// Usa os subgrafos fp16/GPU (`decoder_q4f16.onnx` + encoders fp16).
  final bool useFp16;

  /// Mantém as sessões quentes entre decisões (custo de RAM).
  final bool keepWarm;

  /// Duração máxima de um clipe de áudio no d1-Omni (30 s no contrato).
  final double maxAudioSeconds;

  const D1Config({
    this.threads = 4,
    this.executionProvider = 'xnnpack',
    this.maxStateTokens = 8192,
    this.maxQuestions = 16,
    this.imageMaxTokens = 1024,
    this.audioSampleRate = 16000,
    this.useFp16 = true,
    this.keepWarm = false,
    this.maxAudioSeconds = 30,
  });

  D1Config copyWith({
    int? threads,
    String? executionProvider,
    int? maxStateTokens,
    int? maxQuestions,
    int? imageMaxTokens,
    int? audioSampleRate,
    bool? useFp16,
    bool? keepWarm,
    double? maxAudioSeconds,
  }) =>
      D1Config(
        threads: threads ?? this.threads,
        executionProvider: executionProvider ?? this.executionProvider,
        maxStateTokens: maxStateTokens ?? this.maxStateTokens,
        maxQuestions: maxQuestions ?? this.maxQuestions,
        imageMaxTokens: imageMaxTokens ?? this.imageMaxTokens,
        audioSampleRate: audioSampleRate ?? this.audioSampleRate,
        useFp16: useFp16 ?? this.useFp16,
        keepWarm: keepWarm ?? this.keepWarm,
        maxAudioSeconds: maxAudioSeconds ?? this.maxAudioSeconds,
      );

  Map<String, dynamic> toJson() => {
        'threads': threads,
        'execution_provider': executionProvider,
        'max_state_tokens': maxStateTokens,
        'max_questions': maxQuestions,
        'image_max_tokens': imageMaxTokens,
        'audio_sample_rate': audioSampleRate,
        'use_fp16': useFp16,
        'keep_warm': keepWarm,
        'max_audio_seconds': maxAudioSeconds,
      };

  factory D1Config.fromJson(Map<String, dynamic> j) => D1Config(
        threads: (j['threads'] as num?)?.toInt() ?? 4,
        executionProvider: j['execution_provider'] as String? ?? 'xnnpack',
        maxStateTokens: (j['max_state_tokens'] as num?)?.toInt() ?? 8192,
        maxQuestions: (j['max_questions'] as num?)?.toInt() ?? 16,
        imageMaxTokens: (j['image_max_tokens'] as num?)?.toInt() ?? 1024,
        audioSampleRate: (j['audio_sample_rate'] as num?)?.toInt() ?? 16000,
        useFp16: j['use_fp16'] as bool? ?? true,
        keepWarm: j['keep_warm'] as bool? ?? false,
        maxAudioSeconds: (j['max_audio_seconds'] as num?)?.toDouble() ?? 30,
      );

  List<String> validate() {
    final problems = <String>[];
    if (threads < 1) problems.add('threads tem de ser ≥ 1');
    if (maxStateTokens < 128 || maxStateTokens > 131072) {
      problems.add('max_state_tokens fora do intervalo [128, 131072]');
    }
    if (maxQuestions < 1 || maxQuestions > 16) {
      problems.add('max_questions tem de estar entre 1 e 16');
    }
    if (imageMaxTokens < 0 || imageMaxTokens > 4096) {
      problems.add('image_max_tokens fora do intervalo [0, 4096]');
    }
    if (audioSampleRate != 16000) {
      problems.add('d1-Omni exige áudio a 16 kHz');
    }
    if (!const {'cpu', 'xnnpack', 'coreml'}.contains(executionProvider)) {
      problems.add('execution_provider deve ser cpu, xnnpack ou coreml');
    }
    return problems;
  }
}
