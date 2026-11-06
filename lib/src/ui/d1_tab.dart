/// Ecrã "Decisões d1" — substituto do antigo separador Laya.
///
/// Edita templates de dez primitivas, anexa imagem/vídeo/áudio, aceita
/// perguntas faladas (d1-Omni) e mostra as respostas tipadas com
/// probabilidades, spans e caixas desenhadas sobre a imagem.
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../domain/d1_decision_types.dart';
import '../domain/llm_config.dart';
import '../domain/media_attachment.dart';
import '../domain/templates.dart';
import '../services/store.dart';
import 'app_services.dart';
import 'attachment_picker.dart';
import 'common.dart';
import 'config_sheets.dart';

/// Rascunho editável de uma pergunta d1 (texto puro).
class D1Draft {
  D1Draft({
    required this.id,
    required this.type,
    required this.instructions,
    this.trueCriteria = 'sim',
    this.falseCriteria = 'não',
    this.criteriaText = '',
    this.levelsText = '',
    this.hint = '',
    this.unit = '',
    this.minText = '0',
    this.maxText = '10',
    this.stepText = '1',
    this.target = '',
    this.maxBoxes = 16,
    this.spoken = false,
    this.spokenPath = '',
  });

  final String id;
  D1QuestionType type;
  String instructions;
  String trueCriteria;
  String falseCriteria;
  String criteriaText;
  String levelsText;
  String hint;
  String unit;
  String minText;
  String maxText;
  String stepText;
  String target;
  int maxBoxes;
  bool spoken;
  String spokenPath;

  factory D1Draft.fromQuestion(D1Question q) {
    final base = D1Draft(
      id: q.id,
      type: q.type,
      instructions: q.instructions,
      spoken: q.isSpoken,
      spokenPath: q.spokenPath,
    );
    switch (q) {
      case D1NoulQuestion(:final trueCriteria, :final falseCriteria):
        return base
          ..trueCriteria = trueCriteria
          ..falseCriteria = falseCriteria;
      case D1ChoiceQuestion(:final criteria, :final multiple):
        return base
          ..type = multiple
              ? D1QuestionType.multiChoice
              : D1QuestionType.choice
          ..criteriaText =
              criteria.entries.map((e) => '${e.key}: ${e.value}').join('\n');
      case D1ScoreQuestion(:final levels):
        return base..levelsText = levels.join('\n');
      case D1TextQuestion(:final hint):
        return base..hint = hint ?? '';
      case D1NumberQuestion(:final unitHint):
        return base..unit = unitHint ?? '';
      case D1DateQuestion():
        return base;
      case D1RangeQuestion(:final min, :final max, :final step, :final unitHint):
        return base
          ..minText = '$min'
          ..maxText = '$max'
          ..stepText = '$step'
          ..unit = unitHint ?? '';
      case D1BoxQuestion(:final target):
        return base..target = target ?? '';
      case D1BoxesQuestion(:final target, :final maxBoxes):
        return base
          ..target = target ?? ''
          ..maxBoxes = maxBoxes;
    }
  }

  D1Instruction get instruction => spoken && spokenPath.trim().isNotEmpty
      ? SpokenInstruction(spokenPath.trim())
      : WrittenInstruction(instructions);

