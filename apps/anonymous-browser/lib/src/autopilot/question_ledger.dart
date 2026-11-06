/// Ledger anti-repetição de perguntas ao humano — port do ledger de `ask_user`
/// do desktop (`autopilot.py`, qid = sha1(kind|ctx|pergunta normalizada) +
/// similaridade de Jaccard ≥ 0.8).
///
/// Uma pergunta já respondida (mesmo qid ou similar) nunca volta a sair:
/// replay silencioso da resposta. O humano não é repetidamente incomodado.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Normalização da pergunta para o qid (minúsculas, sem pontuação/espaços).
String normalizeQuestion(String q) {
  final s = q.toLowerCase().replaceAll(RegExp(r'[^a-z0-9à-ÿ\s]'), ' ');
  return s.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// qid estável: sha1(kind|ctx|pergunta normalizada).
String questionId(String kind, String ctx, String question) {
  final raw = '$kind|${ctx.trim()}|${normalizeQuestion(question)}';
  return sha1.convert(utf8.encode(raw)).toString();
}

/// Similaridade de Jaccard sobre os conjuntos de palavras.
double jaccard(String a, String b) {
  final wa = normalizeQuestion(a).split(' ').where((w) => w.isNotEmpty).toSet();
  final wb = normalizeQuestion(b).split(' ').where((w) => w.isNotEmpty).toSet();
  if (wa.isEmpty && wb.isEmpty) return 1.0;
  if (wa.isEmpty || wb.isEmpty) return 0.0;
  final inter = wa.intersection(wb).length;
  final union = wa.union(wb).length;
  return inter / union;
}

/// Pergunta-resposta registada.
class AnsweredQuestion {
  final String qid;
  final String kind;
  final String question;
  final String answer;
  final DateTime at;

  const AnsweredQuestion({
    required this.qid,
    required this.kind,
    required this.question,
    required this.answer,
    required this.at,
  });

  Map<String, dynamic> toJson() => {
        'qid': qid,
        'kind': kind,
        'question': question,
        'answer': answer,
        'at': at.toIso8601String(),
      };

  factory AnsweredQuestion.fromJson(Map<String, dynamic> j) => AnsweredQuestion(
        qid: j['qid'] as String,
        kind: j['kind'] as String? ?? '',
        question: j['question'] as String? ?? '',
        answer: j['answer'] as String? ?? '',
        at: DateTime.tryParse(j['at'] as String? ?? '') ?? DateTime.now(),
      );
}

class QuestionLedger {
  final List<AnsweredQuestion> _entries = [];
  final double similarity;

  QuestionLedger({this.similarity = 0.8});

  List<AnsweredQuestion> get entries => List.unmodifiable(_entries);

  /// Já respondida? Devolve a resposta antiga (replay silencioso) ou null.
  String? recall(String kind, String ctx, String question) {
    final qid = questionId(kind, ctx, question);
    for (final e in _entries.reversed) {
      if (e.qid == qid) return e.answer;
    }
    for (final e in _entries.reversed) {
      if (e.kind == kind && jaccard(e.question, question) >= similarity) {
        return e.answer;
      }
    }
    return null;
  }

  /// Regista a resposta (suplanta duplicados do mesmo qid).
  void record(String kind, String ctx, String question, String answer) {
    final qid = questionId(kind, ctx, question);
    _entries.removeWhere((e) => e.qid == qid);
    _entries.add(AnsweredQuestion(
      qid: qid,
      kind: kind,
      question: question,
      answer: answer,
      at: DateTime.now(),
    ));
  }

  List<Map<String, dynamic>> toJson() => [for (final e in _entries) e.toJson()];

  void loadJson(List<dynamic> json) {
    _entries
      ..clear()
      ..addAll([
        for (final e in json) AnsweredQuestion.fromJson(Map<String, dynamic>.from(e as Map))
      ]);
  }
}
