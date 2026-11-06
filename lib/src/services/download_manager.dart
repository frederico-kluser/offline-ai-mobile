/// Download de bundles de modelos com progresso, verificação SHA-256,
/// retoma por HTTP Range e instalação atómica multi-ficheiro.
///
/// Regras:
///  - cada ficheiro vai para `<nome>.part`; um download interrompido nunca
///    fica "meio instalado";
///  - se o `.part` já existe, pede `Range: bytes=<tamanho>-` e continua; se o
///    servidor não suportar Range (200), recomeça;
///  - só depois de TODOS os ficheiros do bundle estarem completos e
///    verificados é que os `.part` são renomeados para os nomes finais;
///  - o manifesto `.bundle.json` é escrito no fim e serve de prova de
///    instalação (com os SHA-256 efetivos).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'model_registry.dart';

enum DownloadState {
  idle,
  downloading,
  verifying,
  installing,
  done,
  error,
  cancelled,
}

class DownloadProgress {
  final String bundleId;
  final DownloadState state;
  final double fraction;
  final String message;
  final int receivedBytes;
  final int totalBytes;
  final String? currentFile;

  const DownloadProgress({
    required this.bundleId,
    required this.state,
    required this.fraction,
    required this.message,
    required this.receivedBytes,
    required this.totalBytes,
    this.currentFile,
  });
}

/// Resultado de uma instalação.
class InstallResult {
  final bool ok;
  final String? error;
  final Map<String, String> fileHashes;

  const InstallResult({required this.ok, this.error, this.fileHashes = const {}});
}

class DownloadManager {
  final http.Client _client;
  final Map<String, bool> _cancelRequested = {};

  DownloadManager({http.Client? client}) : _client = client ?? http.Client();

  int _totalKnown(ModelBundle bundle) =>
      bundle.files.fold(0, (s, f) => s + (f.bytes > 0 ? f.bytes : 0));

  /// Descarrega todos os ficheiros do bundle para
  /// `<destDirPath>/<bundle.localDirName>`.
  Stream<DownloadProgress> download(ModelBundle bundle, String destDirPath) {
    late StreamController<DownloadProgress> ctrl;
    ctrl = StreamController<DownloadProgress>(onListen: () async {
      final dir = Directory('$destDirPath/${bundle.localDirName}');
      await dir.create(recursive: true);
      _cancelRequested[bundle.id] = false;
      var received = 0;
      final total = _totalKnown(bundle);
      void emit(
        DownloadState st,
        double frac,
        String msg, {
        String? file,
      }) {
        ctrl.add(DownloadProgress(
          bundleId: bundle.id,
          state: st,
          fraction: frac.clamp(0.0, 1.0),
          message: msg,
          receivedBytes: received,
          totalBytes: total,
          currentFile: file,
        ));
      }

      try {
        final hashes = <String, String>{};
        for (final f in bundle.files) {
          if (_cancelRequested[bundle.id] == true) {
            emit(DownloadState.cancelled, 0, 'cancelado');
            await ctrl.close();
            return;
          }
          final target = File('${dir.path}/${f.filename}');
          final part = File('${target.path}.part');

          // Já instalado e íntegro? Salta.
          if (await target.exists() && await _matches(target, f)) {
            final digest = f.sha256 ?? await _sha256Of(target);
            hashes[f.filename] = digest;
            received += await target.length();
            emit(
              DownloadState.downloading,
              total > 0 ? received / total : 0,
              '${f.filename} já instalado',
              file: f.filename,
            );
            continue;
          }
          if (await target.exists()) await target.delete();

          final bytes = await _downloadOne(
            f,
            part,
            bundle.id,
            onChunk: (n, fileReceived, contentLength) {
              received += n;
              final denom = total > 0
                  ? total
                  : (contentLength > 0 ? contentLength : received);
              emit(
                DownloadState.downloading,
                denom > 0 ? received / denom : 0,
                '${f.filename} · '
                '${(fileReceived / (1024 * 1024)).toStringAsFixed(1)} MB',
                file: f.filename,
              );
            },
          );
          if (bytes < 0) {
            emit(DownloadState.cancelled, 0, 'cancelado', file: f.filename);
            await ctrl.close();
            return;
          }

          emit(DownloadState.verifying, total > 0 ? received / total : 0,
              'a verificar ${f.filename}…',
              file: f.filename);
          final length = await part.length();
          if (f.bytes > 0 && length != f.bytes) {
            await part.delete();
            throw StateError(
                'tamanho de ${f.filename} é $length, esperado ${f.bytes}');
          }
          final digest = await _sha256Of(part);
          if (f.sha256 != null && digest != f.sha256) {
            await part.delete();
            throw StateError('checksum sha256 incorreto em ${f.filename}');
          }
          hashes[f.filename] = digest;
        }

        // Instalação atómica: todos os ficheiros estão nos `.part`.
        emit(DownloadState.installing, 1, 'a instalar ${bundle.files.length} '
            'ficheiro(s)…');
        for (final f in bundle.files) {
          final target = File('${dir.path}/${f.filename}');
          final part = File('${target.path}.part');
          if (await part.exists()) {
            if (await target.exists()) await target.delete();
            await part.rename(target.path);
          }
          if (!await target.exists()) {
            throw StateError('ficheiro em falta após instalação: ${f.filename}');
          }
        }
        await _writeManifest(dir, bundle, hashes);
        await _cleanOrphans(dir, bundle);
        emit(DownloadState.done, 1.0, 'instalado');
        await ctrl.close();
      } catch (e) {
        emit(DownloadState.error, 0, 'erro: $e');
        await ctrl.close();
      }
    }, onCancel: () {
      _cancelRequested[bundle.id] = true;
    });
    return ctrl.stream;
  }

