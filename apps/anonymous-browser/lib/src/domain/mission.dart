/// Missão (o que o utilizador pede) e estado persistente da run (park/retoma).
///
/// Espelha o `abctl run` do desktop: objetivo + parâmetros `{{var}}` +
/// saídas esperadas + orçamento de tempo. Os VALORES sensíveis vivem em
/// [MissionSpec.variables] e entram no payload/página só através da camada de
/// confiança (placeholders resolvidos em código, nunca pelo modelo) —
/// ver `autopilot/masking.dart`.
library;

import 'dart:convert';

/// Uma saída esperada da missão (extração): `name` + descrição/regex.
class ExtractSpec {
  final String name;
  final String desc;

  /// Regex de validação da saída (formato), quando existe. Nunca valores de
  /// página voláteis — só formato (regra de asserts do desktop).
  final String? regex;

  const ExtractSpec({required this.name, this.desc = '', this.regex});

  Map<String, dynamic> toJson() =>
      {'name': name, 'desc': desc, if (regex != null) 'regex': regex};

  factory ExtractSpec.fromJson(Map<String, dynamic> j) => ExtractSpec(
        name: j['name'] as String,
        desc: j['desc'] as String? ?? '',
        regex: j['regex'] as String?,
      );
}

/// Backend de decisão por passo.
enum DecisionMode {
  /// Jev online (TypeSafe `typesafe/jev-1.13`, endpoint Decisions do OpenRouter).
  jevOnline,

  /// Laya local no telemóvel (typed-decisions, ONNX) — sem rede.
  layaLocal,
}

/// Backend de texto (composição de texto, extração, verificação).
enum TextMode {
  /// MiMo online (`xiaomi/mimo-v2.6-pro`, OpenRouter chat).
  mimoOnline,

  /// MiniCPM5-2B local no telemóvel (GGUF via llama.cpp).
  minicpmLocal,
}

/// A missão completa — o "pedido" do utilizador.
class MissionSpec {
  final String id;
  final String goal;
  final String startUrl;

  /// Variáveis `{{nome}}` → valor. As marcadas em [secretVariables] são
  /// mascaradas em TODO o tape/log (nunca em claro).
  final Map<String, String> variables;
  final Set<String> secretVariables;

  final List<ExtractSpec> extract;
  final DecisionMode decisionMode;
  final TextMode textMode;

  /// Orçamento de TEMPO (regra do desktop: nunca por número de passos).
  final Duration maxTime;

  /// Modo humano p/ bot-walls: o agente NUNCA luta contra muros/CAPTCHA —
  /// pede ao humano e espera (regra absoluta do desktop).
  final bool humanWalls;

  const MissionSpec({
    required this.id,
    required this.goal,
    required this.startUrl,
    this.variables = const {},
    this.secretVariables = const {},
    this.extract = const [],
    this.decisionMode = DecisionMode.jevOnline,
    this.textMode = TextMode.mimoOnline,
    this.maxTime = const Duration(minutes: 15),
    this.humanWalls = true,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'goal': goal,
        'start_url': startUrl,
        'variables': variables,
        'secret_variables': secretVariables.toList()..sort(),
        'extract': [for (final e in extract) e.toJson()],
        'decision_mode': decisionMode.name,
        'text_mode': textMode.name,
        'max_time_s': maxTime.inSeconds,
        'human_walls': humanWalls,
      };

  factory MissionSpec.fromJson(Map<String, dynamic> j) => MissionSpec(
        id: j['id'] as String,
        goal: j['goal'] as String,
        startUrl: j['start_url'] as String? ?? '',
        variables: Map<String, String>.from(j['variables'] as Map? ?? {}),
        secretVariables: {
          for (final s in (j['secret_variables'] as List? ?? const []))
            s as String
        },
        extract: [
          for (final e in (j['extract'] as List? ?? const []))
            ExtractSpec.fromJson(Map<String, dynamic>.from(e as Map))
        ],
        decisionMode: DecisionMode.values.firstWhere(
            (m) => m.name == (j['decision_mode'] ?? 'jevOnline'),
            orElse: () => DecisionMode.jevOnline),
        textMode: TextMode.values.firstWhere(
            (m) => m.name == (j['text_mode'] ?? 'mimoOnline'),
            orElse: () => TextMode.mimoOnline),
        maxTime: Duration(seconds: (j['max_time_s'] as num? ?? 900).toInt()),
        humanWalls: j['human_walls'] as bool? ?? true,
      );

  String encode() => jsonEncode(toJson());
}

/// Resultado final de uma run (estados do desktop, `core.STATUSES`).
enum RunOutcome {
  running,
  ok,
  needsInput,
  timeout,
  gateDenied,
  cancelled,
  error,
}

/// Uma entrada do histórico da run: `#n QUEM OP 'alvo' ✓ → efeito`.
class HistoryEntry {
  final int step;
  final String who;
  final String op;
  final String target;
  final bool ok;
  final String effect;

  const HistoryEntry({
    required this.step,
    required this.who,
    required this.op,
    required this.target,
    required this.ok,
    required this.effect,
  });

  String toLine() =>
      '#$step $who $op ${target.isEmpty ? "" : "'$target'"} ${ok ? "✓" : "✗"} → $effect';

