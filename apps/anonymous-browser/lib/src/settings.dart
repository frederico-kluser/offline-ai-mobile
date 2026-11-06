/// Definições da app: chave OpenRouter (só o caminho/valor local — nunca em
/// log nem tape), modos de backend e limiares recalibráveis.
library;

import 'package:shared_preferences/shared_preferences.dart';

import 'domain/mission.dart';

class AppSettings {
  /// Chave da API OpenRouter (Jev + MiMo online). Guardada localmente;
  /// apresentação sempre mascarada.
  String openrouterKey;

  DecisionMode decisionMode;
  TextMode textMode;

  /// Bandas de confiança (recalibráveis — as do Jev não transferem p/ Laya).
  double autoBand;
  double minBand;
  double doneBand;

  /// Orçamento de tempo das missões novas (minutos).
  int defaultMaxMinutes;

  AppSettings({
    this.openrouterKey = '',
    this.decisionMode = DecisionMode.jevOnline,
    this.textMode = TextMode.mimoOnline,
    this.autoBand = 0.60,
    this.minBand = 0.50,
    this.doneBand = 0.85,
    this.defaultMaxMinutes = 15,
  });

  static Future<AppSettings> load() async {
    final p = await SharedPreferences.getInstance();
    return AppSettings(
      openrouterKey: p.getString('openrouter_key') ?? '',
      decisionMode: DecisionMode.values.firstWhere(
          (m) => m.name == (p.getString('decision_mode') ?? 'jevOnline'),
          orElse: () => DecisionMode.jevOnline),
      textMode: TextMode.values.firstWhere(
          (m) => m.name == (p.getString('text_mode') ?? 'mimoOnline'),
          orElse: () => TextMode.mimoOnline),
      autoBand: (p.getDouble('auto_band') ?? 0.60),
      minBand: (p.getDouble('min_band') ?? 0.50),
      doneBand: (p.getDouble('done_band') ?? 0.85),
      defaultMaxMinutes: (p.getInt('default_max_minutes') ?? 15),
    );
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('openrouter_key', openrouterKey);
    await p.setString('decision_mode', decisionMode.name);
    await p.setString('text_mode', textMode.name);
    await p.setDouble('auto_band', autoBand);
    await p.setDouble('min_band', minBand);
    await p.setDouble('done_band', doneBand);
    await p.setInt('default_max_minutes', defaultMaxMinutes);
  }

  /// Apresentação da chave: `sk-…1234` (nunca em claro).
  String get maskedKey {
    final k = openrouterKey;
    if (k.length <= 8) return k.isEmpty ? '(não definida)' : '••••';
    return '${k.substring(0, 3)}••••${k.substring(k.length - 4)}';
  }
}
