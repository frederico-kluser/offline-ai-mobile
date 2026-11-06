/// Decode das saídas do decoder d1 para respostas tipadas.
///
/// O grafo devolve `logits` em `[num_slots, 128000]` (log-probabilidades) e
/// `hidden_states` em `[1, seq, 2048]`. As primitivas categóricas usam os
/// grupos de tokens das opções (max-pool por opção + softmax), tal como o
/// runner oficial. As primitivas de span (text/number/date) exigem o pointer
/// head do pacote e falham com [D1UnsupportedPrimitive] quando não está
/// disponível — nunca inventam uma resposta.
library;

import 'dart:math' as math;

import '../domain/d1_decision_types.dart';
import 'd1_engine.dart';
import 'd1_prompt.dart';
import 'd1_tokenizer.dart';

/// Grupos de tokens por rótulo (yes/no, códigos A..Z, dígitos, bins).
class D1AnswerVocabulary {
  final D1Tokenizer tokenizer;
  Map<String, List<int>>? _byNorm;

  D1AnswerVocabulary(this.tokenizer);

  Map<String, List<int>> get _groups {
    final cached = _byNorm;
    if (cached != null) return cached;
    final map = <String, List<int>>{};
    for (final e in tokenizer.inverseVocab.entries) {
      final text = tokenizer.decode([e.key]);
      final norm = _normalize(text);
      if (norm.isEmpty) continue;
      map.putIfAbsent(norm, () => []).add(e.key);
    }
    _byNorm = map;
    return map;
  }

  List<int> idsFor(String label) {
    final variants = <String>{label};
    final numeric = int.tryParse(label);
    if (numeric != null) {
      variants
        ..add(numeric.toString().padLeft(2, '0'))
        ..add(numeric.toString().padLeft(3, '0'));
    }
    final out = <int>{};
    for (final v in variants) {
      out.addAll(_groups[_normalize(v)] ?? const []);
    }
    return out.toList();
  }

  static String _normalize(String s) {
    var t = s.trim().toLowerCase();
    // Remove pontuação/whitespace das pontas e espaços internos.
    t = t.replaceAll(RegExp(r'^[^a-z0-9]+'), '');
    t = t.replaceAll(RegExp(r'[^a-z0-9]+$'), '');
    t = t.replaceAll(RegExp(r'\s+'), '');
    return t;
  }
}

class D1OutputDecoder {
  const D1OutputDecoder();

