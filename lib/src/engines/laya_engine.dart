/// Interface do motor do Laya (decisor tipado ONNX fp32).
///
/// Um pedido entra ([LayaRequest]), decisões tipadas saem ([LayaResponse]).
/// O modelo NÃO gera texto (`output_tokens` invariante = 0).
library;

import '../domain/laya_types.dart';
import '../domain/llm_config.dart';

abstract class LayaEngine {
  bool get isLoaded;
  String get modelId;

  /// Carrega `model.onnx` (head fundida: 5 inputs → logits + act_logits)
  /// e o tokenizer BPE ByteLevel correspondente.
  Future<void> load({
    required String modelPath,
    required String tokenizerPath,
    required LayaConfig config,
  });

  /// Uma passagem só: state + perguntas → respostas tipadas.
  Future<LayaResponse> decide(LayaRequest request);

  Future<void> unload();
}