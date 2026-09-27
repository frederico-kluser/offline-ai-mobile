/// Configuração determinística do LLM (MiniCPM5-2B via llama.cpp).
///
/// Filosofia: "mais qualidade que performance, mais determinismo que
/// liberdade". Os defaults seguem a RECEITA OFICIAL do model card do
/// MiniCPM5-2B (temperature=1.0, top_p=0.95, min_p=0.0) com SEED FIXA para
/// reprodutibilidade — não greedy, porque greedy (temperature=0) AUMENTA o
/// risco de loops auto-reforçados (dossiê Q2). `min_p=0.0` é obrigatório: o
/// default 0.05 do llama.cpp filtra os tokens que quebrariam o ciclo de
/// repetição e é a causa raiz dos "loops eternos" deste modelo.
///
/// Tudo o que afeta a saída entra no [fingerprint] — duas execuções com a
/// mesma impressão DEVEM dar o mesmo texto no mesmo device/runtime (o
/// não-determinismo residual de kernels é registado em Limitações).
library;

import 'dart:convert';

class LlmConfig {
  /// Seed fixa (determinismo). NUNCA -1 (no llama.cpp -1 = seed aleatória).
  final int seed;

  /// Receita oficial do MiniCPM5-2B: 1.0. Greedy (0.0) é um modo alternativo
  /// que exige DRY + deteção em runtime (mais propenso a loops).
  final double temperature;

  /// Receita oficial: top_p=0.95. Em greedy deve ser 1.0.
  final double topP;
  final int topK;

  /// min_p=0.0 é OBRIGATÓRIO para o MiniCPM5-2B — causa raiz dos loops
  /// (default 0.05 do llama.cpp; resposta oficial da OpenBMB).
  final double minP;

  /// Penalidade de repetição. 1.0 = neutra (desligada). A receita oficial
  /// recomenda 1.05 SÓ se a repetição persistir; o operador é mal definido e
  /// pode corromper JSON de tool calls — por isso 1.0 por defeito e DRY ativo.
  final double repeatPenalty;
  final int repeatLastN;

  /// Presença/frequência: 0.0 = desligadas (não reordenam candidatos).
  final double presencePenalty;
  final double frequencyPenalty;

  /// Sampler DRY ("Don't Repeat Yourself") — a defesa anti-loop mais robusta
  /// para tool calling, sem corromper formatação/JSON (dossiê Q2).
  /// λ=0.8, β=1.75, allowed_length=2, janela 1024 (sweep de 34 944 gerações).
  final bool dryEnabled;
  final double dryMultiplier;
  final double dryBase;
  final int dryAllowedLength;
  final int dryPenaltyLastN;

  /// Ordem explícita de samplers (o default do llama.cpp inclui min_p a 0.05;
  /// aqui a ordem é fixa e registada — determinismo).
  static const String samplersOrder = 'penalties;dry;top_k;top_p;min_p;temperature';

  /// Teto EXPLÍCITO de tokens por resposta. O llama.cpp tem n_predict=-1
  /// (infinito!) por omissão — nunca confiar nisso.
  final int maxTokens;

  /// Modo thinking do chat template (`enable_thinking`). OFF para respostas
  /// curtas; ON para tool-use complexo.
  final bool enableThinking;

  /// Threads de CPU: `big_cores − 1` (doc §18).
  final int threads;

  /// Contexto. O modelo suporta 131k MAS o KV cache custa ~42 KB/token
  /// (42 camadas × 2 KV heads × head_dim 128): 131k = ~5,5 GB só de KV.
  /// Em 8 GB de RAM: 8k–16k (32k com KV q8_0).
  final int contextSize;

  /// Camadas descarregadas para GPU (0 = CPU; no emulador x86_64 usar CPU).
  final int gpuLayers;

  /// Cache de prompt: amplifica divergência entre execuções (dossiê Q6) —
  /// desligado nas corridas de verificação.
  final bool cachePrompt;

  const LlmConfig({
    this.seed = 42,
    this.temperature = 1.0,
    this.topP = 0.95,
    this.topK = 0,
    this.minP = 0.0,
    this.repeatPenalty = 1.0,
    this.repeatLastN = 64,
    this.presencePenalty = 0.0,
    this.frequencyPenalty = 0.0,
    this.dryEnabled = true,
    this.dryMultiplier = 0.8,
    this.dryBase = 1.75,
    this.dryAllowedLength = 2,
    this.dryPenaltyLastN = 1024,
    this.maxTokens = 512,
    this.enableThinking = false,
    this.threads = 7,
    this.contextSize = 8192,
    this.gpuLayers = 0,
    this.cachePrompt = false,
  });

  /// Perfil alternativo greedy (temperature 0) — mais determinístico no
  /// sentido trivial, mas MAIS propenso a loops; só com DRY + teto de tokens.
  LlmConfig asGreedy() => copyWith(temperature: 0.0, topP: 1.0, topK: 1);

  LlmConfig copyWith({
    int? seed,
    double? temperature,
    double? topP,
    int? topK,
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
    bool? enableThinking,
    int? threads,
    int? contextSize,
    int? gpuLayers,
    bool? cachePrompt,
  }) =>
      LlmConfig(
        seed: seed ?? this.seed,
        temperature: temperature ?? this.temperature,
        topP: topP ?? this.topP,
        topK: topK ?? this.topK,
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
        enableThinking: enableThinking ?? this.enableThinking,
        threads: threads ?? this.threads,
        contextSize: contextSize ?? this.contextSize,
        gpuLayers: gpuLayers ?? this.gpuLayers,
        cachePrompt: cachePrompt ?? this.cachePrompt,
      );

