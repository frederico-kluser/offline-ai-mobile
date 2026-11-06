/// Léxicos de risco determinísticos — port de `core.DESTRUCTIVE`,
/// `core.SECRET_NAMES`, `RISKY_LABEL` e `BLOCK_RX` do desktop
/// (`agent/anonagent/core.py`, `agent/anonagent/autopilot.py`).
///
/// Zero LLM: o gate de ações irreversíveis e o muro de bloqueios decidem-se em
/// código. Léxicos PT+EN (o projeto é PT-BR/PT-PT).
library;

/// Léxico destrutivo PT/EN (`core.DESTRUCTIVE`) — só para ações que NÃO são
/// links (link = navegação GET): um clique destrutivo pede o gate fora de
/// banda mesmo que o modelo diga "reversível".
final RegExp kDestructive = RegExp(
    r'\b(create (?:(?:my|an?|your|new) )*account|criar (?:(?:minha|uma|a|sua) )*conta|sign ?up|submit|send|'
    r'enviar|pay|pagar|delete|excluir|publicar|publish|confirm|aceitar|transferir|comprar|buy|place order)\b',
    caseSensitive: false);

/// Rótulos de risco (`RISKY_LABEL`): SEMPRE passam pelo gate humano (o
/// `goal_allows` fica 0 — um rescue nunca autoriza a si próprio).
final RegExp kRiskyLabel = RegExp(
    r'cadastre|sign ?up|criar conta|registro|register|finalizar|pagar|pay\b|checkout|comprar|'
    r'buy\b|enviar pedido|submit order|delet|excluir|apagar|remove',
    caseSensitive: false);

/// Página de bloqueio/WAF (`BLOCK_RX`): curta e com estes sinais → não é
/// conteúdo, é muro. O agente nunca luta: humano (ou rotação de sessão).
final RegExp kBlockRx = RegExp(
    r'request blocked|403 error|403 forbidden|access denied|you have been blocked|'
    r'the request could not be satisfied|error 1020|attention required|forbidden',
    caseSensitive: false);

/// Um clique (não link) é destrutivo pelo rótulo/texto?
bool isDestructiveLabel(String? label, {bool isLink = false}) {
  if (isLink) return false;
  final s = label ?? '';
  return s.isNotEmpty && (kDestructive.hasMatch(s) || kRiskyLabel.hasMatch(s));
}

/// Página parece ser um bloqueio/WAF? (texto curto + regex de bloqueio).
bool looksBlocked(String pageText) {
  final t = pageText.trim();
  return t.length < 1200 && kBlockRx.hasMatch(t);
}
