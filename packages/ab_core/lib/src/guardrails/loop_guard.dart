/// Guardrails determinísticos contra loops infinitos.
///
/// Camadas de defesa (todas determinísticas, sem aleatoriedade):
///  1. orçamento total de passos do agente ([LoopGuard.maxSteps]);
///  2. limite de tool calls CONSECUTIVAS sem resposta final ([maxToolCalls]);
///  3. deteção de CICLO por chave canónica de tool call ([canonicalKey]) —
///     a mesma chamada repetida mais de [maxIdenticalCalls] vezes corta o loop;
///  4. deteção de repetição de TEXTOS (n-grama) na geração — degeneração
///     clássica de LLMs pequenos (ver dossiê Q2);
///  5. orçamento de tokens ([tokenBudget]) e timeout por passo ([stepTimeout]);
///  6. resposta FINAL FORÇADA quando qualquer limite é atingido.
///
/// Nenhuma destas camadas depende do modelo cooperar: o corte é sempre do lado
/// do runtime ("mais determinismo que liberdade").
library;

import 'dart:async';

/// Motivo pelo qual o loop terminou (sempre explícito e registável).
enum StopReason {
  finalAnswer,
  maxSteps,
  maxToolCalls,
  cycleDetected,
  repetitionDetected,
  tokenBudgetExhausted,
  stepTimeout,
  cancelled,
  engineError,
}

extension StopReasonWire on StopReason {
  String get wire => name;

  String get explanation => switch (this) {
        StopReason.finalAnswer => 'o modelo entregou resposta final',
        StopReason.maxSteps => 'cortado: máximo de passos do agente atingido',
        StopReason.maxToolCalls =>
          'cortado: máximo de tool calls consecutivas sem resposta final',
        StopReason.cycleDetected =>
          'cortado: ciclo detetado (mesma tool call repetida)',
        StopReason.repetitionDetected =>
          'cortado: repetição degenerada de n-gramas na geração',
        StopReason.tokenBudgetExhausted =>
          'cortado: orçamento de tokens esgotado',
        StopReason.stepTimeout => 'cortado: timeout por passo',
        StopReason.cancelled => 'cancelado pelo utilizador',
        StopReason.engineError => 'parado por erro do motor',
      };
}

/// Um passo do loop de agente (para auditoria/registos).
class LoopStep {
  final int index;
  final String kind; // 'model' | 'tool' | 'guard'
  final String summary;
  final DateTime at;

  const LoopStep({
    required this.index,
    required this.kind,
    required this.summary,
    required this.at,
  });
}

/// Estado acumulado do loop; mutável só dentro do [LoopGuard].
class LoopState {
  int steps = 0;
  int toolCalls = 0;
  int tokensUsed = 0;

  /// contagem por chave canónica de tool call
  final Map<String, int> callCounts = {};

  /// chaves canónicas de tool calls consecutivas (para ciclo imediato A→A)
  final List<String> recentCalls = [];

  final List<LoopStep> log = [];

  StopReason? stop;

  bool get finished => stop != null;
}

/// Configuração dos guardrails. Defaults conservadores e determinísticos.
class LoopGuardConfig {
  /// Máximo de passos totais do agente (modelo + ferramentas).
  final int maxSteps;

  /// Máximo de tool calls consecutivas sem resposta final.
  final int maxToolCalls;

  /// A mesma tool call (ferramenta + argumentos) pode repetir-se no máximo
  /// estas vezes antes de o loop ser cortado por ciclo.
  final int maxIdenticalCalls;

  /// Orçamento total de tokens de geração do agente.
  final int tokenBudget;

  /// Timeout por passo de geração.
  final Duration stepTimeout;

  /// Janela (em PALAVRAS) vigiada para repetição degenerada (256–1024).
  final int repetitionWindow;

  /// Ocorrências do mesmo n-grama de 4 palavras (métrica SER@4) que disparam
  /// o corte (2–3 é o intervalo documentado).
  final int repetitionLimit;

  const LoopGuardConfig({
    this.maxSteps = 8,
    this.maxToolCalls = 6,
    this.maxIdenticalCalls = 2,
    this.tokenBudget = 2048,
    this.stepTimeout = const Duration(seconds: 90),
    this.repetitionWindow = 512,
    this.repetitionLimit = 3,
  });

  Map<String, dynamic> toJson() => {
        'max_steps': maxSteps,
        'max_tool_calls': maxToolCalls,
        'max_identical_calls': maxIdenticalCalls,
        'token_budget': tokenBudget,
        'step_timeout_ms': stepTimeout.inMilliseconds,
        'repetition_window': repetitionWindow,
        'repetition_limit': repetitionLimit,
      };
}

/// O guardião. Cada método devolve `true` se o loop PODE continuar.
/// Quando devolve `false`, [LoopState.stop] indica o motivo exato.
class LoopGuard {
  final LoopGuardConfig config;
  final LoopState state = LoopState();

