/// Construção determinística do prompt e do plano de slots do d1.
///
/// Contrato (extraído do pacote ONNX oficial, `prompt.py`/`slots.py`):
///  - **uma** linha, sem padding, batch 1; até 16 perguntas;
///  - prefixo ChatML: `<|startoftext|><|im_start|>user\n` + mídia + estado +
///    `QUESTION:\n` + bloco da pergunta + `<|im_end|>\n<|im_start|>assistant\n`;
///  - slots de resposta são o token do `:` final de cada marcador
///    (`start:`, `end:`, `present:`, `top:`, …); noul/choice/score/range usam
///    um slot implícito no fim do prefixo do assistente;
///  - `question_ids` = -1 no estado e `k` nos tokens da pergunta k;
///  - `slot_positions` é um vetor plano `[num_slots]`.
///
/// O builder produz **uma pergunta por prompt**. O motor d1 corre um forward
/// pass por pergunta e agrega as respostas — mais simples de validar do que o
/// packing `set` (16 perguntas) e igualmente zero-token.
library;

import 'dart:convert';

import '../domain/d1_decision_types.dart';
import 'd1_tokenizer.dart';

enum D1SlotKind { categorical, spanStart, spanEnd }

class D1SlotSpec {
  final String questionId;
  final D1QuestionType type;
  final String field;
  final D1SlotKind kind;

  /// Rótulos das classes (para `categorical`): `no`/`yes`, códigos de opção,
  /// níveis de score, bins da grelha.
  final List<String> labels;

  /// Intervalo de valores (range/box).
  final double? min;
  final double? max;
  final double? step;

  const D1SlotSpec({
    required this.questionId,
    required this.type,
    required this.field,
    required this.kind,
    this.labels = const [],
    this.min,
    this.max,
    this.step,
  });
}

class D1Prompt {
  final String text;
  final List<int> inputIds;
  final List<int> questionIds;
  final List<int> slotPositions;
  final List<D1SlotSpec> slots;
  final String questionId;

  /// Estado exato (após truncagem) e offsets de caracteres no prompt.
  final String stateText;
  final int stateStartChar;
  final int stateEndChar;

  /// Offsets de caracteres de cada token no prompt.
  final List<int> tokenStarts;
  final List<int> tokenEnds;

  /// Posições dos tokens do estado + BOS0 (chaves do pointer d1).
  final List<int> stateTokenPositions;

  const D1Prompt({
    required this.text,
    required this.inputIds,
    required this.questionIds,
    required this.slotPositions,
    required this.slots,
    required this.questionId,
    required this.stateText,
    required this.stateStartChar,
    required this.stateEndChar,
    required this.tokenStarts,
    required this.tokenEnds,
    required this.stateTokenPositions,
  });
}

class D1PromptBuilder {
  final D1Tokenizer tokenizer;
  final int maxStateTokens;
  final int maxQuestions;

  /// Lead do LFM3 (vazio; o chat template não acrescenta texto).
  final String lead;

  /// Nº de tokens de feature por item de `request.media` (o processor oficial
  /// expande cada `<|image|>`/`<|audio|>` num token por feature). `null` =
  /// 1 por item (compatibilidade com prompts de texto).
  final List<int>? mediaTokenCounts;

  const D1PromptBuilder({
    required this.tokenizer,
    this.maxStateTokens = 8192,
    this.maxQuestions = 16,
    this.lead = '',
    this.mediaTokenCounts,
  });

