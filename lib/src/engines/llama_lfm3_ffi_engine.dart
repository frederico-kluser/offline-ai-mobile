/// Motor de inferência da família Liquid LFM3 sobre llama.cpp via `dart:ffi`.
///
/// Arquitetura:
///  - TODO o código nativo (llama.cpp) corre num ISOLATE próprio
///    ([_workerMain]) — nunca na UI thread;
///  - as `.so` (libllama.so + libggml*.so) entram pela APK via
///    `android/app/src/main/jniLibs/<abi>/`; no iOS os símbolos vêm do
///    `llama.xcframework` ligado ao binário;
///  - structs por valor (`llama_model_params`, `llama_context_params`,
///    `llama_batch`, `llama_sampler_chain_params`) seguem o layout do
///    llama.cpp **b12088** (o `llama_context_params` inclui
///    `moe_cache_size`; ver `tools/llama_ffi.md`);
///  - o prompt é renderizado com o ChatML do LFM3
///    ([renderChat] em `lib/src/agent/lfm3_chat.dart`);
///  - a cadeia de samplers segue EXATAMENTE [LlmConfig.samplersOrder],
///    terminando em `dist(seed)` ou `greedy` (temperature 0);
///  - o raciocínio `<think>` é separado em [GenDelta.thinking] e limitado por
///    [LlmConfig.maxThinkingTokens];
///  - a mídia (imagem/vídeo/áudio) é tratada pelo módulo mtmd
///    (`mtmd_multimodal_ffi_engine.dart`); esta classe aceita o caminho do
///    projetor, mas o pipeline de mídia é ligado nesse módulo.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import '../agent/lfm3_chat.dart' as lfm3;
import '../domain/llm_config.dart';
import '../domain/media_attachment.dart';
import '../services/media_preprocessor.dart';
import 'llm_engine.dart';
import 'mtmd_bindings.dart';

// =============================================================================
// Alocação nativa (libc) — substituto mínimo do `package:ffi`.
// =============================================================================

DynamicLibrary _openLibc() {
  // Android: bionic exporta-se como 'libc.so'; hosts glibc: 'libc.so.6'.
  for (final name in const ['libc.so', 'libc.so.6']) {
    try {
      return DynamicLibrary.open(name);
    } catch (_) {/* tenta o seguinte */}
  }
  return DynamicLibrary.process();
}


/// Abre a biblioteca do llama.cpp conforme a plataforma:
/// Android = ficheiro partilhado nas jniLibs; iOS/macOS = simbolos estaticos
/// no binario principal (XCFramework ligado via CocoaPods).
DynamicLibrary _openLlamaLibrary() {
  if (Platform.isIOS || Platform.isMacOS) {
    return DynamicLibrary.process();
  }
  return DynamicLibrary.open(LlamaLfm3FfiEngine.libName);
}

final DynamicLibrary _libc = _openLibc();
final Pointer<Void> Function(int, int) _calloc = _libc
    .lookupFunction<Pointer<Void> Function(IntPtr, IntPtr),
        Pointer<Void> Function(int, int)>('calloc');
final void Function(Pointer<Void>) _free = _libc.lookupFunction<
    Void Function(Pointer<Void>),
    void Function(Pointer<Void>)>('free');

Pointer<T> _alloc<T extends NativeType>(int bytes) =>
    _calloc(1, math.max(1, bytes)).cast<T>();

void _release(Pointer<NativeType> p) => _free(p.cast());

Pointer<Uint8> _utf8z(String s) {
  final units = utf8.encode(s);
  final p = _alloc<Uint8>(units.length + 1);
  p.asTypedList(units.length).setAll(0, units);
  return p;
}

// =============================================================================
// Structs espelhadas de include/llama.h (llama.cpp b11217).
// Ordem e tipos seguem o header; o `dart:ffi` calcula padding como o C.
// =============================================================================

/// `struct llama_model_params`.
final class _ModelParams extends Struct {
  external Pointer<Void> devices;
  external Pointer<Void> tensorBuftOverrides;
  @Int32()
  external int nGpuLayers;
  @Int32()
  external int splitMode;
  @Int32()
  external int loadMode;
  @Int32()
  external int lazyMode;
  @Int32()
  external int mainGpu;
  external Pointer<Float> tensorSplit;
  external Pointer<Void> progressCallback;
  external Pointer<Void> progressCallbackUserData;
  external Pointer<Void> kvOverrides;
  @Bool()
  external bool vocabOnly;
  @Bool()
  external bool checkTensors;
  @Bool()
  external bool useExtraBufts;
  @Bool()
  external bool noHost;
  @Bool()
  external bool noAlloc;
  @Bool()
  external bool loadMtp;
}

/// `struct llama_context_params`.
final class _ContextParams extends Struct {
  @Uint32()
  external int nCtx;
  @Uint32()
  external int nBatch;
  @Uint32()
  external int nUbatch;
  @Uint32()
  external int nSeqMax;
  @Uint32()
  external int nRsSeq;
  @Uint32()
  external int nOutputsMax;
  @Uint32()
  external int nOutputsMaxPerSeq;
  @Int32()
  external int nThreads;
  @Int32()
  external int nThreadsBatch;
  @Int32()
  external int ctxType;
  @Int32()
  external int ropeScalingType;
  @Int32()
  external int poolingType;
  @Int32()
  external int attentionType;
  @Int32()
  external int flashAttnType;
  @Float()
  external double ropeFreqBase;
  @Float()
  external double ropeFreqScale;
  @Float()
  external double yarnExtFactor;
  @Float()
  external double yarnAttnFactor;
  @Float()
  external double yarnBetaFast;
  @Float()
  external double yarnBetaSlow;
  @Uint32()
  external int yarnOrigCtx;
  @Float()
  external double defragThold;
  external Pointer<Void> cbEval;
  external Pointer<Void> cbEvalUserData;
  @Int32()
  external int typeK;
  @Int32()
  external int typeV;
  @Uint64()
  external int moeCacheSize; // size_t (b12088)
  external Pointer<Void> abortCallback;
  external Pointer<Void> abortCallbackData;
  @Bool()
  external bool embeddings;
  @Bool()
  external bool offloadKqv;
  @Bool()
  external bool noPerf;
  @Bool()
  external bool opOffload;
  @Bool()
  external bool swaFull;
  @Bool()
  external bool kvUnified;
  external Pointer<Void> samplers;
  @Uint64()
  external int nSamplers;
  external Pointer<Void> ctxOther;
}

/// `struct llama_batch`.
final class _Batch extends Struct {
  @Int32()
  external int nTokens;
  external Pointer<Int32> token;
  external Pointer<Float> embd;
  external Pointer<Int32> pos;
  external Pointer<Int32> nSeqId;
  external Pointer<Pointer<Int32>> seqId;
  external Pointer<Int8> logits;
}