  D1Question build() {
    final ins = instruction;
    switch (type) {
      case D1QuestionType.noul:
        return D1NoulQuestion(
          id: id,
          instructions: instructions,
          trueCriteria: trueCriteria.trim().isEmpty ? 'sim' : trueCriteria.trim(),
          falseCriteria:
              falseCriteria.trim().isEmpty ? 'não' : falseCriteria.trim(),
          instruction: ins,
        );
      case D1QuestionType.choice:
        return D1ChoiceQuestion(
          id: id,
          instructions: instructions,
          criteria: _parseChoice(criteriaText),
          instruction: ins,
        );
      case D1QuestionType.multiChoice:
        return D1ChoiceQuestion(
          id: id,
          instructions: instructions,
          criteria: _parseChoice(criteriaText),
          multiple: true,
          instruction: ins,
        );
      case D1QuestionType.score:
        return D1ScoreQuestion(
          id: id,
          instructions: instructions,
          levels: _lines(levelsText),
          instruction: ins,
        );
      case D1QuestionType.textSpan:
        return D1TextQuestion(
          id: id,
          instructions: instructions,
          hint: hint.trim().isEmpty ? null : hint.trim(),
          instruction: ins,
        );
      case D1QuestionType.numberSpan:
        return D1NumberQuestion(
          id: id,
          instructions: instructions,
          unitHint: unit.trim().isEmpty ? null : unit.trim(),
          instruction: ins,
        );
      case D1QuestionType.dateSpan:
        return D1DateQuestion(
          id: id,
          instructions: instructions,
          instruction: ins,
        );
      case D1QuestionType.numberRange:
        return D1RangeQuestion(
          id: id,
          instructions: instructions,
          min: double.tryParse(minText.replaceAll(',', '.')) ?? 0,
          max: double.tryParse(maxText.replaceAll(',', '.')) ?? 10,
          step: double.tryParse(stepText.replaceAll(',', '.')) ?? 1,
          unitHint: unit.trim().isEmpty ? null : unit.trim(),
          instruction: ins,
        );
      case D1QuestionType.box:
        return D1BoxQuestion(
          id: id,
          instructions: instructions,
          target: target.trim().isEmpty ? null : target.trim(),
          instruction: ins,
        );
      case D1QuestionType.boxes:
        return D1BoxesQuestion(
          id: id,
          instructions: instructions,
          target: target.trim().isEmpty ? null : target.trim(),
          maxBoxes: maxBoxes.clamp(1, 16),
          instruction: ins,
        );
    }
  }

  static List<String> _lines(String text) => [
        for (final l in text.split('\n'))
          if (l.trim().isNotEmpty) l.trim(),
      ];