  /// Descarrega um ficheiro com retoma. Devolve o total de bytes do ficheiro
  /// (ou -1 se cancelado).
  Future<int> _downloadOne(
    RemoteFile f,
    File part,
    String bundleId, {
    required void Function(int n, int fileReceived, int contentLength) onChunk,
  }) async {
    final mirror = f.mirrorUrl();
    final urls = [?mirror, f.url];
    Object? lastError;
    for (final url in urls) {
      try {
        var existing = await part.exists() ? await part.length() : 0;
        // Se o `.part` já tem o tamanho esperado, não vale a pena pedir.
        if (f.bytes > 0 && existing == f.bytes) return existing;
        final req = http.Request('GET', Uri.parse(url));
        if (existing > 0) {
          req.headers['Range'] = 'bytes=$existing-';
        }
        final resp = await _client.send(req);
        if (resp.statusCode == 404 && url == mirror) {
          // Espelho ainda não publicado: tenta a origem oficial.
          continue;
        }
        if (resp.statusCode == 416 && existing > 0) {
          // Já temos tudo (ou o servidor discorda do tamanho): valida no fim.
          return existing;
        }
        if (resp.statusCode != 200 && resp.statusCode != 206) {
          throw HttpException('HTTP ${resp.statusCode} em ${f.filename}');
        }
        var append = resp.statusCode == 206 && existing > 0;
        if (!append) existing = 0;
        final raf = await part.open(mode: append ? FileMode.append : FileMode.write);
        final contentLength = resp.contentLength ?? 0;
        var fileReceived = existing;
        try {
          await for (final chunk in resp.stream) {
            if (_cancelRequested[bundleId] == true) {
              await raf.close();
              return -1;
            }
            await raf.writeFrom(chunk);
            fileReceived += chunk.length;
            onChunk(chunk.length, fileReceived, contentLength + existing);
          }
        } finally {
          await raf.close();
        }
        return fileReceived;
      } catch (e) {
        lastError = e;
      }
    }
    throw StateError('falha ao descarregar ${f.filename}: $lastError');
  }

  Future<bool> _matches(File target, RemoteFile f) async {
    final length = await target.length();
    if (length == 0) return false;
    if (f.bytes > 0 && length != f.bytes) return false;
    if (f.sha256 == null) return true;
    return await _sha256Of(target) == f.sha256;
  }

