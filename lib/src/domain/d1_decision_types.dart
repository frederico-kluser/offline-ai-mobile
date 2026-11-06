/// Tipos de domínio do decisor "System One" Liquid d1.
///
/// O contrato cobre as dez famílias de decisão do d1-2B/d1-Omni-2B:
/// `noul`, `choice`, `choice` múltiplo, `score`, extração de texto/número/data
/// com span, estimativa numérica por intervalo e deteção de caixas
/// delimitadoras. Todas são respondidas num único forward pass, sem gerar
/// tokens; [D1Response.outputTokens] é sempre 0.
library;

/// As dez primitivas de pergunta tipada do d1.
enum D1QuestionType {
  noul,
  choice,
  multiChoice,
  score,
  textSpan,
  numberSpan,
  dateSpan,
  numberRange,
  box,
  boxes,
}

extension D1QuestionTypeX on D1QuestionType {
  String get wire => switch (this) {
        D1QuestionType.noul => 'noul',
        D1QuestionType.choice => 'choice',
        D1QuestionType.multiChoice => 'choice+multiple',
        D1QuestionType.score => 'score',
        D1QuestionType.textSpan => 'text',
        D1QuestionType.numberSpan => 'number',
        D1QuestionType.dateSpan => 'date',
        D1QuestionType.numberRange => 'number+range',
        D1QuestionType.box => 'box',
        D1QuestionType.boxes => 'boxes',
      };

  String get label => switch (this) {
        D1QuestionType.noul => 'Sim/Não (noul)',
        D1QuestionType.choice => 'Escolha única',
        D1QuestionType.multiChoice => 'Escolha múltipla',
        D1QuestionType.score => 'Escala (score)',
        D1QuestionType.textSpan => 'Texto (span)',
        D1QuestionType.numberSpan => 'Número (span)',
        D1QuestionType.dateSpan => 'Data ISO 8601',
        D1QuestionType.numberRange => 'Intervalo numérico',
        D1QuestionType.box => '1 caixa (box)',
        D1QuestionType.boxes => 'Até N caixas (boxes)',
      };

  bool get requiresImage => switch (this) {
        D1QuestionType.box || D1QuestionType.boxes => true,
        _ => false,
      };

  bool get requiresAudio => false;

  /// Primitivas disponíveis na via GGUF do llama.cpp (`/v1/systemone`).
  bool get supportedByGguf => switch (this) {
        D1QuestionType.noul ||
        D1QuestionType.choice ||
        D1QuestionType.score =>
          true,
        _ => false,
      };

  static D1QuestionType fromWire(String s) => D1QuestionType.values.firstWhere(
        (t) => t.wire == s,
        orElse: () => throw FormatException('tipo de pergunta d1 desconhecido: $s'),
      );
}

/// Instrução de uma pergunta: escrita ou falada (exclusivo d1-Omni).
sealed class D1Instruction {
  const D1Instruction();

  Map<String, dynamic> toJson();
}

final class WrittenInstruction extends D1Instruction {
  final String text;
  const WrittenInstruction(this.text);

  @override
  Map<String, dynamic> toJson() => {'kind': 'written', 'text': text};
}

/// Pergunta falada (WAV PCM 16 kHz mono). O d1-Omni-2B aceita até 16
/// perguntas faladas no mesmo forward pass.
final class SpokenInstruction extends D1Instruction {
  final String wavFilePath;
  const SpokenInstruction(this.wavFilePath);

  @override
  Map<String, dynamic> toJson() =>
      {'kind': 'spoken', 'wav_path': wavFilePath};
}

/// Mídia que acompanha o estado do d1.
enum D1MediaKind { image, video, audio }

extension D1MediaKindX on D1MediaKind {
  String get wire => name;
}

class D1Media {
  final D1MediaKind kind;
  final String path;

  /// SHA-256 do conteúdo (reutilização de cache visual no llama.cpp/mtmd).
  final String? sha256;
  final int? bytes;
  final double? durationSeconds;

  const D1Media({
    required this.kind,
    required this.path,
    this.sha256,
    this.bytes,
    this.durationSeconds,
  });

  Map<String, dynamic> toJson() => {
        'kind': kind.wire,
        'path': path,
        if (sha256 != null) 'sha256': sha256,
        if (bytes != null) 'bytes': bytes,
        if (durationSeconds != null) 'duration_seconds': durationSeconds,
      };

