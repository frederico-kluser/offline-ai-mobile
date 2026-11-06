/// Injeção simples de dependências da UI (singleton leve).
///
/// Motores concretos: [LlamaLfm3FfiEngine] (llama.cpp + libmtmd) e
/// [D1OnnxEngine] (ONNX Runtime). As factories são injetáveis para testes.
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../agent/tool_loop.dart';
import '../agent/tools.dart';
import '../domain/d1_decision_types.dart';
import '../domain/llm_config.dart';
import '../engines/d1_engine.dart';
import '../engines/d1_onnx_engine.dart';
import '../engines/llama_lfm3_ffi_engine.dart';
import '../engines/llm_engine.dart';
import '../services/device_capability_service.dart';
import '../services/download_manager.dart';
import '../services/model_registry.dart';

class AppServices {
  AppServices._();

  static final AppServices instance = AppServices._();

  /// Motores (injetáveis; por omissão ficam nulos até haver implementação).
  LlmEngine? llm;
  D1Engine? d1;

  /// Gestor de downloads dos bundles do catálogo.
  late final DownloadManager downloads = DownloadManager();

  /// Factories dos motores concretos (injetáveis para testes).
  LlmEngine Function()? llmFactory = LlamaLfm3FfiEngine.new;
  D1Engine Function()? d1Factory = D1OnnxEngine.new;

  /// Factory opcional do [ToolLoop] (para testes/injeção).
  ToolLoop Function({
    required LlmEngine llm,
    required ToolCatalog catalog,
  })? toolLoopFactory;

  /// "Memória" das notas do demo de tool calling.
  final Map<String, String> noteStore = <String, String>{};

  /// Perguntas tipadas atualmente em edição no separador d1.
  List<D1Question> d1Questions = const [];

  /// Último relatório de hardware (para a UI e para a matriz de modelos).
  HardwareProfileReport? hardware;

  // ------------------------------------------------------------ instalação

  /// Mapa bundleId → caminho do ficheiro principal, dos bundles instalados.
  Map<String, String> installed = const {};

  /// Pasta de destino usada na última chamada a [refreshInstalled].
  String? destDirPath;