  Future<void> _writeManifest(
    Directory dir,
    ModelBundle bundle,
    Map<String, String> hashes,
  ) async {
    final manifest = File('${dir.path}/.bundle.json');
    await manifest.writeAsString(jsonEncode({
      'bundle_id': bundle.id,
      'bundle_label': bundle.label,
      'kind': bundle.kind,
      'installed_at': DateTime.now().toUtc().toIso8601String(),
      'main': bundle.mainFilename,
      'mmproj': bundle.mmprojFilename,
      'files': {
        for (final f in bundle.files)
          f.filename: {
            'bytes': await File('${dir.path}/${f.filename}').length(),
            'sha256': hashes[f.filename],
            'role': f.role.name,
          },
      },
    }));
  }

  Future<void> _cleanOrphans(Directory dir, ModelBundle bundle) async {
    final keep = {for (final f in bundle.files) f.filename, '.bundle.json'};
    await for (final entity in dir.list()) {
      if (entity is File) {
        final name = entity.uri.pathSegments.last;
        if (!keep.contains(name)) await entity.delete();
      }
    }
  }

  Future<void> cancel(String bundleId) async {
    _cancelRequested[bundleId] = true;
  }

  /// Mapa bundleId → caminho do ficheiro principal, para bundles
  /// totalmente instalados (manifesto + todos os ficheiros presentes).
  Future<Map<String, String>> installedPaths(String destDirPath) async {
    final out = <String, String>{};
    for (final b in kModelCatalog) {
      final p = await installedMainPath(b, destDirPath);
      if (p != null) out[b.id] = p;
    }
    return out;
  }

  /// Caminho do ficheiro principal do bundle, ou `null` se não instalado.
  Future<String?> installedMainPath(
      ModelBundle bundle, String destDirPath) async {
    final dir = Directory('$destDirPath/${bundle.localDirName}');
    final manifest = File('${dir.path}/.bundle.json');
    if (!await manifest.exists()) return null;
    try {
      final j = jsonDecode(await manifest.readAsString()) as Map;
      if (j['bundle_id'] != bundle.id) return null;
    } catch (_) {
      return null;
    }
    for (final f in bundle.files) {
      if (!await File('${dir.path}/${f.filename}').exists()) return null;
    }
    final main = File('${dir.path}/${bundle.mainFilename}');
    return await main.exists() ? main.path : null;
  }

  /// Verifica todos os ficheiros do bundle contra o manifesto.
  Future<InstallResult> verify(ModelBundle bundle, String destDirPath) async {
    final dir = Directory('$destDirPath/${bundle.localDirName}');
    final manifest = File('${dir.path}/.bundle.json');
    if (!await manifest.exists()) {
      return const InstallResult(ok: false, error: 'bundle não instalado');
    }
    try {
      final j = jsonDecode(await manifest.readAsString()) as Map;
      final files = (j['files'] as Map).cast<String, dynamic>();
      final hashes = <String, String>{};
      for (final f in bundle.files) {
        final entry = files[f.filename];
        if (entry is! Map) {
          return InstallResult(ok: false, error: '${f.filename} em falta');
        }
        final expected = entry['sha256'] as String?;
        final file = File('${dir.path}/${f.filename}');
        if (!await file.exists()) {
          return InstallResult(ok: false, error: '${f.filename} em falta');
        }
        final actual = await _sha256Of(file);
        if (expected != null && actual != expected) {
          return InstallResult(
              ok: false, error: 'checksum de ${f.filename} não confere');
        }
        hashes[f.filename] = actual;
      }
      return InstallResult(ok: true, fileHashes: hashes);
    } catch (e) {
      return InstallResult(ok: false, error: '$e');
    }
  }

  /// Remove todos os ficheiros instalados do bundle.
  Future<void> delete(String bundleId, String destDirPath) async {
    final b = modelById(bundleId);
    if (b == null) return;
    final dir = Directory('$destDirPath/${b.localDirName}');
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  Future<String> _sha256Of(File f) async {
    final digest = await sha256.bind(f.openRead()).first;
    return digest.toString();
  }
}

/// Utilitário: formata bytes legíveis (determinístico, sem locale).
String formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(i == 0 ? 0 : 1)} ${units[i]}';
}

/// Nota: [utf8] é usado pelos consumidores para relatórios JSON.
final Encoding kReportEncoding = utf8;
