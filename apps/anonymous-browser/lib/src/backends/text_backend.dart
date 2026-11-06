/// Contrato dos backends de TEXTO — o gerador de texto da cascata: escreve o
/// texto a digitar (com placeholders), compõe fallbacks de decisão, extrai
/// saídas e verifica conclusões. Online (MiMo) ou local (MiniCPM5-2B).
library;

import 'dart:convert';

import 'package:ab_core/ab_core.dart' show ChatMessage;

/// Erro de um backend de texto (a cascata passa ao próximo).
class TextException implements Exception {
  final String message;
  final int? status;
  const TextException(this.message, {this.status});

  @override
  String toString() => 'TextException($status): $message';
}

/// Backend de texto por passo.
abstract class TextBackend {
  String get name;

  /// Conversa livre. Quando [jsonSchema] existe, o backend faz o máximo para
  /// devolver UM objeto JSON válido nesse schema.
  Future<String> chat({
    required List<ChatMessage> messages,
    double temperature = 1.0,
    int maxTokens = 512,
    Map<String, dynamic>? jsonSchema,
  });
}

/// Extrai o primeiro objeto JSON de uma resposta de modelo (tolerante a
/// cercas ```json e prosa à volta).
Map<String, dynamic>? extractJsonObject(String text) {
  var s = text.trim();
  final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(s);
  if (fence != null) s = fence.group(1)!.trim();
  final start = s.indexOf('{');
  final end = s.lastIndexOf('}');
  if (start < 0 || end <= start) return null;
  try {
    final v = jsonDecode(s.substring(start, end + 1));
    return v is Map ? Map<String, dynamic>.from(v) : null;
  } catch (_) {
    // Tolerância mínima: vírgulas finais antes de } ou ].
    try {
      final v =
          jsonDecode(s.substring(start, end + 1).replaceAll(RegExp(r',\s*([}\]])'), r'$1'));
      return v is Map ? Map<String, dynamic>.from(v) : null;
    } catch (_) {
      return null;
    }
  }
}
