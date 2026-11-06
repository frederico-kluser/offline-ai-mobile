/// Ecrã 3 — LLM + Tools: agente LFM3 com Deferred Tool Search.
///
/// Mostra o catálogo (50+ ferramentas deferidas, só search_tools carregada),
/// a timeline de raciocínio/tool calls/resultados/cortes do LoopGuard, as
/// ferramentas descobertas e a resposta final.
library;

import 'package:flutter/material.dart';

import '../agent/tool_loop.dart';
import '../agent/tools.dart';
import '../domain/llm_config.dart';
import '../domain/media_attachment.dart';
import '../domain/tool_spec.dart';
import '../engines/llm_engine.dart';
import '../guardrails/loop_guard.dart';
import '../services/model_registry.dart';
import '../services/store.dart';
import 'app_services.dart';
import 'attachment_picker.dart';
import 'common.dart';
import 'llm_config_form.dart';
import 'llm_settings_page.dart';

sealed class TimelineEntry {
  const TimelineEntry();
}

class TimelineText extends TimelineEntry {
  TimelineText(this.text, {this.thinking = false});

  String text;
  final bool thinking;
}

class TimelineCall extends TimelineEntry {
  const TimelineCall(this.call, this.step);

  final ToolCall call;
  final int step;
}

class TimelineResult extends TimelineEntry {
  const TimelineResult(this.result, this.step, {this.discovered = const []});

  final ToolResult result;
  final int step;
  final List<Map<String, dynamic>> discovered;
}

class TimelineGuard extends TimelineEntry {
  const TimelineGuard(this.reason, this.detail);

  final StopReason reason;
  final String detail;
}

const String kAgentSystemPrompt = kDefaultAgentSystemPrompt;

class ToolsTab extends StatefulWidget {
  const ToolsTab({super.key, required this.store});

  final AppStore store;

  @override
  State<ToolsTab> createState() => _ToolsTabState();
}

class _ToolsTabState extends State<ToolsTab> {
  late final TextEditingController _taskCtrl =
      TextEditingController(text: widget.store.taskPrompt);
  late LlmConfig _config = widget.store.llmConfig;
  final List<MediaAttachment> _attachments = [];
  final AttachmentPicker _picker = const AttachmentPicker();
  bool _running = false;
  final List<TimelineEntry> _timeline = [];
  ToolLoopResult? _result;
  ToolCatalog? _catalog;

  @override
  void initState() {
    super.initState();
    AppServices.instance.ensureInstalledKnown().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _taskCtrl.dispose();
    super.dispose();
  }

  bool get _configOk => _config.validate().isEmpty;

  ModelBundle? get _bundle => AppServices.instance.generatorFor(
        hasImage: _attachments.any((a) => a.kind == MediaKind.image),
        hasVideo: _attachments.any((a) => a.kind == MediaKind.video),
        hasAudio: _attachments.any((a) => a.kind == MediaKind.audio),
      );