/// `struct llama_sampler_chain_params`.
final class _SamplerChainParams extends Struct {
  @Bool()
  external bool noPerf;
}

// =============================================================================
// Bindings C (subconjunto necessário de llama.h).
// =============================================================================

class _Llama {
  _Llama(DynamicLibrary lib)
      : backendInit = lib.lookupFunction<Void Function(), void Function()>(
            'llama_backend_init'),
        modelDefaultParams = lib.lookupFunction<_ModelParams Function(),
            _ModelParams Function()>('llama_model_default_params'),
        contextDefaultParams = lib.lookupFunction<_ContextParams Function(),
            _ContextParams Function()>('llama_context_default_params'),
        chainDefaultParams = lib.lookupFunction<_SamplerChainParams Function(),
            _SamplerChainParams Function()>(
            'llama_sampler_chain_default_params'),
        modelLoadFromFile = lib.lookupFunction<
            Pointer<Void> Function(Pointer<Uint8>, _ModelParams),
            Pointer<Void> Function(Pointer<Uint8>, _ModelParams)>(
            'llama_model_load_from_file'),
        modelFree = lib.lookupFunction<Void Function(Pointer<Void>),
            void Function(Pointer<Void>)>('llama_model_free'),
        initFromModel = lib.lookupFunction<
            Pointer<Void> Function(Pointer<Void>, _ContextParams),
            Pointer<Void> Function(Pointer<Void>, _ContextParams)>(
            'llama_init_from_model'),
        contextFree = lib.lookupFunction<Void Function(Pointer<Void>),
            void Function(Pointer<Void>)>('llama_free'),
        modelGetVocab = lib.lookupFunction<
            Pointer<Void> Function(Pointer<Void>),
            Pointer<Void> Function(Pointer<Void>)>('llama_model_get_vocab'),
        modelNEmbd = lib.lookupFunction<Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)>('llama_model_n_embd'),
        nCtx = lib.lookupFunction<Uint32 Function(Pointer<Void>),
            int Function(Pointer<Void>)>('llama_n_ctx'),
        setNThreads = lib.lookupFunction<
            Void Function(Pointer<Void>, Int32, Int32),
            void Function(Pointer<Void>, int, int)>('llama_set_n_threads'),
        getMemory = lib.lookupFunction<
            Pointer<Void> Function(Pointer<Void>),
            Pointer<Void> Function(Pointer<Void>)>('llama_get_memory'),
        memoryClear = lib.lookupFunction<
            Void Function(Pointer<Void>, Bool),
            void Function(Pointer<Void>, bool)>('llama_memory_clear'),
        memorySeqRm = lib.lookupFunction<
            Bool Function(Pointer<Void>, Int32, Int32, Int32),
            bool Function(Pointer<Void>, int, int, int)>('llama_memory_seq_rm'),
        tokenize = lib.lookupFunction<
            Int32 Function(Pointer<Void>, Pointer<Uint8>, Int32,
                Pointer<Int32>, Int32, Bool, Bool),
            int Function(Pointer<Void>, Pointer<Uint8>, int, Pointer<Int32>,
                int, bool, bool)>('llama_tokenize'),
        tokenToPiece = lib.lookupFunction<
            Int32 Function(
                Pointer<Void>, Int32, Pointer<Uint8>, Int32, Int32, Bool),
            int Function(
                Pointer<Void>, int, Pointer<Uint8>, int, int, bool)>(
            'llama_token_to_piece'),
        vocabNTokens = lib.lookupFunction<Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)>('llama_vocab_n_tokens'),
        vocabEos = lib.lookupFunction<Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)>('llama_vocab_eos'),
        vocabIsEog = lib.lookupFunction<
            Bool Function(Pointer<Void>, Int32),
            bool Function(Pointer<Void>, int)>('llama_vocab_is_eog'),
        batchInit = lib.lookupFunction<
            _Batch Function(Int32, Int32, Int32),
            _Batch Function(int, int, int)>('llama_batch_init'),
        batchFree = lib.lookupFunction<Void Function(_Batch),
            void Function(_Batch)>('llama_batch_free'),
        decode = lib.lookupFunction<
            Int32 Function(Pointer<Void>, _Batch),
            int Function(Pointer<Void>, _Batch)>('llama_decode'),
        getLogitsIth = lib.lookupFunction<
            Pointer<Float> Function(Pointer<Void>, Int32),
            Pointer<Float> Function(Pointer<Void>, int)>(
            'llama_get_logits_ith'),
        chainInit = lib.lookupFunction<
            Pointer<Void> Function(_SamplerChainParams),
            Pointer<Void> Function(_SamplerChainParams)>(
            'llama_sampler_chain_init'),
        chainAdd = lib.lookupFunction<
            Void Function(Pointer<Void>, Pointer<Void>),
            void Function(Pointer<Void>, Pointer<Void>)>(
            'llama_sampler_chain_add'),
        initPenalties = lib.lookupFunction<
            Pointer<Void> Function(Int32, Int32, Float, Float, Float),
            Pointer<Void> Function(int, int, double, double, double)>(
            'llama_sampler_init_penalties'),
        initTopK = lib.lookupFunction<
            Pointer<Void> Function(Int32),
            Pointer<Void> Function(int)>('llama_sampler_init_top_k'),
        initTopP = lib.lookupFunction<
            Pointer<Void> Function(Float, IntPtr),
            Pointer<Void> Function(double, int)>('llama_sampler_init_top_p'),
        initMinP = lib.lookupFunction<
            Pointer<Void> Function(Float, IntPtr),
            Pointer<Void> Function(double, int)>('llama_sampler_init_min_p'),
        initTemp = lib.lookupFunction<
            Pointer<Void> Function(Float),
            Pointer<Void> Function(double)>('llama_sampler_init_temp'),
        initDist = lib.lookupFunction<
            Pointer<Void> Function(Uint32),
            Pointer<Void> Function(int)>('llama_sampler_init_dist'),
        initGreedy = lib.lookupFunction<
            Pointer<Void> Function(),
            Pointer<Void> Function()>('llama_sampler_init_greedy'),
        sample = lib.lookupFunction<
            Int32 Function(Pointer<Void>, Pointer<Void>, Int32),
            int Function(Pointer<Void>, Pointer<Void>, int)>(
            'llama_sampler_sample'),
        accept = lib.lookupFunction<
            Void Function(Pointer<Void>, Int32),
            void Function(Pointer<Void>, int)>('llama_sampler_accept'),
        samplerFree = lib.lookupFunction<Void Function(Pointer<Void>),
            void Function(Pointer<Void>)>('llama_sampler_free') {
    // DRY: obrigatório na tag b11217, mas ligado defensivamente — se faltar,
    // o DRY é ignorado com aviso no GenEnd.error (contrato).
    initDry = _tryLookup(() => lib.lookupFunction<
            Pointer<Void> Function(Pointer<Void>, Float, Float, Int32, Int32,
                Pointer<Pointer<Uint8>>, IntPtr),
            Pointer<Void> Function(Pointer<Void>, double, double, int, int,
                Pointer<Pointer<Uint8>>, int)>('llama_sampler_init_dry'));
  }

  final void Function() backendInit;
  final _ModelParams Function() modelDefaultParams;
  final _ContextParams Function() contextDefaultParams;
  final _SamplerChainParams Function() chainDefaultParams;
  final Pointer<Void> Function(Pointer<Uint8>, _ModelParams) modelLoadFromFile;
  final void Function(Pointer<Void>) modelFree;
  final Pointer<Void> Function(Pointer<Void>, _ContextParams) initFromModel;
  final void Function(Pointer<Void>) contextFree;
  final Pointer<Void> Function(Pointer<Void>) modelGetVocab;
  final int Function(Pointer<Void>) modelNEmbd;
  final int Function(Pointer<Void>) nCtx;
  final void Function(Pointer<Void>, int, int) setNThreads;
  final Pointer<Void> Function(Pointer<Void>) getMemory;
  final void Function(Pointer<Void>, bool) memoryClear;
  final bool Function(Pointer<Void>, int, int, int) memorySeqRm;
  final int Function(Pointer<Void>, Pointer<Uint8>, int, Pointer<Int32>, int,
      bool, bool) tokenize;
  final int Function(Pointer<Void>, int, Pointer<Uint8>, int, int, bool)
      tokenToPiece;
  final int Function(Pointer<Void>) vocabNTokens;
  final int Function(Pointer<Void>) vocabEos;
  final bool Function(Pointer<Void>, int) vocabIsEog;
  final _Batch Function(int, int, int) batchInit;
  final void Function(_Batch) batchFree;
  final int Function(Pointer<Void>, _Batch) decode;
  final Pointer<Float> Function(Pointer<Void>, int) getLogitsIth;
  final Pointer<Void> Function(_SamplerChainParams) chainInit;
  final void Function(Pointer<Void>, Pointer<Void>) chainAdd;
  final Pointer<Void> Function(int, int, double, double, double) initPenalties;
  final Pointer<Void> Function(int) initTopK;
  final Pointer<Void> Function(double, int) initTopP;
  final Pointer<Void> Function(double, int) initMinP;
  final Pointer<Void> Function(double) initTemp;
  final Pointer<Void> Function(int) initDist;
  final Pointer<Void> Function() initGreedy;
  final int Function(Pointer<Void>, Pointer<Void>, int) sample;
  final void Function(Pointer<Void>, int) accept;
  final void Function(Pointer<Void>) samplerFree;

  /// Opcional: `llama_sampler_init_dry` (presente desde as releases com
  /// suporte a DRY). `null` ⇒ símbolo ausente.
  late final Pointer<Void> Function(Pointer<Void>, double, double, int, int,
      Pointer<Pointer<Uint8>>, int)? initDry;

  bool get hasDry => initDry != null;
}