  static Future<String?> resolveModelsDir() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      return dir.path;
    } catch (_) {
      return null;
    }
  }

  Future<bool> ensureInstalledKnown() async {
    final dir = await resolveModelsDir();
    if (dir == null) return false;
    await refreshInstalled(dir);
    return true;
  }

  Future<Map<String, String>> refreshInstalled(String destDir) async {
    destDirPath = destDir;
    installed = await downloads.installedPaths(destDir);
    return installed;
  }

  bool isInstalled(String bundleId) => installed.containsKey(bundleId);

  String? mainPath(ModelBundle bundle) => installed[bundle.id];

  /// Caminho de um ficheiro do bundle (instalado ou planeado).
  String? filePath(ModelBundle bundle, String filename) {
    final main = installed[bundle.id];
    if (main == null) return null;
    final dir = File(main).parent.path;
    return '$dir/$filename';
  }

  ModelBundle? bundleForMainPath(String path) {
    for (final b in kModelCatalog) {
      final main = installed[b.id];
      if (main == path) return b;
    }
    return null;
  }

  /// Bundle gerador ativo para texto (1.7B preferido).
  ModelBundle? get activeTextBundle {
    for (final id in const [
      'lfm3-1.7b-q4_0',
      'lfm3-1.7b-q4_k_m',
      'lfm3-1.7b-q8_0',
    ]) {
      final b = modelById(id);
      if (b != null && isInstalled(b.id)) return b;
    }
    for (final b in kGeneratorBundles) {
      if (isInstalled(b.id)) return b;
    }
    return null;
  }

  /// Compatibilidade: caminho do modelo de texto ativo.
  String? get llmModelPath {
    final b = activeTextBundle;
    return b == null ? null : mainPath(b);
  }

  /// Bundle d1 ativo (ONNX primeiro, depois GGUF).
  ModelBundle? get activeD1Bundle {
    for (final id in const [
      'd1-2b-onnx-q4f16',
      'd1-omni-2b-onnx-q4f16',
      'd1-2b-q4_k_m',
      'd1-omni-2b-q8_0',
      'd1-omni-600m-legacy-q8_0',
    ]) {
      final b = modelById(id);
      if (b != null && isInstalled(b.id)) return b;
    }
    return null;
  }

  String? get d1ModelPath {
    final b = activeD1Bundle;
    return b == null ? null : mainPath(b);
  }

  /// Escolhe o modelo gerador adequado aos anexos e ao que está instalado.
  ModelBundle? generatorFor({
    required bool hasImage,
    required bool hasVideo,
    required bool hasAudio,
  }) {
    ModelBundle? pick(bool Function(ModelBundle) test) {
      for (final b in kGeneratorBundles) {
        if (isInstalled(b.id) && test(b)) return b;
      }
      return null;
    }

    if (hasAudio) {
      return pick((b) => b.supportsAudio && b.supportsVision) ??
          pick((b) => b.supportsAudio) ??
          activeTextBundle;
    }
    if (hasVideo) {
      return pick((b) => b.supportsVideo && b.supportsVision) ??
          pick((b) => b.supportsVision) ??
          activeTextBundle;
    }
    if (hasImage) {
      return pick((b) => b.supportsVision) ?? activeTextBundle;
    }
    return activeTextBundle ?? pick((b) => b.supportsTools);
  }

  /// Tipo de modelo a passar ao motor.
  Lfm3ModelKind kindOf(ModelBundle b) {
    if (b.supportsAudio && b.supportsVision) return Lfm3ModelKind.omni;
    if (b.supportsAudio) return Lfm3ModelKind.audio;
    if (b.supportsVision) return Lfm3ModelKind.vision;
    return Lfm3ModelKind.text;
  }

  // ---------------------------------------------------------------- motores

  /// Devolve o motor LLM pronto a gerar (carrega o bundle se preciso).
  Future<LlmEngine> ensureLlm({
    required ModelBundle bundle,
    required LlmConfig config,
  }) async {
    final main = mainPath(bundle);
    if (main == null) {
      throw StateError('bundle ${bundle.id} não instalado');
    }
    final mmproj = bundle.mmprojFilename == null
        ? null
        : filePath(bundle, bundle.mmprojFilename!);
    final engine = llm ??= _newLlm();
    if (!engine.isLoaded ||
        _llmLoadedPath != main ||
        _llmLoadedMmproj != mmproj) {
      if (engine.isLoaded) await engine.unload();
      await engine.load(
        modelPath: main,
        mmprojPath: mmproj,
        config: config,
        kind: kindOf(bundle),
      );
      _llmLoadedPath = main;
      _llmLoadedMmproj = mmproj;
      _llmLoadedBundleId = bundle.id;
    }
    return engine;
  }

  /// Devolve o motor d1 pronto a decidir.
  Future<D1Engine> ensureD1({
    required ModelBundle bundle,
    required D1Config config,
  }) async {
    final main = mainPath(bundle);
    if (main == null) {
      throw StateError('bundle ${bundle.id} não instalado');
    }
    final wantOnnx = bundle.isOnnx;
    if (d1 != null && _d1LoadedBundleId != bundle.id) {
      await d1!.unload();
      d1 = null;
    }
    final engine = d1 ??= _newD1(wantOnnx: wantOnnx);
    if (!engine.isLoaded || _d1LoadedPath != main) {
      if (engine.isLoaded) await engine.unload();
      await engine.load(paths: d1Paths(bundle), config: config);
      _d1LoadedPath = main;
      _d1LoadedBundleId = bundle.id;
    }
    return engine;
  }

  D1ModelPaths d1Paths(ModelBundle bundle) {
    final dir = mainPath(bundle) == null
        ? null
        : File(mainPath(bundle)!).parent.path;
    if (dir == null) throw StateError('bundle ${bundle.id} não instalado');
    if (bundle.isOnnx) {
      String? maybe(String? name) =>
          name == null ? null : '$dir/$name';
      return D1ModelPaths(
        decoderPath: '$dir/${bundle.mainFilename}',
        visionEncoderPath: maybe(bundle.visionEncoderFilename),
        audioEncoderPath: maybe(bundle.audioEncoderFilename),
        tokenizerPath: '$dir/${bundle.tokenizerFilename ?? 'tokenizer.json'}',
        processorConfigPath: maybe(bundle.processorConfigFilename),
      );
    }
    return D1ModelPaths(
      tokenizerPath: '$dir/tokenizer.json',
      weightsPath: '$dir/${bundle.mainFilename}',
      mmprojPath: bundle.mmprojFilename == null
          ? null
          : '$dir/${bundle.mmprojFilename}',
    );
  }

  /// Constrói o loop de agente; `null` quando não há implementação.
  ToolLoop? makeToolLoop({
    required LlmEngine llm,
    required ToolCatalog catalog,
  }) {
    final factory = toolLoopFactory;
    if (factory != null) return factory(llm: llm, catalog: catalog);
    return ToolLoop(llm: llm, catalog: catalog);
  }

  /// Reset de motores (testes/limpeza de RAM).
  Future<void> unloadAll() async {
    await llm?.unload();
    await d1?.unload();
    llm = null;
    d1 = null;
    _llmLoadedPath = null;
    _llmLoadedMmproj = null;
    _llmLoadedBundleId = null;
    _d1LoadedPath = null;
    _d1LoadedBundleId = null;
  }

  /// Bundle gerador atualmente carregado (auditoria/UI).
  String? get loadedGeneratorBundleId => _llmLoadedBundleId;

  String? _llmLoadedPath;
  String? _llmLoadedMmproj;
  String? _llmLoadedBundleId;
  String? _d1LoadedPath;
  String? _d1LoadedBundleId;

  LlmEngine _newLlm() {
    final factory = llmFactory;
    if (factory == null) {
      throw UnimplementedError(
        'Motor LFM3 indisponível: LlamaLfm3FfiEngine ainda não está ligado.',
      );
    }
    return factory();
  }

  D1Engine _newD1({required bool wantOnnx}) {
    if (!wantOnnx) {
      return D1GgufEngine();
    }
    final factory = d1Factory;
    if (factory == null) {
      throw UnimplementedError(
        'Motor d1 ONNX indisponível: D1OnnxEngine ainda não está ligado.',
      );
    }
    return factory();
  }
}
