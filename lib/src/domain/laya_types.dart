/// Tipos de domínio do Laya (decisor tipado "System One").
///
/// Espelha o contrato `POST /v1/systemone` documentado em
/// [Laya-Documento-Tecnico-Completo.md] §4, com as três primitivas
/// `noul` / `choice` / `score`.
library;

/// As três primitivas de pergunta tipada do Laya.
enum QType { noul, choice, score }

extension QTypeWire on QType {
  String get wire => switch (this) {
        QType.noul => 'noul',
        QType.choice => 'choice',
        QType.score => 'score',
      };

  /// Índice `qtype` do tensor de entrada do ONNX (confirmado no grafo do
  /// export fp32 de `convaiinnovations/laya-typed-decisions`:
  /// 0=choice, 1=score, 2=noul).
  int get onnxIndex => switch (this) {
        QType.choice => 0,
        QType.score => 1,
        QType.noul => 2,
      };

  static QType fromWire(String s) => QType.values.firstWhere(
        (q) => q.wire == s,
        orElse: () => throw FormatException('qtype desconhecido: $s'),
      );
}

/// Uma pergunta tipada do Laya: instruções + critérios (opções ou níveis).
sealed class TypedQuestion {
  final String id;
  final String instructions;

  const TypedQuestion({required this.id, required this.instructions});

  QType get type;

  /// Texto prosa que alimenta o encoder (o Laya foi treinado em prosa enxuta,
  /// não em JSON bruto — ver doc §10).
  String toProse();

  Map<String, dynamic> toJson();
}

/// `noul` — bernoulli em [0,1]. ⚠️ viés de rótulos `true:`/`false:` (doc §9.2):
/// prefira [BinaryChoiceQuestion] para guardrails.
class NoulQuestion extends TypedQuestion {
  /// Critérios por defeito; o wire format exige as chaves `true`/`false`.
  final String trueCriteria;
  final String falseCriteria;

  const NoulQuestion({
    required super.id,
    required super.instructions,
    this.trueCriteria = 'sim',
    this.falseCriteria = 'não',
  });

  @override
  QType get type => QType.noul;

  @override
  String toProse() =>
      '$instructions Pergunta de sim/não. true: $trueCriteria; false: $falseCriteria.';

  @override
  Map<String, dynamic> toJson() => {
        'type': 'noul',
        'instructions': instructions,
        'criteria': {'true': trueCriteria, 'false': falseCriteria},
      };
}

/// `choice` — escolha entre critérios nomeados (≤20 opções; inclua sempre
/// `none`/`other`, ver doc §10).
class ChoiceQuestion extends TypedQuestion {
  /// nome-da-opção → descrição do critério (ordem estável e reproduzível).
  final Map<String, String> criteria;

  const ChoiceQuestion({
    required super.id,
    required super.instructions,
    required this.criteria,
  });

  @override
  QType get type => QType.choice;

  @override
  String toProse() => '$instructions Opções: '
      '${criteria.entries.map((e) => '${e.key} (${e.value})').join('; ')}.';

  @override
  Map<String, dynamic> toJson() => {
        'type': 'choice',
        'instructions': instructions,
        'criteria': criteria,
      };
}

/// `score` — escala ordinal; resultado = índice esperado (0-based).
/// É a primitiva mais fraca do Laya (doc §9.3) — níveis devem ser situações
/// concretas.
class ScoreQuestion extends TypedQuestion {
  /// níveis ordenados (índice 0..n-1); a wire `criteria` é uma lista.
  final List<String> levels;

  const ScoreQuestion({
    required super.id,
    required super.instructions,
    required this.levels,
  });

  @override
  QType get type => QType.score;

  @override
  String toProse() => '$instructions Níveis: '
      '${levels.asMap().entries.map((e) => '${e.key}=${e.value}').join('; ')}.';

  @override
  Map<String, dynamic> toJson() => {
        'type': 'score',
        'instructions': instructions,
        'criteria': levels,
      };
}

/// Resposta a uma pergunta tipada (espelha o wire format de resposta §4.2).
sealed class TypedAnswer {
  final String id;
  final QType type;
  final Map<String, double> probabilities;
  final double confidence;

  /// `confidence` do Laya = 1 − H(p)/log(k) (choice/score) ou max(p, 1−p)
  /// (noul) — ≠ Jev; limiares calibrados noutro modelo não transferem.
  final double answerConfidence;

  /// Probabilidade `act` da head auxiliar (action.act_probability).
  final double actProbability;

  const TypedAnswer({
    required this.id,
    required this.type,
    required this.probabilities,
    required this.confidence,
    required this.answerConfidence,
    required this.actProbability,
  });

  Map<String, dynamic> toJson();
}

class NoulAnswer extends TypedAnswer {
  final double pTrue;

  const NoulAnswer({
    required super.id,
    required this.pTrue,
    required super.probabilities,
    required super.confidence,
    required super.answerConfidence,
    required super.actProbability,
  }) : super(type: QType.noul);

  @override
  Map<String, dynamic> toJson() => {
        'type': 'noul',
        'noul': pTrue,
        'probabilities': probabilities,
        'confidence': confidence,
        'answer_confidence': answerConfidence,
        'action': {'act_probability': actProbability},
      };
}

class ChoiceAnswer extends TypedAnswer {
  final String choice;

  const ChoiceAnswer({
    required super.id,
    required this.choice,
    required super.probabilities,
    required super.confidence,
    required super.answerConfidence,
    required super.actProbability,
  }) : super(type: QType.choice);

  @override
  Map<String, dynamic> toJson() => {
        'type': 'choice',
        'choice': choice,
        'probabilities': probabilities,
        'confidence': confidence,
        'answer_confidence': answerConfidence,
        'action': {'act_probability': actProbability},
      };
}

class ScoreAnswer extends TypedAnswer {
  /// Índice esperado (0-based, pode ser fracionário).
  final double score;
  final Map<String, String> legend;

  const ScoreAnswer({
    required super.id,
    required this.score,
    required this.legend,
    required super.probabilities,
    required super.confidence,
    required super.answerConfidence,
    required super.actProbability,
  }) : super(type: QType.score);

  @override
  Map<String, dynamic> toJson() => {
        'type': 'score',
        'score': score,
        'legend': legend,
        'probabilities': probabilities,
        'confidence': confidence,
        'answer_confidence': answerConfidence,
        'action': {'act_probability': actProbability},
      };
}

/// Pedido inteiro ao Laya: `state` (prosa enxuta) + perguntas.
class LayaRequest {
  final String state;
  final List<TypedQuestion> questions;

  /// Força de checkpoint (`typed-decisions` por defeito — doc §10).
  final String model;

  const LayaRequest({
    required this.state,
    required this.questions,
    this.model = 'typed-decisions',
  });

  Map<String, dynamic> toJson() => {
        'model': model,
        'state': state,
        'questions': {for (final q in questions) q.id: q.toJson()},
      };
}

/// Resposta inteira do Laya.
class LayaResponse {
  final Map<String, TypedAnswer> answers;
  final int inputTokens;
  final int outputTokens; // invariante: 0 (modelo não gera texto)
  final int latencyMs;

  const LayaResponse({
    required this.answers,
    required this.inputTokens,
    this.outputTokens = 0,
    required this.latencyMs,
  });

  Map<String, dynamic> toJson() => {
        'answers': {for (final e in answers.entries) e.key: e.value.toJson()},
        'usage': {'input_tokens': inputTokens, 'output_tokens': outputTokens},
        'latency_ms': latencyMs,
      };
}