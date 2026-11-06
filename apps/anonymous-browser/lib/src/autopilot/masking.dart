/// Higiene de dados: segredos NUNCA saem em claro — port do `scrubber`/`slug`/
/// `SECRET_NAMES` do desktop (`agent/anonagent/core.py`).
///
/// Duas camadas:
///  1. [SecretScrubber] — substitui formas cru/URL-encoded/JSON/HTML-escaped
///     dos valores secretos por `{{nome}}`, recursivamente em mapas/listas;
///  2. [resolveParams] — resolve placeholders `{{email}}`, `{{password}}`,
///     `{{code}}`, `{{var}}` no texto a digitar com os valores da missão
///     (camada de confiança). O MODELO escreve placeholders, nunca valores.
library;

import 'dart:convert';

/// Nomes de campos que carregam segredos (port de `core.SECRET_NAMES`):
/// 'pin' só como palavra, nunca dentro de 'shipping'/'spinner'.
final RegExp kSecretNames = RegExp(
    r'pass|pwd|secret|token|otp|(?<![a-z])pin(?![a-z])|senha|ticket|api_?key',
    caseSensitive: false);

/// `•••` — o valor de senha nunca aparece em observações (contrato do view.js).
const String kPasswordMask = '•••';

/// Substituidor recursivo de valores secretos por `{{nome}}`.
class SecretScrubber {
  /// valor em claro → nome do placeholder (ex.: senha → `password_field`).
  final Map<String, String> _byValue = {};

  SecretScrubber();

  /// Regista um valor secreto (o valor fica AQUI e nunca em logs/tape).
  void register(String value, String name) {
    if (value.length >= 4) _byValue[value] = name;
  }

  bool get isEmpty => _byValue.isEmpty;

  /// Formas alternativas de cada valor (URL-encoded, escapes JSON/HTML).
  Iterable<String> _forms(String v) sync* {
    yield v;
    final enc = Uri.encodeComponent(v);
    if (enc != v) yield enc;
    final json = jsonEncode(v); // "..." com escapes
    yield json.substring(1, json.length - 1);
    yield v
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
  }

  /// Embrulha um objeto (String/Map/List) com os valores mascarados.
  dynamic scrub(dynamic obj) {
    if (isEmpty) return obj;
    if (obj is String) {
      var s = obj;
      for (final e in _byValue.entries) {
        for (final form in _forms(e.key)) {
          if (form.isEmpty) continue;
          s = s.replaceAll(form, '{{${e.value}}}');
        }
      }
      return s;
    }
    if (obj is Map) {
      return {for (final e in obj.entries) e.key: scrub(e.value)};
    }
    if (obj is List) return [for (final v in obj) scrub(v)];
    return obj;
  }

  String scrubText(String s) => scrub(s) as String;
}

/// Resolve `{{nome}}` num texto com os valores da missão (camada de
/// confiança). Placeholders desconhecidos ficam intactos (o gate/humano decide).
String resolveParams(String text, Map<String, String> variables) {
  var s = text;
  for (final e in variables.entries) {
    s = s.replaceAll('{{${e.key}}}', e.value);
  }
  return s;
}

/// Os placeholders que um texto ainda contém (para saber o que falta resolver).
List<String> pendingParams(String text, Map<String, String> variables) {
  final rx = RegExp(r'\{\{([a-z_][a-z0-9_]*)\}\}', caseSensitive: false);
  return [
    for (final m in rx.allMatches(text))
      if (!variables.containsKey(m.group(1)!)) m.group(1)!
  ];
}

/// Mascara um valor para apresentação em UI: só os últimos 4 chars.
String maskForDisplay(String value) {
  if (value.length <= 4) return kPasswordMask;
  return '$kPasswordMask${value.substring(value.length - 4)}';
}