  bool get _modalityOk {
    final b = _bundle;
    if (b == null) return false;
    if (_attachments.any((a) => a.kind == MediaKind.audio)) {
      return b.supportsAudio;
    }
    if (_attachments.any((a) => a.kind == MediaKind.video)) {
      return b.supportsVideo;
    }
    if (_attachments.any((a) => a.kind == MediaKind.image)) {
      return b.supportsVision;
    }
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

  Future<void> _runAgent() async {
    if (_running) return;
    final task = _taskCtrl.text.trim();
    if (task.isEmpty) {
      showSnack(context, 'Escreve uma tarefa para o agente.', error: true);
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
        '${bundle.label} não suporta os anexos escolhidos.',
        error: true,
      );
      return;
    }
    await widget.store.saveTaskPrompt(_taskCtrl.text);
    await widget.store.saveLlmConfig(_config);
    setState(() {
      _running = true;
      _timeline.clear();
      _result = null;
    });
    try {
      final services = AppServices.instance;
      final engine = await services.ensureLlm(bundle: bundle, config: _config);
      final catalog = buildAgentCatalog(noteStore: services.noteStore);
      _catalog = catalog;
      final loop = services.makeToolLoop(llm: engine, catalog: catalog);
      if (loop == null) {
        if (mounted) {
          showSnack(context, 'ToolLoop indisponível nesta build.', error: true);
        }
        return;
      }
      await for (final ev in loop.run(
        userPrompt: task,
        systemPrompt: kAgentSystemPrompt,
        config: _config.copyWith(enableThinking: true),
        media: [
          for (final a in _attachments)
            LlmMediaInput(kind: a.kind, path: a.path),
        ],
      )) {
        if (!mounted) continue;
        setState(() {
          switch (ev) {
            case LoopText(:final text, :final thinking):
              if (_timeline.isNotEmpty &&
                  _timeline.last is TimelineText &&
                  (_timeline.last as TimelineText).thinking == thinking) {
                (_timeline.last as TimelineText).text += text;
              } else {
                _timeline.add(TimelineText(text, thinking: thinking));
              }
            case LoopToolCall(:final call, :final step):
              _timeline.add(TimelineCall(call, step));
            case LoopToolResult(:final result, :final step,
                :final discoveredSchemas):
              _timeline.add(TimelineResult(result, step,
                  discovered: discoveredSchemas));
            case LoopGuardTrip(:final reason, :final detail):
              _timeline.add(TimelineGuard(reason, detail));
            case LoopEnd(:final result):
              _result = result;
          }
        });
      }
    } catch (e) {
      if (mounted) showSnack(context, 'Erro no agente: $e', error: true);
    } finally {
      if (mounted) setState(() => _running = false);
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
    final result = _result;
    final catalog = _catalog;
    final problems = _config.validate();
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const SectionHeader('Agente LFM3 · Deferred Tool Search'),
        const InfoBanner(
          'Só search_tools entra no system prompt. Quando o modelo a chama, '
          'as ferramentas descobertas chegam em <additional_tools> e o prefixo '
          'do system prompt fica intacto (KV cache reutilizável).',
          icon: Icons.account_tree_outlined,
        ),
        if (_bundle == null)
          const InfoBanner(
            'Nenhum modelo LFM3 instalado. Descarrega LFM3-1.7B na aba Modelos.',
            icon: Icons.warning_amber,
          ),
        TextField(
          controller: _taskCtrl,
          maxLines: 3,
          minLines: 1,
          decoration: const InputDecoration(
            labelText: 'Tarefa do agente',
            hintText: "Ex.: calcula (17*23)+109 e guarda numa nota 'orcamento'",
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        AttachmentButtons(onPick: _addAttachment),
        AttachmentStrip(
          attachments: _attachments,
          onRemove: (i) => setState(() => _attachments.removeAt(i)),
        ),
        const SizedBox(height: 8),
        Text(
          'Catálogo: 50+ ferramentas locais · search_tools ativa · '
          'final_answer para concluir · maxSteps ${const LoopGuardConfig().maxSteps}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: _running || !_configOk ? null : _runAgent,
          icon: _running
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.smart_toy_outlined),
          label: Text(_running ? 'A correr…' : 'Correr agente'),
        ),
        if (!_configOk)
          const InfoBanner(
            '"Correr agente" bloqueado: corrige as violações da configuração.',
            icon: Icons.block,
            color: Colors.red,
          ),
        if (catalog != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                CapabilityChip('catálogo ${catalog.tools.length}'),
                CapabilityChip('deferidas ${catalog.deferred.length}'),
                CapabilityChip('ativas ${catalog.active.length}'),
              ],
            ),
          ),
        SectionHeader('Timeline (${_timeline.length} entradas)'),
        if (_timeline.isEmpty)
          const InfoBanner(
            'Sem passos ainda. A timeline mostra raciocínio, tool calls, '
            'resultados, ferramentas descobertas e cortes do LoopGuard.',
            icon: Icons.timeline,
          ),
        for (var i = 0; i < _timeline.length; i++)
          _TimelineTile(entry: _timeline[i], index: i),
        if (result != null) ...[
          const SectionHeader('Resposta final'),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              result.answer.isEmpty ? '(sem resposta final)' : result.answer,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ),
          if (result.thinking.isNotEmpty)
            ExpansionTile(
              title: Text('Raciocínio (${result.thinkingTokens} tokens)'),
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: SelectableText(result.thinking,
                      style: const TextStyle(fontSize: 12)),
                ),
              ],
            ),
          if (result.discoveredTools.isNotEmpty) ...[
            const SectionHeader('Ferramentas descobertas'),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final name in result.discoveredTools)
                  Chip(label: Text(name), visualDensity: VisualDensity.compact),
              ],
            ),
          ],
          const SectionHeader('Resumo do LoopGuard'),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              children: [
                MetricRow('passos', '${result.log.length}'),
                MetricRow('tool calls', '${result.toolResults.length}'),
                MetricRow('search_tools', '${result.searchQueries.length}'),
                MetricRow('tokens in / out',
                    '${result.promptTokens} / ${result.outputTokens}'),
                MetricRow('thinking tokens', '${result.thinkingTokens}'),
                MetricRow('latência', '${result.latencyMs} ms'),
                MetricRow('stop_reason',
                    '${result.stopReason.wire} — ${result.stopReason.explanation}'),
              ],
            ),
          ),
          if (result.log.isNotEmpty)
            ExpansionTile(
              title: const Text('Registo do LoopGuard'),
              children: [
                for (final step in result.log)
                  ListTile(
                    dense: true,
                    leading: Text('#${step.index}'),
                    title: Text(step.summary),
                    subtitle: Text(step.kind),
                  ),
              ],
            ),
        ],
        if (services.noteStore.isNotEmpty) ...[
          const SectionHeader('Notas guardadas (note_save)'),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final e in services.noteStore.entries)
                  MetricRow(e.key, e.value),
              ],
            ),
          ),
        ],
        const SectionHeader('Configuração do motor'),
        Card(
          margin: const EdgeInsets.symmetric(vertical: 4),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final e in <String, String>{
                      'perfil': _config.profile.label,
                      'temperature': _config.temperature.toStringAsFixed(3),
                      'top_k': '${_config.topK}',
                      'seed': '${_config.seed}',
                      'thinking': _config.enableThinking ? 'ON' : 'OFF',
                    }.entries)
                      Chip(
                        visualDensity: VisualDensity.compact,
                        label: Text('${e.key}: ${e.value}'),
                      ),
                  ],
                ),
                if (problems.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  ValidationBox(problems),
                ],
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _openSettings,
                  icon: const Icon(Icons.tune),
                  label: const Text('Abrir definições completas'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _TimelineTile extends StatelessWidget {
  const _TimelineTile({required this.entry, required this.index});

  final TimelineEntry entry;
  final int index;

  @override
  Widget build(BuildContext context) {
    final Widget body;
    final IconData icon;
    switch (entry) {
      case TimelineText(:final text, :final thinking):
        icon = thinking ? Icons.psychology_outlined : Icons.chat_bubble_outline;
        body = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (thinking)
              Text('raciocínio <think>',
                  style: Theme.of(context).textTheme.labelSmall),
            SelectableText(text,
                style: TextStyle(
                    fontSize: 13,
                    fontStyle: thinking ? FontStyle.italic : FontStyle.normal)),
          ],
        );
      case TimelineCall(:final call, :final step):
        icon = Icons.build;
        body = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('passo $step · tool call: ${call.name}',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            SelectableText('args: ${call.args}',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          ],
        );
      case TimelineResult(:final result, :final step, :final discovered):
        icon = result.ok ? Icons.check_circle_outline : Icons.error_outline;
        body = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
                'passo $step · resultado de ${result.name}: '
                '${result.ok ? 'ok' : 'erro'}'
                '${result.errorKind == null ? '' : ' (${result.errorKind})'}',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            SelectableText(result.output,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            if (discovered.isNotEmpty)
              Text(
                'descobertas: ${discovered.map((s) => s['function']?['name'] ?? s['name']).join(', ')}',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            Text('${result.durationMs} ms',
                style: Theme.of(context).textTheme.labelSmall),
          ],
        );
      case TimelineGuard(:final reason, :final detail):
        icon = Icons.gpp_maybe_outlined;
        body = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('guardrail: ${reason.explanation}',
                style: const TextStyle(fontWeight: FontWeight.bold)),
            if (detail.isNotEmpty) Text(detail),
          ],
        );
    }
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18),
            const SizedBox(width: 8),
            Expanded(child: body),
            Text('#$index', style: Theme.of(context).textTheme.labelSmall),
          ],
        ),
      ),
    );
  }
}