T? _tryLookup<T extends Function>(T Function() lookup) {
  try {
    return lookup();
  } catch (_) {
    return null;
  }
}

// =============================================================================
// Isolate de trabalho — dono de TODO o estado nativo.
// =============================================================================

/// Entrada do isolate. Recebe um [SendPort] do isolate principal e devolve o
/// seu próprio port de comandos.
void _workerMain(SendPort mainPort) {
  final inbox = ReceivePort();
  mainPort.send({'ready': inbox.sendPort});
  final worker = _Worker();
  inbox.listen((raw) {
    final m = (raw as Map).cast<String, Object?>();
    switch (m['cmd']) {
      case 'load':
        worker.load(m);
      case 'generate':
        worker.generate(m);
      case 'count':
        worker.count(m);
      case 'unload':
        worker.unload(m);
      case 'abort':
        worker.abort(m);
    }
  });
}

class _Worker {
  _Llama? lib;
  Pointer<Void> model = nullptr;
  Pointer<Void> ctx = nullptr;
  Pointer<Void> vocab = nullptr;
  int nCtx = 0;
  int nVocab = 0;
  int nBatch = 2048;
  MtmdBindings? mtmd;
  Pointer<Void> mtmdCtx = nullptr;
  bool mtmdVision = false;
  bool mtmdAudio = false;
  String? loadedMmproj;

  /// Tokens da sequência atual no KV cache (para `cachePrompt`).
  List<int> cachedTokens = const [];

  bool busy = false;
  bool abortRequested = false;
  int currentGen = -1;

  static const List<String> drySeqBreakers = ['\n', ':', '"', '*'];