  static Map<String, String> _parseChoice(String text) {
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

class D1Tab extends StatefulWidget {
  const D1Tab({super.key, required this.store});

  final AppStore store;

  @override
  State<D1Tab> createState() => _D1TabState();
}

class _D1TabState extends State<D1Tab> {
  late String _templateId;
  late final TextEditingController _stateCtrl;
  late List<D1Draft> _drafts;
  final List<MediaAttachment> _attachments = [];
  D1Response? _response;
  bool _running = false;
  late D1Config _config = widget.store.d1Config;
  final AttachmentPicker _picker = const AttachmentPicker();

  @override
  void initState() {
    super.initState();
    final template = _initialTemplate();
    _templateId = template.id;
    final savedState = widget.store.d1State;
    _stateCtrl = TextEditingController(
        text: savedState.trim().isEmpty ? template.stateExample : savedState);
    _drafts = [for (final q in template.questions) D1Draft.fromQuestion(q)];
    _syncShared();
    AppServices.instance.ensureInstalledKnown().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _stateCtrl.dispose();
    super.dispose();
  }

  D1Template _initialTemplate() {
    final id = widget.store.selectedTemplateId;
    for (final t in kD1Templates) {
      if (t.id == id) return t;
    }
    return kD1Templates.first;
  }

  D1Template get _template {
    for (final t in kD1Templates) {
      if (t.id == _templateId) return t;
    }
    return kD1Templates.first;
  }

  void _syncShared() {
    AppServices.instance.d1Questions = [for (final d in _drafts) d.build()];
  }

  void _onTemplateChanged(String? id) {
    if (id == null) return;
    final template = kD1Templates.firstWhere(
      (t) => t.id == id,
      orElse: () => kD1Templates.first,
    );
    setState(() {
      _templateId = template.id;
      _drafts = [for (final q in template.questions) D1Draft.fromQuestion(q)];
      _stateCtrl.text = template.stateExample;
      _response = null;
      _attachments.clear();
    });
    _syncShared();
    widget.store.saveSelectedTemplateId(template.id);
  }

  Future<void> _addAttachment(MediaKind kind) async {
    try {
      final a = await _picker.pick(kind);
      if (a == null) return;
      setState(() {
        _attachments.add(a);
        _response = null;
      });
    } catch (e) {
      if (mounted) showSnack(context, 'Falha ao escolher ficheiro: $e', error: true);
    }
  }

  Future<void> _decide() async {
    if (_running) return;
    final state = _stateCtrl.text.trim();
    if (state.isEmpty) {
      showSnack(context, 'Escreve um state antes de decidir.', error: true);
      return;
    }
    final questions = [for (final d in _drafts) d.build()];
    if (questions.isEmpty) {
      showSnack(context, 'Adiciona pelo menos uma pergunta.', error: true);
      return;
    }
    final empty = questions.where((q) => q.instructions.trim().isEmpty);
    if (empty.isNotEmpty) {
      showSnack(context, 'A pergunta "${empty.first.id}" precisa de instruções.',
          error: true);
      return;
    }
    final bundle = AppServices.instance.activeD1Bundle;
    if (bundle == null) {
      showSnack(context,
          'Nenhum decisor d1 instalado. Descarrega d1-2B-ONNX ou d1-2B-GGUF na aba Modelos.',
          error: true);
      return;
    }
    if (!bundle.isOnnx &&
        questions.any((q) => !q.type.supportedByGguf)) {
      showSnack(context,
          'As primitivas tipadas (spans/range/box/boxes) exigem o bundle ONNX; '
          'o GGUF só faz noul/choice/score.',
          error: true);
      return;
    }
    if (_attachments.any((a) => a.kind == MediaKind.video) &&
        !bundle.supportsVideo) {
      showSnack(context,
          'Vídeo no d1 exige um bundle com vision_encoder (d1-2B/d1-Omni).',
          error: true);
      return;
    }
    if (_attachments.any((a) => a.kind == MediaKind.audio) &&
        !bundle.supportsAudio) {
      showSnack(context,
          'Áudio no d1 exige o bundle d1-Omni-2B-ONNX (audio_encoder).',
          error: true);
      return;
    }
    setState(() => _running = true);
    try {
      final services = AppServices.instance;
      final engine = await services.ensureD1(bundle: bundle, config: _config);
      services.d1Questions = questions;
      final media = [
        for (final a in _attachments)
          D1Media(
            kind: switch (a.kind) {
              MediaKind.image => D1MediaKind.image,
              MediaKind.video => D1MediaKind.video,
              MediaKind.audio => D1MediaKind.audio,
            },
            path: a.path,
            bytes: a.bytes,
            sha256: a.sha256,
          ),
      ];
      final response = await engine.decide(D1Request(
        state: state,
        media: media,
        questions: questions,
      ));
      await widget.store.saveD1State(_stateCtrl.text);
      if (mounted) setState(() => _response = response);
    } catch (e) {
      if (mounted) showSnack(context, 'Erro na decisão: $e', error: true);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _openConfig() async {
    final updated = await showD1ConfigSheet(context, widget.store);
    if (!mounted) return;
    setState(() => _config = widget.store.d1Config);
    if (updated) showSnack(context, 'Configuração do d1 guardada');
  }

  void _addQuestion(D1QuestionType type) {
    final n = _drafts.length + 1;
    setState(() {
      _drafts.add(D1Draft(
        id: 'q$n',
        type: type,
        instructions: '',
        criteriaText: type == D1QuestionType.choice ||
                type == D1QuestionType.multiChoice
            ? 'sim: critério de sim\nnao: critério de não'
            : '',
        levelsText: type == D1QuestionType.score ? 'Baixo\nMédio\nAlto' : '',
      ));
      _response = null;
    });
    _syncShared();
  }

  ImageProvider? get _firstImage {
    for (final a in _attachments) {
      if (a.kind == MediaKind.image) return FileImage(File(a.path));
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final services = AppServices.instance;
    final bundle = services.activeD1Bundle;
    final response = _response;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const SectionHeader('Template d1'),
        DropdownButtonFormField<String>(
          initialValue: _templateId,
          decoration: const InputDecoration(
            labelText: 'Template de decisões',
            isDense: true,
            border: OutlineInputBorder(),
          ),
          items: [
            for (final t in kD1Templates)
              DropdownMenuItem(value: t.id, child: Text(t.name)),
          ],
          onChanged: _onTemplateChanged,
        ),
        const SizedBox(height: 4),
        Text(_template.description,
            style: Theme.of(context).textTheme.bodySmall),
        Wrap(
          spacing: 4,
          children: [
            TextButton.icon(
              onPressed: () => setState(() {
                _stateCtrl.text = _template.stateExample;
                _response = null;
              }),
              icon: const Icon(Icons.restart_alt, size: 16),
              label: const Text('State de exemplo'),
            ),
            TextButton.icon(
              onPressed: _openConfig,
              icon: const Icon(Icons.settings, size: 16),
              label: const Text('Configuração d1'),
            ),
          ],
        ),
        if (bundle == null)
          const InfoBanner(
            'Nenhum decisor d1 instalado. Descarrega d1-2B-ONNX (todas as '
            'primitivas) ou d1-2B-GGUF (noul/choice/score) na aba Modelos.',
            icon: Icons.warning_amber,
          )
        else
          InfoBanner(
            'Motor ativo: ${bundle.label} · ${bundle.isOnnx ? 'ONNX (10 primitivas)' : 'GGUF (3 primitivas)'}',
            icon: Icons.memory,
          ),
        const SectionHeader('Estado (texto/JSON)'),
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
        const SectionHeader('Anexos'),
        AttachmentButtons(onPick: _addAttachment),
        AttachmentStrip(
          attachments: _attachments,
          onRemove: (i) => setState(() {
            _attachments.removeAt(i);
            _response = null;
          }),
        ),
        if (_attachments.any((a) => a.kind == MediaKind.image) &&
            _firstImage != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image(
                    image: _firstImage!,
                    height: 180,
                    width: double.infinity,
                    fit: BoxFit.cover,
                  ),
                ),
                if (response != null)
                  Positioned.fill(
                    child: D1BoxOverlay(response: response),
                  ),
              ],
            ),
          ),
        SectionHeader('Perguntas (${_drafts.length})',
            trailing: PopupMenuButton<D1QuestionType>(
              tooltip: 'Adicionar pergunta',
              icon: const Icon(Icons.add_circle_outline),
              onSelected: _addQuestion,
              itemBuilder: (_) => [
                for (final t in D1QuestionType.values)
                  PopupMenuItem(value: t, child: Text(t.label)),
              ],
            )),
        for (var i = 0; i < _drafts.length; i++)
          _QuestionEditor(
            key: ValueKey(
                '${_templateId}_${_drafts[i].id}_${_drafts[i].type.name}'),
            draft: _drafts[i],
            onChanged: () {
              _syncShared();
              setState(() => _response = null);
            },
            onDelete: _drafts.length <= 1
                ? null
                : () {
                    setState(() {
                      _drafts.removeAt(i);
                      _response = null;
                    });
                    _syncShared();
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
                      context, 'D1Response (JSON)', response.toJson()),
              icon: const Icon(Icons.data_object, size: 18),
              label: const Text('Ver JSON'),
            ),
          ],
        ),
        const SectionHeader('Respostas tipadas'),
        if (response == null)
          const InfoBanner(
            'Sem decisão ainda. Toca em "Decidir" para obter respostas '
            'tipadas com probabilidades, spans e caixas.',
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
                MetricRow('slots', '${response.slotCount}'),
                MetricRow('latência', '${response.latencyMs} ms'),
                MetricRow('motor', response.engine),
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
    this.onDelete,
  });