  factory D1Media.fromJson(Map<String, dynamic> j) => D1Media(
        kind: D1MediaKind.values.firstWhere(
          (k) => k.name == j['kind'],
          orElse: () => D1MediaKind.image,
        ),
        path: j['path'] as String,
        sha256: j['sha256'] as String?,
        bytes: (j['bytes'] as num?)?.toInt(),
        durationSeconds: (j['duration_seconds'] as num?)?.toDouble(),
      );
}

/// Pergunta tipada do d1. [instruction] pode ser escrita ou falada.
sealed class D1Question {
  final String id;
  final String instructions;
  final D1Instruction instruction;

  const D1Question({
    required this.id,
    required this.instructions,
    this.instruction = const WrittenInstruction(''),
  });

  D1QuestionType get type;

  /// Prosa estável que o prompt builder usa (não é JSON bruto).
  String get prose;

  Map<String, dynamic> toJson();

  /// Instrução efetiva: a falada substitui a escrita quando presente.
  bool get isSpoken => instruction is SpokenInstruction;

  String get spokenPath =>
      instruction is SpokenInstruction ? (instruction as SpokenInstruction).wavFilePath : '';

  D1Question withInstruction(D1Instruction value);
}

/// `noul` — probabilidade Bernoulli de a afirmação ser verdadeira.
final class D1NoulQuestion extends D1Question {
  final String trueCriteria;
  final String falseCriteria;

  const D1NoulQuestion({
    required super.id,
    required super.instructions,
    this.trueCriteria = 'sim',
    this.falseCriteria = 'não',
    super.instruction,
  });

  @override
  D1QuestionType get type => D1QuestionType.noul;

  @override
  String get prose => '$instructions (true: $trueCriteria; false: $falseCriteria)';

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.wire,
        'instructions': instructions,
        'criteria': {'true': trueCriteria, 'false': falseCriteria},
        'instruction': instruction.toJson(),
      };

  @override
  D1NoulQuestion withInstruction(D1Instruction value) => D1NoulQuestion(
        id: id,
        instructions: instructions,
        trueCriteria: trueCriteria,
        falseCriteria: falseCriteria,
        instruction: value,
      );
}

/// `choice` — escolha única ou múltipla entre critérios nomeados.
final class D1ChoiceQuestion extends D1Question {
  /// nome-da-opção → descrição do critério (ordem estável).
  final Map<String, String> criteria;
  final bool multiple;

  const D1ChoiceQuestion({
    required super.id,
    required super.instructions,
    required this.criteria,
    this.multiple = false,
    super.instruction,
  });

  @override
  D1QuestionType get type =>
      multiple ? D1QuestionType.multiChoice : D1QuestionType.choice;

  @override
  String get prose => '$instructions Opções: '
      '${criteria.entries.map((e) => '${e.key} (${e.value})').join('; ')}';

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'type': 'choice',
        'instructions': instructions,
        'criteria': criteria,
        if (multiple) 'multiple': true,
        'instruction': instruction.toJson(),
      };

  @override
  D1ChoiceQuestion withInstruction(D1Instruction value) => D1ChoiceQuestion(
        id: id,
        instructions: instructions,
        criteria: criteria,
        multiple: multiple,
        instruction: value,
      );
}

/// `score` — escala ordinal; o resultado é o índice esperado (0-based).
final class D1ScoreQuestion extends D1Question {
  /// Níveis ordenados (índice 0..n-1), do mais baixo ao mais alto.
  final List<String> levels;

  const D1ScoreQuestion({
    required super.id,
    required super.instructions,
    required this.levels,
    super.instruction,
  });

  @override
  D1QuestionType get type => D1QuestionType.score;

  @override
  String get prose => '$instructions Níveis: '
      '${levels.asMap().entries.map((e) => '${e.key}=${e.value}').join('; ')}';

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.wire,
        'instructions': instructions,
        'criteria': levels,
        'instruction': instruction.toJson(),
      };

  @override
  D1ScoreQuestion withInstruction(D1Instruction value) => D1ScoreQuestion(
        id: id,
        instructions: instructions,
        levels: levels,
        instruction: value,
      );
}

/// Extração de uma entidade textual (com span opcional).
final class D1TextQuestion extends D1Question {
  final String? hint;
  const D1TextQuestion({
    required super.id,
    required super.instructions,
    this.hint,
    super.instruction,
  });