  /// Constrói o prompt de UMA pergunta (índice [questionIndex]).
  D1Prompt build(D1Request request, {int questionIndex = 0}) {
    final q = request.questions[questionIndex];
    final state = _truncateState(request.state, maxStateTokens ~/ 2);
    final text = StringBuffer()
      ..write('<|startoftext|><|im_start|>user\n');
    for (var i = 0; i < request.media.length; i++) {
      final m = request.media[i];
      final marker = switch (m.kind) {
        D1MediaKind.image => '<|image|>',
        D1MediaKind.video => '<|video|>',
        D1MediaKind.audio => '<|audio|>',
      };
      final count = mediaTokenCounts != null && i < mediaTokenCounts!.length
          ? mediaTokenCounts![i].clamp(1, 4096).toInt()
          : 1;
      // O chat template envolve a mídia em <|vision_start|>…<|vision_end|>.
      text.write('<|vision_start|>');
      for (var t = 0; t < count; t++) {
        text.write(marker);
      }
      text.writeln('<|vision_end|>');
    }
    final stateStart = text.length;
    if (state.isNotEmpty) text.write(state);
    final stateEnd = text.length;
    if (state.isNotEmpty) text.write('\n\n');
    text.write('QUESTION:\n');
    final qStart = text.length;
    text.write(_questionBlock(q));
    final qEnd = text.length;
    text.write('<|im_end|>\n<|im_start|>assistant\n');
    text.write(lead);

    final slots = <D1SlotSpec>[];
    final markerOffsets = <int>[];
    final implicit = <bool>[];

    void addMarker(D1SlotSpec spec, String marker, String colonSource) {
      text.write('\n$marker');
      final idx = text.toString().lastIndexOf(colonSource);
      markerOffsets.add(idx);
      implicit.add(false);
      slots.add(spec);
    }

    switch (q) {
      case D1NoulQuestion():
        _addImplicit(text, slots, markerOffsets, implicit,
            D1SlotSpec(
              questionId: q.id,
              type: q.type,
              field: 'answer',
              kind: D1SlotKind.categorical,
              labels: const ['no', 'yes'],
            ));
      case D1ChoiceQuestion(:final criteria, :final multiple):
        if (multiple) {
          final codes = _codes(criteria.length);
          for (var i = 0; i < criteria.length; i++) {
            addMarker(
              D1SlotSpec(
                questionId: q.id,
                type: D1QuestionType.multiChoice,
                field: 'option:${codes[i]}',
                kind: D1SlotKind.categorical,
                labels: const ['no', 'yes'],
              ),
              jsonEncode(codes[i]),
              ':',
            );
          }
        } else {
          _addImplicit(
            text,
            slots,
            markerOffsets,
            implicit,
            D1SlotSpec(
              questionId: q.id,
              type: D1QuestionType.choice,
              field: 'answer',
              kind: D1SlotKind.categorical,
              labels: _codes(criteria.length),
            ),
          );
        }
      case D1ScoreQuestion(:final levels):
        _addImplicit(
          text,
          slots,
          markerOffsets,
          implicit,
          D1SlotSpec(
            questionId: q.id,
            type: D1QuestionType.score,
            field: 'answer',
            kind: D1SlotKind.categorical,
            labels: [for (var i = 0; i < levels.length; i++) '$i'],
          ),
        );
      case D1TextQuestion():
        _addSpan(text, q, slots, markerOffsets, implicit);
      case D1NumberQuestion():
        _addSpan(text, q, slots, markerOffsets, implicit);
      case D1DateQuestion():
        _addSpan(text, q, slots, markerOffsets, implicit);
      case D1RangeQuestion(:final min, :final max, :final step):
        _addImplicit(
          text,
          slots,
          markerOffsets,
          implicit,
          D1SlotSpec(
            questionId: q.id,
            type: D1QuestionType.numberRange,
            field: 'estimate',
            kind: D1SlotKind.categorical,
            labels: [for (var i = 0; i < 128; i++) '$i'],
            min: min,
            max: max,
            step: step,
          ),
        );
      case D1BoxQuestion():
        _addBox(text, q, 'box0', slots, markerOffsets, implicit);
      case D1BoxesQuestion(:final maxBoxes):
        for (var b = 0; b < maxBoxes; b++) {
          _addBox(text, q, 'box$b', slots, markerOffsets, implicit);
        }
    }

    final promptText = text.toString();
    final tokens = tokenizer.encodeTokens(promptText);
    final slotPositions = <int>[];
    for (var i = 0; i < slots.length; i++) {
      if (implicit[i]) {
        slotPositions.add(tokens.isEmpty ? 0 : tokens.length - 1);
        continue;
      }
      final offset = markerOffsets[i];
      var found = -1;
      for (var t = 0; t < tokens.length; t++) {
        if (tokens[t].start <= offset && offset < tokens[t].end) {
          found = t;
          break;
        }
      }
      if (found < 0) {
        throw StateError('slot $i não encontrado no tokenizer (offset $offset)');
      }
      slotPositions.add(found);
    }

    final questionIds = List<int>.filled(tokens.length, -1);
    for (var t = 0; t < tokens.length; t++) {
      if (tokens[t].start >= qStart && tokens[t].start < qEnd) {
        questionIds[t] = questionIndex + 1;
      }
    }

    final statePositions = <int>[
      if (tokens.isNotEmpty) 0, // BOS0: leitura "nada"
      for (var t = 0; t < tokens.length; t++)
        if (tokens[t].start >= stateStart && tokens[t].start < stateEnd) t,
    ];

    return D1Prompt(
      text: promptText,
      inputIds: [for (final t in tokens) t.id],
      questionIds: questionIds,
      slotPositions: slotPositions,
      slots: slots,
      questionId: q.id,
      stateText: state,
      stateStartChar: stateStart,
      stateEndChar: stateEnd,
      tokenStarts: [for (final t in tokens) t.start],
      tokenEnds: [for (final t in tokens) t.end],
      stateTokenPositions: statePositions,
    );
  }

