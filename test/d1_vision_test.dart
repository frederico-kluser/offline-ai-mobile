/// Testes do tensor `pixel_values` do d1.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_ai_mobile/src/engines/d1_vision.dart';
import 'package:offline_ai_mobile/src/services/media_preprocessor.dart';

void main() {
  test('imagem 64×64 gera shape [2,2,2,2,1536]', () {
    final rgb = Uint8List(64 * 64 * 3);
    for (var i = 0; i < rgb.length; i += 3) {
      rgb[i] = 255; // R
      rgb[i + 1] = 0;
      rgb[i + 2] = 0;
    }
    final t = buildD1PixelValues(
      PreparedImage(width: 64, height: 64, rgb: rgb),
    );
    expect(t.shape, [2, 2, 2, 2, 1536]);
    expect(t.data.length, 2 * 2 * 2 * 2 * 1536);
    expect(t.data[0], 1.0);
    expect(t.data[1], -1.0);
    expect(t.data[2], -1.0);
    expect(t.data[768], 1.0); // segundo frame duplicado
  });

  test('par de frames codifica frame0/frame1', () {
    final red = PreparedImage(
      width: 64,
      height: 64,
      rgb: Uint8List.fromList(List.generate(64 * 64 * 3, (i) => i % 3 == 0 ? 255 : 0)),
    );
    final blue = PreparedImage(
      width: 64,
      height: 64,
      rgb: Uint8List.fromList(List.generate(64 * 64 * 3, (i) => i % 3 == 2 ? 255 : 0)),
    );
    final t = buildD1VideoValues(red, blue);
    expect(t.shape, [2, 2, 2, 2, 1536]);
    expect(t.data[0], 1.0); // R do frame0
    expect(t.data[768], -1.0); // R do frame1 (azul)
    expect(t.data[770], 1.0); // B do frame1
  });

  test('imagem fora de múltiplos de 32 falha', () {
    expect(
      () => buildD1PixelValues(PreparedImage(
        width: 30,
        height: 32,
        rgb: Uint8List(30 * 32 * 3),
      )),
      throwsArgumentError,
    );
  });

  test('concatena features de várias imagens', () {
    expect(concatD1Features([
      [1, 2],
      [3]
    ]), [1, 2, 3]);
  });
}