  D1Answer decodeOne({
    required D1Question question,
    required D1Prompt prompt,
    required List<double> logits,
    required List<int> logitsShape,
    required D1Tokenizer tokenizer,
    required double latencyMs,
    List<double>? hiddenStates,
    List<int>? hiddenShape,
  }) {
    final rows = _rows(logits, logitsShape, prompt);
    final vocab = D1AnswerVocabulary(tokenizer);
    switch (question) {
      case D1NoulQuestion():
        final p = _categorical(rows.first, const ['no', 'yes'], vocab);
        return D1NoulAnswer(
          id: question.id,
          pTrue: p['yes'] ?? 0,
          confidence: _confidence(p.values.toList()),
          probabilities: _roundMap(p),
        );
      case D1ChoiceQuestion(:final criteria, :final multiple):
        if (multiple) {
          final probs = <String, double>{};
          final codes = prompt.slots.map((s) => s.field.split(':').last).toList();
          for (var i = 0; i < prompt.slots.length; i++) {
            final p = _categorical(rows[i], const ['no', 'yes'], vocab);
            probs[codes[i]] = p['yes'] ?? 0;
          }
          final selectedCodes = [
            for (final e in probs.entries)
              if (e.value >= 0.5) e.key,
          ];
          final keys = criteria.keys.toList();
          final selected = [
            for (final code in selectedCodes)
              if (_codeIndex(code) >= 0 && _codeIndex(code) < keys.length)
                keys[_codeIndex(code)],
          ];
          return D1MultiChoiceAnswer(
            id: question.id,
            selected: selected,
            confidence: _confidence(probs.values.toList()),
            probabilities: {
              for (var i = 0; i < keys.length; i++)
                keys[i]: _round4(probs[prompt.slots[i].field.split(':').last] ?? 0),
            },
          );
        }
        final labels = prompt.slots.first.labels;
        final p = _categorical(rows.first, labels, vocab);
        var bestCode = labels.first;
        var bestP = -1.0;
        for (final e in p.entries) {
          if (e.value > bestP) {
            bestP = e.value;
            bestCode = e.key;
          }
        }
        final keys = criteria.keys.toList();
        final idx = _codeIndex(bestCode);
        final choice = idx >= 0 && idx < keys.length ? keys[idx] : bestCode;
        return D1ChoiceAnswer(
          id: question.id,
          choice: choice,
          confidence: _confidence(p.values.toList()),
          probabilities: {
            for (var i = 0; i < keys.length; i++)
              keys[i]: _round4(p[labels[i]] ?? 0),
          },
        );
      case D1ScoreQuestion(:final levels):
        final labels = prompt.slots.first.labels;
        final p = _categorical(rows.first, labels, vocab);
        var expected = 0.0;
        for (var i = 0; i < labels.length; i++) {
          expected += i * (p[labels[i]] ?? 0);
        }
        return D1ScoreAnswer(
          id: question.id,
          score: _round4(expected),
          levels: levels,
          confidence: _confidence(p.values.toList()),
          probabilities: _roundMap(p),
        );
      case D1RangeQuestion(:final min, :final max):
        final slot = prompt.slots.first;
        final p = _categorical(rows.first, slot.labels, vocab);
        var bin = 0.0;
        for (var i = 0; i < slot.labels.length; i++) {
          bin += i * (p[slot.labels[i]] ?? 0);
        }
        final values = <double>[];
        for (var i = 0; i < slot.labels.length; i++) {
          values.add(min + (max - min) * i / (slot.labels.length - 1));
        }
        double percentile(double q) {
          var acc = 0.0;
          for (var i = 0; i < slot.labels.length; i++) {
            acc += p[slot.labels[i]] ?? 0;
            if (acc >= q) return values[i];
          }
          return values.last;
        }

        return D1RangeAnswer(
          id: question.id,
          median: _round4(values[bin.round().clamp(0, values.length - 1)]),
          p10: _round4(percentile(0.10)),
          p90: _round4(percentile(0.90)),
          unit: question.unitHint,
          found: true,
          confidence: _confidence(p.values.toList()),
        );
      case D1BoxQuestion():
        final box = _decodeBox(question.id, prompt, rows, vocab, 0);
        return D1BoxAnswer(
          id: question.id,
          box: box,
          confidence: box?.confidence ?? 0,
        );
      case D1BoxesQuestion(:final maxBoxes):
        final boxes = <BoundingBoxFrac>[];
        for (var b = 0; b < maxBoxes; b++) {
          final box = _decodeBox(question.id, prompt, rows, vocab, b);
          if (box != null && box.isPresent) boxes.add(box);
        }
        return D1BoxesAnswer(
          id: question.id,
          boxes: boxes,
          confidence: boxes.isEmpty ? 0 : boxes.first.confidence,
        );
      case D1TextQuestion():
        return _decodeSpan(
          question,
          prompt,
          rows,
          hiddenStates,
          hiddenShape,
          isText: true,
        );
      case D1NumberQuestion():
        return _decodeSpan(
          question,
          prompt,
          rows,
          hiddenStates,
          hiddenShape,
          isText: false,
        );
      case D1DateQuestion():
        return _decodeSpan(
          question,
          prompt,
          rows,
          hiddenStates,
          hiddenShape,
          isText: false,
        );
    }
  }