  @override
  D1QuestionType get type => D1QuestionType.textSpan;

  @override
  String get prose => hint == null ? instructions : '$instructions ($hint)';

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'type': 'text',
        'instructions': instructions,
        if (hint != null) 'hint': hint,
        'instruction': instruction.toJson(),
      };

  @override
  D1TextQuestion withInstruction(D1Instruction value) =>
      D1TextQuestion(id: id, instructions: instructions, hint: hint, instruction: value);
}

/// Extração de um número com unidade (ex.: 1234.5 EUR).
final class D1NumberQuestion extends D1Question {
  final String? unitHint;
  const D1NumberQuestion({
    required super.id,
    required super.instructions,
    this.unitHint,
    super.instruction,
  });

  @override
  D1QuestionType get type => D1QuestionType.numberSpan;

  @override
  String get prose =>
      unitHint == null ? instructions : '$instructions (unidade: $unitHint)';

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'type': 'number',
        'instructions': instructions,
        if (unitHint != null) 'unit': unitHint,
        'instruction': instruction.toJson(),
      };

  @override
  D1NumberQuestion withInstruction(D1Instruction value) => D1NumberQuestion(
        id: id,
        instructions: instructions,
        unitHint: unitHint,
        instruction: value,
      );
}

/// Extração de uma data normalizada em ISO 8601 (YYYY-MM-DD).
final class D1DateQuestion extends D1Question {
  const D1DateQuestion({
    required super.id,
    required super.instructions,
    super.instruction,
  });

  @override
  D1QuestionType get type => D1QuestionType.dateSpan;

  @override
  String get prose => '$instructions (devolve ISO 8601 YYYY-MM-DD)';

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'type': 'date',
        'instructions': instructions,
        'instruction': instruction.toJson(),
      };

  @override
  D1DateQuestion withInstruction(D1Instruction value) =>
      D1DateQuestion(id: id, instructions: instructions, instruction: value);
}

/// Estimativa numérica por intervalo: devolve mediana e [p10, p90].
final class D1RangeQuestion extends D1Question {
  final double min;
  final double max;
  final double step;
  final String? unitHint;

  const D1RangeQuestion({
    required super.id,
    required super.instructions,
    required this.min,
    required this.max,
    this.step = 1,
    this.unitHint,
    super.instruction,
  });

  @override
  D1QuestionType get type => D1QuestionType.numberRange;

  @override
  String get prose => '$instructions Intervalo: [$min, $max], passo $step'
      '${unitHint == null ? '' : ' ($unitHint)'}';

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'type': 'number',
        'instructions': instructions,
        'range': {'min': min, 'max': max, 'step': step},
        if (unitHint != null) 'unit': unitHint,
        'instruction': instruction.toJson(),
      };

  @override
  D1RangeQuestion withInstruction(D1Instruction value) => D1RangeQuestion(
        id: id,
        instructions: instructions,
        min: min,
        max: max,
        step: step,
        unitHint: unitHint,
        instruction: value,
      );
}

/// Deteção de um objeto na imagem (coordenadas fracionárias 0..1).
final class D1BoxQuestion extends D1Question {
  final String? target;
  const D1BoxQuestion({
    required super.id,
    required super.instructions,
    this.target,
    super.instruction,
  });

  @override
  D1QuestionType get type => D1QuestionType.box;

  @override
  String get prose =>
      target == null ? instructions : '$instructions (alvo: $target)';

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'type': 'box',
        'instructions': instructions,
        if (target != null) 'target': target,
        'instruction': instruction.toJson(),
      };

  @override
  D1BoxQuestion withInstruction(D1Instruction value) =>
      D1BoxQuestion(id: id, instructions: instructions, target: target, instruction: value);
}

/// Deteção de até [maxBoxes] objetos (limite do contrato d1: 16).
final class D1BoxesQuestion extends D1Question {
  final String? target;
  final int maxBoxes;

  const D1BoxesQuestion({
    required super.id,
    required super.instructions,
    this.target,
    this.maxBoxes = 16,
    super.instruction,
  });

  @override
  D1QuestionType get type => D1QuestionType.boxes;

