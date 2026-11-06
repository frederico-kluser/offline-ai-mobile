/// Download de modelos com progresso, verificação sha256 e instalação atómica.
///
/// Regras (doc §11 — cadeia de suprimentos): descarrega sempre para `.part`,
/// verifica checksum quando publicado, e só depois renomeia. Um download
/// interrompido nunca fica "meio instalado".
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'model_registry.dart';

enum DownloadState { idle, downloading, verifying, done, error, cancelled }

class DownloadProgress {
  final String artifactId;
  final DownloadState state;
  final double fraction;
  final String message;
  final int receivedBytes;
  final int totalBytes;

  const DownloadProgress({
    required this.artifactId,
    required this.state,
    required this.fraction,
    required this.message,
    required this.receivedBytes,
    required this.totalBytes,
  });
}

class DownloadManager {
  final http.Client _client;
  final Map<String, bool> _cancelRequested = {};

  DownloadManager({http.Client? client}) : _client = client ?? http.Client();

  /// Descarrega todos os ficheiros do artefacto para `<destDirPath>/<localDirName>`.
  Stream<DownloadProgress> download(ModelArtifact a, String destDirPath) {
    late StreamController<DownloadProgress> ctrl;
    ctrl = StreamController<DownloadProgress>(onListen: () async {
      final dir = Directory('$destDirPath/${a.localDirName}');
      await dir.create(recursive: true);
      var received = 0;
      final total = a.totalBytes;
      void emit(DownloadState st, double frac, String msg) {
        ctrl.add(DownloadProgress(
          artifactId: a.id,
          state: st,
          fraction: frac,
          message: msg,
          receivedBytes: received,
          totalBytes: total,
        ));
      }

      try {
        for (final f in a.files) {
          if (_cancelRequested[a.id] == true) {
            emit(DownloadState.cancelled, 0, 'cancelado');
            await ctrl.close();
            return;
          }
          final target = File('${dir.path}/${f.filename}');
          if (await target.exists() &&
              (f.sha256 == null ||
                  await _sha256Of(target) == f.sha256)) {
            received += f.bytes;
            emit(DownloadState.downloading, received / total,
                '${f.filename} já instalado');
            continue;
          }
          final part = File('${target.path}.part');
          final sink = part.openWrite();
          final req = http.Request('GET', Uri.parse(f.url));
          final resp = await _client.send(req);
          if (resp.statusCode != 200) {
            throw HttpException(
                'HTTP ${resp.statusCode} em ${f.filename}');
          }
          final expected = f.bytes > 0
              ? f.bytes
              : (resp.contentLength ?? 0);
          var fileReceived = 0;
          final completer = Completer<void>();
          resp.stream.listen(
            (chunk) {
              sink.add(chunk);
              fileReceived += chunk.length;
              received += chunk.length;
              final frac =
                  expected > 0 ? (received / total).clamp(0.0, 1.0) : 0.0;
              emit(DownloadState.downloading, frac,
                  '${f.filename} · ${(fileReceived / (1024 * 1024)).toStringAsFixed(1)} MB');
            },
            onDone: () async {
              await sink.flush();
              await sink.close();
              completer.complete();
            },
            onError: (Object e) async {
              await sink.close();
              if (!completer.isCompleted) completer.completeError(e);
            },
            cancelOnError: true,
          );
          await completer.future.timeout(const Duration(hours: 2));

          // Verificação de integridade.
          emit(DownloadState.verifying, received / total,
              'a verificar ${f.filename}…');
          if (f.sha256 != null) {
            final actual = await _sha256Of(part);
            if (actual != f.sha256) {
              await part.delete();
              throw const HttpException('checksum sha256 incorreto');
            }
          }
          // Instalação atómica.
          if (await target.exists()) await target.delete();
          await part.rename(target.path);
        }
        // Limpeza de ficheiros órfãos do diretório do artefacto (ex.: o kit 4-bit
        // antigo, `model_q4.onnx`, após a troca para o export fp32) — só depois
        // de a instalação estar completa; `.part` de downloads cancelados também
        // sai aqui. O diretório é gerido pela app.
        final keep = {for (final f in a.files) f.filename};
        await for (final entity in dir.list()) {
          if (entity is File && !keep.contains(entity.uri.pathSegments.last)) {
            await entity.delete();
          }
        }
        emit(DownloadState.done, 1.0, 'instalado');
        await ctrl.close();
      } catch (e) {
        emit(DownloadState.error, 0, 'erro: $e');
        await ctrl.close();
      }
    }, onCancel: () {
      _cancelRequested[a.id] = true;
    });
    return ctrl.stream;
  }

  Future<void> cancel(String artifactId) async {
    _cancelRequested[artifactId] = true;
  }

  /// Mapa artifactId → caminho do ficheiro principal, para artefactos
  /// totalmente instalados (todos os ficheiros presentes).
  Future<Map<String, String>> installedPaths(String destDirPath) async {
    final out = <String, String>{};
    for (final a in kModelCatalog) {
      final dir = Directory('$destDirPath/${a.localDirName}');
      var all = true;
      for (final f in a.files) {
        if (!await File('${dir.path}/${f.filename}').exists()) {
          all = false;
          break;
        }
      }
      if (all) {
        out[a.id] = '${dir.path}/${a.mainFilename}';
      }
    }
    return out;
  }

  /// Remove todos os ficheiros instalados do artefacto.
  Future<void> delete(String artifactId, String destDirPath) async {
    final a = modelById(artifactId);
    if (a == null) return;
    final dir = Directory('$destDirPath/${a.localDirName}');
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