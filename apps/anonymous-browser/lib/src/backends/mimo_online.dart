/// MiMo online — port de `llm.chat_json`/`chat_text` do desktop
/// (`agent/anonagent/llm.py`): `POST {base}/api/v1/chat/completions` com
/// `xiaomi/mimo-v2.6-pro` (o modelo que PROCESSA as ações).
///
/// A key vem das definições; as chamadas NUNCA levam valores de segredos
/// (o tape já recebe o request mascarado).
library;

import 'dart:convert';

import 'package:ab_core/ab_core.dart' show ChatMessage;
import 'package:http/http.dart' as http;

import 'text_backend.dart';

/// Backend de texto MiMo via OpenRouter (chat completions).
class MimoOnlineBackend implements TextBackend {
  final String apiKey;
  final String baseUrl;
  final String model;
  final Duration timeout;

  final void Function(Map<String, dynamic> request, String? response,
      {int ms, double costUsd})? onTrace;

  MimoOnlineBackend({
    required this.apiKey,
    this.baseUrl = 'https://openrouter.ai',
    this.model = 'xiaomi/mimo-v2.6-pro',
    this.timeout = const Duration(seconds: 60),
    this.onTrace,
  });

  @override
  String get name => 'mimo-online';

  @override
  Future<String> chat({
    required List<ChatMessage> messages,
    double temperature = 1.0,
    int maxTokens = 512,
    Map<String, dynamic>? jsonSchema,
  }) async {
    final body = <String, dynamic>{
      'model': model,
      'messages': [
        for (final m in messages) {'role': m.role, 'content': m.content}
      ],
      'temperature': temperature,
      'max_tokens': maxTokens,
      if (jsonSchema != null)
        'response_format': {
          'type': 'json_schema',
          'json_schema': {'name': 'reply', 'strict': true, 'schema': jsonSchema},
        },
    };
    final sw = Stopwatch()..start();
    http.Response resp;
    try {
      resp = await http
          .post(
            Uri.parse('$baseUrl/api/v1/chat/completions'),
            headers: {
              'Authorization': 'Bearer $apiKey',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(timeout);
    } catch (e) {
      throw TextException('mimo: $e');
    }
    sw.stop();
    if (resp.statusCode != 200) {
      onTrace?.call(body, null, ms: sw.elapsedMilliseconds);
      throw TextException('mimo: HTTP ${resp.statusCode}', status: resp.statusCode);
    }
    final json = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    final choices = (json['choices'] as List?) ?? const [];
    String content = '';
    if (choices.isNotEmpty) {
      final msg = ((choices.first as Map)['message'] as Map?) ?? const {};
      content = '${msg['content'] ?? ''}';
    }
    final usage = (json['usage'] as Map?) ?? const {};
    final cost = (usage['cost'] as num? ?? 0).toDouble();
    onTrace?.call(body, content,
        ms: sw.elapsedMilliseconds, costUsd: cost);
    return content;
  }
}
