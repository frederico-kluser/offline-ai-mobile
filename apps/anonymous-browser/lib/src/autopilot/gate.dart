/// Gate de segurança fora de banda — port de `gated()` do desktop
/// (`agent/anonagent/autopilot.py`) e da semântica de `gate.py`.
///
/// Princípio inegociável: **o objetivo do utilizador é a autorização**. Uma
/// ação irreversível passa SEM confirmação quando o objetivo a pede
/// explicitamente (`goal_allows ≥ 0.7`); caso contrário o humano confirma.
/// No mobile o gate é um diálogo nativo — mesma semântica: **fora de banda,
/// sem auto-aprovação, timeout = NEGADO**.
library;

import 'risk_lexicon.dart';

/// Configuração de limiares (recalibráveis; os do Jev não transferem para o
/// Laya — ver `TypedAnswer` em ab_core).
class GateThresholds {
  /// Noul `irreversible` acima disto → arriscada.
  final double irreversible;

  /// Noul `goal_allows` ≥ disto → autorizada pelo objetivo.
  final double goalAllows;

  const GateThresholds({this.irreversible = 0.6, this.goalAllows = 0.7});
}

/// O que fazer com a ação escolhida.
enum GateVerdict {
  /// Pode executar sem confirmação.
  allow,

  /// Ação irreversível NÃO autorizada → confirmação humana (ou negada).
  needsHuman,

  /// O humano já confirmou ESTA assinatura de ação (replay da confirmação).
  confirmed,
}

class GateResult {
  final GateVerdict verdict;
  final bool codeRisky;
  final String why;

  const GateResult({
    required this.verdict,
    required this.codeRisky,
    required this.why,
  });
}

/// Avalia uma ação candidata (port de `gated()`).
///
/// [irreversible] = noul do decisor; [goalAllows] = noul do decisor;
/// [label]/[role] = rótulo/papel do alvo escolhido (na página);
/// [confirmedSignature] = assinatura já confirmada pelo humano (ou null).
GateResult evaluateGate({
  required double irreversible,
  required double goalAllows,
  String label = '',
  String role = '',
  String? confirmedSignature,
  required String actionSignature,
  GateThresholds thresholds = const GateThresholds(),
}) {
  final isLink = role == 'link';
  // code_risky do desktop: rótulo casa léxico (só não-links) OU noul ≈ 1.
  final codeRisky =
      isDestructiveLabel(label, isLink: isLink) || irreversible >= 0.999;
  // risky: noul > 0.6 OU léxico destrutivo em não-link.
  final risky = irreversible > thresholds.irreversible || codeRisky;
  if (!risky) {
    return GateResult(
      verdict: GateVerdict.allow,
      codeRisky: codeRisky,
      why: '',
    );
  }
  if (goalAllows >= thresholds.goalAllows) {
    return GateResult(
      verdict: GateVerdict.allow,
      codeRisky: codeRisky,
      why: 'ação irreversível autorizada pelo objetivo '
          '(goal_allows=${goalAllows.toStringAsFixed(2)})',
    );
  }
  if (confirmedSignature != null && confirmedSignature == actionSignature) {
    return GateResult(
      verdict: GateVerdict.confirmed,
      codeRisky: codeRisky,
      why: 'confirmação humana anterior para esta ação',
    );
  }
  return GateResult(
    verdict: GateVerdict.needsHuman,
    codeRisky: codeRisky,
    why: codeRisky
        ? 'rótulo destrutivo "$label" sem autorização do objetivo — '
            'gate humano (timeout = negado)'
        : 'ação irreversível (noul=${irreversible.toStringAsFixed(2)}) '
            'não autorizada pelo objetivo — gate humano (timeout = negado)',
  );
}