  /// Pointer parameter-free do d1: `hidden[slot] · hidden[state] / sqrt(D)`.
  D1Answer _decodeSpan(
    D1Question question,
    D1Prompt prompt,
    List<List<double>> rows,
    List<double>? hidden,
    List<int>? hiddenShape, {
    required bool isText,
  }) {
    if (hidden == null || hiddenShape == null || hiddenShape.length != 3) {
      throw D1UnsupportedPrimitive(
        question.type,
        'hidden_states ausentes ou com shape inválido ($hiddenShape); '
        'o pointer d1 precisa de [1, seq, 2048]',
      );
    }
    final startSlot =
        prompt.slots.indexWhere((s) => s.field == 'span_start');
    final endSlot = prompt.slots.indexWhere((s) => s.field == 'span_end');
    if (startSlot < 0 || endSlot < 0) {
      throw D1UnsupportedPrimitive(
        question.type,
        'slots start/end em falta no prompt',
      );
    }
    final seq = hiddenShape[1];
    final dim = hiddenShape[2];
    if (hidden.length != seq * dim) {
      throw D1UnsupportedPrimitive(
        question.type,
        'hidden_states com ${hidden.length} valores; esperado ${seq * dim}',
      );
    }

    List<double> row(int i) => hidden.sublist(i * dim, (i + 1) * dim);
    final stateRows = [
      for (final pos in prompt.stateTokenPositions)
        if (pos >= 0 && pos < seq) row(pos),
    ];
    if (stateRows.isEmpty) {
      throw D1UnsupportedPrimitive(
        question.type,
        'sem posições de estado para o pointer',
      );
    }

    final startLogp = _pointerLogp(
      row(prompt.slotPositions[startSlot]),
      stateRows,
    );
    final endLogp = _pointerLogp(
      row(prompt.slotPositions[endSlot]),
      stateRows,
    );

    final found = (1 - math.exp(startLogp[0])).clamp(0.0, 1.0);
    final cap = isText ? 512 : 32;
    var bestScore = -double.infinity;
    var bestStart = 0;
    var bestEnd = 0;
    for (var s = 1; s < stateRows.length; s++) {
      final maxEnd = math.min(stateRows.length, s + cap);
      for (var e = s; e < maxEnd; e++) {
        final score = startLogp[s] + endLogp[e];
        if (score > bestScore) {
          bestScore = score;
          bestStart = s;
          bestEnd = e;
        }
      }
    }

    String? text;
    D1Span? span;
    if (found >= 0.5 && bestStart > 0) {
      final tokenStart = prompt.stateTokenPositions[bestStart];
      final tokenEnd = prompt.stateTokenPositions[bestEnd];
      final a = (prompt.tokenStarts[tokenStart] - prompt.stateStartChar)
          .clamp(0, prompt.stateText.length);
      final b = (prompt.tokenEnds[tokenEnd] - prompt.stateStartChar)
          .clamp(0, prompt.stateText.length);
      text = prompt.stateText.substring(a, b).trim();
      span = D1Span(a, b);
    }

    final confidence = _round4(found);
    if (question is D1TextQuestion) {
      return D1TextAnswer(
        id: question.id,
        text: text,
        span: span,
        found: found >= 0.5 && (text?.isNotEmpty ?? false),
        confidence: confidence,
      );
    }
    if (question is D1NumberQuestion) {
      final value = _parseNumber(text);
      return D1NumberAnswer(
        id: question.id,
        value: value,
        unit: _parseUnit(text),
        span: span,
        found: found >= 0.5 && value != null,
        confidence: confidence,
      );
    }
    final date = _parseDate(text);
    return D1DateAnswer(
      id: question.id,
      date: date,
      span: span,
      found: found >= 0.5 && date != null,
      confidence: confidence,
    );
  }

  List<double> _pointerLogp(List<double> query, List<List<double>> state) {
    if (state.isEmpty) return const [1.0];
    final scale = math.sqrt(query.length.toDouble());
    final scores = [
      for (final s in state)
        _dot(query, s) / (scale == 0 ? 1 : scale),
    ];
    final maxZ = scores.reduce(math.max);
    final e = [for (final v in scores) math.exp(v - maxZ)];
    final sum = e.fold<double>(0, (a, b) => a + b);
    return [for (final v in e) math.log(v / sum)];
  }

  double _dot(List<double> a, List<double> b) {
    final n = math.min(a.length, b.length);
    var s = 0.0;
    for (var i = 0; i < n; i++) {
      s += a[i] * b[i];
    }
    return s;
  }

  double? _parseNumber(String? text) {
    if (text == null) return null;
    final match = RegExp(r'[-+]?\d[\d\s.,]*').firstMatch(text);
    if (match == null) return null;
    var raw = match.group(0)!.replaceAll(RegExp(r'\s'), '');
    if (raw.contains(',') && raw.contains('.')) {
      raw = raw.replaceAll(',', '');
    } else if (raw.contains(',')) {
      raw = raw.replaceAll(',', '.');
    }
    return double.tryParse(raw);
  }

  String? _parseUnit(String? text) {
    if (text == null) return null;
    final match = RegExp(r'[A-Za-z€$£%]+').firstMatch(text);
    return match?.group(0);
  }

  DateTime? _parseDate(String? text) {
    if (text == null) return null;
    final direct = DateTime.tryParse(text.trim());
    if (direct != null) return direct;
    final match =
        RegExp(r'(\d{1,4})[./-](\d{1,2})[./-](\d{1,4})').firstMatch(text);
    if (match == null) return null;
    final a = int.parse(match.group(1)!);
    final b = int.parse(match.group(2)!);
    final c = int.parse(match.group(3)!);
    int year, month, day;
    if (match.group(1)!.length == 4) {
      year = a;
      month = b;
      day = c;
    } else if (a > 12) {
      day = a;
      month = b;
      year = c;
    } else {
      month = a;
      day = b;
      year = c;
    }
    if (year < 100) year += 2000;
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    final d = DateTime(year, month, day);
    if (d.year != year || d.month != month || d.day != day) return null;
    return d;
  }

