/// Preparação de mídia para os motores nativos (libmtmd / ONNX).
///
/// Imagem: descodifica para RGB intercalado e redimensiona para múltiplos de
/// 32 (patch 16 × merge 2). Áudio: lê WAV PCM16/F32, faz downmix mono e
/// reamostra para 16 kHz. Vídeo: extrai frames a 2 fps via canal nativo e
/// prepara a banda sonora quando existe.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

import '../domain/media_attachment.dart';
import '../engines/llm_engine.dart';

class PreparedImage {
  final int width;
  final int height;
  final Uint8List rgb;

  const PreparedImage({
    required this.width,
    required this.height,
    required this.rgb,
  });

  Map<String, Object> toMap() =>
      {'width': width, 'height': height, 'rgb': rgb};
}

class PreparedAudio {
  final Float32List samples;
  final int sampleRate;

  const PreparedAudio({required this.samples, this.sampleRate = 16000});

  Map<String, Object> toMap() =>
      {'samples': samples, 'sample_rate': sampleRate};
}

class PreparedVideo {
  final List<PreparedImage> frames;
  final PreparedAudio? soundtrack;

  const PreparedVideo({required this.frames, this.soundtrack});

  Map<String, Object> toMap() => {
        'frames': [for (final f in frames) f.toMap()],
        if (soundtrack != null) 'soundtrack': soundtrack!.toMap(),
      };
}

class PreparedMedia {
  final MediaKind kind;
  final PreparedImage? image;
  final PreparedAudio? audio;
  final PreparedVideo? video;

  const PreparedMedia.image(this.image)
      : kind = MediaKind.image,
        audio = null,
        video = null;
  const PreparedMedia.audio(this.audio)
      : kind = MediaKind.audio,
        image = null,
        video = null;
  const PreparedMedia.video(this.video)
      : kind = MediaKind.video,
        image = null,
        audio = null;

  Map<String, Object?> toMap() => {
        'kind': kind.wire,
        if (image != null) 'image': image!.toMap(),
        if (audio != null) 'audio': audio!.toMap(),
        if (video != null) 'video': video!.toMap(),
      };
}

class MediaPreprocessor {
  static const MethodChannel mediaChannel =
      MethodChannel('offline_ai_mobile/media');

  const MediaPreprocessor();

  Future<PreparedMedia> prepare(LlmMediaInput input) async {
    switch (input.kind) {
      case MediaKind.image:
        return PreparedMedia.image(await prepareImage(input.path));
      case MediaKind.audio:
        return PreparedMedia.audio(await prepareAudio(input.path));
      case MediaKind.video:
        return PreparedMedia.video(await prepareVideo(input.path));
    }
  }

