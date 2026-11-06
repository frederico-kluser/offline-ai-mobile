/// Gate real do d1-2B ONNX no dispositivo (opt-in).
///
///   `flutter test integration_test/real_d1_test.dart --dart-define=REAL_D1=true -d DEVICE`
///
/// Descarrega o pacote oficial d1-2B-ONNX (~1,95 GB) para os documentos da
/// app e corre uma pergunta `noul` com `output_tokens == 0`.
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:offline_ai_mobile/src/domain/d1_decision_types.dart';
import 'package:offline_ai_mobile/src/domain/llm_config.dart';
import 'package:offline_ai_mobile/src/engines/d1_engine.dart';
import 'package:offline_ai_mobile/src/engines/d1_onnx_engine.dart';

const _hf = 'https://huggingface.co/LiquidAI/d1-2B-ONNX/resolve/main';

Future<File> _download(String remote, int bytes) async {
  final name = remote.split('/').last;
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}/models-real-d1');
  await dir.create(recursive: true);
  final file = File('${dir.path}/$name');
  if (await file.exists() && await file.length() == bytes) return file;
  // ignore: avoid_print
  print('D1 REAL: download $_hf/$remote');
  final client = http.Client();
  final res = await client.send(http.Request('GET', Uri.parse('$_hf/$remote')));
  if (res.statusCode != 200) {
    client.close();
    throw StateError('download HTTP ${res.statusCode} para $remote');
  }
  await res.stream.pipe(file.openWrite());
  client.close();
  final length = await file.length();
  if (length != bytes) {
    throw StateError('$name tem $length bytes; esperado $bytes');
  }
  return file;
}

Future<File> _downloadOmni(String remote, int bytes) async {
  final name = remote.split('/').last;
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}/models-real-d1');
  await dir.create(recursive: true);
  final file = File('${dir.path}/$name');
  if (await file.exists() && await file.length() == bytes) return file;
  const base = 'https://huggingface.co/LiquidAI/d1-Omni-2B-ONNX/resolve/main';
  // ignore: avoid_print
  print('D1 OMNI: download $base/$remote');
  final client = http.Client();
  final res = await client.send(http.Request('GET', Uri.parse('$base/$remote')));
  if (res.statusCode != 200) {
    client.close();
    throw StateError('download HTTP ${res.statusCode} para $remote');
  }
  await res.stream.pipe(file.openWrite());
  client.close();
  final length = await file.length();
  if (length != bytes) {
    throw StateError('$name tem $length bytes; esperado $bytes');
  }
  return file;
}

Future<File> _spokenWav() async {
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}/models-real-d1');
  await dir.create(recursive: true);
  final file = File('${dir.path}/hello_pt.wav');
  final data = await rootBundle.load('assets/audio/hello_pt.wav');
  await file.writeAsBytes(data.buffer.asUint8List());
  return file;
}

Future<File> _redVideo() async {
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}/models-real-d1');
  await dir.create(recursive: true);
  final file = File('${dir.path}/red.mp4');
  final data = await rootBundle.load('assets/video/red.mp4');
  await file.writeAsBytes(data.buffer.asUint8List());
  return file;
}

