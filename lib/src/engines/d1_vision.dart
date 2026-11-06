/// Pré-processamento tensorial do d1 (imagem/vídeo → `pixel_values`).
///
/// O `vision_encoder` do d1-2B/d1-Omni-2B espera
/// `pixel_values` float32 com shape
/// `[grid_h_blocks, grid_w_blocks, 2, 2, 1536]`:
///  - blocos de 32×32 px (patch 16 × merge 2);
///  - 2×2 patches por bloco;
///  - 1536 = 3 canais × 16 × 16 × 2 frames (temporal patch 2).
///
/// Normalização: `(pixel / 255 − 0.5) / 0.5`.
library;

import 'dart:typed_data';

import '../services/media_preprocessor.dart';

class D1PixelTensor {
  final Float32List data;
  final List<int> shape;

  const D1PixelTensor(this.data, this.shape);
}

/// Uma imagem estática é duplicada nos dois frames temporais.
D1PixelTensor buildD1PixelValues(PreparedImage image) =>
    _pixelTensor(image, image);

/// Um par de frames de vídeo (2 fps → 2 frames por patch temporal).
D1PixelTensor buildD1VideoValues(PreparedImage frame0, PreparedImage frame1) =>
    _pixelTensor(frame0, frame1);

D1PixelTensor _pixelTensor(PreparedImage a, PreparedImage b) {
  if (a.width != b.width || a.height != b.height) {
    throw ArgumentError('frames com dimensões diferentes: '
        '${a.width}×${a.height} vs ${b.width}×${b.height}');
  }
  if (a.width % 32 != 0 || a.height % 32 != 0) {
    throw ArgumentError(
        'imagem ${a.width}×${a.height} não é múltipla de 32');
  }
  if (a.rgb.length != a.width * a.height * 3 ||
      b.rgb.length != b.width * b.height * 3) {
    throw ArgumentError('RGB com tamanho inválido');
  }
  final gh = a.height ~/ 32;
  final gw = a.width ~/ 32;
  final data = Float32List(gh * gw * 2 * 2 * 1536);
  var o = 0;
  for (var by = 0; by < gh; by++) {
    for (var bx = 0; bx < gw; bx++) {
      for (var py = 0; py < 2; py++) {
        for (var px = 0; px < 2; px++) {
          for (var frame = 0; frame < 2; frame++) {
            final src = frame == 0 ? a : b;
            for (var y = 0; y < 16; y++) {
              for (var x = 0; x < 16; x++) {
                final sy = by * 32 + py * 16 + y;
                final sx = bx * 32 + px * 16 + x;
                final i = (sy * src.width + sx) * 3;
                data[o++] = (src.rgb[i] / 255.0 - 0.5) / 0.5;
                data[o++] = (src.rgb[i + 1] / 255.0 - 0.5) / 0.5;
                data[o++] = (src.rgb[i + 2] / 255.0 - 0.5) / 0.5;
              }
            }
          }
        }
      }
    }
  }
  return D1PixelTensor(data, [gh, gw, 2, 2, 1536]);
}

/// Concatena features de várias imagens (o decoder injeta-as nos marcadores
/// `<|image|>` pela ordem do prompt).
List<double> concatD1Features(List<List<double>> parts) =>
    [for (final p in parts) ...p];
