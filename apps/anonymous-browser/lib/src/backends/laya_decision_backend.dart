/// Backend de decisão Laya local — o "System One" tipado do telemóvel
/// (`convaiinnovations/laya-typed-decisions`, ONNX via ab_core).
///
/// Adapta o MESMO contrato de perguntas do Jev (`choice`/`noul` wire) ao
/// [LayaRequest] do ab_core e devolve o envelope `DecisionAnswers` idêntico.
/// Sem rede: decisões 100% no aparelho. ⚠️ Limiares próprios (os do Jev não
/// transferem — doc §9 do Laya).
library;

import 'dart:convert';

import 'package:ab_core/ab_core.dart';

import 'decision_backend.dart';

/// Converte o `state` (mapa desktop) em prosa enxuta para o encoder do Laya.
String stateToProse(Map<String, dynamic> state) {
  final buf = StringBuffer();
  void add(String key, [String? label]) {
    final v = state[key];
    if (v == null) return;
    final text = v is List
        ? v.map((e) => '$e').join(' · ')
        : v is Map
            ? jsonEncode(v)
            : '$v';
    if (text.trim().isEmpty || text == 'null') return;
    buf.writeln('${label ?? key}: $text');
  }

  add('goal', 'Objetivo');
  add('url', 'URL');
  add('title', 'Título');
  add('page_text', 'Texto da página');
  add('clickable', 'Elementos clicáveis');
  add('fields', 'Campos');
  add('select_options', 'Selects');
  add('historico_curto', 'Histórico');
  add('last_change', 'Última mudança');
  add('outputs_status', 'Saídas');
  add('already_tried_without_result', 'Já tentado sem resultado');
  add('user_guidance', 'Orientação do utilizador');
  return buf.toString().trim();
}

/// Backend de decisão sobre o motor Laya local (ab_core).
class LayaLocalDecisionBackend implements DecisionBackend {
  final LayaEngine engine;

  /// Nome do checkpoint (`typed-decisions` por defeito).
  final String model;

  final void Function(Map<String, dynamic> request, Map<String, dynamic>? response,
      {int ms, double costUsd})? onTrace;

  LayaLocalDecisionBackend({
    required this.engine,
    this.model = 'typed-decisions',
    this.onTrace,
  });

  @override
  String get name => 'laya-local';

  @override
  Future<DecisionAnswers> ask({
    required Map<String, dynamic> state,
    required Map<String, dynamic> questions,
  }) async {
    final typed = <TypedQuestion>[];
    for (final e in questions.entries) {
      final q = Map<String, dynamic>.from(e.value as Map);
      final type = q['type'] as String? ?? 'choice';
      final instructions = q['instructions'];
      final instr = instructions is Map
          ? instructions.entries.map((x) => '${x.key}: ${x.value}').join('\n')
          : '$instructions';
      final criteria = (q['criteria'] as Map?)?.cast<String, dynamic>() ?? const {};
      switch (type) {
        case 'noul':
          typed.add(NoulQuestion(
            id: e.key,
            instructions: instr,
            trueCriteria: '${criteria['true'] ?? 'sim'}',
            falseCriteria: '${criteria['false'] ?? 'não'}',
          ));
        case 'score':
          typed.add(ScoreQuestion(
            id: e.key,
            instructions: instr,
            levels: [for (final v in criteria.values) '$v'],
          ));
        default:
          typed.add(ChoiceQuestion(
            id: e.key,
            instructions: instr,
            criteria: {for (final c in criteria.entries) c.key: '${c.value}'},
          ));
      }
    }
    final request = LayaRequest(
      state: stateToProse(state),
      questions: typed,
      model: model,
    );
    final sw = Stopwatch()..start();
    LayaResponse resp;
    try {
      resp = await engine.decide(request);
    } catch (e) {
      throw DecisionException('laya: $e');
    }
    sw.stop();
    final answers = <String, TypedDecision>{};
    for (final e in resp.answers.entries) {
      final a = e.value;
      if (a is ChoiceAnswer) {
        answers[e.key] = TypedDecision(
          id: e.key,
          kind: 'choice',
          choice: a.choice,
          confidence: a.answerConfidence,
          probabilities: a.probabilities,
        );
      } else if (a is NoulAnswer) {
        answers[e.key] = TypedDecision(
          id: e.key,
          kind: 'noul',
          noul: a.pTrue,
          confidence: a.answerConfidence,
          probabilities: a.probabilities,
        );
      } else if (a is ScoreAnswer) {
        answers[e.key] = TypedDecision(
          id: e.key,
          kind: 'score',
          confidence: a.answerConfidence,
          probabilities: a.probabilities,
        );
      }
    }
    onTrace?.call({'model': model, 'state': state, 'questions': questions},
        resp.toJson(),
        ms: sw.elapsedMilliseconds);
    return DecisionAnswers(
      answers: answers,
      ms: resp.latencyMs == 0 ? sw.elapsedMilliseconds : resp.latencyMs,
      costUsd: 0,
      backend: name,
    );
  }
}