  @override
  String get prose =>
      '$instructions (${target ?? 'objetos'}; até $maxBoxes caixas)';

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'type': 'boxes',
        'instructions': instructions,
        if (target != null) 'target': target,
        'max': maxBoxes,
        'instruction': instruction.toJson(),
      };

  @override
  D1BoxesQuestion withInstruction(D1Instruction value) => D1BoxesQuestion(
        id: id,
        instructions: instructions,
        target: target,
        maxBoxes: maxBoxes,
        instruction: value,
      );
}

/// Caixa delimitadora em coordenadas fracionárias [0, 1].
class BoundingBoxFrac {
  final double top;
  final double bottom;
  final double left;
  final double right;
  final double confidence;

  /// Probabilidade de o objeto estar presente (o contrato devolve `found`).
  final double found;

  const BoundingBoxFrac({
    required this.top,
    required this.bottom,
    required this.left,
    required this.right,
    this.confidence = 0,
    this.found = 1,
  });

  bool get isPresent => found >= 0.5;

  double get width => (right - left).abs();
  double get height => (bottom - top).abs();
  double get centerX => (left + right) / 2;
  double get centerY => (top + bottom) / 2;

  /// Converte para píxeis numa imagem de [width] × [height].
  ({double left, double top, double right, double bottom}) toPixels(
          double imageWidth, double imageHeight) =>
      (
        left: left * imageWidth,
        top: top * imageHeight,
        right: right * imageWidth,
        bottom: bottom * imageHeight,
      );

  Map<String, dynamic> toJson() => {
        'top': top,
        'bottom': bottom,
        'left': left,
        'right': right,
        'confidence': confidence,
        'found': found,
      };

  factory BoundingBoxFrac.fromJson(Map<String, dynamic> j) => BoundingBoxFrac(
        top: (j['top'] as num? ?? 0).toDouble(),
        bottom: (j['bottom'] as num? ?? 0).toDouble(),
        left: (j['left'] as num? ?? 0).toDouble(),
        right: (j['right'] as num? ?? 0).toDouble(),
        confidence: (j['confidence'] as num? ?? 0).toDouble(),
        found: (j['found'] as num? ?? 1).toDouble(),
      );
}

/// Span de caracteres/tokens devolvido pelas primitivas de extração.
class D1Span {
  final int start;
  final int end;
  const D1Span(this.start, this.end);

  Map<String, dynamic> toJson() => {'start': start, 'end': end};
}

/// Resposta a uma pergunta tipada.
sealed class D1Answer {
  final String id;
  final D1QuestionType type;

  /// Confiança calibrada do d1 (max(p) ou 1 − H(p)/log k).
  final double confidence;

  /// Probabilidades por rótulo/opção (vazio quando não aplicável).
  final Map<String, double> probabilities;

  const D1Answer({
    required this.id,
    required this.type,
    required this.confidence,
    this.probabilities = const {},
  });

  /// Valor principal legível (para a UI e para os relatórios).
  String get summary;

  Map<String, dynamic> toJson();
}

class D1NoulAnswer extends D1Answer {
  final double pTrue;
  const D1NoulAnswer({
    required super.id,
    required this.pTrue,
    required super.confidence,
    super.probabilities,
  }) : super(type: D1QuestionType.noul);

  bool get value => pTrue >= 0.5;

  @override
  String get summary => 'noul · P(true) = ${pTrue.toStringAsFixed(3)}';

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'type': 'noul',
        'noul': pTrue,
        'value': value,
        'confidence': confidence,
        'probabilities': probabilities,
      };
}

class D1ChoiceAnswer extends D1Answer {
  final String choice;
  const D1ChoiceAnswer({
    required super.id,
    required this.choice,
    required super.confidence,
    super.probabilities,
  }) : super(type: D1QuestionType.choice);

  @override
  String get summary => 'choice · $choice';

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'type': 'choice',
        'choice': choice,
        'confidence': confidence,
        'probabilities': probabilities,
      };
}

class D1MultiChoiceAnswer extends D1Answer {
  final List<String> selected;
  final double threshold;

  const D1MultiChoiceAnswer({
    required super.id,
    required this.selected,
    required super.confidence,
    this.threshold = 0.5,
    super.probabilities,
  }) : super(type: D1QuestionType.multiChoice);

  @override
  String get summary =>
      'multi-choice · ${selected.isEmpty ? 'nenhuma' : selected.join(', ')}';

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'type': 'choice',
        'multiple': true,
        'selected': selected,
        'threshold': threshold,
        'confidence': confidence,
        'probabilities': probabilities,
      };
}

