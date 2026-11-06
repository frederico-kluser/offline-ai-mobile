/// MiniCPM5-2B local — o gerador de texto no telemóvel (GGUF via llama.cpp,
/// ab_core). Sem rede: composição de texto, fallback de decisão e extração
/// 100% no aparelho.
library;

import 'package:ab_core/ab_core.dart';

import 'text_backend.dart';

/// Backend de texto sobre o motor MiniCPM5-2B local (ab_core).
class MinicpmLocalTextBackend implements TextBackend {
  final LlmEngine engine;
  final LlmConfig config;

  /// Teto de tokens por chamada (o default do llama.cpp é infinito — a app
  /// impõe SEMPRE teto explícito).
  final int maxTokens;

  MinicpmLocalTextBackend({
    required this.engine,
    required this.config,
    this.maxTokens = 512,
  });

  @override
  String get name => 'minicpm-local';

  @override
  Future<String> chat({
    required List<ChatMessage> messages,
    double temperature = 1.0,
    int maxTokens = 512,
    Map<String, dynamic>? jsonSchema,
  }) async {
    if (!engine.isLoaded) {
      throw const TextException('minicpm: motor não carregado');
    }
    final buf = StringBuffer();
    var ended = false;
    await for (final ev in engine.generate(
      messages: messages,
      config: config,
      maxTokensOverride: maxTokens <= 0 ? this.maxTokens : maxTokens,
    )) {
      switch (ev) {
        case GenDelta(:final text):
          buf.write(text);
        case GenEnd(:final stopReason, :final error):
          ended = true;
          if (stopReason == 'error') {
            throw TextException('minicpm: ${error ?? "erro de geração"}');
          }
      }
    }
    if (!ended && buf.isEmpty) {
      throw const TextException('minicpm: geração vazia');
    }
    return buf.toString();
  }
}
