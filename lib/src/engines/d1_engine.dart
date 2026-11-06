/// Contrato do motor de decisão Liquid d1.
///
/// Duas vias:
///  - [D1OnnxEngine] — grafo ONNX (decoder + vision/audio encoders), todas as
///    dez primitivas, um forward pass sem KV cache;
///  - [D1GgufEngine] — via GGUF do llama.cpp (`/v1/systemone`), apenas
///    noul/choice/score; a ponte nativa é opcional e reporta
///    [D1Unavailable] quando a build não a expõe.
library;

import '../domain/d1_decision_types.dart';
import '../domain/llm_config.dart';

enum D1BackendKind { onnx, gguf }

/// Caminhos do bundle d1 instalado.
class D1ModelPaths {
  /// ONNX: `decoder_q4.onnx` / `decoder_q4f16.onnx`.
  final String? decoderPath;

  /// ONNX: sidecar `.onnx_data` (quando o grafo usa pesos externos).
  final String? decoderDataPath;

  /// ONNX: `vision_encoder_q8.onnx` / `vision_encoder_fp16.onnx`.
  final String? visionEncoderPath;

  /// ONNX: `audio_encoder.onnx` / `audio_encoder_fp16.onnx` (d1-Omni).
  final String? audioEncoderPath;

  /// `tokenizer.json`.
  final String tokenizerPath;

  /// `processor_config.json` (normalização de imagem/áudio).
  final String? processorConfigPath;

  /// Heads opcionais para spans/range/box (`d1_heads.json`).
  final String? headsPath;

  /// GGUF: pesos `d1-2B-Q4_K_M.gguf` / `d1-Omni-2B-Q8_0.gguf`.
  final String? weightsPath;

  /// GGUF: projetor `mmproj-d1-*.gguf`.
  final String? mmprojPath;

  const D1ModelPaths({
    this.decoderPath,
    this.decoderDataPath,
    this.visionEncoderPath,
    this.audioEncoderPath,
    required this.tokenizerPath,
    this.processorConfigPath,
    this.headsPath,
    this.weightsPath,
    this.mmprojPath,
  });

  bool get isOnnx => decoderPath != null;
  bool get isGguf => weightsPath != null;
}

/// Capacidades efectivas do backend carregado.
abstract class D1Engine {
  bool get isLoaded;
  String get modelId;
  D1BackendKind get backend;
  D1Capabilities get capabilities;
  String? get loadError;

  Future<void> load({
    required D1ModelPaths paths,
    required D1Config config,
  });

  Future<D1Response> decide(D1Request request);

  Future<void> unload();
}

/// O bundle não tem os heads necessários para uma primitiva.
class D1UnsupportedPrimitive implements Exception {
  final D1QuestionType type;
  final String message;
  const D1UnsupportedPrimitive(this.type, this.message);

  @override
  String toString() => 'D1UnsupportedPrimitive(${type.wire}): $message';
}

/// O backend não está disponível nesta build/bundle.
class D1Unavailable implements Exception {
  final String message;
  const D1Unavailable(this.message);

  @override
  String toString() => 'D1Unavailable: $message';
}

/// Via GGUF opcional: delega no motor llama.cpp com `/v1/systemone`.
///
/// A build móvel atual não expõe a API C de SystemOne; esta classe mantém o
/// contrato e devolve [D1Unavailable] com uma mensagem accionável em vez de
/// fingir uma decisão. O caminho principal para todas as primitivas é o ONNX.
class D1GgufEngine implements D1Engine {
  final Future<D1Response> Function(D1Request request)? systemOne;

  D1GgufEngine({this.systemOne});

  bool _loaded = false;
  String _modelId = '';
  String? _loadError;

  @override
  bool get isLoaded => _loaded;

  @override
  String get modelId => _modelId;

  @override
  D1BackendKind get backend => D1BackendKind.gguf;

  @override
  D1Capabilities get capabilities => D1Capabilities.ggufBasic;

  @override
  String? get loadError => _loadError;

  @override
  Future<void> load({
    required D1ModelPaths paths,
    required D1Config config,
  }) async {
    final w = paths.weightsPath;
    if (w == null) {
      _loadError = 'd1 GGUF: weightsPath em falta';
      _loaded = false;
      return;
    }
    _modelId = w.split(RegExp(r'[/\\]')).last;
    _loaded = true;
    _loadError = null;
  }

  @override
  Future<D1Response> decide(D1Request request) async {
    if (!_loaded) {
      throw D1Unavailable(_loadError ?? 'd1 GGUF não carregado');
    }
    final fn = systemOne;
    if (fn == null) {
      throw const D1Unavailable(
        'a build llama.cpp não expõe /v1/systemone; usa o bundle ONNX '
        '(d1-2B-ONNX / d1-Omni-2B-ONNX) para todas as primitivas',
      );
    }
    final unsupported =
        request.questions.where((q) => !q.type.supportedByGguf).toList();
    if (unsupported.isNotEmpty) {
      throw D1UnsupportedPrimitive(
        unsupported.first.type,
        'a via GGUF do llama.cpp só suporta noul, choice e score',
      );
    }
    return fn(request);
  }

  @override
  Future<void> unload() async {
    _loaded = false;
    _modelId = '';
  }
}
