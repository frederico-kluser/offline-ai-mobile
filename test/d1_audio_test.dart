/// Testes do front-end log-mel do d1-Omni.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_ai_mobile/src/engines/d1_audio.dart';
import 'package:offline_ai_mobile/src/services/media_preprocessor.dart';

void main() {
  test('silêncio 1 s → [1,128,99]', () {
    final audio = PreparedAudio(samples: Float32List(16000));
    final t = buildD1LogMel(audio);
    expect(t.shape, [1, 128, 99]);
    expect(t.data.length, 128 * 99);
    for (final v in t.data) {
      expect(v.isFinite, isTrue);
    }
    // energia 0 → log10(1e-10) = -10 → (-10+4)/4 = -1.5
    expect(t.data[0], closeTo(-1.5, 1e-5));
  });

  test('senoide 440 Hz 1 s mantém shape e valores finitos', () {
    final samples = Float32List(16000);
    for (var i = 0; i < samples.length; i++) {
      samples[i] = 0.5 * math.sin(2 * math.pi * 440 * i / 16000);
    }
    final t = buildD1LogMel(PreparedAudio(samples: samples));
    expect(t.shape, [1, 128, 99]);
    expect(t.data.every((v) => v.isFinite), isTrue);
  });

  test('senoide 440 Hz concentra energia nos bins mel baixos', () {
    final samples = Float32List(16000);
    for (var i = 0; i < samples.length; i++) {
      samples[i] = 0.5 * math.sin(2 * math.pi * 440 * i / 16000);
    }
    final t = buildD1LogMel(PreparedAudio(samples: samples));
    final frames = t.shape[2];
    final perMel = List<double>.filled(128, 0);
    for (var m = 0; m < 128; m++) {
      for (var f = 0; f < frames; f++) {
        perMel[m] += t.data[m * frames + f];
      }
    }
    var best = 0;
    for (var m = 1; m < 128; m++) {
      if (perMel[m] > perMel[best]) best = m;
    }
    expect(best, inInclusiveRange(5, 30));
  });

  test('áudio de 0,1 s é padded e produz frames', () {
    final t = buildD1LogMel(PreparedAudio(samples: Float32List(1600)));
    expect(t.shape[0], 1);
    expect(t.shape[1], 128);
    expect(t.shape[2], greaterThan(0));
  });

  test('sample rate diferente de 16 kHz falha', () {
    expect(
      () => buildD1LogMel(
        PreparedAudio(samples: Float32List(10), sampleRate: 8000),
      ),
      throwsArgumentError,
    );
  });
}


