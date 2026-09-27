/// Persistência leve de configurações, prompts e histórico (shared_preferences).
///
/// Princípio: nunca rebentar com valores ausentes/corrompidos — tudo cai para
/// os defaults determinísticos do domínio ([LlmConfig], [LayaConfig]).
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/llm_config.dart';
import '../domain/run_record.dart';

/// Armazenamento da app. Criar com [AppStore.load].
class AppStore {
  AppStore._(this._prefs);

  final SharedPreferences _prefs;

  static const String _kLlm = 'cfg.llm';
  static const String _kLaya = 'cfg.laya';
  static const String _kSystem = 'prompt.system';
  static const String _kUser = 'prompt.user';
  static const String _kTask = 'prompt.task';
  static const String _kLayaState = 'laya.state';
  static const String _kTemplate = 'laya.template';
  static const String _kRuns = 'runs.history';
  static const String _kGoldens = 'runs.goldens';

  /// Teto do histórico (memória do telefone é limitada).
  static const int maxRuns = 40;

  /// Tarefa por omissão do demo de tool calling.
  static const String defaultTask =
      "Calcula 17*23+5 e guarda o resultado na nota 'res'";

  static Future<AppStore> load() async {
    final prefs = await SharedPreferences.getInstance();
    return AppStore._(prefs);
  }

  // ---------------------------------------------------------------- config

  LlmConfig get llmConfig {
    final raw = _prefs.getString(_kLlm);
    if (raw == null) return const LlmConfig();
    try {
      return LlmConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const LlmConfig();
    }
  }

  Future<void> saveLlmConfig(LlmConfig config) =>
      _prefs.setString(_kLlm, jsonEncode(config.toJson()));

  LayaConfig get layaConfig {
    final raw = _prefs.getString(_kLaya);
    if (raw == null) return const LayaConfig();
    try {
      return LayaConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const LayaConfig();
    }
  }

  Future<void> saveLayaConfig(LayaConfig config) =>
      _prefs.setString(_kLaya, jsonEncode(config.toJson()));

  // ---------------------------------------------------------------- prompts

  String get systemPrompt => _prefs.getString(_kSystem) ?? '';

  Future<void> saveSystemPrompt(String value) =>
      _prefs.setString(_kSystem, value);

  String get userPrompt => _prefs.getString(_kUser) ?? '';

  Future<void> saveUserPrompt(String value) => _prefs.setString(_kUser, value);

  String get taskPrompt => _prefs.getString(_kTask) ?? defaultTask;

  Future<void> saveTaskPrompt(String value) => _prefs.setString(_kTask, value);

  String get layaState => _prefs.getString(_kLayaState) ?? '';

  Future<void> saveLayaState(String value) => _prefs.setString(_kLayaState, value);

  String get selectedTemplateId => _prefs.getString(_kTemplate) ?? '';

  Future<void> saveSelectedTemplateId(String id) => _prefs.setString(_kTemplate, id);

  // ---------------------------------------------------------------- corridas

  List<RunRecord> get runs {
    final raw = _prefs.getString(_kRuns);
    if (raw == null) return const [];
    try {
      final list = (jsonDecode(raw) as List).cast<dynamic>();
      return [
        for (final e in list)
          RunRecord.fromJson((e as Map).cast<String, dynamic>()),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Insere no topo e corta o histórico em [maxRuns].
  Future<void> addRun(RunRecord record) async {
    final all = [record, ...runs];
    final trimmed = all.length > maxRuns ? all.sublist(0, maxRuns) : all;
    await _prefs.setString(
        _kRuns, jsonEncode([for (final r in trimmed) r.toJson()]));
  }

  Future<void> clearRuns() => _prefs.remove(_kRuns);

  // ---------------------------------------------------------------- goldens

  Map<String, RunRecord> get goldens {
    final raw = _prefs.getString(_kGoldens);
    if (raw == null) return {};
    try {
      final map = (jsonDecode(raw) as Map).cast<String, dynamic>();
      return {
        for (final e in map.entries)
          e.key: RunRecord.fromJson((e.value as Map).cast<String, dynamic>()),
      };
    } catch (_) {
      return {};
    }
  }

  /// Guarda [record] como golden da sua assinatura (uma por assinatura).
  Future<void> setGolden(RunRecord record) async {
    final map = goldens;
    map[record.signature] = record;
    await _prefs.setString(
        _kGoldens, jsonEncode({for (final e in map.entries) e.key: e.value.toJson()}));
  }

  /// Golden registado para a assinatura, se existir.
  RunRecord? goldenFor(String signature) => goldens[signature];
}