/// Contrato dos backends de decisão — o "Jev" do mobile pode ser
/// **online** (TypeSafe `typesafe/jev-1.13`, endpoint Decisions do OpenRouter)
/// ou **local** (Laya typed-decisions, ONNX, no telemóvel).
///
/// Mesmo envelope de resposta nos dois casos (contrato `clm_local` do desktop
/// `llm.py`): `answers: {qid: {choice|noul|score, confidence, probabilities}}`.
/// Os limiares NÃO transferem entre modelos — são configuração.
library;

/// Uma resposta tipada.
class TypedDecision {
  final String id;

  /// `choice` | `noul` | `score`.
  final String kind;
  final String? choice;
  final double? noul;
  final double confidence;
  final Map<String, double> probabilities;

  const TypedDecision({
    required this.id,
    required this.kind,
    this.choice,
    this.noul,
    this.confidence = 0,
    this.probabilities = const {},
  });

  factory TypedDecision.fromJson(String id, Map<String, dynamic> j) {
    final kind = (j['noul'] != null)
        ? 'noul'
        : (j['score'] != null ? 'score' : 'choice');
    return TypedDecision(
      id: id,
      kind: kind,
      choice: j['choice'] as String?,
      noul: (j['noul'] as num?)?.toDouble(),
      confidence: (j['confidence'] as num? ?? 0).toDouble(),
      probabilities: {
        for (final e in ((j['probabilities'] as Map?) ?? const {}).entries)
          e.key as String: (e.value as num).toDouble()
      },
    );
  }
}

/// Resposta inteira de um backend de decisão.
class DecisionAnswers {
  final Map<String, TypedDecision> answers;
  final int ms;
  final double costUsd;
  final String backend;

  const DecisionAnswers({
    required this.answers,
    this.ms = 0,
    this.costUsd = 0,
    required this.backend,
  });

  TypedDecision? operator [](String id) => answers[id];

  /// Probabilidade `noul` de um juízo (0 quando ausente).
  double noulOf(String id, {double fallback = 0}) =>
      answers[id]?.noul ?? fallback;

  /// Escolha de uma `choice` (null quando ausente).
  String? choiceOf(String id) => answers[id]?.choice;

  double confidenceOf(String id) => answers[id]?.confidence ?? 0;
}

/// Backend de decisão por passo.
abstract class DecisionBackend {
  /// Nome estável para auditoria (`jev-online`, `laya-local`).
  String get name;

  /// Pergunta ao decisor: `state` (português/inglês, compacto) + `questions`
  /// (formato wire `choice`/`noul`/`score`). Nunca lança por erro de página:
  /// erros do backend viram `DecisionException` para a cascata decidir.
  Future<DecisionAnswers> ask({
    required Map<String, dynamic> state,
    required Map<String, dynamic> questions,
  });
}

/// Erro de um backend de decisão (a cascata escala para o próximo).
class DecisionException implements Exception {
  final String message;
  final int? status;
  const DecisionException(this.message, {this.status});

  @override
  String toString() => 'DecisionException($status): $message';
}