class D1ScoreAnswer extends D1Answer {
  /// Índice esperado (0-based, pode ser fracionário).
  final double score;
  final List<String> levels;

  const D1ScoreAnswer({
    required super.id,
    required this.score,
    required this.levels,
    required super.confidence,
    super.probabilities,
  }) : super(type: D1QuestionType.score);

  String get levelLabel {
    if (levels.isEmpty) return '—';
    final i = score.round().clamp(0, levels.length - 1);
    return levels[i];
  }

  @override
  String get summary =>
      'score · ${score.toStringAsFixed(2)} ($levelLabel)';

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'type': 'score',
        'score': score,
        'level': levelLabel,
        'levels': levels,
        'confidence': confidence,
        'probabilities': probabilities,
      };
}

class D1TextAnswer extends D1Answer {
  final String? text;
  final D1Span? span;
  final bool found;

  const D1TextAnswer({
    required super.id,
    required this.text,
    required this.found,
    this.span,
    required super.confidence,
    super.probabilities,
  }) : super(type: D1QuestionType.textSpan);

  @override
  String get summary =>
      found ? 'text · "${text ?? ''}"' : 'text · não encontrado';

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'type': 'text',
        'text': found ? text : null,
        'found': found,
        if (span != null) 'span': span!.toJson(),
        'confidence': confidence,
      };
}

class D1NumberAnswer extends D1Answer {
  final double? value;
  final String? unit;
  final D1Span? span;
  final bool found;

  const D1NumberAnswer({
    required super.id,
    required this.value,
    required this.found,
    this.unit,
    this.span,
    required super.confidence,
    super.probabilities,
  }) : super(type: D1QuestionType.numberSpan);

  @override
  String get summary => found
      ? 'number · ${value?.toString() ?? ''}${unit == null ? '' : ' $unit'}'
      : 'number · não encontrado';

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'type': 'number',
        'number': found ? value : null,
        if (unit != null) 'unit': unit,
        'found': found,
        if (span != null) 'span': span!.toJson(),
        'confidence': confidence,
      };
}

class D1DateAnswer extends D1Answer {
  final DateTime? date;
  final D1Span? span;
  final bool found;

  const D1DateAnswer({
    required super.id,
    required this.date,
    required this.found,
    this.span,
    required super.confidence,
    super.probabilities,
  }) : super(type: D1QuestionType.dateSpan);

  String? get iso => date == null
      ? null
      : '${date!.year.toString().padLeft(4, '0')}-'
          '${date!.month.toString().padLeft(2, '0')}-'
          '${date!.day.toString().padLeft(2, '0')}';

  @override
  String get summary => found ? 'date · $iso' : 'date · não encontrada';

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'type': 'date',
        'date': found ? iso : null,
        'found': found,
        if (span != null) 'span': span!.toJson(),
        'confidence': confidence,
      };
}

class D1RangeAnswer extends D1Answer {
  final double? median;
  final double? p10;
  final double? p90;
  final String? unit;
  final bool found;

  const D1RangeAnswer({
    required super.id,
    required this.median,
    required this.found,
    this.p10,
    this.p90,
    this.unit,
    required super.confidence,
    super.probabilities,
  }) : super(type: D1QuestionType.numberRange);

  @override
  String get summary => found
      ? 'range · mediana ${median?.toStringAsFixed(1)} '
          '[p10 ${p10?.toStringAsFixed(1)}, p90 ${p90?.toStringAsFixed(1)}]'
      : 'range · não estimado';

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'type': 'number',
        'range': true,
        'median': found ? median : null,
        'p10': found ? p10 : null,
        'p90': found ? p90 : null,
        if (unit != null) 'unit': unit,
        'found': found,
        'confidence': confidence,
      };
}

class D1BoxAnswer extends D1Answer {
  final BoundingBoxFrac? box;
  const D1BoxAnswer({
    required super.id,
    required this.box,
    required super.confidence,
  }) : super(type: D1QuestionType.box);

  bool get found => box?.isPresent ?? false;

  @override
  String get summary => found
      ? 'box · [${box!.left.toStringAsFixed(3)}, ${box!.top.toStringAsFixed(3)}, '
          '${box!.right.toStringAsFixed(3)}, ${box!.bottom.toStringAsFixed(3)}]'
      : 'box · não encontrada';

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'type': 'box',
        'box': found ? box!.toJson() : null,
        'found': found,
        'confidence': confidence,
      };
}