  // ---------------------------------------------------------------- load ---
  void load(Map<String, Object?> m) {
    final reply = m['reply'] as SendPort;
    final path = m['path'] as String;
    final mmprojPath = m['mmproj'] as String?;
    final cfg = LlmConfig.fromJson((m['config'] as Map).cast<String, dynamic>());
    final notes = <String>[];
    try {
      if (busy) {
        reply.send({'ok': false, 'error': 'ocupado: geração em curso'});
        return;
      }
      _unloadNative(); // nunca ter 2 modelos em memória
      lib ??= _Llama(_openLlamaLibrary());
      final b = lib!;
      b.backendInit();

      // Model params: defaults (mmap ON por defeito) + camadas de GPU.
      // Semantica C API: negativo = TODAS as camadas na GPU.
      //  - Apple REAL (Metal): usar tal-e-qual (-1 = offload completo; saída
      //    correta verificada no macOS nativo com este GGUF).
      //  - iOS SIMULATOR: Metal incompleto (Apple docs; llama.rn; ggml #19563)
      //    => mojibake obrigatório; cai para CPU automaticamente.
      //  - Android: negativo vira 0 (shaders Vulkan só Adreno; CPU estável).
      final mp = b.modelDefaultParams();
      // Deteção robusta de simulador iOS: (a) env var SIMULATOR_DEVICE_NAME
      // (nem sempre visível no harness de testes); (b) o simulador partilha o
      // FS do Mac — /Users existe; num iPhone real NÃO existe. Qualquer dos
      // sinais ativa o fallback CPU (Metal do simulador = mojibake).
      final onSimulator = Platform.isIOS &&
          (Platform.environment.containsKey('SIMULATOR_DEVICE_NAME') ||
              Directory('/Users').existsSync());
      final wantsAll = cfg.gpuLayers < 0;
      final useGpuLayers = (Platform.isAndroid || onSimulator)
          ? (wantsAll ? 0 : cfg.gpuLayers)
          : cfg.gpuLayers;
      mp.nGpuLayers = useGpuLayers;

      final pathPtr = _utf8z(path);
      model = b.modelLoadFromFile(pathPtr, mp);
      _release(pathPtr);
      if (model == nullptr) {
        reply.send({
          'ok': false,
          'error': 'llama_model_load_from_file devolveu NULL para $path',
        });
        return;
      }

      vocab = b.modelGetVocab(model);
      nVocab = b.vocabNTokens(vocab);

      // Context params: defaults + contexto/threads/batch do config.
      // Flash Attention: ENABLED quando há GPU Apple ativa (verificado no
      // macOS com saída correta); AUTO nos restantes (enum: -1/0/1).
      final cp = b.contextDefaultParams();
      nCtx = cfg.contextSize;
      cp.nCtx = nCtx;
      cp.nBatch = cfg.nBatch > 0 ? cfg.nBatch : math.min(nCtx, 2048);
      if (cp.nBatch > nCtx) cp.nBatch = nCtx;
      cp.nUbatch = cfg.nUbatch > 0 ? cfg.nUbatch : math.min(cp.nBatch, 512);
      if (cp.nUbatch > cp.nBatch) cp.nUbatch = cp.nBatch;
      nBatch = cp.nBatch;
      cp.nThreads = cfg.threads;
      cp.nThreadsBatch = cfg.threads;
      // KV cache: F16 (12,29 KB/token) ou Q8_0 (6,53 KB/token).
      cp.typeK = cfg.kvTypeK.ggmlType;
      cp.typeV = cfg.kvTypeV.ggmlType;
      cp.flashAttnType = cfg.flashAttn ? 1 : 0;
      cp.nSeqMax = 1;

      ctx = b.initFromModel(model, cp);
      if (ctx == nullptr) {
        b.modelFree(model);
        model = nullptr;
        reply.send({
          'ok': false,
          'error': 'llama_init_from_model devolveu NULL (contexto $nCtx)',
        });
        return;
      }
      final nCtxActual = b.nCtx(ctx);
      b.memoryClear(b.getMemory(ctx), true);
      cachedTokens = const [];
      loadedMmproj = mmprojPath;

      // ---- libmtmd: projetor multimodal (opcional) ----------------------
      if (mmprojPath != null && mmprojPath.isNotEmpty) {
        mtmd = MtmdBindings.tryOpen();
        if (mtmd == null) {
          notes.add('aviso: libmtmd indisponível; mídia desativada');
        } else {
          final params = mtmd!.contextDefaultParams();
          params.useGpu = useGpuLayers != 0;
          params.nThreads = cfg.threads;
          params.imageMaxTokens = cfg.imageMaxTokens;
          final marker = _utf8z(lfm3.Lfm3Markup.mediaMarker);
          params.mediaMarker = marker;
          final mmprojPtr = _utf8z(mmprojPath);
          mtmdCtx = mtmd!.initFromFile(mmprojPtr, model, params);
          _release(mmprojPtr);
          _release(marker);
          if (mtmdCtx == nullptr) {
            notes.add('aviso: mtmd_init_from_file devolveu NULL');
            mtmd = null;
          } else {
            mtmdVision = mtmd!.supportVision(mtmdCtx);
            mtmdAudio = mtmd!.supportAudio(mtmdCtx);
          }
        }
      }

      reply.send({
        'ok': true,
        'n_embd': b.modelNEmbd(model),
        'n_vocab': nVocab,
        'n_ctx': nCtxActual,
        'dry': b.hasDry,
        'mmproj': mmprojPath,
        'mmap': true,
        'mtmd': mtmdCtx != nullptr,
        'mtmd_vision': mtmdVision,
        'mtmd_audio': mtmdAudio,
        'notes': notes.join('; '),
      });
    } catch (e) {
      reply.send({'ok': false, 'error': '$e'});
    }
  }

  // ------------------------------------------------------------ count -----
  void count(Map<String, Object?> m) {
    final reply = m['reply'] as SendPort;
    final text = m['text'] as String;
    try {
      if (model == nullptr || ctx == nullptr) {
        reply.send({'ok': false, 'error': 'modelo não carregado'});
        return;
      }
      // Contagem fiel ao prompt: add_special + parse_special.
      final toks = _tokenize(text, addSpecial: true, parseSpecial: true);
      reply.send({'ok': true, 'n': toks.length});
    } catch (e) {
      reply.send({'ok': false, 'error': '$e'});
    }
  }

  // ---------------------------------------------------------- unload ------
  void unload(Map<String, Object?> m) {
    final reply = m['reply'] as SendPort;
    if (busy) {
      reply.send({'ok': false, 'error': 'ocupado: geração em curso'});
      return;
    }
    try {
      _unloadNative();
      reply.send({'ok': true});
    } catch (e) {
      reply.send({'ok': false, 'error': '$e'});
    }
  }

  void _unloadNative() {
    final b = lib;
    if (mtmdCtx != nullptr && mtmd != null) {
      mtmd!.free(mtmdCtx);
      mtmdCtx = nullptr;
    }
    mtmd = null;
    mtmdVision = false;
    mtmdAudio = false;
    loadedMmproj = null;
    if (b != null) {
      if (ctx != nullptr) {
        b.contextFree(ctx);
        ctx = nullptr;
      }
      if (model != nullptr) {
        b.modelFree(model);
        model = nullptr;
      }
    }
    vocab = nullptr;
    nCtx = 0;
    nVocab = 0;
    cachedTokens = const [];
    abortRequested = false;
    currentGen = -1;
  }

  // ---------------------------------------------------------- abort ------
  void abort(Map<String, Object?> m) {
    final id = m['id'] as int?;
    if (busy && (id == null || id == currentGen)) {
      abortRequested = true;
    }
  }