  /// Lista de linhas de logits, uma por slot.
  List<List<double>> _rows(
    List<double> logits,
    List<int> shape,
    D1Prompt prompt,
  ) {
    if (shape.length != 2) {
      throw D1UnsupportedPrimitive(
        D1QuestionType.noul,
        'logits com shape $shape; esperado [n_slots, classes]',
      );
    }
    final a = shape[0], b = shape[1];
    if (a == prompt.slots.length) {
      return [
        for (var i = 0; i < a; i++) logits.sublist(i * b, (i + 1) * b),
      ];
    }
    if (a >= prompt.inputIds.length) {
      return [
        for (final pos in prompt.slotPositions)
          logits.sublist(pos * b, (pos + 1) * b),
      ];
    }
    throw D1UnsupportedPrimitive(
      D1QuestionType.noul,
      'logits $shape não alinham com ${prompt.slots.length} slots '
      'nem com ${prompt.inputIds.length} tokens',
    );
  }

  Map<String, double> _categorical(
    List<double> logits,
    List<String> labels,
    D1AnswerVocabulary vocab,
  ) {
    if (logits.length == labels.length) {
      return _softmaxMap(logits, labels);
    }
    // Logits sobre o vocabulário: max-pool por grupo de tokens da opção.
    final scores = <String, double>{};
    for (final label in labels) {
      final ids = vocab.idsFor(label);
      if (ids.isEmpty) {
        throw D1UnsupportedPrimitive(
          D1QuestionType.choice,
          'não há tokens para o rótulo "$label" no tokenizer',
        );
      }
      var best = -double.infinity;
      for (final id in ids) {
        if (id >= 0 && id < logits.length) {
          if (logits[id] > best) best = logits[id];
        }
      }
      if (best == -double.infinity) {
        throw D1UnsupportedPrimitive(
          D1QuestionType.choice,
          'logits não cobrem os tokens do rótulo "$label"',
        );
      }
      scores[label] = best;
    }
    return _softmaxMap(scores.values.toList(), labels);
  }

  Map<String, double> _softmaxMap(List<double> logits, List<String> labels) {
    if (logits.length == 1 && labels.length == 2) {
      final p = 1 / (1 + math.exp(-logits.first));
      return {labels[0]: 1 - p, labels[1]: p};
    }
    final maxZ = logits.reduce(math.max);
    final e = [for (final v in logits) math.exp(v - maxZ)];
    final sum = e.fold<double>(0, (a, b) => a + b);
    return {
      for (var i = 0; i < labels.length; i++) labels[i]: e[i] / sum,
    };
  }

  BoundingBoxFrac? _decodeBox(
    String questionId,
    D1Prompt prompt,
    List<List<double>> rows,
    D1AnswerVocabulary vocab,
    int boxIndex,
  ) {
    final prefix = 'box$boxIndex.';
    final presenceIndex = prompt.slots
        .indexWhere((s) => s.field == '${prefix}presence');
    if (presenceIndex < 0) return null;
    final presence = _categorical(
      rows[presenceIndex],
      const ['no', 'yes'],
      vocab,
    );
    final found = presence['yes'] ?? 0;
    final coords = <String, double>{};
    for (final edge in const ['top', 'bottom', 'left', 'right']) {
      final idx = prompt.slots.indexWhere((s) => s.field == '$prefix$edge');
      if (idx < 0) continue;
      final p = _categorical(rows[idx], prompt.slots[idx].labels, vocab);
      var bin = 0.0;
      for (var i = 0; i < prompt.slots[idx].labels.length; i++) {
        bin += i * (p[prompt.slots[idx].labels[i]] ?? 0);
      }
      coords[edge] = bin / (prompt.slots[idx].labels.length - 1);
    }
    return BoundingBoxFrac(
      top: coords['top'] ?? 0,
      bottom: coords['bottom'] ?? 1,
      left: coords['left'] ?? 0,
      right: coords['right'] ?? 1,
      confidence: _round4(found),
      found: found,
    );
  }

  int _codeIndex(String code) {
    if (code.isEmpty) return -1;
    if (code.length == 1) {
      final c = code.codeUnitAt(0);
      if (c >= 65 && c <= 90) return c - 65;
    }
    if (code.length == 2) {
      final a = code.codeUnitAt(0) - 65;
      final b = code.codeUnitAt(1) - 65;
      if (a >= 0 && b >= 0) return 26 + a * 26 + b;
    }
    return -1;
  }

  double _confidence(List<double> probs) {
    if (probs.isEmpty) return 0;
    if (probs.length == 1) return probs.first.clamp(0, 1);
    final maxP = probs.reduce(math.max);
    var ent = 0.0;
    for (final p in probs) {
      if (p > 0) ent -= p * math.log(p);
    }
    final normalized = 1 - ent / math.log(probs.length);
    return _round4((maxP + normalized).clamp(0, 2) / 2);
  }

  Map<String, double> _roundMap(Map<String, double> m) =>
      {for (final e in m.entries) e.key: _round4(e.value)};

  double _round4(double x) => (x * 1e4).roundToDouble() / 1e4;
}
