/// Testes do downloader: Range/resume, SHA-256, instalação atómica e manifesto.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:offline_ai_mobile/src/services/download_manager.dart';
import 'package:offline_ai_mobile/src/services/model_registry.dart';

String sha(String s) => sha256.convert(utf8.encode(s)).toString();

ModelBundle bundle({String? aSha, String? bSha}) => ModelBundle(
      id: 'test-bundle',
      label: 'Test',
      description: 'test',
      family: ModelFamily.lfm3,
      kind: 'gguf',
      files: [
        RemoteFile(
          filename: 'a.gguf',
          url: 'https://huggingface.co/test/a.gguf',
          bytes: 6,
          sha256: aSha ?? sha('abcdef'),
          role: ModelFileRole.weights,
        ),
        RemoteFile(
          filename: 'b.gguf',
          url: 'https://huggingface.co/test/b.gguf',
          bytes: 4,
          sha256: bSha ?? sha('1234'),
          role: ModelFileRole.mmproj,
        ),
      ],
      localDirName: 'models/test',
      mainFilename: 'a.gguf',
      mmprojFilename: 'b.gguf',
      minFreeRamMb: 0,
      minFreeDiskMb: 0,
      tier: 1,
    );

http.Client mockClient({bool failA = false}) => MockClient((request) async {
      final url = request.url.toString();
      if (url.contains('github.com')) {
        return http.Response('not found', 404);
      }
      final name = url.split('/').last;
      final data = name == 'a.gguf' ? utf8.encode('abcdef') : utf8.encode('1234');
      final range = request.headers['Range'] ?? request.headers['range'];
      if (range != null && range.startsWith('bytes=')) {
        final start = int.parse(range.substring(6).split('-').first);
        final body = data.sublist(start);
        return http.Response.bytes(body, 206);
      }
      if (failA && name == 'a.gguf') {
        return http.Response.bytes(utf8.encode('xxxxxx'), 200);
      }
      return http.Response.bytes(data, 200);
    });

void main() {
  test('descarrega bundle multi-ficheiro e instala atomicamente', () async {
    final dir = await Directory.systemTemp.createTemp('dl-test');
    addTearDown(() => dir.delete(recursive: true));
    final manager = DownloadManager(client: mockClient());
    final events = await manager.download(bundle(), dir.path).toList();

    expect(events.last.state, DownloadState.done);
    expect(events.last.fraction, 1);
    final main = await manager.installedMainPath(bundle(), dir.path);
    expect(main, isNotNull);
    expect(main, endsWith('models/test/a.gguf'));
    expect(File('${dir.path}/models/test/a.gguf').readAsStringSync(), 'abcdef');
    expect(File('${dir.path}/models/test/b.gguf').readAsStringSync(), '1234');
    expect(File('${dir.path}/models/test/.bundle.json').existsSync(), isTrue);
    final verify = await manager.verify(bundle(), dir.path);
    expect(verify.ok, isTrue);
  });

  test('retoma um .part com Range', () async {
    final dir = await Directory.systemTemp.createTemp('dl-resume');
    addTearDown(() => dir.delete(recursive: true));
    final targetDir = Directory('${dir.path}/models/test');
    await targetDir.create(recursive: true);
    await File('${targetDir.path}/a.gguf.part').writeAsString('abc');
    final manager = DownloadManager(client: mockClient());
    final events = await manager.download(bundle(), dir.path).toList();
    expect(events.last.state, DownloadState.done,
        reason: 'o .part devia ser retomado e completado');
    expect(File('${targetDir.path}/a.gguf').readAsStringSync(), 'abcdef');
  });

  test('checksum errado falha sem instalar', () async {
    final dir = await Directory.systemTemp.createTemp('dl-bad');
    addTearDown(() => dir.delete(recursive: true));
    final manager = DownloadManager(client: mockClient(failA: true));
    final events = await manager.download(bundle(), dir.path).toList();
    expect(events.last.state, DownloadState.error);
    expect(events.last.message, contains('checksum'));
    expect(File('${dir.path}/models/test/a.gguf').existsSync(), isFalse);
  });

  test('verify deteta corrupção', () async {
    final dir = await Directory.systemTemp.createTemp('dl-verify');
    addTearDown(() => dir.delete(recursive: true));
    final manager = DownloadManager(client: mockClient());
    await manager.download(bundle(), dir.path).toList();
    await File('${dir.path}/models/test/a.gguf').writeAsString('corrompido');
    final verify = await manager.verify(bundle(), dir.path);
    expect(verify.ok, isFalse);
  });
}