  // ------------------------------------------------------- generate -------
  Future<void> generate(Map<String, Object?> m) async {
    final events = m['events'] as SendPort;
    final id = m['id'] as int;
    if (busy || model == nullptr || ctx == nullptr) {
      events.send({
        'e': 'end',
        'pt': 0,
        'ot': 0,
        'ms': 0,
        'stop': 'error',
        'err': busy ? 'já existe uma geração em curso' : 'modelo não carregado',
      });
      return;
    }
    busy = true;
    currentGen = id;
    abortRequested = false;

    final b = lib!;
    final cfg =
        LlmConfig.fromJson((m['config'] as Map).cast<String, dynamic>());
    final prompt = m['prompt'] as String;
    final maxRequested = m['maxTokens'] as int? ?? cfg.maxTokens;
    // Teto EXPLÍCITO — nunca -1 nem infinito.
    final maxTokens = maxRequested < 1 ? 512 : maxRequested;

    final sw = Stopwatch()..start();
    var promptTokens = 0;
    var outputTokens = 0;
    var thinkingTokens = 0;
    var prefillMs = 0;
    var decodeMs = 0;
    var stop = 'error';
    String? error;
    final notes = <String>[];
    if (cfg.dryEnabled && !b.hasDry) {
      notes.add('aviso: llama_sampler_init_dry indisponível nesta build — '
          'DRY ignorado');
    }

    Pointer<Void> chain = nullptr;
    try {
      // ---- sampler chain pela ordem canónica (LlmConfig.samplersOrder) ----
      chain = _buildChain(cfg, notes);

      var total = 0;
      var sampleIdx = 0;
      final mediaList = (m['media'] as List?) ?? const [];

      if (mediaList.isNotEmpty) {
        // ---- caminho multimodal: libmtmd tokeniza + avalia os chunks ------
        if (mtmdCtx == nullptr || mtmd == null) {
          throw StateError(
              'mídia recebida mas o projetor libmtmd não está carregado');
        }
        b.memoryClear(b.getMemory(ctx), true);
        b.setNThreads(ctx, cfg.threads, cfg.threads);
        final bitmaps = <MtmdBitmap>[];
        MtmdInputChunks? chunks;
        final nPast = _alloc<Int32>(4);
        try {
          for (final raw in mediaList) {
            final map = (raw as Map).cast<String, Object?>();
            final kind = map['kind'] as String?;
            if (kind == 'image') {
              final img = (map['image'] as Map).cast<String, Object?>();
              final rgb = img['rgb']! as Uint8List;
              final ptr = _alloc<Uint8>(rgb.length);
              ptr.asTypedList(rgb.length).setAll(0, rgb);
              bitmaps.add(mtmd!.image(
                width: img['width']! as int,
                height: img['height']! as int,
                rgb: ptr,
              ));
            } else if (kind == 'audio') {
              final a = (map['audio'] as Map).cast<String, Object?>();
              final samples = a['samples']! as Float32List;
              final ptr = _alloc<Float>(samples.length * sizeOf<Float>());
              ptr.asTypedList(samples.length).setAll(0, samples);
              bitmaps.add(mtmd!.audio(
                samples: ptr,
                nSamples: samples.length,
              ));
            } else if (kind == 'video') {
              final v = (map['video'] as Map).cast<String, Object?>();
              for (final f in (v['frames'] as List? ?? const [])) {
                final frame = (f as Map).cast<String, Object?>();
                final rgb = frame['rgb']! as Uint8List;
                final ptr = _alloc<Uint8>(rgb.length);
                ptr.asTypedList(rgb.length).setAll(0, rgb);
                final bm = mtmd!.image(
                  width: frame['width']! as int,
                  height: frame['height']! as int,
                  rgb: ptr,
                );
                bm.setMergeable(true);
                bm.setIsVideo(true);
                bitmaps.add(bm);
              }
              final s = v['soundtrack'];
              if (s is Map) {
                final samples = s['samples']! as Float32List;
                final ptr = _alloc<Float>(samples.length * sizeOf<Float>());
                ptr.asTypedList(samples.length).setAll(0, samples);
                bitmaps.add(mtmd!.audio(samples: ptr, nSamples: samples.length));
              }
            }
          }

          chunks = mtmd!.tokenizeText(
            context: mtmdCtx,
            text: prompt,
            bitmaps: bitmaps,
            addSpecial: false,
            parseSpecial: true,
          );
          final rc = mtmd!.helperEval(
            mtmdCtx,
            ctx,
            chunks.ptr,
            0,
            0,
            nBatch,
            true,
            nPast,
          );
          if (rc != 0) {
            throw StateError('mtmd_helper_eval_chunks devolveu $rc');
          }
          total = nPast.value;
          promptTokens = total;
          sampleIdx = -1; // logits do último token avaliado
          if (total >= nCtx) {
            throw StateError('prompt multimodal ($total tokens) excede $nCtx');
          }
          cachedTokens = const [];
        } finally {
          _release(nPast);
          chunks?.dispose();
          for (final bm in bitmaps) {
            bm.dispose();
          }
        }
      } else {
        // ---- prompt → tokens (add_special + parse_special) ---------------
        final toks = _tokenize(prompt, addSpecial: true, parseSpecial: true);
        promptTokens = toks.length;
        if (promptTokens == 0) {
          throw StateError('prompt vazio após tokenização');
        }
        if (promptTokens >= nCtx) {
          throw StateError(
              'prompt tem $promptTokens tokens mas o contexto é $nCtx');
        }

        // ---- KV cache: clear, ou reutilização de prefixo (cachePrompt) ---
        var reuse = 0;
        if (cfg.cachePrompt && cachedTokens.isNotEmpty) {
          final limit = math.min(cachedTokens.length, toks.length);
          while (reuse < limit && cachedTokens[reuse] == toks[reuse]) {
            reuse++;
          }
          if (reuse > toks.length - 1) reuse = toks.length - 1;
          if (reuse > 0) {
            b.memorySeqRm(b.getMemory(ctx), 0, reuse, -1);
          } else {
            b.memoryClear(b.getMemory(ctx), true);
          }
        } else {
          b.memoryClear(b.getMemory(ctx), true);
        }

        // O sampler tem de conhecer TODO o prompt (penalties/DRY).
        for (final t in toks) {
          b.accept(chain, t);
        }
        b.setNThreads(ctx, cfg.threads, cfg.threads);

        total = toks.length;
        for (var i = reuse; i < total;) {
          final len = math.min(nBatch, total - i);
          final batch = b.batchInit(len, 0, 1);
          for (var j = 0; j < len; j++) {
            batch.token[j] = toks[i + j];
            batch.pos[j] = i + j;
            batch.nSeqId[j] = 1;
            batch.seqId[j][0] = 0;
            batch.logits[j] = (i + j == total - 1) ? 1 : 0;
          }
          batch.nTokens = len;
          final rc = b.decode(ctx, batch);
          b.batchFree(batch);
          if (rc != 0) {
            throw StateError('llama_decode(prompt) devolveu $rc '
                '(tokens $i..${i + len - 1})');
          }
          i += len;
          sampleIdx = len - 1;
          if (abortRequested) {
            stop = 'aborted';
            break;
          }
          if (i < total) {
            await Future<void>.delayed(Duration.zero);
            if (abortRequested) {
              stop = 'aborted';
              break;
            }
          }
        }
        cachedTokens = [...toks];
      }

      var budget = maxTokens;
      final room = nCtx - promptTokens;
      if (budget > room) budget = room;

      prefillMs = sw.elapsedMilliseconds;

      // ---- ciclo de geração ----------------------------------------------
      final endMarker = lfm3.Lfm3Markup.imEnd;
      var pending = '';
      var inThink = cfg.enableThinking;
      var hitEnd = false;
      final generated = <int>[];

      void emitChunk(String text, bool thinking) {
        if (text.isEmpty) return;
        events.send({'e': 'delta', 't': text, 'think': thinking});
      }

      bool drain({required bool flushAll}) {
        final buf = StringBuffer();
        var i = 0;
        while (i < pending.length) {
          if (pending.startsWith(endMarker, i)) {
            emitChunk(buf.toString(), inThink);
            buf.clear();
            pending = pending.substring(i + endMarker.length);
            hitEnd = true;
            stop = 'stop_string';
            return false;
          }
          if (pending.startsWith(lfm3.Lfm3Markup.thinkStart, i)) {
            emitChunk(buf.toString(), inThink);
            buf.clear();
            inThink = true;
            i += lfm3.Lfm3Markup.thinkStart.length;
            continue;
          }
          if (pending.startsWith(lfm3.Lfm3Markup.thinkEnd, i)) {
            emitChunk(buf.toString(), inThink);
            buf.clear();
            inThink = false;
            i += lfm3.Lfm3Markup.thinkEnd.length;
            continue;
          }
          if (!flushAll) {
            var hold = 0;
            for (var k = 1; k <= 12 && k <= pending.length - i; k++) {
              final suffix = pending.substring(pending.length - k);
              if (endMarker.startsWith(suffix) ||
                  lfm3.Lfm3Markup.thinkStart.startsWith(suffix) ||
                  lfm3.Lfm3Markup.thinkEnd.startsWith(suffix)) {
                hold = k;
              }
            }
            if (hold > 0 && i >= pending.length - hold) break;
          }
          buf.write(pending[i]);
          i++;
        }
        pending = pending.substring(i);
        emitChunk(buf.toString(), inThink);
        return true;
      }

      if (stop != 'aborted') {
        for (var step = 0; step < budget; step++) {
          final tok = b.sample(chain, ctx, sampleIdx);
          outputTokens++;
          generated.add(tok);

          if (b.vocabIsEog(vocab, tok) || tok == b.vocabEos(vocab)) {
            stop = 'eos';
            break;
          }

          pending += piece(tok);
          if (!drain(flushAll: false)) break;
          if (inThink) thinkingTokens++;
          if (cfg.maxThinkingTokens > 0 &&
              thinkingTokens >= cfg.maxThinkingTokens) {
            stop = 'thinking_budget';
            break;
          }

          if (step == budget - 1) {
            stop = 'max_tokens';
            break;
          }

          // Decode do token gerado para obter os logits seguintes.
          final batch = b.batchInit(1, 0, 1);
          batch.token[0] = tok;
          batch.pos[0] = total + step;
          batch.nSeqId[0] = 1;
          batch.seqId[0][0] = 0;
          batch.logits[0] = 1;
          batch.nTokens = 1;
          final rc = b.decode(ctx, batch);
          b.batchFree(batch);
          if (rc == 1) {
            stop = 'max_tokens'; // sem slot de KV — contexto cheio
            break;
          }
          if (rc != 0) {
            stop = 'error';
            error = 'llama_decode devolveu $rc a meio da geração';
            break;
          }
          sampleIdx = 0;

          await Future<void>.delayed(Duration.zero); // cede p/ abort
          if (abortRequested) {
            stop = 'aborted';
            break;
          }
        }
      }

      // Texto ainda retido por causa de um possível marcador partido.
      if (stop != 'aborted' && !hitEnd) {
        drain(flushAll: true);
      }
      decodeMs = sw.elapsedMilliseconds - prefillMs;

      // ---- bookkeeping do cache de prompt --------------------------------
      // Só o caminho de texto reutiliza o prefixo; mídia invalida o cache.
      if (mediaList.isEmpty) {
        cachedTokens = [...cachedTokens, ...generated];
      }
    } catch (e) {
      stop = 'error';
      error = '$e';
    } finally {
      if (chain != nullptr) {
        b.samplerFree(chain); // liberta também os samplers filhos
      }
      busy = false;
      currentGen = -1;
      final warn = notes.isEmpty ? null : notes.join('; ');
      events.send({
        'e': 'end',
        'pt': promptTokens,
        'ot': outputTokens,
        'tt': thinkingTokens,
        'pm': prefillMs,
        'dm': decodeMs,
        'ms': sw.elapsedMilliseconds,
        'stop': stop,
        'err': error == null
            ? warn
            : (warn == null ? error : '$error; $warn'),
      });
    }
  }

