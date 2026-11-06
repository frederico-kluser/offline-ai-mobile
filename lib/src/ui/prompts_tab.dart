/// Ecrã 1 — Prompts: banco de testes dos modelos geradores LFM3.
///
/// System/user prompt, anexos imagem/vídeo/áudio, perfil de amostragem,
/// raciocínio `<think>` separado, métricas, fingerprint e histórico com
/// comparação golden.
library;

import 'package:flutter/material.dart';

import '../agent/lfm3_chat.dart';
import '../domain/llm_config.dart';
import '../domain/media_attachment.dart';
import '../domain/run_record.dart';
import '../domain/templates.dart';
import '../engines/llm_engine.dart';
import '../services/model_registry.dart';
import '../services/store.dart';
import 'app_services.dart';
import 'attachment_picker.dart';
import 'common.dart';
import 'history_page.dart';
import 'llm_settings_page.dart';

class PromptsTab extends StatefulWidget {
  const PromptsTab({super.key, required this.store});

  final AppStore store;

  @override
  State<PromptsTab> createState() => _PromptsTabState();
}

class _PromptsTabState extends State<PromptsTab> {
  late final TextEditingController _systemCtrl =
      TextEditingController(text: widget.store.systemPrompt);
  late final TextEditingController _userCtrl =
      TextEditingController(text: widget.store.userPrompt);

  late LlmConfig _config = widget.store.llmConfig;
  final List<MediaAttachment> _attachments = [];
  final AttachmentPicker _picker = const AttachmentPicker();
  bool _running = false;

  String _output = '';
  String _thinking = '';
  String _stopReason = '—';
  int _promptTokens = 0;
  int _outputTokens = 0;
  int _thinkingTokens = 0;
  int _latencyMs = 0;
  String _signature = '—';
  List<RunRecord> _history = const [];