  final D1Draft draft;
  final VoidCallback onChanged;
  final VoidCallback? onDelete;

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
  late final TextEditingController _levels =
      TextEditingController(text: widget.draft.levelsText);
  late final TextEditingController _hint =
      TextEditingController(text: widget.draft.hint);
  late final TextEditingController _unit =
      TextEditingController(text: widget.draft.unit);
  late final TextEditingController _min =
      TextEditingController(text: widget.draft.minText);
  late final TextEditingController _max =
      TextEditingController(text: widget.draft.maxText);
  late final TextEditingController _step =
      TextEditingController(text: widget.draft.stepText);
  late final TextEditingController _target =
      TextEditingController(text: widget.draft.target);
  late final TextEditingController _spokenPath =
      TextEditingController(text: widget.draft.spokenPath);

  @override
  void dispose() {
    for (final c in [
      _instructions,
      _trueCtrl,
      _falseCtrl,
      _criteria,
      _levels,
      _hint,
      _unit,
      _min,
      _max,
      _step,
      _target,
      _spokenPath,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  InputDecoration _dec(String label) => InputDecoration(
        labelText: label,
        isDense: true,
        border: const OutlineInputBorder(),
      );

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
                if (widget.onDelete != null)
                  IconButton(
                    tooltip: 'Remover pergunta',
                    icon: const Icon(Icons.delete_outline, size: 18),
                    onPressed: widget.onDelete,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _instructions,
              maxLines: 2,
              minLines: 1,
              decoration: _dec('instruções'),
              onChanged: (s) {
                draft.instructions = s;
                widget.onChanged();
              },
            ),
            const SizedBox(height: 8),
            if (draft.type == D1QuestionType.noul) ...[
              TextField(
                controller: _trueCtrl,
                decoration: _dec('critério true'),
                onChanged: (s) {
                  draft.trueCriteria = s;
                  widget.onChanged();
                },
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _falseCtrl,
                decoration: _dec('critério false'),
                onChanged: (s) {
                  draft.falseCriteria = s;
                  widget.onChanged();
                },
              ),
            ] else if (draft.type == D1QuestionType.choice ||
                draft.type == D1QuestionType.multiChoice) ...[
              TextField(
                controller: _criteria,
                maxLines: 4,
                minLines: 2,
                decoration: _dec('critérios (nome: descrição, um por linha)'),
                onChanged: (s) {
                  draft.criteriaText = s;
                  widget.onChanged();
                },
              ),
              if (draft.type == D1QuestionType.multiChoice)
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text('multiple: true — uma probabilidade P(yes) por opção'),
                ),
            ] else if (draft.type == D1QuestionType.score)
              TextField(
                controller: _levels,
                maxLines: 4,
                minLines: 2,
                decoration: _dec('níveis (um por linha, ordem = escala)'),
                onChanged: (s) {
                  draft.levelsText = s;
                  widget.onChanged();
                },
              )
            else if (draft.type == D1QuestionType.textSpan)
              TextField(
                controller: _hint,
                decoration: _dec('hint (opcional)'),
                onChanged: (s) {
                  draft.hint = s;
                  widget.onChanged();
                },
              )
            else if (draft.type == D1QuestionType.numberSpan)
              TextField(
                controller: _unit,
                decoration: _dec('unidade (opcional)'),
                onChanged: (s) {
                  draft.unit = s;
                  widget.onChanged();
                },
              )
            else if (draft.type == D1QuestionType.numberRange) ...[
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _min,
                      keyboardType: TextInputType.number,
                      decoration: _dec('min'),
                      onChanged: (s) {
                        draft.minText = s;
                        widget.onChanged();
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _max,
                      keyboardType: TextInputType.number,
                      decoration: _dec('max'),
                      onChanged: (s) {
                        draft.maxText = s;
                        widget.onChanged();
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _step,
                      keyboardType: TextInputType.number,
                      decoration: _dec('step'),
                      onChanged: (s) {
                        draft.stepText = s;
                        widget.onChanged();
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _unit,
                decoration: _dec('unidade (opcional)'),
                onChanged: (s) {
                  draft.unit = s;
                  widget.onChanged();
                },
              ),
            ] else if (draft.type == D1QuestionType.box ||
                draft.type == D1QuestionType.boxes) ...[
              TextField(
                controller: _target,
                decoration: _dec('alvo (ex.: botão Confirmar)'),
                onChanged: (s) {
                  draft.target = s;
                  widget.onChanged();
                },
              ),
              if (draft.type == D1QuestionType.boxes)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    children: [
                      const Text('máx. caixas'),
                      Expanded(
                        child: Slider(
                          value: draft.maxBoxes.toDouble(),
                          min: 1,
                          max: 16,
                          divisions: 15,
                          label: '${draft.maxBoxes}',
                          onChanged: (v) {
                            setState(() => draft.maxBoxes = v.round());
                            widget.onChanged();
                          },
                        ),
                      ),
                      Text('${draft.maxBoxes}'),
                    ],
                  ),
                ),
            ],
            const SizedBox(height: 8),
            SwitchListTile.adaptive(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('Pergunta falada (d1-Omni)'),
              subtitle: const Text('WAV PCM 16 kHz mono'),
              value: draft.spoken,
              onChanged: (v) {
                setState(() => draft.spoken = v);
                widget.onChanged();
              },
            ),
            if (draft.spoken)
              TextField(
                controller: _spokenPath,
                decoration: _dec('caminho do WAV da pergunta'),
                onChanged: (s) {
                  draft.spokenPath = s;
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
  final D1Answer answer;

  @override
  Widget build(BuildContext context) {
    final probs = answer.probabilities.entries.toList()
      ..sort((x, y) => y.value.compareTo(x.value));
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
            Text(describeAnswer(answer),
                style: Theme.of(context).textTheme.bodyMedium),
            if (probs.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (final p in probs) ProbBar(p.key, p.value),
            ],
            const SizedBox(height: 8),
            MetricRow('confidence', answer.confidence.toStringAsFixed(3)),
          ],
        ),
      ),
    );
  }
}

