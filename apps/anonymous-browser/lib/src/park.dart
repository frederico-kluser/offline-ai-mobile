/// Park/retoma — persistência das missões e runs (port do `park`/`--continue`
/// do desktop). Mobile agrava: o SO mata processos em background, por isso o
/// estado grava-se a cada passo e a retomada é idempotente.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'domain/mission.dart';

class Park {
  Future<Directory> _runsDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/anonymous_browser/runs');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<File> _runFile(String id) async {
    final dir = await _runsDir();
    return File('${dir.path}/$id.json');
  }

  /// Grava o estado da run (chamado a cada passo).
  Future<void> saveRun(MissionRunState run) async {
    final f = await _runFile(run.spec.id);
    await f.writeAsString(jsonEncode(run.toJson()));
  }

  Future<MissionRunState?> loadRun(String id) async {
    final f = await _runFile(id);
    if (!await f.exists()) return null;
    try {
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return MissionRunState.fromJson(j);
    } catch (_) {
      return null;
    }
  }

  /// Todas as runs gravadas (mais recente primeiro).
  Future<List<MissionRunState>> listRuns() async {
    final dir = await _runsDir();
    final out = <MissionRunState>[];
    await for (final e in dir.list()) {
      if (e is File && e.path.endsWith('.json')) {
        final run = await loadRun(
            e.uri.pathSegments.last.replaceAll('.json', ''));
        if (run != null) out.add(run);
      }
    }
    out.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return out;
  }

  Future<void> deleteRun(String id) async {
    final f = await _runFile(id);
    if (await f.exists()) await f.delete();
  }
}