  Map<String, dynamic> toJson() => {
        'step': step,
        'who': who,
        'op': op,
        'target': target,
        'ok': ok,
        'effect': effect,
      };

  factory HistoryEntry.fromJson(Map<String, dynamic> j) => HistoryEntry(
        step: (j['step'] as num? ?? 0).toInt(),
        who: j['who'] as String? ?? '',
        op: j['op'] as String? ?? '',
        target: j['target'] as String? ?? '',
        ok: j['ok'] as bool? ?? false,
        effect: j['effect'] as String? ?? '',
      );
}

/// Estado mutável da run — o que sobrevive a crash/app em background (park).
///
/// Mobile agrava o problema do desktop (o SO mata processos): o estado é
/// gravado a cada passo e a retomada é idempotente.
class MissionRunState {
  final MissionSpec spec;
  int step;
  RunOutcome outcome;
  DateTime startedAt;
  String url;
  String title;

  /// Últimas 8 URLs (direção: GO_BACK).
  final List<String> urlTrail;

  /// Histórico de ações (para `historico_curto`/`progress_summary`).
  final List<HistoryEntry> history;

  /// Últimas 4 respostas do humano (user_guidance).
  final List<String> guidance;

  /// Repetições por assinatura (escada de repetição).
  final Map<String, int> tried;

  /// Saídas já extraídas (nome → valor MASCARADO quando secreto).
  final Map<String, String> extracted;

  /// Último efeito observado (view diff) — `last_change` do payload.
  String lastChange;

  /// Pistas do loopguard para o próximo estado (contexto, nunca instrução).
  String? loopguardHint;

  /// Perguntas já respondidas (ledger anti-repetição: qid → resposta).
  final Map<String, String> answeredQuestions;

  MissionRunState({
    required this.spec,
    this.step = 0,
    this.outcome = RunOutcome.running,
    DateTime? startedAt,
    this.url = '',
    this.title = '',
    List<String>? urlTrail,
    List<HistoryEntry>? history,
    List<String>? guidance,
    Map<String, int>? tried,
    Map<String, String>? extracted,
    this.lastChange = 'first observation of this page',
    this.loopguardHint,
    Map<String, String>? answeredQuestions,
  })  : startedAt = startedAt ?? DateTime.now(),
        urlTrail = urlTrail ?? [],
        history = history ?? [],
        guidance = guidance ?? [],
        tried = tried ?? {},
        extracted = extracted ?? {},
        answeredQuestions = answeredQuestions ?? {};

  Duration get elapsed => DateTime.now().difference(startedAt);

  bool get budgetExceeded => elapsed > spec.maxTime;

  /// Resumo do progresso: o que já deu certo + efeito (últimas 8).
  List<String> progressSummary() => [
        for (final h in history.where((h) => h.ok).take(8).toList().reversed)
          '✓ ${h.op}${h.target.isEmpty ? "" : " ${h.target}"} → ${h.effect}'
      ];

  /// Últimas 6 ações (formato desktop `#n QUEM OP 'alvo' ✓ → efeito`).
  List<String> shortHistory() =>
      [for (final h in history.length > 6 ? history.sublist(history.length - 6) : history) h.toLine()];

  /// `already_tried_without_result`: repetições na página atual.
  List<String> triedLines() => [
        for (final e in tried.entries)
          if (e.value > 1) '${e.key} (${e.value}×)'
      ];

  Map<String, dynamic> toJson() => {
        'spec': spec.toJson(),
        'step': step,
        'outcome': outcome.name,
        'started_at': startedAt.toIso8601String(),
        'url': url,
        'title': title,
        'url_trail': urlTrail,
        'history': [for (final h in history) h.toJson()],
        'guidance': guidance,
        'tried': tried,
        'extracted': extracted,
        'last_change': lastChange,
        if (loopguardHint != null) 'loopguard_hint': loopguardHint,
        'answered_questions': answeredQuestions,
      };

  factory MissionRunState.fromJson(Map<String, dynamic> j) => MissionRunState(
        spec: MissionSpec.fromJson(Map<String, dynamic>.from(j['spec'] as Map)),
        step: (j['step'] as num? ?? 0).toInt(),
        outcome: RunOutcome.values.firstWhere(
            (o) => o.name == (j['outcome'] ?? 'running'),
            orElse: () => RunOutcome.running),
        startedAt:
            DateTime.tryParse(j['started_at'] as String? ?? '') ?? DateTime.now(),
        url: j['url'] as String? ?? '',
        title: j['title'] as String? ?? '',
        urlTrail: [
          for (final u in (j['url_trail'] as List? ?? const [])) u as String
        ],
        history: [
          for (final h in (j['history'] as List? ?? const []))
            HistoryEntry.fromJson(Map<String, dynamic>.from(h as Map))
        ],
        guidance: [for (final g in (j['guidance'] as List? ?? const [])) g as String],
        tried: {
          for (final e in ((j['tried'] as Map?) ?? const {}).entries)
            e.key as String: (e.value as num).toInt()
        },
        extracted: Map<String, String>.from(j['extracted'] as Map? ?? {}),
        lastChange: j['last_change'] as String? ?? '',
        loopguardHint: j['loopguard_hint'] as String?,
        answeredQuestions:
            Map<String, String>.from(j['answered_questions'] as Map? ?? {}),
      );
}
