/// Front-end log-mel do d1-Omni-2B (16 kHz, 128 mel).
///
/// Reproduz `Lfm3OmniFeatureExtractor` do pacote oficial:
///  - `torch.stft(center=False, n_fft=400, hop=160, win=400,
///    window=hann_window(400))`;
///  - `power = |stft|²`;
///  - `mel_filter_bank(201 bins, 128 filtros, 0..8000 Hz, norm=slaney,
///    mel_scale=slaney)`;
///  - `log10(power).clamp(min=-12)`;
///  - `(log_mel + 4) / 4`.
///
/// O resultado é `input_features` `[1, 128, num_frames]` para o
/// `audio_encoder.onnx` do d1-Omni.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fftea/fftea.dart';

import '../services/media_preprocessor.dart';

class D1AudioTensor {
  final Float32List data;
  final List<int> shape;

  const D1AudioTensor(this.data, this.shape);
}

D1AudioTensor buildD1LogMel(PreparedAudio audio) {
  if (audio.sampleRate != 16000) {
    throw ArgumentError('d1-Omni exige 16 kHz; recebi ${audio.sampleRate}');
  }
  final samples = audio.samples;
  final padded = _padLength(samples.length);
  final frames = 1 + (padded - 400) ~/ 160;
  final out = Float32List(128 * frames);
  final window = _hann(400);
  final mel = _melFilters();
  final fft = FFT(400);

  for (var t = 0; t < frames; t++) {
    final frame = Float64List(400);
    final base = t * 160;
    for (var i = 0; i < 400; i++) {
      final idx = base + i;
      final s = idx < samples.length ? samples[idx] : 0.0;
      frame[i] = s * window[i];
    }
    final spectrum = fft.realFft(frame).discardConjugates().magnitudes();
    if (spectrum.length < 201) {
      throw StateError('FFT devolveu ${spectrum.length} bins; esperado 201');
    }
    final power = Float64List(201);
    for (var k = 0; k < 201; k++) {
      power[k] = spectrum[k] * spectrum[k];
    }
    for (var m = 0; m < 128; m++) {
      var energy = 0.0;
      final filter = mel[m];
      for (var k = 0; k < 201; k++) {
        energy += filter[k] * power[k];
      }
      final logMel = _log10(math.max(energy, 1e-10)).clamp(-12.0, 100.0);
      out[m * frames + t] = (logMel + 4.0) / 4.0;
    }
  }
  return D1AudioTensor(out, [1, 128, frames]);
}

int _padLength(int n) {
  if (n < 400) return 400;
  return n + (-(n - 400) % 160);
}

Float64List _hann(int n) {
  final w = Float64List(n);
  for (var i = 0; i < n; i++) {
    w[i] = 0.5 - 0.5 * math.cos(2 * math.pi * i / n);
  }
  return w;
}

List<Float64List> _melFilters() {
  const nMels = 128;
  const nBins = 201;
  const sr = 16000.0;
  const maxHz = sr / 2;
  final freqs = List<double>.generate(nBins, (i) => maxHz * i / (nBins - 1));
  final melMin = _hzToMel(0);
  final melMax = _hzToMel(maxHz);
  final melPoints = List<double>.generate(nMels + 2,
      (i) => melMin + (melMax - melMin) * i / (nMels + 1));
  final hzPoints = [for (final m in melPoints) _melToHz(m)];
  final filters = <Float64List>[];
  for (var m = 0; m < nMels; m++) {
    final lower = hzPoints[m];
    final center = hzPoints[m + 1];
    final upper = hzPoints[m + 2];
    final f = Float64List(nBins);
    for (var k = 0; k < nBins; k++) {
      final hz = freqs[k];
      double v = 0;
      if (hz >= lower && hz <= center) {
        v = (hz - lower) / math.max(1e-12, center - lower);
      } else if (hz > center && hz <= upper) {
        v = (upper - hz) / math.max(1e-12, upper - center);
      }
      if (v != 0) {
        // norm="slaney"
        v *= 2.0 / math.max(1e-12, upper - lower);
      }
      f[k] = v;
    }
    filters.add(f);
  }
  return filters;
}

double _hzToMel(double f) {
  const fSp = 200.0 / 3.0;
  const minLogHz = 1000.0;
  const minLogMel = 15.0;
  final logstep = math.log(6.4) / 27.0;
  if (f < minLogHz) return f / fSp;
  return minLogMel + math.log(f / minLogHz) / logstep;
}

double _melToHz(double m) {
  const fSp = 200.0 / 3.0;
  const minLogHz = 1000.0;
  const minLogMel = 15.0;
  final logstep = math.log(6.4) / 27.0;
  if (m < minLogMel) return m * fSp;
  return minLogHz * math.exp(logstep * (m - minLogMel));
}

double _log10(double x) => math.log(x) / math.ln10;
