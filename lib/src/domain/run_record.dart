/// Registo determinístico de execuções (testes de prompts).
///
/// Cada execução fica assinada por hash do (modelo + prompt + parâmetros) —
/// mesma assinatura ⇒ saída esperada igual. É a base do modo "mais
/// determinismo que liberdade": nada de execuções anónimas.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// SHA-256 compacto via `crypto` — usado como fingerprint de execução.
String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

/// Assinatura canónica de uma execução de prompt.
String runSignature({
  required String modelId,
  required String prompt,
  required Map<String, dynamic> params,
  String? systemPrompt,
}) {
  final sorted = Map<String, dynamic>.fromEntries(
      params.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
  final payload = jsonEncode({
    'model': modelId,
    'system': systemPrompt ?? '',
    'prompt': prompt,
    'params': sorted,
  });
  return sha256Hex(utf8.encode(payload)).substring(0, 16);
}

class RunRecord {
  final String id;
  final DateTime startedAt;
  final String kind; // 'llm' | 'laya' | 'tool-loop'
  final String modelId;
  final String prompt;
  final String? systemPrompt;
  final Map<String, dynamic> params;
  final String output;
  final int promptTokens;
  final int outputTokens;
  final int latencyMs;
  final String signature;

  /// Motivo de paragem explícito (guardrails) — nunca implícito.
  final String? stopReason;

  const RunRecord({
    required this.id,
    required this.startedAt,
    required this.kind,
    required this.modelId,
    required this.prompt,
    this.systemPrompt,
    required this.params,
    required this.output,
    required this.promptTokens,
    required this.outputTokens,
    required this.latencyMs,
    required this.signature,
    this.stopReason,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'started_at': startedAt.toUtc().toIso8601String(),
        'kind': kind,
        'model_id': modelId,
        'prompt': prompt,
        if (systemPrompt != null) 'system_prompt': systemPrompt,
        'params': params,
        'output': output,
        'prompt_tokens': promptTokens,
        'output_tokens': outputTokens,
        'latency_ms': latencyMs,
        'signature': signature,
        if (stopReason != null) 'stop_reason': stopReason,
      };

  factory RunRecord.fromJson(Map<String, dynamic> j) => RunRecord(
        id: j['id'] as String,
        startedAt: DateTime.parse(j['started_at'] as String),
        kind: j['kind'] as String,
        modelId: j['model_id'] as String,
        prompt: j['prompt'] as String,
        systemPrompt: j['system_prompt'] as String?,
        params: Map<String, dynamic>.from(j['params'] as Map),
        output: j['output'] as String,
        promptTokens: (j['prompt_tokens'] as num).toInt(),
        outputTokens: (j['output_tokens'] as num).toInt(),
        latencyMs: (j['latency_ms'] as num).toInt(),
        signature: j['signature'] as String,
        stopReason: j['stop_reason'] as String?,
      );
}

/// Comparação determinística de duas execuções (para regressão golden).
class RunDiff {
  final String signatureA;
  final String signatureB;
  final bool identicalOutput;
  final String? firstDivergence;

  const RunDiff({
    required this.signatureA,
    required this.signatureB,
    required this.identicalOutput,
    this.firstDivergence,
  });
}

RunDiff diffRuns(RunRecord a, RunRecord b) {
  final identical = a.output == b.output;
  String? divergence;
  if (!identical) {
    final n = a.output.length < b.output.length
        ? a.output.length
        : b.output.length;
    var i = 0;
    while (i < n && a.output[i] == b.output[i]) {
      i++;
    }
    divergence =
        'offset $i: "${_clip(a.output, i)}" ≠ "${_clip(b.output, i)}"';
  }
  return RunDiff(
    signatureA: a.signature,
    signatureB: b.signature,
    identicalOutput: identical,
    firstDivergence: divergence,
  );
}

String _clip(String s, int at) {
  final start = at > 20 ? at - 20 : 0;
  final end = (at + 20 < s.length) ? at + 20 : s.length;
  return s.substring(start, end);
}