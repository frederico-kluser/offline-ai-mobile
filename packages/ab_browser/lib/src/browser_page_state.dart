/// Estado observável da página do browser embutido — o "mapa" que alimenta o
/// piloto (Laya), o agente (MiniCPM5-2B) e o painel de elementos das teclas
/// flutuantes.
///
/// Princípio (dossiês de agentes web): representação COMPACTA e com refs
/// estáveis (`e1`, `e2`, …) para o modelo escolher alvos sem coordenadas.
library;

import 'dart:convert';

/// Um elemento interativo da página, com ref estável atribuída pela ponte JS.
class PageElement {
  /// Ref estável (`e3`) — âncora para [BrowserTap]/[BrowserType].
  final String ref;

  /// Tag DOM (`button`, `a`, `input`, `select`, …).
  final String tag;

  /// Papel acessível quando existe (`link`, `button`, `textbox`, …).
  final String role;

  /// Nome acessível / texto visível do elemento (rótulo curto).
  final String name;

  /// Valor atual (inputs) quando relevante.
  final String? value;

  /// Tipo do input (`text`, `email`, `submit`, …) quando aplicável.
  final String? inputType;

  /// Posição/tamanho NORMALIZADOS (0..1) do viewport — permite `tap_at`.
  final double x;
  final double y;
  final double w;
  final double h;

  const PageElement({
    required this.ref,
    required this.tag,
    required this.role,
    required this.name,
    this.value,
    this.inputType,
    this.x = 0,
    this.y = 0,
    this.w = 0,
    this.h = 0,
  });

  bool get isEditable =>
      tag == 'input' || tag == 'textarea' || tag == 'select' ||
      (tag == 'div' && role == 'textbox');

  factory PageElement.fromJson(Map<String, dynamic> json) => PageElement(
        ref: json['ref'] as String,
        tag: json['tag'] as String? ?? '',
        role: json['role'] as String? ?? '',
        name: json['name'] as String? ?? '',
        value: json['value'] as String?,
        inputType: json['input_type'] as String?,
        x: (json['x'] as num? ?? 0).toDouble(),
        y: (json['y'] as num? ?? 0).toDouble(),
        w: (json['w'] as num? ?? 0).toDouble(),
        h: (json['h'] as num? ?? 0).toDouble(),
      );

  Map<String, dynamic> toJson() => {
        'ref': ref,
        'tag': tag,
        'role': role,
        'name': name,
        if (value != null) 'value': value,
        if (inputType != null) 'input_type': inputType,
        'x': x,
        'y': y,
        'w': w,
        'h': h,
      };

  /// Linha compacta para prompts: `e3 button "Enviar"`.
  String toCompactLine() {
    final label = role.isNotEmpty ? role : tag;
    final buf = StringBuffer('$ref $label "$name"');
    if (value != null && value!.isNotEmpty) buf.write(' value="$value"');
    return buf.toString();
  }
}

/// Mapa da página capturado pela ponte JS (`window.__oai.snapshot()`).
class PageSnapshot {
  final String url;
  final String title;

  /// Texto visível resumido (truncado pela ponte).
  final String text;

  final List<PageElement> elements;
  final bool truncated;
  final int capturedAtMs;

  /// Identidade do documento (`docId` da ponte) — ações de outro doc são
  /// rejeitadas (`stale-doc`).
  final String docId;

  /// Época do DOM no momento do snapshot (`refEpoch`) — deteta refs caducadas.
  final int refEpoch;

  const PageSnapshot({
    required this.url,
    required this.title,
    required this.text,
    required this.elements,
    this.truncated = false,
    this.capturedAtMs = 0,
    this.docId = '',
    this.refEpoch = 0,
  });

  factory PageSnapshot.fromJson(Map<String, dynamic> json) => PageSnapshot(
        url: json['url'] as String? ?? '',
        title: json['title'] as String? ?? '',
        text: json['text'] as String? ?? '',
        elements: [
          for (final e in (json['elements'] as List? ?? const []))
            PageElement.fromJson(Map<String, dynamic>.from(e as Map)),
        ],
        truncated: json['truncated'] as bool? ?? false,
        capturedAtMs: (json['captured_at_ms'] as num? ?? 0).toInt(),
        docId: json['doc_id'] as String? ?? '',
        refEpoch: (json['ref_epoch'] as num? ?? 0).toInt(),
      );

  Map<String, dynamic> toJson() => {
        'url': url,
        'title': title,
        'text': text,
        'elements': [for (final e in elements) e.toJson()],
        'truncated': truncated,
        'captured_at_ms': capturedAtMs,
        'doc_id': docId,
        'ref_epoch': refEpoch,
      };

  String encode() => jsonEncode(toJson());

  static PageSnapshot decode(String source) =>
      PageSnapshot.fromJson(Map<String, dynamic>.from(jsonDecode(source) as Map));

  /// Resumo prosa compacto para o `state` do Laya / contexto do LLM.
  String toCompactText({int maxElements = 20, int maxTextChars = 600}) {
    final buf = StringBuffer()
      ..writeln('URL: $url')
      ..writeln('Título: $title');
    final shown = elements.take(maxElements).toList();
    if (shown.isNotEmpty) {
      buf.writeln('Elementos:');
      for (final e in shown) {
        buf.writeln('- ${e.toCompactLine()}');
      }
      if (elements.length > shown.length) {
        buf.writeln('- … +${elements.length - shown.length} elementos');
      }
    }
    var t = text.trim();
    if (t.length > maxTextChars) {
      t = '${t.substring(0, maxTextChars)}… [texto truncado]';
    }
    if (t.isNotEmpty) buf.writeln('Texto: $t');
    return buf.toString().trim();
  }
}
