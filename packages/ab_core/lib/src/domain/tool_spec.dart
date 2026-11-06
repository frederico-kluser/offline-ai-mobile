/// Contrato de ferramentas para o exemplo de tool calling do MiniCPM5-2B.
///
/// Determinismo por construção: argumentos são validados contra [ToolSpec]
/// ANTES de executar (o modelo é tratado como "sugestão", nunca como autoridade
/// — doc §17) e todo o ciclo é limitado pelo `LoopGuard`.
library;

import 'dart:convert';

/// Esquema de um parâmetro de ferramenta (subset de JSON Schema, suficiente
/// para validação rígida local).
class ParamSpec {
  final String name;

  /// `string` | `number` | `integer` | `boolean` | `enum`
  final String type;
  final String description;
  final bool required;

  /// Valores permitidos quando [type] == `enum`.
  final List<String>? enumValues;

  const ParamSpec({
    required this.name,
    required this.type,
    required this.description,
    this.required = true,
    this.enumValues,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'type': type,
        'description': description,
        'required': required,
        if (enumValues != null) 'enum': enumValues,
      };
}

/// Ferramenta disponível ao agente.
class ToolSpec {
  final String name;
  final String description;
  final List<ParamSpec> params;

  const ToolSpec({
    required this.name,
    required this.description,
    required this.params,
  });

  /// Assinatura canónica determinística (usada na deteção de ciclos).
  String get canonicalSig => params.map((p) => '${p.name}:${p.type}').join(',');

  Map<String, dynamic> toJson() => {
        'name': name,
        'description': description,
        'params': params.map((p) => p.toJson()).toList(),
      };
}

/// Um tool call emitido pelo modelo (pós-parse do formato XML do MiniCPM5).
class ToolCall {
  final String name;
  final Map<String, dynamic> args;

  /// Texto bruto de onde o call foi extraído (auditoria).
  final String raw;

  const ToolCall({required this.name, required this.args, this.raw = ''});

  /// Chave canónica determinística para deteção de ciclos: ferramenta +
  /// argumentos em JSON com chaves ordenadas.
  String get canonicalKey {
    final sorted = Map<String, dynamic>.fromEntries(
        args.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
    return '$name(${jsonEncode(sorted)})';
  }

  Map<String, dynamic> toJson() =>
      {'name': name, 'args': args, 'raw': raw};
}

/// Resultado de uma execução de ferramenta.
class ToolResult {
  final String name;
  final bool ok;
  final String output;
  final int durationMs;

  /// Motivo quando [ok] == false (ex.: `schema-invalid`, `tool-error`).
  final String? errorKind;

  const ToolResult({
    required this.name,
    required this.ok,
    required this.output,
    required this.durationMs,
    this.errorKind,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'ok': ok,
        'output': output,
        'duration_ms': durationMs,
        if (errorKind != null) 'error_kind': errorKind,
      };
}

/// Erro de validação de argumentos contra o [ToolSpec].
class ToolValidationError implements Exception {
  final String tool;
  final String message;
  const ToolValidationError(this.tool, this.message);

  @override
  String toString() => 'ToolValidationError($tool): $message';
}

/// Validação RÍGIDA de argumentos (guardrail anti-loop e anti-erro).
/// Lança [ToolValidationError] no primeiro problema — nunca "conserta" dados
/// do modelo às escondidas (determinismo > liberdade).
void validateToolArgs(ToolSpec spec, Map<String, dynamic> args) {
  final known = {for (final p in spec.params) p.name};
  for (final key in args.keys) {
    if (!known.contains(key)) {
      throw ToolValidationError(spec.name, 'parâmetro desconhecido: $key');
    }
  }
  for (final p in spec.params) {
    final v = args[p.name];
    if (v == null) {
      if (p.required) {
        throw ToolValidationError(spec.name, 'parâmetro obrigatório em falta: ${p.name}');
      }
      continue;
    }
    switch (p.type) {
      case 'string':
        if (v is! String) {
          throw ToolValidationError(spec.name, '${p.name} deve ser string');
        }
        if (p.enumValues != null && !p.enumValues!.contains(v)) {
          throw ToolValidationError(
              spec.name, '${p.name} fora do enum: $v');
        }
      case 'number':
        if (v is! num) {
          throw ToolValidationError(spec.name, '${p.name} deve ser number');
        }
      case 'integer':
        if (v is! int) {
          throw ToolValidationError(spec.name, '${p.name} deve ser integer');
        }
      case 'boolean':
        if (v is! bool) {
          throw ToolValidationError(spec.name, '${p.name} deve ser boolean');
        }
      case 'enum':
        if (p.enumValues == null || !p.enumValues!.contains(v)) {
          throw ToolValidationError(spec.name, '${p.name} fora do enum: $v');
        }
      default:
        throw ToolValidationError(spec.name, 'tipo de schema não suportado: ${p.type}');
    }
  }
}