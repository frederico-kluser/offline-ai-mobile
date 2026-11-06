/// Gates de inferência real do LFM3 (llama.cpp + libmtmd) no dispositivo.
///
/// Só correm com `--dart-define=REAL_LFM3=true` e descarregam os pesos
/// (~1,05 GB texto; ~1,30 GB VL+mmproj) para os documentos da app na
/// primeira execução:
///
///   `flutter test integration_test/real_lfm3_test.dart --dart-define=REAL_LFM3=true -d DEVICE`
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:offline_ai_mobile/src/domain/llm_config.dart';
import 'package:offline_ai_mobile/src/domain/media_attachment.dart';
import 'package:offline_ai_mobile/src/engines/llama_lfm3_ffi_engine.dart';
import 'package:offline_ai_mobile/src/engines/llm_engine.dart';

const _base =
    'https://github.com/frederico-kluser/lfm3-mobile-models/releases/download/'
    'models-lfm3-suite-v1';

Future<File> _download(String name, int bytes) async {
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}/models-real');
  await dir.create(recursive: true);
  final file = File('${dir.path}/$name');
  if (await file.exists() && await file.length() == bytes) return file;
  final url = '$_base/$name';
  // ignore: avoid_print
  print('REAL: download $url');
  final client = http.Client();
  final req = http.Request('GET', Uri.parse(url));
  final res = await client.send(req);
  if (res.statusCode != 200) {
    client.close();
    throw StateError('download HTTP ${res.statusCode}');
  }
  final sink = file.openWrite();
  await res.stream.pipe(sink);
  client.close();
  final length = await file.length();
  if (length != bytes) {
    throw StateError('$name tem $length bytes; esperado $bytes');
  }
  // ignore: avoid_print
  print('REAL: $name $length bytes');
  return file;
}