/// Desenha caixas normalizadas [0,1] sobre a imagem.
class D1BoxOverlay extends StatelessWidget {
  const D1BoxOverlay({super.key, required this.response});

  final D1Response response;

  @override
  Widget build(BuildContext context) {
    final boxes = <BoundingBoxFrac>[];
    for (final a in response.answers.values) {
      if (a is D1BoxAnswer && a.box != null) boxes.add(a.box!);
      if (a is D1BoxesAnswer) boxes.addAll(a.boxes);
    }
    if (boxes.isEmpty) return const SizedBox.shrink();
    return CustomPaint(painter: _BoxPainter(boxes));
  }
}

class _BoxPainter extends CustomPainter {
  final List<BoundingBoxFrac> boxes;
  const _BoxPainter(this.boxes);

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()
      ..color = const Color(0x33FFC107)
      ..style = PaintingStyle.fill;
    final stroke = Paint()
      ..color = const Color(0xFFFFC107)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    for (final b in boxes) {
      if (!b.isPresent) continue;
      final r = Rect.fromLTRB(
        b.left.clamp(0, 1) * size.width,
        b.top.clamp(0, 1) * size.height,
        b.right.clamp(0, 1) * size.width,
        b.bottom.clamp(0, 1) * size.height,
      );
      canvas.drawRect(r, fill);
      canvas.drawRect(r, stroke);
    }
  }

  @override
  bool shouldRepaint(covariant _BoxPainter oldDelegate) =>
      oldDelegate.boxes != boxes;
}
