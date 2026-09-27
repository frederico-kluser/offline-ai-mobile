/// Motor de inferência do MiniCPM5-2B sobre llama.cpp via `dart:ffi`.
///
/// Arquitetura:
///  - TODO o código nativo (llama.cpp) corre num ISOLATE próprio
///    ([_workerMain]) — nunca na UI thread. O isolate de UI só troca
///    mensagens (SendPort/ReceivePort) com tipos primitivos;
///  - as `.so` (libllama.so + libggml*.so) entram pela APK via
///    `android/app/src/main/jniLibs/<abi>/` e são abertas COM
///    [DynamicLibrary.open] por nome de ficheiro (`DynamicLibrary.process()`
///    não enxerga libs carregadas pelo Android linker);
///  - sem `package:ffi`: o `malloc`/`calloc`/`free` vêm do libc, ligados por
///    FFI (o pubspec não tem `package:ffi` — ver tools/llama_ffi.md);
///  - structs por valor (llama_model_params, llama_context_params,
///    llama_batch, llama_sampler_chain_params) são passadas diretamente —
///    o `dart:ffi` atual implementa o ABI C completo para isso;
///  - o prompt é renderizado com o chat template oficial do MiniCPM5
///    ([renderChat] em `lib/src/agent/minicpm5_chat.dart` — ficheiro não é
///    alterado, apenas usado);
///  - a cadeia de samplers segue EXATAMENTE [LlmConfig.samplersOrder]
///    (`penalties;dry;top_k;top_p;min_p;temperature`) terminando em
///    `dist(seed)` — determinística. Com `temperature <= 0` o terminal é
///    `greedy` (ver nota em [_Worker._buildChain]);
///  - abort: mensagem `abort` processada entre tokens (o loop de geração
///    cede o event loop por token) → `stopReason: 'aborted'`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:math' as math;

