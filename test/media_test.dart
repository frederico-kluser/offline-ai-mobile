/// Testes do pré-processamento de mídia (WAV PCM16/F32 e mapas).
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_ai_mobile/src/domain/media_attachment.dart';
import 'package:offline_ai_mobile/src/engines/llm_engine.dart';
import 'package:offline_ai_mobile/src/services/media_preprocessor.dart';

Uint8List wavPcm16(List<int> samples, {int rate = 16000, int channels = 1}) {
  final data = BytesBuilder();
  for (final s in samples) {
    data.add([s & 0xFF, (s >> 8) & 0xFF]);
  }
  final dataBytes = data.toBytes();
  final byteRate = rate * channels * 2;
  final fmt = BytesBuilder()
    ..add([1, 0]) // PCM
    ..add([channels, 0])
    ..add(_u32(rate))
    ..add(_u32(byteRate))
    ..add([channels * 2, 0])
    ..add([16, 0]);
  final body = BytesBuilder()
    ..add('WAVE'.codeUnits)
    ..add('fmt '.codeUnits)
    ..add(_u32(16))
    ..add(fmt.toBytes())
    ..add('data'.codeUnits)
    ..add(_u32(dataBytes.length))
    ..add(dataBytes);
  final out = BytesBuilder()
    ..add('RIFF'.codeUnits)
    ..add(_u32(body.length))
    ..add(body.toBytes());
  return out.toBytes();
}

List<int> _u32(int v) =>
    [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];

void main() {
  test('WAV PCM16 mono 16 kHz', () {
    const pre = MediaPreprocessor();
    final wav = wavPcm16([0, 16384, -16384, 32767]);
    final a = pre.decodeWav(wav);
    expect(a.sampleRate, 16000);
    expect(a.samples.length, 4);
    expect(a.samples[0], closeTo(0, 0.001));
    expect(a.samples[1], closeTo(0.5, 0.01));
    expect(a.samples[2], closeTo(-0.5, 0.01));
  });

  test('WAV 8 kHz é reamostrado para 16 kHz', () {
    const pre = MediaPreprocessor();
    final wav = wavPcm16([0, 1000, 2000, 3000], rate: 8000);
    final a = pre.decodeWav(wav);
    expect(a.sampleRate, 16000);
    expect(a.samples.length, 8);
  });

  test('WAV inválido falha com mensagem explícita', () {
    const pre = MediaPreprocessor();
    expect(() => pre.decodeWav(Uint8List.fromList([1, 2, 3])),
        throwsA(isA<FormatException>()));
  });

  test('PreparedMedia serializa imagem/áudio/vídeo', () {
    final image = PreparedImage(
      width: 2,
      height: 2,
      rgb: Uint8List.fromList([255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255]),
    );
    final audio = PreparedAudio(samples: Float32List.fromList([0.1, 0.2]));
    final video = PreparedVideo(frames: [image], soundtrack: audio);
    final map = PreparedMedia.video(video).toMap();
    expect(map['kind'], 'video');
    final v = map['video']! as Map;
    expect((v['frames'] as List).length, 1);
    expect(v['soundtrack'], isNotNull);
  });

  test('attachment mantém kind/caminho', () {
    const a = MediaAttachment(
      kind: MediaKind.audio,
      path: '/tmp/a.wav',
      label: 'a.wav',
      bytes: 10,
    );
    expect(a.kind, MediaKind.audio);
    expect(LlmMediaInput(kind: a.kind, path: a.path).kind, MediaKind.audio);
  });
}
