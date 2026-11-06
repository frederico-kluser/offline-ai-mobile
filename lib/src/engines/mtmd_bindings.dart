/// Bindings `dart:ffi` para o libmtmd do llama.cpp b12088.
///
/// Cobre o subconjunto necessário ao pipeline multimodal móvel:
/// inicialização do projetor, bitmaps de imagem/áudio, tokenização com
/// marcadores `<__media__>`, avaliação de chunks no contexto llama e
/// capacidades (visão/áudio/vídeo).
///
/// A API do libmtmd é experimental; os structs abaixo seguem
/// `tools/mtmd/mtmd.h` na revisão b12088. Qualquer símbolo em falta é
/// detetado no arranque e reportado como indisponível (nunca crash).
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

final class MtmdContextParams extends Struct {
  @Bool()
  external bool useGpu;
  external Pointer<Void> device;
  @Bool()
  external bool printTimings;
  @Int32()
  external int nThreads;
  external Pointer<Uint8> imageMarker;
  external Pointer<Uint8> mediaMarker;
  @Int32()
  external int flashAttnType;
  @Bool()
  external bool warmup;
  @Int32()
  external int imageMinTokens;
  @Int32()
  external int imageMaxTokens;
  external Pointer<Void> cbEval;
  external Pointer<Void> cbEvalUserData;
  @Int32()
  external int batchMaxTokens;
  external Pointer<Void> progressCallback;
  external Pointer<Void> progressCallbackUserData;
}

final class MtmdInputText extends Struct {
  external Pointer<Uint8> text;
  @Uint64()
  external int textLen;
  @Bool()
  external bool addSpecial;
  @Bool()
  external bool parseSpecial;
}

final class MtmdCaps extends Struct {
  @Bool()
  external bool inpVision;
  @Bool()
  external bool inpAudio;
  @Bool()
  external bool genAudio;
}

final class MtmdVideoConfig extends Struct {
  @Int32()
  external int tmpl;
  @Float()
  external double fps;
  @Int32()
  external int nFrames;
  @Int32()
  external int frameWidth;
  @Int32()
  external int frameHeight;
}

/// Wrapper de um bitmap nativo (imagem RGB ou áudio F32).
class MtmdBitmap {
  final Pointer<Void> ptr;
  final Pointer<Uint8> _data;
  final Pointer<Float> _audio;
  final MtmdBindings _bindings;
  bool _freed = false;

  MtmdBitmap._({
    required this.ptr,
    required MtmdBindings bindings,
    Pointer<Uint8>? data,
    Pointer<Float>? audio,
    // ignore: prefer_initializing_formals
  })  : _bindings = bindings,
        _data = data ?? nullptr,
        _audio = audio ?? nullptr;

  factory MtmdBitmap.image(
    MtmdBindings bindings, {
    required int width,
    required int height,
    required Pointer<Uint8> rgb,
  }) {
    final ptr = bindings.bitmapInit(width, height, rgb);
    if (ptr == nullptr) {
      throw StateError('mtmd_bitmap_init devolveu NULL');
    }
    return MtmdBitmap._(
      ptr: ptr,
      bindings: bindings,
      data: rgb,
    );
  }

  factory MtmdBitmap.audio(
    MtmdBindings bindings, {
    required Pointer<Float> samples,
    required int nSamples,
  }) {
    final ptr = bindings.bitmapInitFromAudio(nSamples, samples);
    if (ptr == nullptr) {
      throw StateError('mtmd_bitmap_init_from_audio devolveu NULL');
    }
    return MtmdBitmap._(
      ptr: ptr,
      bindings: bindings,
      audio: samples,
    );
  }

  void setId(String id) {
    final p = id.toNativeUtf8();
    _bindings.bitmapSetId(ptr, p.cast());
    calloc.free(p);
  }

  void setMergeable(bool value) => _bindings.bitmapSetMergeable(ptr, value);
  void setIsVideo(bool value) => _bindings.bitmapSetIsVideo(ptr, value);

  void dispose() {
    if (_freed) return;
    _freed = true;
    _bindings.bitmapFree(ptr);
    if (_data != nullptr) calloc.free(_data);
    if (_audio != nullptr) calloc.free(_audio);
  }
}

/// Wrapper de `mtmd_input_chunks`.
class MtmdInputChunks {
  final Pointer<Void> ptr;
  final MtmdBindings _bindings;
  bool _freed = false;

  MtmdInputChunks._(this.ptr, this._bindings);

  int get length => _bindings.inputChunksSize(ptr);

  Pointer<Void> chunkAt(int index) => _bindings.inputChunksGet(ptr, index);

  int chunkType(Pointer<Void> chunk) => _bindings.inputChunkGetType(chunk);

  int chunkNTokens(Pointer<Void> chunk) => _bindings.inputChunkGetNTokens(chunk);

