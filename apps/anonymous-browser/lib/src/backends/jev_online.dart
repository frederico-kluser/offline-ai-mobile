/// Jev online — port de `llm.jev()` do desktop (`agent/anonagent/llm.py`):
/// `POST {base}/api/alpha/decisions` com `{"model": "typesafe/jev-1.13",
/// "state": …, "questions": …}` e respostas `{choice|noul, confidence,
/// probabilities}`.
///
/// Snapshot FIXO do modelo (`typesafe/jev-1.13`): os limiares são calibrados
/// nele. A key vem das definições (nunca em argv/log/tape — o tape recebe o
/// request já sem o header).
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'decision_backend.dart';

/// Backend de decisão Jev via OpenRouter (endpoint Decisions, alpha).
class JevOnlineBackend implements DecisionBackend {
  final String apiKey;
  final String baseUrl;
  final String model;
  final Duration timeout;

  /// Observador de chamadas (tape) — recebe o request EXATO, sem headers.
  final void Function(Map<String, dynamic> request, Map<String, dynamic>? response,
      {int ms, double costUsd})? onTrace;

  JevOnlineBackend({
    required this.apiKey,
    this.baseUrl = 'https://openrouter.ai',
    this.model = 'typesafe/jev-1.13',
    this.timeout = const Duration(seconds: 20),
    this.onTrace,
  });

  @override
  String get name => 'jev-online';

  @override
  Future<DecisionAnswers> ask({
    required Map<String, dynamic> state,
    required Map<String, dynamic> questions,
  }) async {
    final body = jsonEncode({
      'model': model,
      'state': state,
      'questions': questions,
    });
    final sw = Stopwatch()..start();
    http.Response resp;
    try {
      resp = await http
          .post(
            Uri.parse('$baseUrl/api/alpha/decisions'),
            headers: {
              'Authorization': 'Bearer $apiKey',
              'Content-Type': 'application/json',
            },
            body: body,
          )
          .timeout(timeout);
    } catch (e) {
      throw DecisionException('jev: $e');
    }
    sw.stop();
    if (resp.statusCode != 200) {
      onTrace?.call({'model': model, 'state': state, 'questions': questions},
          {'status': resp.statusCode},
          ms: sw.elapsedMilliseconds);
      throw DecisionException('jev: HTTP ${resp.statusCode}',
          status: resp.statusCode);
    }
    final json = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    final answersRaw =
        (json['answers'] as Map?)?.cast<String, dynamic>() ?? const {};
    final answers = <String, TypedDecision>{};
    for (final e in answersRaw.entries) {
      final v = e.value;
      if (v is Map) {
        answers[e.key] =
            TypedDecision.fromJson(e.key, Map<String, dynamic>.from(v));
      }
    }
    final usage = (json['usage'] as Map?) ?? const {};
    final cost = (usage['cost'] as num? ?? 0).toDouble();
    onTrace?.call({'model': model, 'state': state, 'questions': questions}, json,
        ms: sw.elapsedMilliseconds, costUsd: cost);
    return DecisionAnswers(
      answers: answers,
      ms: sw.elapsedMilliseconds,
      costUsd: cost,
      backend: name,
    );
  }
}
