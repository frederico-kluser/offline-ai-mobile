/// Gate real do d1-2B ONNX no dispositivo (opt-in).
///
///   `flutter test integration_test/real_d1_test.dart --dart-define=REAL_D1=true -d DEVICE`
///
/// Descarrega o pacote oficial d1-2B-ONNX (~1,95 GB) para os documentos da
/// app e corre uma pergunta `noul` com `output_tokens == 0`.
library;

import 'dart:io';

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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'd1-2B ONNX decide noul sem gerar tokens',
    (tester) async {
      await tester.runAsync(() async {
        final decoder =
            await _download('onnx/decoder_q4f16.onnx', 274492);
        await _download('onnx/decoder_q4f16.onnx_data', 1567474688);
        final tokenizer = await _download('tokenizer.json', 17908258);
        final processor = await _download('processor_config.json', 1254);
        await _download('config.json', 2903);
        await _download('chat_template.jinja', 12762);

        final engine = D1OnnxEngine();
        await engine.load(
          paths: D1ModelPaths(
            decoderPath: decoder.path,
            decoderDataPath: '${decoder.parent.path}/decoder_q4f16.onnx_data',
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
}