  Map<String, dynamic> toJson() => {
        'seed': seed,
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
        'enable_thinking': enableThinking,
        'threads': threads,
        'context_size': contextSize,
        'gpu_layers': gpuLayers,
        'cache_prompt': cachePrompt,
      };

  factory LlmConfig.fromJson(Map<String, dynamic> j) {
    final dry = (j['dry'] as Map?)?.cast<String, dynamic>() ?? const {};
    return LlmConfig(
      seed: (j['seed'] as num?)?.toInt() ?? 42,
      temperature: (j['temperature'] as num?)?.toDouble() ?? 1.0,
      topP: (j['top_p'] as num?)?.toDouble() ?? 0.95,
      topK: (j['top_k'] as num?)?.toInt() ?? 0,
      minP: (j['min_p'] as num?)?.toDouble() ?? 0.0,
      repeatPenalty: (j['repeat_penalty'] as num?)?.toDouble() ?? 1.0,
      repeatLastN: (j['repeat_last_n'] as num?)?.toInt() ?? 64,
      presencePenalty: (j['presence_penalty'] as num?)?.toDouble() ?? 0.0,
      frequencyPenalty: (j['frequency_penalty'] as num?)?.toDouble() ?? 0.0,
      dryEnabled: dry['enabled'] as bool? ?? true,
      dryMultiplier: (dry['multiplier'] as num?)?.toDouble() ?? 0.8,
      dryBase: (dry['base'] as num?)?.toDouble() ?? 1.75,
      dryAllowedLength: (dry['allowed_length'] as num?)?.toInt() ?? 2,
      dryPenaltyLastN: (dry['penalty_last_n'] as num?)?.toInt() ?? 1024,
      maxTokens: (j['max_tokens'] as num?)?.toInt() ?? 512,
      enableThinking: j['enable_thinking'] as bool? ?? false,
      threads: (j['threads'] as num?)?.toInt() ?? 7,
      contextSize: (j['context_size'] as num?)?.toInt() ?? 8192,
      gpuLayers: (j['gpu_layers'] as num?)?.toInt() ?? 0,
      cachePrompt: j['cache_prompt'] as bool? ?? false,
    );
  }

  /// Impressão canónica determinística (JSON com chaves ordenadas) para
  /// assinar execuções — mesma impressão ⇒ mesma saída esperada.
  String get fingerprint {
    final sorted = Map<String, dynamic>.fromEntries(
        toJson().entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
    return jsonEncode(sorted);
  }

  /// Validação: bloqueia configurações que sabidamente causam loops ou
  /// não-determinismo. Devolve a lista de violações (vazia = ok).
  List<String> validate() {
    final problems = <String>[];
    if (minP != 0.0) {
      problems.add(
          'min_p deve ser 0.0 no MiniCPM5-2B (o default 0.05 do llama.cpp é a causa raiz dos loops)');
    }
    if (seed == -1) {
      problems.add('seed -1 = aleatória no llama.cpp; use seed fixa (ex.: 42)');
    }
    if (maxTokens < 1) {
      problems.add(
          'max_tokens tem de ser um teto explícito (o default do llama.cpp é infinito)');
    }
    if (repeatPenalty > 1.05) {
      problems.add(
          'repeat_penalty > 1.05 corrompe JSON/tool calls; prefira DRY (0.8/1.75/2)');
    }
    if (repeatPenalty < 1.0) {
      problems.add('repeat_penalty < 1.0 incentiva repetição (mínimo 1.0)');
    }
    if (temperature == 0.0 && !dryEnabled) {
      problems.add(
          'greedy (temperature 0) aumenta o risco de loops — ative o DRY e mantenha deteção em runtime');
    }
    if (temperature > 0.0 && temperature < 0.7) {
      problems.add(
          'fora da receita oficial: temperature 1.0 + top_p 0.95 + min_p 0.0 (com seed fixa é reprodutível)');
    }
    if (contextSize > 32768) {
      problems.add(
          'contexto >32k exige KV q8_0 e >3.7 GB de RAM só em KV cache (8 GB de RAM ⇒ 8k–16k)');
    }
    return problems;
  }
}

/// Configuração do motor Laya (ONNX).
class LayaConfig {
  /// Threads de CPU para o ONNX Runtime (XNNPACK).
  final int threads;

  /// `cpu` (ground truth de determinismo) | `xnnpack` (mais rápido;
  /// medir é obrigatório — doc §13 e dossiê Q6).
  final String executionProvider;

  /// Comprimento máx. de tokens do estado (1024 no typed-decisions; o doc
  /// recomenda estados ≤512 tok).
  final int maxStateTokens;

  /// Truncagem de `state` em caracteres (contagem fina é do tokenizer).
  final int maxStateChars;

  const LayaConfig({
    this.threads = 4,
    this.executionProvider = 'xnnpack',
    this.maxStateTokens = 512,
    this.maxStateChars = 2000,
  });

  Map<String, dynamic> toJson() => {
        'threads': threads,
        'execution_provider': executionProvider,
        'max_state_tokens': maxStateTokens,
        'max_state_chars': maxStateChars,
      };

  factory LayaConfig.fromJson(Map<String, dynamic> j) => LayaConfig(
        threads: (j['threads'] as num?)?.toInt() ?? 4,
        executionProvider: j['execution_provider'] as String? ?? 'xnnpack',
        maxStateTokens: (j['max_state_tokens'] as num?)?.toInt() ?? 512,
        maxStateChars: (j['max_state_chars'] as num?)?.toInt() ?? 2000,
      );
}