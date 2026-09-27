/// Tela 2 — Laya: templates de decisões tipadas, state editável, perguntas
/// editáveis (instruções + critérios), decisão com respostas tipadas
/// (probabilidades, confidence, answer_confidence, act_probability), JSON e
/// configuração do motor numa bottom sheet.
library;

import 'package:flutter/material.dart';

import '../domain/laya_types.dart';
import '../domain/templates.dart';
import '../services/store.dart';
import 'app_services.dart';
import 'common.dart';
import 'config_sheets.dart';

/// Rascunho editável de uma pergunta tipada (texto puro).
class QDraft {
  QDraft({
    required this.id,
    required this.type,
    required this.instructions,
    this.trueCriteria = 'sim',
    this.falseCriteria = 'não',
    this.criteriaText = '',
  });

  final String id;
  final QType type;
  String instructions;
  String trueCriteria;
  String falseCriteria;

  /// choice: linhas `nome: descrição`; score: um nível por linha.
  String criteriaText;

  factory QDraft.fromQuestion(TypedQuestion q) => switch (q) {
        NoulQuestion(
          :final id,
          :final instructions,
          :final trueCriteria,
          :final falseCriteria
        ) =>
          QDraft(
            id: id,
            type: QType.noul,
            instructions: instructions,
            trueCriteria: trueCriteria,
            falseCriteria: falseCriteria,
          ),
        ChoiceQuestion(:final id, :final instructions, :final criteria) =>
          QDraft(
            id: id,
            type: QType.choice,
            instructions: instructions,
            criteriaText:
                criteria.entries.map((e) => '${e.key}: ${e.value}').join('\n'),
          ),
        ScoreQuestion(:final id, :final instructions, :final levels) => QDraft(
            id: id,
            type: QType.score,
            instructions: instructions,
            criteriaText: levels.join('\n'),
          ),
      };

  TypedQuestion build() => switch (type) {
        QType.noul => NoulQuestion(
            id: id,
            instructions: instructions,
            trueCriteria:
                trueCriteria.trim().isEmpty ? 'sim' : trueCriteria.trim(),
            falseCriteria:
                falseCriteria.trim().isEmpty ? 'não' : falseCriteria.trim(),
          ),
        QType.choice => ChoiceQuestion(
            id: id,
            instructions: instructions,
            criteria: _parseChoiceCriteria(criteriaText),
          ),
        QType.score => ScoreQuestion(
            id: id,
            instructions: instructions,
            levels: [
              for (final l in criteriaText.split('\n'))
                if (l.trim().isNotEmpty) l.trim(),
            ],
          ),
      };

  static Map<String, String> _parseChoiceCriteria(String text) {
    final map = <String, String>{};
    for (final line in text.split('\n')) {
      final t = line.trim();
      if (t.isEmpty) continue;
      final i = t.indexOf(':');
      if (i <= 0) {
        map[t] = '';
      } else {
        map[t.substring(0, i).trim()] = t.substring(i + 1).trim();
      }
    }
    return map;
  }
}

class LayaTab extends StatefulWidget {
  const LayaTab({super.key, required this.store});

  final AppStore store;

  @override
  State<LayaTab> createState() => _LayaTabState();
}