import '../agent/minicpm5_chat.dart' as mc;
import '../domain/llm_config.dart';
import 'llm_engine.dart';

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
    final cfg = LlmConfig.fromJson((m['config'] as Map).cast<String, dynamic>());
    try {
      if (busy) {
        reply.send({'ok': false, 'error': 'ocupado: geração em curso'});
        return;
      }
      _unloadNative(); // nunca ter 2 modelos em memória
      lib ??= _Llama(DynamicLibrary.open(LlamaFfiEngine.libName));
      final b = lib!;
      b.backendInit();

      // Model params: defaults (mmap ON por defeito) + camadas de GPU.
      final mp = b.modelDefaultParams();
      mp.nGpuLayers = cfg.gpuLayers;

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
      final cp = b.contextDefaultParams();
      nCtx = cfg.contextSize;
      cp.nCtx = nCtx;
      if (cp.nBatch == 0 || cp.nBatch > nCtx) cp.nBatch = nCtx;
      nBatch = cp.nBatch;
      cp.nThreads = cfg.threads;
      cp.nThreadsBatch = cfg.threads;

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
      reply.send({
        'ok': true,
        'n_embd': b.modelNEmbd(model),
        'n_vocab': nVocab,
        'n_ctx': nCtxActual,
        'dry': b.hasDry,
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

      // ---- prompt → tokens (add_special + parse_special) -----------------
      final toks = _tokenize(prompt, addSpecial: true, parseSpecial: true);
      promptTokens = toks.length;
      if (promptTokens == 0) {
        throw StateError('prompt vazio após tokenização');
      }
      if (promptTokens >= nCtx) {
        throw StateError(
            'prompt tem $promptTokens tokens mas o contexto é $nCtx');
      }
      var budget = maxTokens;
      final room = nCtx - promptTokens;
      if (budget > room) budget = room; // o teto nunca ultrapassa o contexto

      // ---- KV cache: clear, ou reutilização de prefixo (cachePrompt) ------
      var reuse = 0;
      if (cfg.cachePrompt && cachedTokens.isNotEmpty) {
        final limit = math.min(cachedTokens.length, toks.length);
        while (reuse < limit && cachedTokens[reuse] == toks[reuse]) {
          reuse++;
        }
        // O último token do prompt tem de ser sempre decodificado para
        // produzir logits — nunca reutilizar o prompt inteiro.
        if (reuse > toks.length - 1) reuse = toks.length - 1;
        // Aproveitar só o alinhamento de tokens por posição.
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

      // Threads por chamada (config re-aplicada).
      b.setNThreads(ctx, cfg.threads, cfg.threads);

      // ---- decode do prompt em chunks, logits só no último token ---------
      final total = toks.length;
      var sampleIdx = 0;
      for (var i = reuse; i < total;) {
        final len = math.min(nBatch, total - i);
        final batch = b.batchInit(len, 0, 1);
        for (var j = 0; j < len; j++) {
          batch.token[j] = toks[i + j];
          batch.pos[j] = i + j; // posições absolutas
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
        sampleIdx = len - 1; // último token do último chunk = fim do prompt
        if (abortRequested) {
          stop = 'aborted';
          break;
        }
        if (i < total) {
          await Future<void>.delayed(Duration.zero); // cede p/ abort
          if (abortRequested) {
            stop = 'aborted';
            break;
          }
        }
      }

      // ---- ciclo de geração ----------------------------------------------
      // Marcador de fim de turno do template MiniCPM5.
      final endMarker = mc.Tags.open('im_end');
      var held = '';
      final generated = <int>[];
      if (stop != 'aborted') {
        for (var step = 0; step < budget; step++) {
          final tok = b.sample(chain, ctx, sampleIdx);
          outputTokens++;
          generated.add(tok);

          if (b.vocabIsEog(vocab, tok) || tok == b.vocabEos(vocab)) {
            stop = 'eos';
            break;
          }

          // Peça de texto, com retenção de sufixo que pode vir a ser o
          // início de '<im_end>' (pode partir-se entre tokens).
          held += piece(tok);
          final cut = held.indexOf(endMarker);
          if (cut >= 0) {
            events.send({'e': 'delta', 't': held.substring(0, cut)});
            stop = 'stop_string';
            break;
          }
          var hold = 0;
          for (var k = 1; k < endMarker.length && k <= held.length; k++) {
            if (held.endsWith(endMarker.substring(0, k))) hold = k;
          }
          final out = held.substring(0, held.length - hold);
          held = held.substring(held.length - hold);
          events.send({'e': 'delta', 't': out}); // 1 GenDelta por token

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

      // Texto ainda retido por causa de um possível '<im_end>' partido:
      // emite-se, salvo quando a paragem foi exactamente por esse marcador.
      if (stop != 'stop_string' && held.isNotEmpty) {
        events.send({'e': 'delta', 't': held});
        held = '';
      }

      // ---- bookkeeping do cache de prompt --------------------------------
      cachedTokens = [...toks, ...generated];
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

/// [LlmEngine] sobre llama.cpp (MiniCPM5-2B) — ver doc do ficheiro.
class LlamaFfiEngine implements LlmEngine {
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
  int _genCounter = 0;
  _GenLink? _active;

  @override
  bool get isLoaded => _loaded;

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
          link.ctrl.add(GenDelta(m['t'] as String));
        }
      case 'end':
        if (!link.ctrl.isClosed) {
          link.ctrl.add(GenEnd(
            promptTokens: m['pt'] as int,
            outputTokens: m['ot'] as int,
            latencyMs: m['ms'] as int,
            stopReason: m['stop'] as String,
            error: m['err'] as String?,
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
  Future<void> load(
      {required String modelPath, required LlmConfig config}) async {
    await unload(); // nunca manter 2 modelos em memória
    final resp = await _request({
      'cmd': 'load',
      'path': modelPath,
      'config': config.toJson(),
    });
    if (resp['ok'] != true) {
      throw StateError('llama: falha ao carregar $modelPath — '
          '${resp['error']}');
    }
    _loaded = true;
    _modelPath = modelPath;
  }

  // --------------------------------------------------------- generate -----
  @override
  Stream<GenEvent> generate({
    required List<ChatMessage> messages,
    required LlmConfig config,
    int? maxTokensOverride,
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

      // Render do chat template oficial do MiniCPM5 (ficheiro não alterado).
      final String prompt;
      try {
        prompt = mc.renderChat(messages,
            tools: const [], enableThinking: config.enableThinking);
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

/// Alias de compatibilidade (a UI já referencia `LlmEngineLlama`).
typedef LlmEngineLlama = LlamaFfiEngine;