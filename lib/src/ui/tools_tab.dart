/// Tela 3 — LLM + Tools: configuração COMPLETA do [LlmConfig] com validação
/// rígida (violações a vermelho bloqueiam execução) e demo de tool calling
/// sobre o [ToolLoop] (timeline de passos, guardrails e resumo).
library;

import 'package:flutter/material.dart';

import '../agent/tool_loop.dart';
import '../agent/tools.dart';
import '../domain/llm_config.dart';
import '../domain/tool_spec.dart';
import '../guardrails/loop_guard.dart';
import '../services/store.dart';
import 'app_services.dart';
import 'common.dart';
import 'llm_config_form.dart';
import 'llm_settings_page.dart';

/// Entradas da timeline do agente.
sealed class TimelineEntry {
  const TimelineEntry();
}

class TimelineText extends TimelineEntry {
  TimelineText(this.text);

  String text;
}

class TimelineCall extends TimelineEntry {
  const TimelineCall(this.call, this.step);

  final ToolCall call;
  final int step;
}

class TimelineResult extends TimelineEntry {
  const TimelineResult(this.result, this.step);

  final ToolResult result;
  final int step;
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
  bool _running = false;
  final List<TimelineEntry> _timeline = [];
  ToolLoopResult? _result;

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
  bool get _llmInstalled => AppServices.instance.llmModelPath != null;

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
    await widget.store.saveTaskPrompt(_taskCtrl.text);
    await widget.store.saveLlmConfig(_config);
    setState(() {
      _running = true;
      _timeline.clear();
      _result = null;
    });
    try {
      final services = AppServices.instance;
      final modelPath = services.llmModelPath;
      if (modelPath == null) {
        if (mounted) {
          showSnack(context,
              'Modelo GGUF não instalado. Descarrega o GGUF na aba Modelos.',
              error: true);
        }
        return;
      }
      final engine =
          await services.ensureLlm(modelPath: modelPath, config: _config);
      final tools = demoTools(services.noteStore);
      final loop = services.makeToolLoop(llm: engine, tools: tools);
      if (loop == null) {
        if (mounted) {
          showSnack(context, 'ToolLoop indisponível nesta build.', error: true);
        }
        return;
      }
      await for (final ev
          in loop.run(userPrompt: task, systemPrompt: kAgentSystemPrompt, config: _config)) {
        if (!mounted) continue;
        setState(() {
          switch (ev) {
            case LoopText(:final text):
              if (_timeline.isNotEmpty && _timeline.last is TimelineText) {
                (_timeline.last as TimelineText).text += text;
              } else {
                _timeline.add(TimelineText(text));
              }
            case LoopToolCall(:final call, :final step):
              _timeline.add(TimelineCall(call, step));
            case LoopToolResult(:final result, :final step):
              _timeline.add(TimelineResult(result, step));
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

  /// Abre as Definições do LLM (progressive disclosure) e aplica o resultado.
  Future<void> _openSettings() async {
    final updated = await LlmSettingsPage.open(context, _config);
    if (!mounted || updated == null) return;
    setState(() => _config = updated);
    await widget.store.saveLlmConfig(updated);
  }

  @override
  Widget build(BuildContext context) {
    final services = AppServices.instance;
    final problems = _config.validate();
    final result = _result;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const SectionHeader('Demo de tool calling'),
        if (!_llmInstalled)
          const InfoBanner(
            'Modelo MiniCPM5-2B (GGUF) não instalado. '
            'Descarrega o GGUF na aba Modelos.',
            icon: Icons.warning_amber,
          ),
        TextField(
          controller: _taskCtrl,
          maxLines: 3,
          minLines: 1,
          decoration: const InputDecoration(
            labelText: 'Tarefa do agente',
            hintText: 'Ex.: calcula, guarda o resultado numa nota e resume',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        Text('Ferramentas locais: calculator · note_save · note_read · '
            'final_answer (conclusão explícita)',
            style: Theme.of(context).textTheme.bodySmall),
        Text('System prompt do agente: $kAgentSystemPrompt',
            style: Theme.of(context).textTheme.labelSmall),
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
        SectionHeader('Timeline (${_timeline.length} entradas)'),
        if (_timeline.isEmpty)
          const InfoBanner(
            'Sem passos ainda. A timeline mostra texto do modelo, tool calls, '
            'resultados e cortes do LoopGuard.',
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
                MetricRow('tokens in / out',
                    '${result.promptTokens} / ${result.outputTokens}'),
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
        const SectionHeader('Configuração do LLM'),
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
                      'temperature': _config.temperature.toStringAsFixed(3),
                      'min_p': _config.minP.toStringAsFixed(3),
                      'seed': '${_config.seed}',
                      'DRY': _config.dryEnabled ? 'ligado' : 'desligado',
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
      case TimelineText(:final text):
        icon = Icons.chat_bubble_outline;
        body = SelectableText(text);
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
      case TimelineResult(:final result, :final step):
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