class _LayaTabState extends State<LayaTab> {
  late String _templateId;
  late final TextEditingController _stateCtrl;
  late List<QDraft> _drafts;
  LayaResponse? _response;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    final template = _initialTemplate();
    _templateId = template.id;
    final savedState = widget.store.layaState;
    _stateCtrl = TextEditingController(
        text: savedState.trim().isEmpty ? template.stateExample : savedState);
    _drafts = [for (final q in template.questions) QDraft.fromQuestion(q)];
    _syncSharedQuestions();
  }

  @override
  void dispose() {
    _stateCtrl.dispose();
    super.dispose();
  }

  LayaTemplate _initialTemplate() {
    final id = widget.store.selectedTemplateId;
    for (final t in kLayaTemplates) {
      if (t.id == id) return t;
    }
    return kLayaTemplates.first;
  }

  LayaTemplate get _template {
    for (final t in kLayaTemplates) {
      if (t.id == _templateId) return t;
    }
    return kLayaTemplates.first;
  }

  void _syncSharedQuestions() {
    AppServices.instance.layaQuestions = [
      for (final d in _drafts) d.build(),
    ];
  }

  void _onTemplateChanged(String? id) {
    if (id == null) return;
    final template = kLayaTemplates.firstWhere(
      (t) => t.id == id,
      orElse: () => kLayaTemplates.first,
    );
    setState(() {
      _templateId = template.id;
      _drafts = [for (final q in template.questions) QDraft.fromQuestion(q)];
      _stateCtrl.text = template.stateExample;
      _response = null;
    });
    _syncSharedQuestions();
    widget.store.saveSelectedTemplateId(template.id);
  }

  Future<void> _decide() async {
    if (_running) return;
    final state = _stateCtrl.text.trim();
    if (state.isEmpty) {
      showSnack(context, 'Escreve um state antes de decidir.', error: true);
      return;
    }
    final questions = [for (final d in _drafts) d.build()];
    final empty = questions.where((q) => q.instructions.trim().isEmpty);
    if (empty.isNotEmpty) {
      showSnack(context,
          'A pergunta "${empty.first.id}" precisa de instruções.', error: true);
      return;
    }
    setState(() => _running = true);
    try {
      final services = AppServices.instance;
      final modelPath = services.layaModelPath;
      final tokenizerPath = services.layaTokenizerPath;
      if (modelPath == null || tokenizerPath == null) {
        showSnack(context,
            'Kit ONNX do Laya não instalado. Descarrega o kit na aba Modelos.',
            error: true);
        return;
      }
      final engine = await services.ensureLaya(
        modelPath: modelPath,
        tokenizerPath: tokenizerPath,
        config: widget.store.layaConfig,
      );
      services.layaQuestions = questions;
      final response = await engine.decide(
        LayaRequest(state: state, questions: questions),
      );
      await widget.store.saveLayaState(_stateCtrl.text);
      if (mounted) setState(() => _response = response);
    } catch (e) {
      if (mounted) showSnack(context, 'Erro na decisão: $e', error: true);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final services = AppServices.instance;
    final template = _template;
    final response = _response;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const SectionHeader('Template'),
        DropdownButtonFormField<String>(
          initialValue: _templateId,
          decoration: const InputDecoration(
            labelText: 'Template de decisões',
            isDense: true,
            border: OutlineInputBorder(),
          ),
          items: [
            for (final t in kLayaTemplates)
              DropdownMenuItem(value: t.id, child: Text(t.name)),
          ],
          onChanged: _onTemplateChanged,
        ),
        const SizedBox(height: 4),
        Text(template.description,
            style: Theme.of(context).textTheme.bodySmall),
        Wrap(
          spacing: 4,
          children: [
            TextButton.icon(
              onPressed: () => setState(() {
                _stateCtrl.text = template.stateExample;
                _response = null;
              }),
              icon: const Icon(Icons.restart_alt, size: 16),
              label: const Text('State de exemplo'),
            ),
            TextButton.icon(
              onPressed: () async {
                final changed =
                    await showLayaConfigSheet(context, widget.store);
                if (!mounted || !context.mounted) return;
                setState(() {});
                if (changed) {
                  showSnack(context, 'Configuração do Laya guardada');
                }
              },
              icon: const Icon(Icons.settings, size: 16),
              label: const Text('Configuração do Laya'),
            ),
          ],
        ),
        if (services.layaModelPath == null)
          const InfoBanner(
            'Kit ONNX do Laya não instalado. Descarrega o kit na aba Modelos.',
            icon: Icons.warning_amber,
          ),
        const SectionHeader('State (prosa enxuta)'),
        TextField(
          controller: _stateCtrl,
          maxLines: 5,
          minLines: 2,
          decoration: const InputDecoration(
            labelText: 'State',
            hintText: 'Texto a classificar/decidir',
            border: OutlineInputBorder(),
          ),
        ),
        SectionHeader('Perguntas tipadas (${_drafts.length})'),
        for (var i = 0; i < _drafts.length; i++)
          _QuestionEditor(
            key: ValueKey('${_drafts[i].id}_${_drafts[i].type.name}'),
            draft: _drafts[i],
            onChanged: () {
              _syncSharedQuestions();
              setState(() => _response = null);
            },
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            FilledButton.icon(
              onPressed: _running ? null : _decide,
              icon: _running
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.fact_check),
              label: Text(_running ? 'A decidir…' : 'Decidir'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: response == null
                  ? null
                  : () => showJsonDialog(
                      context, 'LayaResponse (JSON)', response.toJson()),
              icon: const Icon(Icons.data_object, size: 18),
              label: const Text('Ver JSON'),
            ),
          ],
        ),
        const SectionHeader('Respostas tipadas'),
        if (response == null)
          const InfoBanner(
            'Sem decisão ainda. Toca em "Decidir" para obter respostas '
            'tipadas com probabilidades e confidence.',
            icon: Icons.rule,
          )
        else ...[
          for (final e in response.answers.entries)
            _AnswerCard(id: e.key, answer: e.value),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              children: [
                MetricRow('tokens in / out',
                    '${response.inputTokens} / ${response.outputTokens}'),
                MetricRow('latência', '${response.latencyMs} ms'),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _QuestionEditor extends StatefulWidget {
  const _QuestionEditor({
    super.key,
    required this.draft,
    required this.onChanged,
  });

  final QDraft draft;
  final VoidCallback onChanged;

  @override
  State<_QuestionEditor> createState() => _QuestionEditorState();
}

class _QuestionEditorState extends State<_QuestionEditor> {
  late final TextEditingController _instructions =
      TextEditingController(text: widget.draft.instructions);
  late final TextEditingController _trueCtrl =
      TextEditingController(text: widget.draft.trueCriteria);
  late final TextEditingController _falseCtrl =
      TextEditingController(text: widget.draft.falseCriteria);
  late final TextEditingController _criteria =
      TextEditingController(text: widget.draft.criteriaText);

  @override
  void dispose() {
    _instructions.dispose();
    _trueCtrl.dispose();
    _falseCtrl.dispose();
    _criteria.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final draft = widget.draft;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Chip(
                  label: Text(draft.type.wire),
                  visualDensity: VisualDensity.compact,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(draft.id,
                      style: Theme.of(context)
                          .textTheme
                          .labelLarge
                          ?.copyWith(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _instructions,
              maxLines: 2,
              minLines: 1,
              decoration: const InputDecoration(
                labelText: 'instruções',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: (s) {
                draft.instructions = s;
                widget.onChanged();
              },
            ),
            const SizedBox(height: 8),
            if (draft.type == QType.noul) ...[
              TextField(
                controller: _trueCtrl,
                decoration: const InputDecoration(
                  labelText: 'critério true',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onChanged: (s) {
                  draft.trueCriteria = s;
                  widget.onChanged();
                },
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _falseCtrl,
                decoration: const InputDecoration(
                  labelText: 'critério false',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onChanged: (s) {
                  draft.falseCriteria = s;
                  widget.onChanged();
                },
              ),
            ] else
              TextField(
                controller: _criteria,
                maxLines: 4,
                minLines: 2,
                decoration: InputDecoration(
                  labelText: 'critérios',
                  hintText: draft.type == QType.choice
                      ? 'um por linha, "nome: descrição"'
                      : 'um nível por linha (ordem = escala)',
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (s) {
                  draft.criteriaText = s;
                  widget.onChanged();
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _AnswerCard extends StatelessWidget {
  const _AnswerCard({required this.id, required this.answer});

  final String id;
  final TypedAnswer answer;

  @override
  Widget build(BuildContext context) {
    final TypedAnswer a = answer;
    final probs = a.probabilities.entries.toList()
      ..sort((x, y) => y.value.compareTo(x.value));
    final score = a is ScoreAnswer ? a : null;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(id,
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(fontWeight: FontWeight.bold)),
                ),
                Text(answer.type.wire,
                    style: Theme.of(context).textTheme.labelSmall),
              ],
            ),
            const SizedBox(height: 4),
            Text(describeAnswer(a),
                style: Theme.of(context).textTheme.bodyMedium),
            if (score != null && score.legend.isNotEmpty)
              Text(
                'lenda: ${score.legend.entries.map((e) => '${e.key}=${e.value}').join('; ')}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            const SizedBox(height: 8),
            for (final p in probs) ProbBar(p.key, p.value),
            const SizedBox(height: 8),
            MetricRow('confidence', a.confidence.toStringAsFixed(3)),
            MetricRow(
                'answer_confidence', a.answerConfidence.toStringAsFixed(3)),
            MetricRow(
                'act_probability', a.actProbability.toStringAsFixed(3)),
          ],
        ),
      ),
    );
  }
}