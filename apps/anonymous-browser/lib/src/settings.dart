/// Definições da app: modos de backend e bandas recalibráveis.
///
/// A chave OpenRouter **não** vive aqui: persiste-se criptografada no
/// [KeyVault] (Keychain/Keystore) e só o valor em memória (mascarado na UI)
/// passa por esta classe. `shared_preferences` guarda apenas preferências não
/// sensíveis.
library;

import 'package:shared_preferences/shared_preferences.dart';

import 'domain/mission.dart';
import 'key_vault.dart';

class AppSettings {
  /// Chave OpenRouter (Jev + MiMo online) — cache EM MEMÓRIA. A persistência é
  /// criptografada (ver [KeyVault]); nunca vai para `shared_preferences`.
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

  static Future<AppSettings> load({KeyVault? vault}) async {
    final p = await SharedPreferences.getInstance();
    final s = AppSettings(
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
    try {
      s.openrouterKey =
          await (vault ?? KeyVault(store: SecureKeyStore())).readKey() ?? '';
    } catch (_) {
      s.openrouterKey = ''; // sem cofre disponível (testes) — sem chave
    }
    return s;
  }

  /// Guarda as preferências NÃO sensíveis. A chave NUNCA entra aqui.
  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('decision_mode', decisionMode.name);
    await p.setString('text_mode', textMode.name);
    await p.setDouble('auto_band', autoBand);
    await p.setDouble('min_band', minBand);
    await p.setDouble('done_band', doneBand);
    await p.setInt('default_max_minutes', defaultMaxMinutes);
  }

  /// Apresentação da chave: `sk-••••1234` (nunca em claro).
  String get maskedKey => KeyVault.mask(openrouterKey);

  bool get hasKey => openrouterKey.trim().isNotEmpty;
}