class D1BoxesAnswer extends D1Answer {
  final List<BoundingBoxFrac> boxes;
  const D1BoxesAnswer({
    required super.id,
    required this.boxes,
    required super.confidence,
  }) : super(type: D1QuestionType.boxes);

  int get count => boxes.length;

  @override
  String get summary => 'boxes · $count caixa(s)';

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'type': 'boxes',
        'boxes': [for (final b in boxes) b.toJson()],
        'count': count,
        'confidence': confidence,
      };
}

/// Estado completo de um pedido ao d1.
class D1Request {
  /// Texto/JSON do estado (o d1 foi treinado com estado textual enxuto).
  final String state;
  final List<D1Media> media;
  final List<D1Question> questions;

  const D1Request({
    required this.state,
    this.media = const [],
    required this.questions,
  });

  int get imageCount =>
      media.where((m) => m.kind == D1MediaKind.image).length;
  int get videoCount =>
      media.where((m) => m.kind == D1MediaKind.video).length;
  int get audioCount =>
      media.where((m) => m.kind == D1MediaKind.audio).length;

  Map<String, dynamic> toJson() => {
        'state': state,
        'media': [for (final m in media) m.toJson()],
        'questions': {for (final q in questions) q.id: q.toJson()},
      };
}

/// Resposta completa do d1.
class D1Response {
  final Map<String, D1Answer> answers;

  /// Tokens de entrada do decoder (state + perguntas).
  final int inputTokens;

  /// Invariante: 0 (o d1 não gera texto).
  final int outputTokens;

  final int latencyMs;

  /// Número de slots de resposta avaliados no forward pass.
  final int slotCount;

  /// `d1-onnx` | `d1-gguf`.
  final String engine;

  const D1Response({
    required this.answers,
    required this.inputTokens,
    this.outputTokens = 0,
    required this.latencyMs,
    this.slotCount = 0,
    this.engine = 'd1-onnx',
  });

  Map<String, dynamic> toJson() => {
        'answers': {for (final e in answers.entries) e.key: e.value.toJson()},
        'usage': {
          'input_tokens': inputTokens,
          'output_tokens': outputTokens,
          'slot_count': slotCount,
        },
        'latency_ms': latencyMs,
        'engine': engine,
      };
}

/// Capacidades do backend d1 carregado.
class D1Capabilities {
  final Set<D1QuestionType> types;
  final bool vision;
  final bool video;
  final bool audio;

  const D1Capabilities({
    required this.types,
    this.vision = false,
    this.video = false,
    this.audio = false,
  });

  bool supports(D1QuestionType t) => types.contains(t);

  static const D1Capabilities onnxFull = D1Capabilities(
    types: {
      D1QuestionType.noul,
      D1QuestionType.choice,
      D1QuestionType.multiChoice,
      D1QuestionType.score,
      D1QuestionType.textSpan,
      D1QuestionType.numberSpan,
      D1QuestionType.dateSpan,
      D1QuestionType.numberRange,
      D1QuestionType.box,
      D1QuestionType.boxes,
    },
    vision: true,
    video: true,
    audio: true,
  );

  /// O que o `D1OnnxEngine` desta build executa: todas as primitivas de
  /// texto + imagem; áudio/vídeo ONNX ainda exigem o processor oficial.
  static const D1Capabilities onnxVisionText = D1Capabilities(
    types: {
      D1QuestionType.noul,
      D1QuestionType.choice,
      D1QuestionType.multiChoice,
      D1QuestionType.score,
      D1QuestionType.textSpan,
      D1QuestionType.numberSpan,
      D1QuestionType.dateSpan,
      D1QuestionType.numberRange,
      D1QuestionType.box,
      D1QuestionType.boxes,
    },
    vision: true,
    video: false,
    audio: false,
  );

  /// Via GGUF do llama.cpp: apenas noul/choice/score (limitação documentada).
  static const D1Capabilities ggufBasic = D1Capabilities(
    types: {
      D1QuestionType.noul,
      D1QuestionType.choice,
      D1QuestionType.score,
    },
  );

  Map<String, dynamic> toJson() => {
        'types': [for (final t in types) t.wire],
        'vision': vision,
        'video': video,
        'audio': audio,
      };
}