  void _addImplicit(
    StringBuffer text,
    List<D1SlotSpec> slots,
    List<int> offsets,
    List<bool> implicit,
    D1SlotSpec spec,
  ) {
    // Sem marcador: o slot é o último token do prefixo do assistente.
    offsets.add(text.length);
    implicit.add(true);
    slots.add(spec);
  }

  void _addSpan(
    StringBuffer text,
    D1Question q,
    List<D1SlotSpec> slots,
    List<int> offsets,
    List<bool> implicit,
  ) {
    for (final field in const ['start', 'end']) {
      text.write('\n$field:');
      offsets.add(text.length - 1);
      implicit.add(false);
      slots.add(D1SlotSpec(
        questionId: q.id,
        type: q.type,
        field: 'span_$field',
        kind: field == 'start' ? D1SlotKind.spanStart : D1SlotKind.spanEnd,
      ));
    }
  }

  void _addBox(
    StringBuffer text,
    D1Question q,
    String prefix,
    List<D1SlotSpec> slots,
    List<int> offsets,
    List<bool> implicit,
  ) {
    void add(String field, List<String> labels, double min, double max,
        D1SlotKind kind) {
      final marker = field == 'presence' ? '$prefix.present' : '$prefix.$field';
      text.write('\n$marker:');
      offsets.add(text.length - 1);
      implicit.add(false);
      slots.add(D1SlotSpec(
        questionId: q.id,
        type: q.type,
        field: '$prefix.$field',
        kind: kind,
        labels: labels,
        min: min,
        max: max,
      ));
    }

    add('presence', const ['no', 'yes'], 0, 1, D1SlotKind.categorical);
    for (final edge in const ['top', 'bottom', 'left', 'right']) {
      add(edge, [for (var i = 0; i < 128; i++) '$i'], 0, 1,
          D1SlotKind.categorical);
    }
  }

  String _questionBlock(D1Question q) {
    switch (q) {
      case D1NoulQuestion():
        return '${q.instructions}\nAnswer yes or no.\n';
      case D1ChoiceQuestion(:final criteria, :final multiple):
        final codes = _codes(criteria.length);
        final buf = StringBuffer('${q.instructions}\n');
        for (var i = 0; i < criteria.length; i++) {
          buf.writeln('${codes[i]}. ${criteria.values.elementAt(i)}');
        }
        if (multiple) buf.writeln('Select all that apply.');
        return buf.toString();
      case D1ScoreQuestion(:final levels):
        final buf = StringBuffer('${q.instructions}\n');
        for (var i = 0; i < levels.length; i++) {
          buf.writeln('$i. ${levels[i]}');
        }
        return buf.toString();
      case D1TextQuestion():
        return '${q.instructions}\n';
      case D1NumberQuestion():
        return '${q.instructions}\n';
      case D1DateQuestion():
        return '${q.instructions}\n';
      case D1RangeQuestion(:final min, :final max):
        return '${q.instructions}\nEstimate a number between $min and $max.\n';
      case D1BoxQuestion(:final target):
        return '${q.instructions}\nLocate: ${target ?? 'object'}.\n';
      case D1BoxesQuestion(:final target):
        return '${q.instructions}\nLocate all: ${target ?? 'objects'}.\n';
    }
  }

  List<String> _codes(int n) {
    final out = <String>[];
    for (var i = 0; i < n; i++) {
      if (i < 26) {
        out.add(String.fromCharCode(65 + i));
      } else {
        final a = ((i - 26) ~/ 26) % 26;
        final b = (i - 26) % 26;
        out.add('${String.fromCharCode(65 + a)}${String.fromCharCode(65 + b)}');
      }
    }
    return out;
  }

  String _truncateState(String state, int maxTokens) {
    if (maxTokens <= 0) return state;
    final ids = tokenizer.encode(state);
    if (ids.length <= maxTokens) return state;
    return tokenizer.decode(ids.take(maxTokens).toList());
  }
}