  final GlobalKey _resultKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _history = widget.store.runs;
    AppServices.instance.ensureInstalledKnown().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _systemCtrl.dispose();
    _userCtrl.dispose();
    super.dispose();
  }

  bool get _hasImage => _attachments.any((a) => a.kind == MediaKind.image);
  bool get _hasVideo => _attachments.any((a) => a.kind == MediaKind.video);
  bool get _hasAudio => _attachments.any((a) => a.kind == MediaKind.audio);

  ModelBundle? get _bundle => AppServices.instance.generatorFor(
        hasImage: _hasImage,
        hasVideo: _hasVideo,
        hasAudio: _hasAudio,
      );

  bool get _modalityOk {
    final b = _bundle;
    if (b == null) return false;
    if (_hasAudio) return b.supportsAudio;
    if (_hasVideo) return b.supportsVideo;
    if (_hasImage) return b.supportsVision;
    return true;
  }

  Future<void> _addAttachment(MediaKind kind) async {
    try {
      final a = await _picker.pick(kind);
      if (a == null) return;
      setState(() => _attachments.add(a));
    } catch (e) {
      if (mounted) showSnack(context, 'Falha ao escolher ficheiro: $e', error: true);
    }
  }

  void _applyTemplate(Lfm3PromptTemplate t) {
    setState(() {
      _systemCtrl.text = t.systemPrompt;
      _userCtrl.text = t.userPrompt;
      _config = _config.copyWith(enableThinking: t.enableThinking);
      _attachments.clear();
      _output = '';
      _thinking = '';
    });
  }

  Future<void> _run() async {
    if (_running) return;
    final user = _userCtrl.text.trim();
    final system = _systemCtrl.text.trim();
    if (user.isEmpty) {
      showSnack(context, 'Escreve um user prompt antes de executar.',
          error: true);
      return;
    }
    final problems = _config.validate();
    if (problems.isNotEmpty) {
      showSnack(context, 'Configuração inválida: ${problems.first}', error: true);
      return;
    }
    final bundle = _bundle;
    if (bundle == null) {
      showSnack(context,
          'Nenhum modelo LFM3 instalado. Descarrega um bundle na aba Modelos.',
          error: true);
      return;
    }
    if (!_modalityOk) {
      showSnack(
        context,
        '${bundle.label} não suporta os anexos escolhidos. Usa LFM3-VL-2B '
        '(imagem/vídeo), LFM3-Audio-2B (áudio) ou LFM3-Omni-2B (tudo).',
        error: true,
      );
      return;
    }
    await widget.store.saveUserPrompt(_userCtrl.text);
    await widget.store.saveSystemPrompt(_systemCtrl.text);
    await widget.store.saveLlmConfig(_config);

    setState(() {
      _running = true;
      _output = '';
      _thinking = '';
      _stopReason = '—';
      _promptTokens = 0;
      _outputTokens = 0;
      _thinkingTokens = 0;
      _latencyMs = 0;
      _signature = '—';
    });
    try {
      final services = AppServices.instance;
      final engine = await services.ensureLlm(bundle: bundle, config: _config);
      final messages = [
        if (system.isNotEmpty) ChatMessage('system', system),
        ChatMessage('user', user),
      ];
      final media = [
        for (final a in _attachments)
          LlmMediaInput(kind: a.kind, path: a.path),
      ];
      final startedAt = DateTime.now();
      final visible = StringBuffer();
      final think = StringBuffer();
      GenEnd? end;
      await for (final ev in engine.generate(
        messages: messages,
        config: _config,
        media: media,
      )) {
        if (ev is GenDelta) {
          if (ev.thinking) {
            think.write(ev.text);
          } else {
            visible.write(ev.text);
          }
          if (mounted) {
            setState(() {
              _output = visible.toString();
              _thinking = think.toString();
            });
          }
        } else if (ev is GenEnd) {
          end = ev;
        }
      }
      final raw = '${think.isEmpty ? '' : '<think>${think.toString()}</think>'}$visible';
      final parsed = Lfm3OutputParser.parse(raw);
      final content = parsed.visibleContent;
      final thinkingText = parsed.thinkingContent ?? think.toString();
      final signature = runSignature(
        modelId: engine.modelId,
        prompt: user,
        params: _config.toJson(),
        systemPrompt: system.isEmpty ? null : system,
      );
      final record = RunRecord(
        id: '${signature}_${startedAt.microsecondsSinceEpoch}',
        startedAt: startedAt,
        kind: 'lfm3',
        modelId: engine.modelId,
        prompt: user,
        systemPrompt: system.isEmpty ? null : system,
        params: {
          ..._config.toJson(),
          'bundle': bundle.id,
          'media': [for (final a in _attachments) a.toJson()],
        },
        output: content,
        promptTokens: end?.promptTokens ?? 0,
        outputTokens: end?.outputTokens ?? 0,
        latencyMs: end?.latencyMs ?? 0,
        signature: signature,
        stopReason: end?.stopReason ?? 'aborted',
      );
      await _finishRun(record);
      if (mounted) {
        setState(() {
          _output = content;
          _thinking = thinkingText;
          _stopReason = end?.stopReason ?? 'aborted';
          _promptTokens = end?.promptTokens ?? 0;
          _outputTokens = end?.outputTokens ?? 0;
          _thinkingTokens = end?.thinkingTokens ?? 0;
          _latencyMs = end?.latencyMs ?? 0;
          _signature = signature;
        });
      }
    } catch (e) {
      if (mounted) showSnack(context, 'Erro na execução: $e', error: true);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _finishRun(RunRecord record) async {
    await widget.store.addRun(record);
    if (!mounted) return;
    setState(() => _history = widget.store.runs);
  }

  Future<void> _runAndScroll() async {
    await _run();
    if (!mounted || !context.mounted) return;
    final ctx = _resultKey.currentContext;
    if (ctx != null) {
      await Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 300),
        alignment: 0.05,
      );
    }
  }

  Future<void> _openSettings() async {
    final updated = await LlmSettingsPage.open(context, _config);
    if (!mounted || updated == null) return;
    setState(() => _config = updated);
    await widget.store.saveLlmConfig(updated);
  }

  @override
  Widget build(BuildContext context) {
    final services = AppServices.instance;
    final bundle = _bundle;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const SectionHeader('Prompts'),
        DropdownButtonFormField<String>(
          initialValue: null,
          decoration: const InputDecoration(
            labelText: 'Template de prompt',
            isDense: true,
            border: OutlineInputBorder(),
          ),
          items: [
            for (final t in kLfm3PromptTemplates)
              DropdownMenuItem(value: t.id, child: Text(t.name)),
          ],
          onChanged: (id) {
            if (id == null) return;
            final t = kLfm3PromptTemplates.firstWhere((t) => t.id == id);
            _applyTemplate(t);
          },
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _systemCtrl,
          maxLines: 3,
          minLines: 1,
          decoration: const InputDecoration(
            labelText: 'System prompt (opcional)',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _userCtrl,
          maxLines: 5,
          minLines: 2,
          decoration: const InputDecoration(
            labelText: 'User prompt',
            hintText: 'O que queres perguntar ao modelo?',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        AttachmentButtons(onPick: _addAttachment),
        AttachmentStrip(
          attachments: _attachments,
          onRemove: (i) => setState(() => _attachments.removeAt(i)),
        ),
        if (_attachments.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: InfoBanner(
              _modalityOk
                  ? 'Anexos compatíveis com ${bundle?.label ?? 'o modelo ativo'}.'
                  : 'O modelo ativo não suporta estes anexos. Usa LFM3-VL-2B '
                      '(imagem/vídeo), LFM3-Audio-2B (áudio) ou LFM3-Omni-2B.',
              icon: _modalityOk ? Icons.perm_media : Icons.warning_amber,
              color: _modalityOk ? null : Colors.red,
            ),
          ),
        SectionHeader('Modelo',
            trailing: TextButton.icon(
              onPressed: _openSettings,
              icon: const Icon(Icons.tune, size: 18),
              label: const Text('Configuração'),
            )),
        if (bundle == null)
          const InfoBanner(
            'Nenhum modelo gerador instalado. Descarrega LFM3-1.7B (texto) '
            'ou um VL/Audio/Omni na aba Modelos.',
            icon: Icons.warning_amber,
          )
        else
          Card(
            margin: const EdgeInsets.symmetric(vertical: 4),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(bundle.label,
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      CapabilityChip('texto'),
                      if (bundle.supportsThinking) CapabilityChip('think'),
                      if (bundle.supportsVision) CapabilityChip('visão'),
                      if (bundle.supportsVideo) CapabilityChip('vídeo 2 fps'),
                      if (bundle.supportsAudio) CapabilityChip('áudio 16k/24k'),
                      if (bundle.supportsTools) CapabilityChip('tools'),
                      CapabilityChip(bundle.sizeLabel),
                    ],
                  ),
                ],
              ),
            ),
          ),
        SectionHeader(
          'Parâmetros (resumo)',
          trailing: TextButton.icon(
            onPressed: _openSettings,
            icon: const Icon(Icons.tune, size: 18),
            label: const Text('Editar definições'),
          ),
        ),
        Card(
          margin: const EdgeInsets.symmetric(vertical: 4),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                _ParamChip('perfil', _config.profile.label),
                _ParamChip('temperature', _config.temperature.toStringAsFixed(3)),
                _ParamChip('top_k', '${_config.topK}'),
                _ParamChip('min_p', _config.minP.toStringAsFixed(3)),
                _ParamChip('maxTokens', '${_config.maxTokens}'),
                _ParamChip('seed', '${_config.seed}'),
                _ParamChip('thinking', _config.enableThinking ? 'ON' : 'OFF'),
                _ParamChip('KV', _config.kvTypeK.wire),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: _running ? null : _runAndScroll,
          icon: _running
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.play_arrow),
          label: Text(_running ? 'A executar…' : 'Executar'),
        ),
        const SectionHeader('Resultado'),
        Card(
          key: _resultKey,
          margin: const EdgeInsets.symmetric(vertical: 4),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_thinking.isNotEmpty)
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: Text('Raciocínio <think> ($_thinkingTokens tokens)',
                        style: Theme.of(context).textTheme.labelLarge),
                    children: [
                      SelectableText(
                        _thinking,
                        style: const TextStyle(
                            fontFamily: 'monospace', fontSize: 12),
                      ),
                    ],
                  ),
                SelectableText(
                  _output.isEmpty ? 'sem saída' : _output,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                ),
                const Divider(height: 16),
                MetricRow('tokens in / out',
                    '$_promptTokens / $_outputTokens'),
                MetricRow('thinking tokens', '$_thinkingTokens'),
                MetricRow('latência', '$_latencyMs ms'),
                MetricRow('stop_reason', _stopReason),
                MetricRow('fingerprint da execução', _signature),
              ],
            ),
          ),
        ),
        const SectionHeader('Histórico'),
        Card(
          margin: const EdgeInsets.symmetric(vertical: 4),
          child: ListTile(
            leading: const Icon(Icons.history),
            title: Text('Ver histórico (${_history.length} execuções)'),
            subtitle: const Text('Métricas, assinaturas e comparação golden'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              await HistoryPage.open(context, widget.store);
              if (!mounted) return;
              setState(() => _history = widget.store.runs);
            },
          ),
        ),
        if (services.llm == null && services.d1 == null)
          const InfoBanner(
            'Motores ainda não ligados a esta build — as execuções mostram '
            'erro claro em vez de rebentar.',
            icon: Icons.info_outline,
          ),
      ],
    );
  }
}

class _ParamChip extends StatelessWidget {
  const _ParamChip(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Chip(
      visualDensity: VisualDensity.compact,
      avatar: const Icon(Icons.tune, size: 14),
      label: Text('$label: $value',
          style: Theme.of(context).textTheme.labelMedium),
    );
  }
}