  /// Cadeia de samplers por [LlmConfig.samplersOrder], terminando em
  /// `dist(seed)` — determinística. Com `temperature <= 0` o terminal é
  /// `greedy`: o `dist` com logits a 0/inf após `temp(0)` não é definido, e
  /// greedy é a escolha determinística canónica para temperature 0.
  Pointer<Void> _buildChain(LlmConfig cfg, List<String> notes) {
    final b = lib!;
    final chain = b.chainInit(b.chainDefaultParams());
    void add(Pointer<Void> s) => b.chainAdd(chain, s);

    for (final name in LlmConfig.samplersOrder.split(';')) {
      switch (name) {
        case 'penalties':
          add(b.initPenalties(nVocab, cfg.repeatLastN, cfg.repeatPenalty,
              cfg.frequencyPenalty, cfg.presencePenalty));
        case 'dry':
          if (!cfg.dryEnabled) break;
          final dry = b.initDry;
          if (dry == null) {
            if (!notes.any((n) => n.contains('DRY ignorado'))) {
              notes.add('aviso: llama_sampler_init_dry indisponível nesta '
                  'build — DRY ignorado');
            }
            break;
          }
          final nBreak = drySeqBreakers.length;
          final breakers = _alloc<Pointer<Uint8>>(nBreak * sizeOf<Pointer<Uint8>>());
          for (var i = 0; i < drySeqBreakers.length; i++) {
            breakers[i] = _utf8z(drySeqBreakers[i]);
          }
          final s = dry(vocab, cfg.dryMultiplier, cfg.dryBase,
              cfg.dryAllowedLength, cfg.dryPenaltyLastN, breakers, nBreak);
          for (var i = 0; i < nBreak; i++) {
            _release(breakers[i]);
          }
          _release(breakers);
          add(s);
        case 'top_k':
          if (cfg.topK > 0) add(b.initTopK(cfg.topK)); // 0 = off
        case 'top_p':
          if (cfg.topP > 0 && cfg.topP < 1.0) add(b.initTopP(cfg.topP, 1));
        case 'min_p':
          if (cfg.minP > 0) add(b.initMinP(cfg.minP, 1)); // 0.0 = off
        case 'temperature':
          if (cfg.temperature > 0) add(b.initTemp(cfg.temperature));
      }
    }

    // Terminal determinístico.
    if (cfg.temperature > 0) {
      add(b.initDist(cfg.seed < 0 ? 0 : cfg.seed & 0xFFFFFFFF));
    } else {
      add(b.initGreedy());
    }
    return chain;
  }

