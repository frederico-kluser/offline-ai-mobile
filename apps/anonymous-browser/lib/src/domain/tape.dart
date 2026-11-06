/// Tape de auditoria — port do `tape.jsonl`/`steps.jsonl` do desktop.
///
/// Toda observação, chamada de LLM (request exato) e ação fica gravada,
/// MASCARADA pelo [SecretScrubber] (segredos nunca em claro). Formato: JSONL,
/// uma entrada por linha: `{"t": ISO8601, "type": ..., ...}`.
library;

import 'dart:convert';

import '../autopilot/masking.dart';

/// Tipos de entrada do tape (estáveis).
class TapeType {
  static const view = 'view';
  static const decision = 'decision';
  static const llm = 'llm';
  static const action = 'action';
  static const note = 'note';
  static const handoff = 'handoff';
  static const end = 'end';
}

class Tape {
  final SecretScrubber scrubber;
  final List<Map<String, dynamic>> entries = [];

  Tape({SecretScrubber? scrubber}) : scrubber = scrubber ?? SecretScrubber();

  /// Grava uma entrada (tudo passa pela máscara de segredos).
  void record(String type, Map<String, dynamic> data) {
    final masked = scrubber.scrub({
      't': DateTime.now().toIso8601String(),
      'type': type,
      ...data,
    }) as Map;
    entries.add(Map<String, dynamic>.from(masked));
  }

  /// Registo de decisão (contrato do desktop: quem/conf/op/alvo/porquê/ok/efeito).
  void decision({
    required String who,
    required double conf,
    required String op,
    String targetId = '',
    String reason = '',
    bool? ok,
    String effect = '',
    double? costUsd,
    int? llmMs,
  }) {
    record(TapeType.decision, {
      'who': who,
      'conf': conf,
      'op': op,
      'target_id': targetId,
      'reason': reason,
      'ok': ?ok,
      'effect': effect,
      'cost_usd': ?costUsd,
      'llm_ms': ?llmMs,
    });
  }

  /// Chamada de LLM (o request EXATO: state+questions ou system+user).
  void llmCall({
    required String model,
    required String kind,
    required Map<String, dynamic> request,
    Map<String, dynamic>? response,
    int? ms,
    double? costUsd,
  }) {
    record(TapeType.llm, {
      'model': model,
      'call': kind,
      'request': request,
      'response': ?response,
      'ms': ?ms,
      'cost_usd': ?costUsd,
    });
  }

  /// Serializa o tape inteiro em JSONL.
  String toJsonl() =>
      entries.map((e) => jsonEncode(e)).join('\n') + (entries.isEmpty ? '' : '\n');

  /// Serializa como lista JSON (para persistência da run).
  List<Map<String, dynamic>> toJson() => entries;
}