  LoopGuard({this.config = const LoopGuardConfig()});

  bool get canContinue => !state.finished;

  /// Antes de um passo de geração do modelo.
  bool beforeModelStep({required int tokensSoFar}) {
    if (state.finished) return false;
    state.steps++;
    if (state.steps > config.maxSteps) {
      return _stop(StopReason.maxSteps);
    }
    if (tokensSoFar >= config.tokenBudget) {
      return _stop(StopReason.tokenBudgetExhausted);
    }
    return true;
  }

  /// Antes de executar uma tool call; valida o ciclo ANTES de executar
  /// (nunca executamos uma chamada que sabemos estar em loop).
  bool beforeToolCall(ToolCallKey call) {
    if (state.finished) return false;
    final key = call.canonicalKey;
    final count = (state.callCounts[key] ?? 0) + 1;
    state.callCounts[key] = count;
    state.toolCalls++;

    if (count > config.maxIdenticalCalls) {
      state.log.add(LoopStep(
          index: state.steps,
          kind: 'guard',
          summary: 'ciclo: "$key" repetiu ${count}x',
          at: DateTime.now()));
      return _stop(StopReason.cycleDetected);
    }
    if (state.toolCalls > config.maxToolCalls) {
      return _stop(StopReason.maxToolCalls);
    }
    // Ciclo imediato A→A→A: mesma chamada nas últimas 2 posições.
    if (state.recentCalls.length >= 2 &&
        state.recentCalls[state.recentCalls.length - 1] == key &&
        state.recentCalls[state.recentCalls.length - 2] == key) {
      return _stop(StopReason.cycleDetected);
    }
    // Ping-pong A→B→A→B: duas ferramentas a alternar sem fim.
    if (state.recentCalls.length >= 3) {
      final r = state.recentCalls;
      final a = r[r.length - 3], b = r[r.length - 2], a2 = r[r.length - 1];
      if (a == a2 && b == key && a != b) {
        state.log.add(LoopStep(
            index: state.steps,
            kind: 'guard',
            summary: 'ciclo ping-pong: $a → $b → $a → $b',
            at: DateTime.now()));
        return _stop(StopReason.cycleDetected);
      }
    }
    state.recentCalls.add(key);
    return true;
  }

  /// Repetição degenerada de texto: n-gramas de 4 PALAVRAS repetidos (SER@4)
  /// numa janela deslizante — a métrica documentada para loops de LLMs
  /// (dossiê Q2). O match exato de sufixos curtos falha perante variações
  /// lexicais; n=4 cobre os casos reais.
  bool checkTextRepetition(String generatedText) {
    if (state.finished) return false;
    const n = 4;
    final words =
        generatedText.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    final tokens = words.toList();
    if (tokens.length < n * 2) return true;

    // Conta n-gramas repetidos dentro da janela mais recente.
    final window = tokens.length > config.repetitionWindow
        ? tokens.sublist(tokens.length - config.repetitionWindow)
        : tokens;
    final counts = <String, int>{};
    for (var i = 0; i + n <= window.length; i++) {
      final gram = window.sublist(i, i + n).join(' ');
      counts[gram] = (counts[gram] ?? 0) + 1;
    }
    String? worst;
    var worstCount = 0;
    counts.forEach((gram, c) {
      if (c > worstCount) {
        worstCount = c;
        worst = gram;
      }
    });
    if (worstCount >= config.repetitionLimit) {
      state.log.add(LoopStep(
          index: state.steps,
          kind: 'guard',
          summary: 'repetição degenerada SER@$n: "$worst" ×$worstCount',
          at: DateTime.now()));
      return _stop(StopReason.repetitionDetected);
    }
    return true;
  }

  /// Acumula tokens gerados e valida o orçamento.
  bool addTokens(int n) {
    if (state.finished) return false;
    state.tokensUsed += n;
    if (state.tokensUsed >= config.tokenBudget) {
      return _stop(StopReason.tokenBudgetExhausted);
    }
    return true;
  }

  /// Executa [step] com timeout; em timeout corta o loop com [StopReason.stepTimeout].
  Future<T?> runStepWithTimeout<T>(Future<T> Function() step) async {
    if (state.finished) return null;
    try {
      return await step().timeout(config.stepTimeout);
    } on TimeoutException {
      _stop(StopReason.stepTimeout);
      return null;
    }
  }

  void cancel() => _stop(StopReason.cancelled);

  void fail() => _stop(StopReason.engineError);

  /// O modelo entregou resposta final — término legítimo.
  void finish() => _stop(StopReason.finalAnswer);

  void log(String kind, String summary) => state.log.add(LoopStep(
      index: state.steps, kind: kind, summary: summary, at: DateTime.now()));

  bool _stop(StopReason r) {
    state.stop ??= r;
    return false;
  }
}

/// Chave canónica abstrata (para não depender de dart:convert aqui).
abstract class ToolCallKey {
  String get canonicalKey;
}