  // -------------------------------------------------- tokenização ---------
  List<int> _tokenize(String text,
      {required bool addSpecial, required bool parseSpecial}) {
    final b = lib!;
    final bytes = utf8.encode(text);
    final textPtr = _alloc<Uint8>(bytes.length + 1);
    textPtr.asTypedList(bytes.length).setAll(0, bytes);
    var cap = bytes.length + 16;
    try {
      while (true) {
        final tokPtr = _alloc<Int32>(cap * sizeOf<Int32>());
        final n = b.tokenize(vocab, textPtr, bytes.length, tokPtr, cap,
            addSpecial, parseSpecial);
        if (n >= 0 && n <= cap) {
          final out = tokPtr.asTypedList(n).toList();
          _release(tokPtr);
          return out;
        }
        _release(tokPtr);
        if (n < 0) {
          cap = -n; // espaço necessário
        } else {
          cap = n + 16;
        }
        if (cap > 1 << 24) {
          throw StateError('tokenização excede 16M tokens');
        }
      }
    } finally {
      _release(textPtr);
    }
  }
}

extension on _Worker {
  /// `llama_token_to_piece` → texto UTF-8 (special renderizado).
  String piece(int token) {
    final b = lib!;
    var cap = 512;
    for (var attempt = 0; attempt < 8; attempt++) {
      final buf = _alloc<Uint8>(cap);
      final n = b.tokenToPiece(vocab, token, buf, cap, 0, true);
      if (n >= 0 && n <= cap) {
        final s = utf8.decode(buf.asTypedList(n), allowMalformed: true);
        _release(buf);
        return s;
      }
      _release(buf);
      cap = n < 0 ? -n + 1 : cap * 2;
      if (cap > 1 << 20) return '';
    }
    return '';
  }
}

// =============================================================================
// Lado do isolate principal — implementação do contrato [LlmEngine].
// =============================================================================

class _GenLink {
  _GenLink(this.id, this.port, this.ctrl);
  final int id;
  final ReceivePort port;
  final StreamController<GenEvent> ctrl;
  final Completer<void> done = Completer<void>();
}

/// [LlmEngine] sobre llama.cpp (família LFM3) — ver doc do ficheiro.
class LlamaLfm3FfiEngine implements LlmEngine {
  /// Nome da biblioteca partilhada (empacotada em
  /// `android/app/src/main/jniLibs/<abi>/`). Aberta por NOME DE FICHEIRO —
  /// obrigatório no Android, onde as libs são carregadas pelo linker.
  static const String libName = 'libllama.so';

  Isolate? _isolate;
  SendPort? _commands;
  ReceivePort? _inbox;
  Future<SendPort>? _ready;
  bool _loaded = false;
  String _modelPath = '';
  String? _mmprojPath;
  Lfm3ModelKind _kind = Lfm3ModelKind.text;
  Lfm3ModelInfo? _info;
  int _genCounter = 0;
  _GenLink? _active;

  @override
  bool get isLoaded => _loaded;

  @override
  Lfm3ModelKind get kind => _kind;

  @override
  Lfm3ModelInfo? get info => _info;

  /// Projetor multimodal carregado (se houver).
  String? get mmprojPath => _mmprojPath;

  @override
  String get modelId {
    if (_modelPath.isEmpty) return '';
    final i = _modelPath.lastIndexOf(RegExp(r'[/\\]'));
    return i < 0 ? _modelPath : _modelPath.substring(i + 1);
  }

  // ------------------------------------------------------- bootstrap ------
  Future<SendPort> _ensureWorker() {
    final ready = _ready;
    if (ready != null && _commands != null) return ready;
    final handshake = Completer<SendPort>();
    final inbox = ReceivePort();
    inbox.listen((raw) {
      final m = (raw as Map).cast<String, Object?>();
      if (m['ready'] is SendPort) {
        if (!handshake.isCompleted) {
          handshake.complete(m['ready'] as SendPort);
        }
        return;
      }
      _onWorkerMessage(m);
    });
    _inbox = inbox;
    final future = Isolate.spawn(_workerMain, inbox.sendPort).then((iso) {
      _isolate = iso;
      return handshake.future;
    }).then((port) {
      _commands = port;
      return port;
    });
    _ready = future;
    return future;
  }

  void _onWorkerMessage(Map<String, Object?> m) {
    final link = _active;
    if (link == null) return;
    switch (m['e']) {
      case 'delta':
        if (!link.ctrl.isClosed) {
          link.ctrl.add(GenDelta(
            m['t'] as String,
            thinking: m['think'] as bool? ?? false,
          ));
        }
      case 'end':
        if (!link.ctrl.isClosed) {
          link.ctrl.add(GenEnd(
            promptTokens: m['pt'] as int,
            outputTokens: m['ot'] as int,
            latencyMs: m['ms'] as int,
            stopReason: m['stop'] as String,
            error: m['err'] as String?,
            thinkingTokens: m['tt'] as int? ?? 0,
            prefillMs: m['pm'] as int? ?? 0,
            decodeMs: m['dm'] as int? ?? 0,
          ));
        }
        _finish(link);
    }
  }

  void _finish(_GenLink link) {
    if (identical(_active, link)) _active = null;
    link.port.close();
    if (!link.done.isCompleted) link.done.complete();
    if (!link.ctrl.isClosed) link.ctrl.close();
  }

  Future<Map<String, Object?>> _request(Map<String, Object?> cmd) async {
    final port = await _ensureWorker();
    final reply = ReceivePort();
    try {
      port.send({...cmd, 'reply': reply.sendPort});
      final raw = await reply.first;
      return (raw as Map).cast<String, Object?>();
    } finally {
      reply.close();
    }
  }

