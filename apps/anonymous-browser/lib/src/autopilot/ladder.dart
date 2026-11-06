/// Escada de repetição — port dos limiares 3/5 (WAIT: 5/8) do desktop
/// (`autopilot.py`, escada `force_mimo` → vision rescue → humano) e dos
/// orçamentos do LoopGuard (2 tentativas por assinatura, 5 por run).
///
/// Repetir a MESMA assinatura (op + alvo) sem progresso não é caminho: 1.º
/// cede o passo ao modelo de texto (resgate), depois ao humano. Nunca posterga
/// o humano para além destes limites.
library;

/// O que fazer quando a assinatura repete.
enum LadderAction {
  /// Dentro do orçamento — seguir com a decisão normal.
  proceed,

  /// Repetição a subir — forçar o modelo de texto (fallback/resgate).
  forceTextModel,

  /// Esgotado — humano decide (handoff).
  askHuman,
}

/// Configuração da escada (WAIT tem mais paciência: páginas a carregar).
class LadderConfig {
  final int textAt;
  final int humanAt;
  final int waitTextAt;
  final int waitHumanAt;

  /// Orçamento total de correções por run (LoopGuard).
  final int runBudget;

  const LadderConfig({
    this.textAt = 3,
    this.humanAt = 5,
    this.waitTextAt = 5,
    this.waitHumanAt = 8,
    this.runBudget = 5,
  });
}

/// Assinatura de uma ação (op + alvo) — a chave de repetição.
String actionSignature({required String op, String target = ''}) =>
    '$op|${target.trim()}';

/// Decide o patamar da escada para esta assinatura (n = repetições já feitas).
LadderAction ladderCheck({
  required int repeats,
  required bool isWait,
  int correctionsUsed = 0,
  LadderConfig config = const LadderConfig(),
}) {
  if (correctionsUsed >= config.runBudget) return LadderAction.askHuman;
  final textAt = isWait ? config.waitTextAt : config.textAt;
  final humanAt = isWait ? config.waitHumanAt : config.humanAt;
  if (repeats >= humanAt) return LadderAction.askHuman;
  if (repeats >= textAt) return LadderAction.forceTextModel;
  return LadderAction.proceed;
}