  void dispose() {
    if (_freed) return;
    _freed = true;
    _bindings.inputChunksFree(ptr);
  }
}

class MtmdProjectorInfo {
  final bool vision;
  final bool audio;
  final bool generatesAudio;
  final String marker;

  const MtmdProjectorInfo({
    required this.vision,
    required this.audio,
    required this.generatesAudio,
    required this.marker,
  });

  Map<String, dynamic> toJson() => {
        'vision': vision,
        'audio': audio,
        'gen_audio': generatesAudio,
        'marker': marker,
      };
}

/// Bindings do libmtmd.
class MtmdBindings {
  final DynamicLibrary lib;

  late final Pointer<Uint8> Function() defaultMarker =
      lib.lookupFunction<Pointer<Uint8> Function(), Pointer<Uint8> Function()>(
          'mtmd_default_marker');
  late final MtmdContextParams Function() contextDefaultParams = lib.lookupFunction<
      MtmdContextParams Function(),
      MtmdContextParams Function()>('mtmd_context_params_default');
  late final Pointer<Void> Function(
      Pointer<Uint8>, Pointer<Void>, MtmdContextParams) initFromFile = lib
      .lookupFunction<
          Pointer<Void> Function(Pointer<Uint8>, Pointer<Void>,
              MtmdContextParams),
          Pointer<Void> Function(Pointer<Uint8>, Pointer<Void>,
              MtmdContextParams)>('mtmd_init_from_file');
  late final void Function(Pointer<Void>) free =
      lib.lookupFunction<Void Function(Pointer<Void>),
          void Function(Pointer<Void>)>('mtmd_free');
  late final bool Function(Pointer<Void>) supportVision = lib.lookupFunction<
      Bool Function(Pointer<Void>),
      bool Function(Pointer<Void>)>('mtmd_support_vision');
  late final bool Function(Pointer<Void>) supportAudio = lib.lookupFunction<
      Bool Function(Pointer<Void>),
      bool Function(Pointer<Void>)>('mtmd_support_audio');
  late final int Function(Pointer<Void>) audioSampleRate = lib.lookupFunction<
      Int32 Function(Pointer<Void>),
      int Function(Pointer<Void>)>('mtmd_get_audio_sample_rate');
  late final Pointer<Uint8> Function(Pointer<Void>) getMarker = lib
      .lookupFunction<Pointer<Uint8> Function(Pointer<Void>),
          Pointer<Uint8> Function(Pointer<Void>)>('mtmd_get_marker');
  late final Pointer<Void> Function(int, int, Pointer<Uint8>) bitmapInit = lib
      .lookupFunction<
          Pointer<Void> Function(Uint32, Uint32, Pointer<Uint8>),
          Pointer<Void> Function(
              int, int, Pointer<Uint8>)>('mtmd_bitmap_init');
  late final Pointer<Void> Function(int, Pointer<Float>) bitmapInitFromAudio =
      lib.lookupFunction<
          Pointer<Void> Function(Uint64, Pointer<Float>),
          Pointer<Void> Function(
              int, Pointer<Float>)>('mtmd_bitmap_init_from_audio');
  late final void Function(Pointer<Void>) bitmapFree = lib.lookupFunction<
      Void Function(Pointer<Void>),
      void Function(Pointer<Void>)>('mtmd_bitmap_free');
  late final void Function(Pointer<Void>, Pointer<Uint8>) bitmapSetId = lib
      .lookupFunction<Void Function(Pointer<Void>, Pointer<Uint8>),
          void Function(Pointer<Void>, Pointer<Uint8>)>('mtmd_bitmap_set_id');
  late final void Function(Pointer<Void>, bool) bitmapSetMergeable = lib
      .lookupFunction<Void Function(Pointer<Void>, Bool),
          void Function(Pointer<Void>, bool)>('mtmd_bitmap_set_mergeable');
  late final void Function(Pointer<Void>, bool) bitmapSetIsVideo = lib
      .lookupFunction<Void Function(Pointer<Void>, Bool),
          void Function(Pointer<Void>, bool)>('mtmd_bitmap_set_is_video');
  late final Pointer<Void> Function() inputChunksInit = lib.lookupFunction<
      Pointer<Void> Function(),
      Pointer<Void> Function()>('mtmd_input_chunks_init');
  late final void Function(Pointer<Void>) inputChunksFree = lib.lookupFunction<
      Void Function(Pointer<Void>),
      void Function(Pointer<Void>)>('mtmd_input_chunks_free');
  late final int Function(Pointer<Void>) inputChunksSize = lib.lookupFunction<
      Uint64 Function(Pointer<Void>),
      int Function(Pointer<Void>)>('mtmd_input_chunks_size');
  late final Pointer<Void> Function(Pointer<Void>, int) inputChunksGet = lib
      .lookupFunction<Pointer<Void> Function(Pointer<Void>, Uint64),
          Pointer<Void> Function(Pointer<Void>, int)>('mtmd_input_chunks_get');
  late final int Function(Pointer<Void>) inputChunkGetType = lib.lookupFunction<
      Int32 Function(Pointer<Void>),
      int Function(Pointer<Void>)>('mtmd_input_chunk_get_type');
  late final int Function(Pointer<Void>) inputChunkGetNTokens = lib
      .lookupFunction<Uint64 Function(Pointer<Void>),
          int Function(Pointer<Void>)>('mtmd_input_chunk_get_n_tokens');
  late final Pointer<Int32> Function(Pointer<Void>, Pointer<Uint64>)
      inputChunkGetTokensText = lib.lookupFunction<
          Pointer<Int32> Function(Pointer<Void>, Pointer<Uint64>),
          Pointer<Int32> Function(
              Pointer<Void>, Pointer<Uint64>)>('mtmd_input_chunk_get_tokens_text');
  late final int Function(Pointer<Void>) inputChunkGetNPos = lib.lookupFunction<
      Int32 Function(Pointer<Void>),
      int Function(Pointer<Void>)>('mtmd_input_chunk_get_n_pos');
  late final int Function(Pointer<Void>, Pointer<Void>, Pointer<MtmdInputText>,
      Pointer<Pointer<Void>>, int) tokenize = lib.lookupFunction<
      Int32 Function(Pointer<Void>, Pointer<Void>, Pointer<MtmdInputText>,
          Pointer<Pointer<Void>>, Uint64),
      int Function(Pointer<Void>, Pointer<Void>, Pointer<MtmdInputText>,
          Pointer<Pointer<Void>>, int)>('mtmd_tokenize');
  late final int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, int, int,
      int, bool, Pointer<Int32>) helperEval = lib.lookupFunction<
      Int32 Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, Int32, Int32,
          Int32, Bool, Pointer<Int32>),
      int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>, int, int, int,
          bool, Pointer<Int32>)>('mtmd_helper_eval_chunks');
  late final MtmdCaps Function(Pointer<Uint8>) getCapFromFile = lib
      .lookupFunction<MtmdCaps Function(Pointer<Uint8>),
          MtmdCaps Function(Pointer<Uint8>)>('mtmd_get_cap_from_file');

  MtmdBindings(this.lib);

  static MtmdBindings? tryOpen() {
    try {
      if (Platform.isIOS || Platform.isMacOS) {
        return MtmdBindings(DynamicLibrary.process());
      }
      return MtmdBindings(DynamicLibrary.open('libmtmd.so'));
    } catch (_) {
      return null;
    }
  }

  /// Lê as capacidades do projetor sem carregar o modelo de texto.
  MtmdProjectorInfo? inspectProjector(String path) {
    try {
      final p = path.toNativeUtf8();
      final caps = getCapFromFile(p.cast());
      calloc.free(p);
      return MtmdProjectorInfo(
        vision: caps.inpVision,
        audio: caps.inpAudio,
        generatesAudio: caps.genAudio,
        marker: defaultMarker().cast<Utf8>().toDartString(),
      );
    } catch (_) {
      return null;
    }
  }

  MtmdBitmap image({
    required int width,
    required int height,
    required Pointer<Uint8> rgb,
  }) =>
      MtmdBitmap.image(this, width: width, height: height, rgb: rgb);

  MtmdBitmap audio({
    required Pointer<Float> samples,
    required int nSamples,
  }) =>
      MtmdBitmap.audio(this, samples: samples, nSamples: nSamples);

  MtmdInputChunks tokenizeText({
    required Pointer<Void> context,
    required String text,
    required List<MtmdBitmap> bitmaps,
    bool addSpecial = true,
    bool parseSpecial = true,
  }) {
    final textBytes = utf8.encode(text);
    final textPtr = text.toNativeUtf8();
    final input = calloc<MtmdInputText>();
    input.ref
      ..text = textPtr.cast()
      ..textLen = textBytes.length
      ..addSpecial = addSpecial
      ..parseSpecial = parseSpecial;
    final bitmapPtrs = calloc<Pointer<Void>>(mathMax(1, bitmaps.length));
    for (var i = 0; i < bitmaps.length; i++) {
      bitmapPtrs[i] = bitmaps[i].ptr;
    }
    final chunksPtr = inputChunksInit();
    final rc = tokenize(context, chunksPtr, input, bitmapPtrs, bitmaps.length);
    calloc.free(input);
    calloc.free(textPtr);
    calloc.free(bitmapPtrs);
    if (rc != 0) {
      inputChunksFree(chunksPtr);
      throw StateError('mtmd_tokenize devolveu $rc');
    }
    return MtmdInputChunks._(chunksPtr, this);
  }
}

int mathMax(int a, int b) => a > b ? a : b;
