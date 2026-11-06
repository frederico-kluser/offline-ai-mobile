/// Gate de inferência real do LFM3 (llama.cpp + libmtmd) no dispositivo.
///
/// Só corre com `--dart-define=REAL_LFM3=true` e descarrega o QAD-Q4_0
/// (~1,05 GB) para os documentos da app na primeira execução:
///
///   flutter test integration_test/real_lfm3_test.dart \
///     --dart-define=REAL_LFM3=true -d `<device>`
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:offline_ai_mobile/src/domain/llm_config.dart';
import 'package:offline_ai_mobile/src/engines/llama_lfm3_ffi_engine.dart';
import 'package:offline_ai_mobile/src/engines/llm_engine.dart';

const _url =
    'https://github.com/frederico-kluser/lfm3-mobile-models/releases/download/'
    'models-lfm3-suite-v1/LFM3-1.7B-QAD-Q4_0.gguf';
const _bytes = 1049615680;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'LFM3-1.7B QAD-Q4_0 carrega e gera texto',
    (tester) async {
      await tester.runAsync(() async {
        final docs = await getApplicationDocumentsDirectory();
        final dir = Directory('${docs.path}/models-real');
        await dir.create(recursive: true);
        final file = File('${dir.path}/LFM3-1.7B-QAD-Q4_0.gguf');
        if (!await file.exists() || await file.length() != _bytes) {
          // ignore: avoid_print
          print('REAL: download $_url');
          final client = http.Client();
          final req = http.Request('GET', Uri.parse(_url));
          final res = await client.send(req);
          if (res.statusCode != 200) {
            throw StateError('download HTTP ${res.statusCode}');
          }
          final sink = file.openWrite();
          await res.stream.pipe(sink);
          client.close();
        }
        final length = await file.length();
        // ignore: avoid_print
        print('REAL: $length bytes em ${file.path}');

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
}