  Future<PreparedImage> prepareImage(String path) async {
    final bytes = await File(path).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    var image = frame.image;
    // O LFM3 (patch 16 × merge 2) e o d1 (grid de 32 px) exigem lados
    // múltiplos de 32; limita o lado maior a 1024 para o prefill móvel.
    final maxSide = math.max(image.width, image.height);
    final scale = maxSide > 1024 ? 1024 / maxSide : 1.0;
    final w = _multipleOf32((image.width * scale).round());
    final h = _multipleOf32((image.height * scale).round());
    if (w != image.width || h != image.height) {
      final resized =
          await ui.instantiateImageCodec(bytes, targetWidth: w, targetHeight: h);
      final f2 = await resized.getNextFrame();
      image = f2.image;
    }
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) {
      throw StateError('não foi possível ler píxeis de $path');
    }
    final rgba = data.buffer.asUint8List();
    final rgb = Uint8List(image.width * image.height * 3);
    for (var i = 0, j = 0; i < rgba.length; i += 4, j += 3) {
      rgb[j] = rgba[i];
      rgb[j + 1] = rgba[i + 1];
      rgb[j + 2] = rgba[i + 2];
    }
    return PreparedImage(width: image.width, height: image.height, rgb: rgb);
  }

  Future<PreparedAudio> prepareAudio(String path) async {
    final bytes = await File(path).readAsBytes();
    return decodeWav(bytes);
  }

  Future<PreparedVideo> prepareVideo(String path) async {
    Map<dynamic, dynamic>? result;
    try {
      result = await mediaChannel.invokeMethod<Map<dynamic, dynamic>>(
        'extractVideoFrames',
        {'path': path, 'fps': 2.0},
      );
    } on MissingPluginException {
      throw StateError(
        'extração de vídeo indisponível: canal nativo offline_ai_mobile/media '
        'não ligado nesta build',
      );
    } catch (e) {
      throw StateError('falha ao extrair frames de vídeo: $e');
    }
    if (result == null) {
      throw StateError('canal de vídeo devolveu null');
    }
    final framePaths = [
      for (final p in (result['frames'] as List? ?? const [])) p.toString(),
    ];
    final frames = <PreparedImage>[];
    for (final p in framePaths) {
      frames.add(await prepareImage(p));
    }
    PreparedAudio? soundtrack;
    final s = result['soundtrack']?.toString();
    if (s != null && s.isNotEmpty && File(s).existsSync()) {
      soundtrack = await prepareAudio(s);
    }
    return PreparedVideo(frames: frames, soundtrack: soundtrack);
  }

  /// WAV PCM16 ou Float32, mono, 16 kHz.
  PreparedAudio decodeWav(Uint8List bytes) {
    if (bytes.length < 44 ||
        String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF' ||
        String.fromCharCodes(bytes.sublist(8, 12)) != 'WAVE') {
      throw const FormatException('áudio não é WAV (converte para WAV PCM16)');
    }
    var offset = 12;
    int? format;
    int? channels;
    int? rate;
    int? bits;
    Uint8List? data;
    while (offset + 8 <= bytes.length) {
      final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
      final size = ByteData.sublistView(bytes, offset + 4, offset + 8)
          .getUint32(0, Endian.little);
      final body = offset + 8;
      if (id == 'fmt ') {
        final bd = ByteData.sublistView(bytes, body, body + size);
        format = bd.getUint16(0, Endian.little);
        channels = bd.getUint16(2, Endian.little);
        rate = bd.getUint32(4, Endian.little);
        bits = bd.getUint16(14, Endian.little);
      } else if (id == 'data') {
        data = Uint8List.sublistView(bytes, body, math.min(bytes.length, body + size));
      }
      offset = body + size + (size.isOdd ? 1 : 0);
    }
    if (format == null || channels == null || rate == null || bits == null || data == null) {
      throw const FormatException('WAV sem fmt/data');
    }
    final frames = <double>[];
    if (format == 1 && bits == 16) {
      final bd = ByteData.sublistView(data);
      for (var i = 0; i + 2 <= data.length; i += 2) {
        frames.add(bd.getInt16(i, Endian.little) / 32768.0);
      }
    } else if (format == 3 && bits == 32) {
      final bd = ByteData.sublistView(data);
      for (var i = 0; i + 4 <= data.length; i += 4) {
        frames.add(bd.getFloat32(i, Endian.little));
      }
    } else {
      throw FormatException(
          'WAV format=$format bits=$bits não suportado (PCM16/F32)');
    }
    final perChannel = frames.length ~/ channels;
    final mono = Float32List(perChannel);
    for (var i = 0; i < perChannel; i++) {
      var v = 0.0;
      for (var c = 0; c < channels; c++) {
        v += frames[i * channels + c];
      }
      mono[i] = v / channels;
    }
    final resampled = _resample(mono, rate, 16000);
    return PreparedAudio(samples: resampled, sampleRate: 16000);
  }

  Float32List _resample(Float32List input, int from, int to) {
    if (from == to) return input;
    final outLength = (input.length * to / from).round();
    final out = Float32List(outLength);
    for (var i = 0; i < outLength; i++) {
      final src = i * from / to;
      final i0 = src.floor().clamp(0, input.length - 1);
      final i1 = (i0 + 1).clamp(0, input.length - 1);
      final t = src - i0;
      out[i] = input[i0] * (1 - t) + input[i1] * t;
    }
    return out;
  }

  int _multipleOf32(int v) => math.max(32, (v / 32).round() * 32);
}

/// Nome do canal nativo de mídia (usado também pelo código de plataforma).
const String kMediaChannelName = 'offline_ai_mobile/media';

/// Tipo de anexo auxiliar para a UI.
String mediaKindLabel(MediaKind kind) => kind.label;