Future<File> _redImage() async {
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}/models-real');
  await dir.create(recursive: true);
  final file = File('${dir.path}/red.png');
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    const ui.Rect.fromLTWH(0, 0, 64, 64),
    ui.Paint()..color = const ui.Color(0xFFFF0000),
  );
  final image = await recorder.endRecording().toImage(64, 64);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  await file.writeAsBytes(data!.buffer.asUint8List());
  image.dispose();
  return file;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'LFM3-1.7B QAD-Q4_0 carrega e gera texto',
    (tester) async {
      await tester.runAsync(() async {
        final file = await _download('LFM3-1.7B-QAD-Q4_0.gguf', 1049615680);
        final engine = LlamaLfm3FfiEngine();
        final config = LlmConfig.forProfile(Lfm3Profile.agent).copyWith(
          gpuLayers: 0,
          contextSize: 512,
          maxTokens: 24,
          maxThinkingTokens: 0,
          enableThinking: false,
        );
        await engine.load(
          modelPath: file.path,
          config: config,
          kind: Lfm3ModelKind.text,
        );
        // ignore: avoid_print
        print('REAL: modelo carregado ${engine.info?.modelId}');

        final out = StringBuffer();
        GenEnd? end;
        await for (final ev in engine.generate(
          messages: const [
            ChatMessage('system', 'Responde em português, uma frase curta.'),
            ChatMessage('user', 'Diz apenas: olá, mundo.'),
          ],
          config: config,
          maxTokensOverride: 24,
        )) {
          if (ev is GenDelta) out.write(ev.text);
          if (ev is GenEnd) end = ev;
        }
        await engine.unload();
        // ignore: avoid_print
        print('REAL: saida="$out" pt=${end?.promptTokens} '
            'ot=${end?.outputTokens} ms=${end?.latencyMs} '
            'stop=${end?.stopReason} err=${end?.error}');
        expect(out.toString().trim(), isNotEmpty);
        expect(end?.error, isNull);
      });
    },
    timeout: const Timeout(Duration(minutes: 20)),
    skip: !const bool.fromEnvironment('REAL_LFM3'),
  );

  testWidgets(
    'LFM3-Audio-2B transcreve um WAV de fala',
    (tester) async {
      await tester.runAsync(() async {
        final model =
            await _download('LFM3-Audio-2B-Q4_K_M.gguf', 1099626016);
        final mmproj =
            await _download('mmproj-LFM3-Audio-2B-Q8_0.gguf', 303811840);
        final docs = await getApplicationDocumentsDirectory();
        final dir = Directory('${docs.path}/models-real');
        await dir.create(recursive: true);
        final wav = File('${dir.path}/hello_pt.wav');
        final data = await rootBundle.load('assets/audio/hello_pt.wav');
        await wav.writeAsBytes(data.buffer.asUint8List());

        final engine = LlamaLfm3FfiEngine();
        final config = LlmConfig.forProfile(Lfm3Profile.audioAsr).copyWith(
          gpuLayers: 0,
          contextSize: 1024,
          maxTokens: 48,
          maxThinkingTokens: 0,
          enableThinking: false,
        );
        await engine.load(
          modelPath: model.path,
          config: config,
          mmprojPath: mmproj.path,
          kind: Lfm3ModelKind.audio,
        );
        // ignore: avoid_print
        print('REAL AUDIO: carregado ${engine.info?.modelId}');

        final out = StringBuffer();
        GenEnd? end;
        await for (final ev in engine.generate(
          messages: const [
            ChatMessage('user', 'Transcreve o áudio em português.'),
          ],
          media: [LlmMediaInput(kind: MediaKind.audio, path: wav.path)],
          config: config,
          maxTokensOverride: 48,
        )) {
          if (ev is GenDelta) out.write(ev.text);
          if (ev is GenEnd) end = ev;
        }
        await engine.unload();
        // ignore: avoid_print
        print('REAL AUDIO: saida="$out" pt=${end?.promptTokens} '
            'ot=${end?.outputTokens} ms=${end?.latencyMs} '
            'stop=${end?.stopReason} err=${end?.error}');
        expect(out.toString().trim(), isNotEmpty);
        expect(end?.error, isNull);
      });
    },
    timeout: const Timeout(Duration(minutes: 20)),
    skip: !const bool.fromEnvironment('REAL_LFM3'),
  );

  testWidgets(
    'LFM3-VL-2B + mmproj descreve uma imagem',
    (tester) async {
      await tester.runAsync(() async {
        final model = await _download('LFM3-VL-2B-Q4_K_M.gguf', 1099627808);
        final mmproj =
            await _download('mmproj-LFM3-VL-2B-Q8_0.gguf', 203031872);
        final image = await _redImage();
        final engine = LlamaLfm3FfiEngine();
        final config = LlmConfig.forProfile(Lfm3Profile.vision).copyWith(
          gpuLayers: 0,
          contextSize: 1024,
          maxTokens: 24,
          maxThinkingTokens: 0,
          enableThinking: false,
          imageMaxTokens: 256,
        );
        await engine.load(
          modelPath: model.path,
          config: config,
          mmprojPath: mmproj.path,
          kind: Lfm3ModelKind.vision,
        );
        // ignore: avoid_print
        print('REAL VL: carregado ${engine.info?.modelId} '
            'mmproj=${engine.info?.mmprojPath}');

        final out = StringBuffer();
        GenEnd? end;
        await for (final ev in engine.generate(
          messages: const [
            ChatMessage('user',
                'Que cor predomina nesta imagem? Responde numa palavra.'),
          ],
          media: [LlmMediaInput(kind: MediaKind.image, path: image.path)],
          config: config,
          maxTokensOverride: 16,
        )) {
          if (ev is GenDelta) out.write(ev.text);
          if (ev is GenEnd) end = ev;
        }
        await engine.unload();
        // ignore: avoid_print
        print('REAL VL: saida="$out" pt=${end?.promptTokens} '
            'ot=${end?.outputTokens} ms=${end?.latencyMs} '
            'stop=${end?.stopReason} err=${end?.error}');
        expect(out.toString().trim(), isNotEmpty);
        expect(end?.error, isNull);
      });
    },
    timeout: const Timeout(Duration(minutes: 20)),
    skip: !const bool.fromEnvironment('REAL_LFM3'),
  );
}
