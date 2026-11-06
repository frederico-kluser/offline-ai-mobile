/// Vocabulário FECHADO de operações de decisão — port mobile do `OPS` do
/// `agent/anonagent/autopilot.py` (desktop `anonymous-browser`).
///
/// O decisor (Jev online ou Laya local) escolhe exatamente UMA destas
/// operações por passo; o alvo vem sempre por ref estável (`e1..eN`) nunca por
/// seletor. Conjunto fechado = validação determinística + auditoria.
///
/// Diferenças face ao desktop (dossiê `pesquisas/2026-09-27-browser-embutido/
/// frentes/00-arquitetura-anonymous-browser.md` §5.2): `CLOSE_TAB` cai
/// (WebView mobile: 0-1 abas) e `CHECK_EMAIL` cai (sem caixa descartável na
/// app v1). `LOOK_AGAIN` não existe — o desktop também o removeu (abstenções
/// custavam um fallback completo e a vista vazia é tratada em código).
library;

/// As operações de decisão, na ordem do menu.
enum Op {
  click('CLICK', 'Click one listed element to advance the goal (navigation or open a control).'),
  typeText('TYPE_TEXT', 'Type into one listed field. The text to type is written by the text model or given by the goal.'),
  pressEnter('PRESS_ENTER', 'Press Enter in the field just filled (when no submit button is visible).'),
  scrollDown('SCROLL_DOWN', 'Scroll down: the needed element or evidence is probably below.'),
  scrollUp('SCROLL_UP', 'Scroll up: the needed element is above.'),
  select('SELECT', 'Choose an option in a dropdown (select).'),
  goBack('GO_BACK', 'Go back in history: this page is the wrong part of the site.'),
  wait('WAIT', 'Wait: page is loading, redirecting or a check is running.'),
  done('DONE', 'The GOAL is fully satisfied by what is visible now; outputs are complete.'),
  blocked('BLOCKED', 'No listed action can advance the goal; a human is needed.');

  const Op(this.wire, this.criteria);

  /// Nome de fio (estável, igual ao desktop).
  final String wire;

  /// Critério (descrição) que vai para o modelo — inglês, como no desktop.
  final String criteria;

  static Op? fromWire(String s) {
    for (final o in Op.values) {
      if (o.wire == s) return o;
    }
    return null;
  }
}

/// Pergunta tipada `choice` de alvo: sempre com a opção `none` (o modelo pode
/// abstiver-se do alvo — nunca inventa refs).
const String kNoneTarget = 'none';

/// Texto do `none` nos alvos (equivalente a `jevtargets.NONE_TEXT` do desktop).
const String kNoneTargetText = 'no listed element fits this operation right now';

/// Mapeamento operação → pergunta de alvo correspondente.
const Map<Op, String> kTargetQuestionOf = {
  Op.click: 'click_target',
  Op.typeText: 'type_text_target',
  Op.select: 'select_target',
};
