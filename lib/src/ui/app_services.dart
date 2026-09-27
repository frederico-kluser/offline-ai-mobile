/// Injeção simples de dependências da UI (singleton leve).
///
/// Os motores concretos (`LlamaFfiEngine`, `LayaOnnxEngine`) são injetados via
/// factories: enquanto os ficheiros `llm_engine_llama.dart` /
/// `laya_engine_onnx.dart` não existirem, as factories lançam
/// [UnimplementedError] com mensagem clara e a UI mostra SnackBar/banner em vez
/// de rebentar.
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../agent/tool_loop.dart';
import '../agent/tools.dart';
import '../engines/laya_engine.dart';
import '../engines/llm_engine.dart';
import '../services/download_manager.dart';
import '../services/model_registry.dart';
import '../domain/llm_config.dart';
import '../domain/laya_types.dart';

class AppServices {
  AppServices._();

  static final AppServices instance = AppServices._();

  /// Motores (injetáveis; por omissão ficam nulos até haver implementação).
  LlmEngine? llm;
  LayaEngine? laya;

  /// Gestor de downloads dos artefactos do catálogo.
  late final DownloadManager downloads = DownloadManager();

  /// Factories opcionais de motores (ligadas quando os ficheiros existem).
  LlmEngine Function()? llmFactory;
  LayaEngine Function()? layaFactory;

  /// Factory opcional do [ToolLoop] (para testes/injeção).
  ToolLoop Function({required LlmEngine llm, required List<LocalTool> tools})?
      toolLoopFactory;

  /// "Memória" das notas do demo de tool calling.
  final Map<String, String> noteStore = <String, String>{};

  /// Perguntas tipadas atualmente em edição no separador Laya (partilhadas
  /// com o modo Laya do separador Prompts).
  List<TypedQuestion> layaQuestions = const [];

  // ------------------------------------------------------------ instalação

  /// Mapa artifactId → caminho do ficheiro principal, dos artefactos
  /// totalmente instalados em [destDir].
  Map<String, String> installed = const {};

  /// Pasta de destino usada na última chamada a [refreshInstalled].
  String? destDirPath;

  /// Pasta de destino dos modelos (documents dir). `null` se indisponível
  /// (ex.: em testes sem plugins).
  static Future<String?> resolveModelsDir() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      return dir.path;
    } catch (_) {
      return null;
    }
  }

  /// Atualiza [installed] se a pasta de destino for resolvível.
  /// Devolve `false` quando a pasta não está disponível.
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

  /// Artefacto GGUF do LLM ativo (o primeiro instalado por ordem de catálogo).
  ModelArtifact? get activeLlmArtifact {
    for (final a in kModelCatalog) {
      if (a.kind == 'llm-gguf' && installed.containsKey(a.id)) return a;
    }
    return null;
  }

  String? get llmModelPath {
    final a = activeLlmArtifact;
    return a == null ? null : installed[a.id];
  }

  /// Kit ONNX do Laya (se existir no catálogo).
  ModelArtifact? get layaArtifact {
    for (final a in kModelCatalog) {
      if (a.kind == 'laya-onnx-kit') return a;
    }
    return null;
  }

  String? get layaModelPath {
    final a = layaArtifact;
    return a == null ? null : installed[a.id];
  }

  /// Caminho do tokenizer WordPiece do kit Laya (ficheiro irmão do ONNX).
  String? get layaTokenizerPath {
    final main = layaModelPath;
    final a = layaArtifact;
    if (main == null || a == null) return null;
    final dir = File(main).parent.path;
    String? candidate;
    for (final f in a.files) {
      final name = f.filename.toLowerCase();
      if (name.contains('tokenizer') && !name.contains('config')) {
        candidate = f.filename;
        break;
      }
    }
    return '$dir/${candidate ?? 'tokenizer.json'}';
  }

  // ---------------------------------------------------------------- motores

  /// Devolve o motor LLM pronto a gerar (carrega o modelo se preciso).
  /// Lança [UnimplementedError] quando não há implementação ligada.
  Future<LlmEngine> ensureLlm({
    required String modelPath,
    required LlmConfig config,
  }) async {
    final engine = llm ??= _newLlm();
    if (!engine.isLoaded || _llmLoadedPath != modelPath) {
      if (engine.isLoaded) await engine.unload();
      await engine.load(modelPath: modelPath, config: config);
      _llmLoadedPath = modelPath;
    }
    return engine;
  }

  /// Devolve o motor Laya pronto a decidir.
  Future<LayaEngine> ensureLaya({
    required String modelPath,
    required String tokenizerPath,
    required LayaConfig config,
  }) async {
    final engine = laya ??= _newLaya();
    if (!engine.isLoaded || _layaLoadedPath != modelPath) {
      if (engine.isLoaded) await engine.unload();
      await engine.load(
          modelPath: modelPath, tokenizerPath: tokenizerPath, config: config);
      _layaLoadedPath = modelPath;
    }
    return engine;
  }

  /// Constrói o loop de agente; `null` quando não há [ToolLoop] disponível.
  ToolLoop? makeToolLoop({
    required LlmEngine llm,
    required List<LocalTool> tools,
  }) {
    final factory = toolLoopFactory;
    if (factory != null) return factory(llm: llm, tools: tools);
    return ToolLoop(llm: llm, tools: tools);
  }

  String? _llmLoadedPath;
  String? _layaLoadedPath;

  LlmEngine _newLlm() {
    final factory = llmFactory;
    if (factory == null) {
      throw UnimplementedError(
          'Motor LLM indisponível: `LlamaFfiEngine` (llm_engine_llama.dart) '
          'ainda não está ligado a esta build.');
    }
    return factory();
  }

  LayaEngine _newLaya() {
    final factory = layaFactory;
    if (factory == null) {
      throw UnimplementedError(
          'Motor Laya indisponível: `LayaOnnxEngine` (laya_engine_onnx.dart) '
          'ainda não está ligado a esta build.');
    }
    return factory();
  }
}