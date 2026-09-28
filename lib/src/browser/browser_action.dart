/// Vocabulário de ações do browser embutido (espelha o design de controlo do
/// projeto `anonymous-browser`: um decisor escolhe UMA ação por passo, num
/// vocabulário fechado e tipado).
///
/// Três produtores partilham o MESMO vocabulário e o mesmo barramento:
///   1. o humano — pelas "teclas flutuantes" da UI;
///   2. o Laya — decisões tipadas (`choice`) sobre os candidatos do passo;
///   3. o MiniCPM5-2B — tool calling (`browser_*`) no [ToolLoop].
///
/// Determinismo por construção: cada ação serializa para JSON com chaves
/// estáveis ([canonicalKey] para deteção de ciclos) e é validada pelo
/// [BrowserController] antes de tocar na página.
library;

import 'dart:convert';

/// Ação abstrata do browser. `kind` é o nome de wire (estável).
sealed class BrowserAction {
  const BrowserAction();

  String get kind;

  /// Chave canónica determinística (para ciclos e para o histórico do piloto).
  String get canonicalKey;

  Map<String, dynamic> toJson();

  /// Serializa para o payload do protocolo `window.__oai.act(...)`.
  String encode() => jsonEncode(toJson());

  factory BrowserAction.fromJson(Map<String, dynamic> json) {
    final kind = json['kind'] as String?;
    return switch (kind) {
      'navigate' => BrowserNavigate(json['url'] as String),
      'back' => const BrowserBack(),
      'forward' => const BrowserForward(),
      'reload' => const BrowserReload(),
      'tap' => BrowserTap(json['ref'] as String),
      'tap_at' => BrowserTapAt(
          (json['x'] as num).toDouble(), (json['y'] as num).toDouble()),
      'type' => BrowserType(
          ref: json['ref'] as String? ?? '',
          text: json['text'] as String? ?? '',
          submit: json['submit'] as bool? ?? false,
        ),
      'scroll' => BrowserScroll(
          (json['dx'] as num? ?? 0).toDouble(),
          (json['dy'] as num? ?? 0).toDouble(),
        ),
      'select' =>
        BrowserSelect(json['ref'] as String, json['value'] as String? ?? ''),
      'snapshot' => const BrowserSnapshot(),
      'extract' => const BrowserExtract(),
      'eval' => BrowserEval(json['code'] as String? ?? ''),
      'stop' => const BrowserStop(),
      _ => throw FormatException('ação de browser desconhecida: $kind'),
    };
  }
}

/// Navega para um URL (http/https/about:). A normalização é do controlador.
class BrowserNavigate extends BrowserAction {
  final String url;

  const BrowserNavigate(this.url);

  @override
  String get kind => 'navigate';

  @override
  String get canonicalKey => 'navigate($url)';

  @override
  Map<String, dynamic> toJson() => {'kind': kind, 'url': url};
}

class BrowserBack extends BrowserAction {
  const BrowserBack();

  @override
  String get kind => 'back';

  @override
  String get canonicalKey => 'back';

  @override
  Map<String, dynamic> toJson() => {'kind': kind};
}

class BrowserForward extends BrowserAction {
  const BrowserForward();

  @override
  String get kind => 'forward';

  @override
  String get canonicalKey => 'forward';

  @override
  Map<String, dynamic> toJson() => {'kind': kind};
}

class BrowserReload extends BrowserAction {
  const BrowserReload();

  @override
  String get kind => 'reload';

  @override
  String get canonicalKey => 'reload';

  @override
  Map<String, dynamic> toJson() => {'kind': kind};
}

/// Clica no elemento com a ref estável atribuída pelo snapshot
/// (`data-oai-ref`, ex.: `e3`).
class BrowserTap extends BrowserAction {
  final String ref;

  const BrowserTap(this.ref);

  @override
  String get kind => 'tap';

  @override
  String get canonicalKey => 'tap($ref)';