  // ------------------------------------------------------------- load -----
  @override
  Future<void> load({
    required String modelPath,
    required LlmConfig config,
    String? mmprojPath,
    Lfm3ModelKind kind = Lfm3ModelKind.text,
  }) async {
    await unload(); // nunca manter 2 modelos em memória
    final resp = await _request({
      'cmd': 'load',
      'path': modelPath,
      'mmproj': mmprojPath,
      'config': config.toJson(),
    });
    if (resp['ok'] != true) {
      throw StateError('llama: falha ao carregar $modelPath — '
          '${resp['error']}');
    }
    _loaded = true;
    _modelPath = modelPath;
    _mmprojPath = mmprojPath;
    _kind = kind;
    _info = Lfm3ModelInfo(
      modelId: modelId,
      kind: kind,
      nCtx: resp['n_ctx'] as int? ?? config.contextSize,
      nEmbd: resp['n_embd'] as int? ?? 0,
      nVocab: resp['n_vocab'] as int? ?? 0,
      multimodal: mmprojPath != null,
      mmap: resp['mmap'] as bool? ?? true,
      mmprojPath: mmprojPath,
    );
  }

  // --------------------------------------------------------- generate -----
  @override
  Stream<GenEvent> generate({
    required List<ChatMessage> messages,
    required LlmConfig config,
    List<LlmMediaInput> media = const [],
    int? maxTokensOverride,
    String? systemPromptOverride,
  }) {
    final ctrl = StreamController<GenEvent>();
    () async {
      if (!_loaded) {
        ctrl.add(const GenEnd(
          promptTokens: 0,
          outputTokens: 0,
          latencyMs: 0,
          stopReason: 'error',
          error: 'modelo não carregado (chame load() primeiro)',
        ));
        await ctrl.close();
        return;
      }
      if (_active != null) {
        ctrl.add(const GenEnd(
          promptTokens: 0,
          outputTokens: 0,
          latencyMs: 0,
          stopReason: 'error',
          error: 'já existe uma geração em curso',
        ));
        await ctrl.close();
        return;
      }
      // ---- preparação de mídia (isolate principal, dart:ui) --------------
      final preparedMedia = <Map<String, Object?>>[];
      var markerCount = 0;
      try {
        const preprocessor = MediaPreprocessor();
        for (final m in media) {
          final p = await preprocessor.prepare(m);
          preparedMedia.add(p.toMap());
          switch (p.kind) {
            case MediaKind.image:
            case MediaKind.audio:
              markerCount++;
            case MediaKind.video:
              markerCount += (p.video?.frames.length ?? 0) +
                  (p.video?.soundtrack != null ? 1 : 0);
          }
        }
      } catch (e) {
        ctrl.add(GenEnd(
          promptTokens: 0,
          outputTokens: 0,
          latencyMs: 0,
          stopReason: 'error',
          error: 'preparação de mídia: $e',
        ));
        await ctrl.close();
        return;
      }

      // Render do ChatML oficial do LFM3, com um marcador por bitmap.
      final String prompt;
      try {
        var patched = systemPromptOverride == null
            ? messages
            : [
                ChatMessage('system', systemPromptOverride),
                ...messages.where((m) => m.role != 'system'),
              ];
        if (markerCount > 0) {
          final markers =
              List<String>.filled(markerCount, lfm3.Lfm3Markup.mediaMarker)
                  .join('\n');
          final lastUser = patched.lastIndexWhere((m) => m.role == 'user');
          if (lastUser >= 0) {
            final u = patched[lastUser];
            patched = [
              ...patched.take(lastUser),
              ChatMessage(u.role, '${u.content}\n\n$markers'),
              ...patched.skip(lastUser + 1),
            ];
          } else {
            patched = [...patched, ChatMessage('user', markers)];
          }
        }
        prompt = lfm3.renderChat(
          patched,
          enableThinking: config.enableThinking,
          preserveThinking: config.preserveThinking,
          jsonResponse: config.responseFormat != ResponseFormat.text,
          responseJsonSchema: config.responseJsonSchema,
          audioOutput: config.profile == Lfm3Profile.audioTts,
          interleavedAudio: config.profile == Lfm3Profile.audioTts,
        );
      } catch (e) {
        ctrl.add(GenEnd(
          promptTokens: 0,
          outputTokens: 0,
          latencyMs: 0,
          stopReason: 'error',
          error: 'chat template: $e',
        ));
        await ctrl.close();
        return;
      }

      final port = await _ensureWorker();
      final id = ++_genCounter;
      final inbox = ReceivePort();
      final link = _GenLink(id, inbox, ctrl);
      _active = link;
      inbox.listen((raw) => _onWorkerMessage((raw as Map).cast<String, Object?>()));
      link.ctrl.onCancel = () {
        // Cancelamento do stream = abort (stopReason 'aborted' se chegar).
        if (identical(_active, link) && !link.done.isCompleted) {
          port.send({'cmd': 'abort', 'id': id});
        }
      };
      port.send({
        'cmd': 'generate',
        'id': id,
        'events': inbox.sendPort,
        'prompt': prompt,
        'config': config.toJson(),
        'maxTokens': maxTokensOverride ?? config.maxTokens,
        'media': preparedMedia,
      });
    }();
    return ctrl.stream;
  }

  /// Aborta a geração em curso (se existir). Ao contrário do cancelamento do
  /// stream, o ouvinte ATIVO recebe um [GenEnd] com `stopReason: 'aborted'`.
  void abort() {
    final link = _active;
    if (link != null && !link.done.isCompleted) {
      _commands?.send({'cmd': 'abort', 'id': link.id});
    }
  }

  // ------------------------------------------------------ countTokens -----
  @override
  Future<int> countTokens(String text) async {
    final resp = await _request({'cmd': 'count', 'text': text});
    if (resp['ok'] != true) {
      throw StateError('llama: countTokens falhou — ${resp['error']}');
    }
    return resp['n'] as int;
  }

  // ----------------------------------------------------------- unload -----
  @override
  Future<void> unload() async {
    final link = _active;
    if (link != null) {
      _commands?.send({'cmd': 'abort', 'id': link.id});
      await link.done.future.timeout(const Duration(seconds: 30),
          onTimeout: () {});
      _finish(link);
    }
    _loaded = false;
    _modelPath = '';
    _mmprojPath = null;
    _info = null;
    final commands = _commands;
    if (commands != null) {
      // Liberta os handles nativos (contexto + modelo) no isolate de trabalho.
      final reply = ReceivePort();
      try {
        commands.send({'cmd': 'unload', 'reply': reply.sendPort});
        await reply.first.timeout(const Duration(seconds: 60),
            onTimeout: () => {'ok': true});
      } finally {
        reply.close();
      }
    }
    // Teardown completo: mata o isolate e força re-spawn no próximo load().
    _isolate?.kill(priority: Isolate.immediate);
    _inbox?.close();
    _isolate = null;
    _inbox = null;
    _commands = null;
    _ready = null;
  }
}

/// Alias de compatibilidade com o nome antigo.
typedef LlmEngineLlama = LlamaLfm3FfiEngine;

/// Alias curto para a UI.
typedef Lfm3Engine = LlamaLfm3FfiEngine;