Future<File> _redImage() async {
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}/models-real-d1');
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
    'd1-2B ONNX decide noul sem gerar tokens',
    (tester) async {
      await tester.runAsync(() async {
        final decoder = await _download('onnx/decoder_q4.onnx', 358945);
        await _download('onnx/decoder_q4.onnx_data', 1741806592);
        final tokenizer = await _download('tokenizer.json', 17908258);
        final processor = await _download('processor_config.json', 1254);
        await _download('config.json', 2903);
        await _download('chat_template.jinja', 12762);

        final engine = D1OnnxEngine();
        await engine.load(
          paths: D1ModelPaths(
            decoderPath: decoder.path,
            decoderDataPath: '${decoder.parent.path}/decoder_q4.onnx_data',
            tokenizerPath: tokenizer.path,
            processorConfigPath: processor.path,
          ),
          config: const D1Config(threads: 2, maxStateTokens: 2048),
        );
        // ignore: avoid_print
        print('D1 REAL: backend=${engine.backend} caps=${engine.capabilities}');

        final response = await engine.decide(const D1Request(
          state: 'O cliente disse: quero pagar a fatura hoje.',
          questions: [
            D1NoulQuestion(
              id: 'pay',
              instructions: 'O cliente quer pagar?',
              trueCriteria: 'quer pagar',
              falseCriteria: 'não quer pagar',
            ),
          ],
        ));
        await engine.unload();
        final answer = response.answers['pay'];
        // ignore: avoid_print
        print('D1 REAL: $answer input_tokens=${response.inputTokens} '
            'latency=${response.latencyMs} engine=${response.engine}');
        expect(answer, isA<D1NoulAnswer>());
        expect(response.inputTokens, greaterThan(0));
        expect(response.engine, 'd1-onnx');
      });
    },
    timeout: const Timeout(Duration(minutes: 20)),
    skip: !const bool.fromEnvironment('REAL_D1'),
  );

  testWidgets(
    'd1-2B ONNX usa image_features numa pergunta visual',
    (tester) async {
      await tester.runAsync(() async {
        final decoder = await _download('onnx/decoder_q4.onnx', 358945);
        await _download('onnx/decoder_q4.onnx_data', 1741806592);
        final vision =
            await _download('onnx/vision_encoder_q8.onnx', 126353);
        await _download('onnx/vision_encoder_q8.onnx_data', 196153344);
        final tokenizer = await _download('tokenizer.json', 17908258);
        final processor = await _download('processor_config.json', 1254);
        final image = await _redImage();

        final engine = D1OnnxEngine();
        await engine.load(
          paths: D1ModelPaths(
            decoderPath: decoder.path,
            decoderDataPath: '${decoder.parent.path}/decoder_q4.onnx_data',
            visionEncoderPath: vision.path,
            tokenizerPath: tokenizer.path,
            processorConfigPath: processor.path,
          ),
          config: const D1Config(threads: 2, maxStateTokens: 2048),
        );
        final response = await engine.decide(D1Request(
          state: 'A imagem é uma cor sólida.',
          media: [D1Media(kind: D1MediaKind.image, path: image.path)],
          questions: const [
            D1NoulQuestion(
              id: 'red',
              instructions: 'A imagem é vermelha?',
              trueCriteria: 'sim, vermelha',
              falseCriteria: 'não é vermelha',
            ),
          ],
        ));
        await engine.unload();
        final answer = response.answers['red'];
        // ignore: avoid_print
        print('D1 IMAGE: $answer input_tokens=${response.inputTokens} '
            'latency=${response.latencyMs}');
        expect(answer, isA<D1NoulAnswer>());
        expect(response.inputTokens, greaterThan(0));
      });
    },
    timeout: const Timeout(Duration(minutes: 20)),
    skip: !const bool.fromEnvironment('REAL_D1'),
  );

  testWidgets(
    'd1-Omni ONNX usa audio_features numa pergunta falada',
    (tester) async {
      await tester.runAsync(() async {
        final decoder =
            await _downloadOmni('onnx/decoder_q4.onnx', 360831);
        await _downloadOmni('onnx/decoder_q4.onnx_data', 1741806592);
        final audio = await _downloadOmni(
            'onnx/audio_encoder_fp16.onnx', 163115);
        await _downloadOmni(
            'onnx/audio_encoder_fp16.onnx_data', 255173120);
        final tokenizer =
            await _downloadOmni('tokenizer.json', 17908634);
        final processor =
            await _downloadOmni('processor_config.json', 1928);
        final wav = await _spokenWav();

        final engine = D1OnnxEngine();
        await engine.load(
          paths: D1ModelPaths(
            decoderPath: decoder.path,
            decoderDataPath: '${decoder.parent.path}/decoder_q4.onnx_data',
            audioEncoderPath: audio.path,
            tokenizerPath: tokenizer.path,
            processorConfigPath: processor.path,
          ),
          config: const D1Config(threads: 2, maxStateTokens: 2048),
        );
        final response = await engine.decide(D1Request(
          state: '',
          media: [D1Media(kind: D1MediaKind.audio, path: wav.path)],
          questions: const [
            D1NoulQuestion(
              id: 'spoken',
              instructions: 'O áudio diz olá, mundo?',
              trueCriteria: 'sim, diz olá mundo',
              falseCriteria: 'não diz olá mundo',
            ),
          ],
        ));
        await engine.unload();
        final answer = response.answers['spoken'];
        // ignore: avoid_print
        print('D1 AUDIO: $answer input_tokens=${response.inputTokens} '
            'latency=${response.latencyMs}');
        expect(answer, isA<D1NoulAnswer>());
        expect(response.inputTokens, greaterThan(0));
      });
    },
    timeout: const Timeout(Duration(minutes: 20)),
    skip: !const bool.fromEnvironment('REAL_D1'),
  );

  testWidgets(
    'd1-2B ONNX usa video_features num clipe de 2 fps',
    (tester) async {
      await tester.runAsync(() async {
        final decoder = await _download('onnx/decoder_q4.onnx', 358945);
        await _download('onnx/decoder_q4.onnx_data', 1741806592);
        final vision =
            await _download('onnx/vision_encoder_q8.onnx', 126353);
        await _download('onnx/vision_encoder_q8.onnx_data', 196153344);
        final tokenizer = await _download('tokenizer.json', 17908258);
        final processor = await _download('processor_config.json', 1254);
        final video = await _redVideo();

        final engine = D1OnnxEngine();
        await engine.load(
          paths: D1ModelPaths(
            decoderPath: decoder.path,
            decoderDataPath: '${decoder.parent.path}/decoder_q4.onnx_data',
            visionEncoderPath: vision.path,
            tokenizerPath: tokenizer.path,
            processorConfigPath: processor.path,
          ),
          config: const D1Config(threads: 2, maxStateTokens: 2048),
        );
        final response = await engine.decide(D1Request(
          state: 'Um clipe curto de cor sólida.',
          media: [D1Media(kind: D1MediaKind.video, path: video.path)],
          questions: const [
            D1NoulQuestion(
              id: 'video',
              instructions: 'O clipe é vermelho?',
              trueCriteria: 'sim, vermelho',
              falseCriteria: 'não é vermelho',
            ),
          ],
        ));
        await engine.unload();
        final answer = response.answers['video'];
        // ignore: avoid_print
        print('D1 VIDEO: $answer input_tokens=${response.inputTokens} '
            'latency=${response.latencyMs}');
        expect(answer, isA<D1NoulAnswer>());
        expect(response.inputTokens, greaterThan(0));
      });
    },
    timeout: const Timeout(Duration(minutes: 20)),
    skip: !const bool.fromEnvironment('REAL_D1'),
  );

  testWidgets(
    'd1-2B ONNX cobre as dez primitivas num só forward',
    (tester) async {
      await tester.runAsync(() async {
        final decoder = await _download('onnx/decoder_q4.onnx', 358945);
        await _download('onnx/decoder_q4.onnx_data', 1741806592);
        final vision =
            await _download('onnx/vision_encoder_q8.onnx', 126353);
        await _download('onnx/vision_encoder_q8.onnx_data', 196153344);
        final tokenizer = await _download('tokenizer.json', 17908258);
        final processor = await _download('processor_config.json', 1254);
        final image = await _redImage();

        final engine = D1OnnxEngine();
        await engine.load(
          paths: D1ModelPaths(
            decoderPath: decoder.path,
            decoderDataPath: '${decoder.parent.path}/decoder_q4.onnx_data',
            visionEncoderPath: vision.path,
            tokenizerPath: tokenizer.path,
            processorConfigPath: processor.path,
          ),
          config: const D1Config(threads: 2, maxStateTokens: 2048),
        );
        final response = await engine.decide(D1Request(
          state: 'Fatura da ACME. Total: 42,50 EUR. Vencimento: 2026-12-01. '
              'Assinado por João Silva.',
          media: [D1Media(kind: D1MediaKind.image, path: image.path)],
          questions: const [
            D1NoulQuestion(
              id: 'noul',
              instructions: 'A fatura é da ACME?',
              trueCriteria: 'sim',
              falseCriteria: 'não',
            ),
            D1ChoiceQuestion(
              id: 'choice',
              instructions: 'O que fazer?',
              criteria: {'pay': 'Pagar', 'hold': 'Reter'},
            ),
            D1ChoiceQuestion(
              id: 'multiple',
              instructions: 'Quem emitiu?',
              criteria: {'acme': 'ACME', 'other': 'Outra'},
              multiple: true,
            ),
            D1ScoreQuestion(
              id: 'score',
              instructions: 'Qual o risco?',
              levels: ['baixo', 'médio', 'alto'],
            ),
            D1TextQuestion(
              id: 'text',
              instructions: 'Quem assinou?',
            ),
            D1NumberQuestion(
              id: 'number',
              instructions: 'Qual o total?',
              unitHint: 'EUR',
            ),
            D1DateQuestion(
              id: 'date',
              instructions: 'Qual o vencimento?',
            ),
            D1RangeQuestion(
              id: 'range',
              instructions: 'Qual o total?',
              min: 0,
              max: 100,
              unitHint: 'EUR',
            ),
            D1BoxQuestion(
              id: 'box',
              instructions: 'Onde está o objeto?',
              target: 'objeto',
            ),
            D1BoxesQuestion(
              id: 'boxes',
              instructions: 'Onde estão os objetos?',
              target: 'objeto',
              maxBoxes: 4,
            ),
          ],
        ));
        await engine.unload();
        // ignore: avoid_print
        print('D1 ALL: input_tokens=${response.inputTokens} '
            'latency=${response.latencyMs} answers=${response.answers.length}');
        for (final e in response.answers.entries) {
          // ignore: avoid_print
          print('D1 ALL ${e.key}: ${e.value.summary}');
        }
        expect(response.answers.length, 10);
        expect(response.inputTokens, greaterThan(0));
      });
    },
    timeout: const Timeout(Duration(minutes: 20)),
    skip: !const bool.fromEnvironment('REAL_D1'),
  );
}