  @override
  Map<String, dynamic> toJson() => {'kind': kind, 'ref': ref};
}

/// Clica em coordenadas NORMALIZADAS (0..1) do viewport — caminho do humano
/// (toque direto na página quando o modo "clicar" está ativo).
class BrowserTapAt extends BrowserAction {
  final double x;
  final double y;

  const BrowserTapAt(this.x, this.y);

  @override
  String get kind => 'tap_at';

  @override
  String get canonicalKey =>
      'tap_at(${x.toStringAsFixed(3)},${y.toStringAsFixed(3)})';

  @override
  Map<String, dynamic> toJson() =>
      {'kind': kind, 'x': x, 'y': y};
}

/// Escreve texto no campo `ref` (value + eventos `input`/`change` nativos,
/// para frameworks reativos). `submit: true` envia o formulário (Enter).
class BrowserType extends BrowserAction {
  final String ref;
  final String text;
  final bool submit;

  const BrowserType({
    required this.ref,
    required this.text,
    this.submit = false,
  });

  @override
  String get kind => 'type';

  @override
  String get canonicalKey => 'type($ref,${submit ? 'submit' : 'nosubmit'})';

  @override
  Map<String, dynamic> toJson() =>
      {'kind': kind, 'ref': ref, 'text': text, 'submit': submit};
}

/// Rola a janela por frações do viewport (dy>0 desce).
class BrowserScroll extends BrowserAction {
  final double dx;
  final double dy;

  const BrowserScroll(this.dx, this.dy);

  @override
  String get kind => 'scroll';

  @override
  String get canonicalKey =>
      'scroll(${dx.toStringAsFixed(2)},${dy.toStringAsFixed(2)})';

  @override
  Map<String, dynamic> toJson() => {'kind': kind, 'dx': dx, 'dy': dy};
}

/// Seleciona uma opção de um `<select>` (por valor ou texto da opção).
class BrowserSelect extends BrowserAction {
  final String ref;
  final String value;

  const BrowserSelect(this.ref, this.value);

  @override
  String get kind => 'select';

  @override
  String get canonicalKey => 'select($ref,$value)';

  @override
  Map<String, dynamic> toJson() => {'kind': kind, 'ref': ref, 'value': value};
}

/// Captura o mapa da página (URL, título, texto, elementos interativos).
class BrowserSnapshot extends BrowserAction {
  const BrowserSnapshot();

  @override
  String get kind => 'snapshot';

  @override
  String get canonicalKey => 'snapshot';

  @override
  Map<String, dynamic> toJson() => {'kind': kind};
}

/// Extrai o texto principal da página (heurística de conteúdo, sem boilerplate).
class BrowserExtract extends BrowserAction {
  const BrowserExtract();

  @override
  String get kind => 'extract';

  @override
  String get canonicalKey => 'extract';

  @override
  Map<String, dynamic> toJson() => {'kind': kind};
}

/// Escape hatch: JS arbitrário. Só o humano dispara (o piloto/Laya e o LLM
/// NÃO recebem esta ação nos seus vocabulários).
class BrowserEval extends BrowserAction {
  final String code;

  const BrowserEval(this.code);

  @override
  String get kind => 'eval';

  @override
  String get canonicalKey => 'eval';

  @override
  Map<String, dynamic> toJson() => {'kind': kind, 'code': code};
}

/// Pede a paragem do agente em curso (handoff para o humano).
class BrowserStop extends BrowserAction {
  const BrowserStop();

  @override
  String get kind => 'stop';

  @override
  String get canonicalKey => 'stop';

  @override
  Map<String, dynamic> toJson() => {'kind': kind};
}

/// Vocabulário do piloto/LLM (SEM `eval` nem `stop` — `stop` é transversal).
const List<String> kAgentActionKinds = [
  'navigate',
  'back',
  'forward',
  'reload',
  'tap',
  'tap_at',
  'type',
  'scroll',
  'select',
  'snapshot',
  'extract',
];
