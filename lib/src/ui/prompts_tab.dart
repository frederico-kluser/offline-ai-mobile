/// Tela 1 — Prompts: editor de system/user prompt, modo de execução
/// (LLM MiniCPM5-2B | Laya decisor), parâmetros essenciais, saída,
/// métricas (tokens, latência, stop_reason, fingerprint) e histórico de
/// [RunRecord] com cópia de JSON e comparação golden ([diffRuns]).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/laya_types.dart';
import '../domain/llm_config.dart';
import '../domain/run_record.dart';
import '../domain/templates.dart';
import '../engines/llm_engine.dart';
import '../services/store.dart';
import 'app_services.dart';
import 'common.dart';
import 'llm_config_form.dart';

enum RunMode { llm, laya }

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

  RunMode _mode = RunMode.llm;
  late LlmConfig _config = widget.store.llmConfig;
  bool _running = false;

  String _output = '';
  String _stopReason = '—';
  int _promptTokens = 0;
  int _outputTokens = 0;
  int _latencyMs = 0;
  String _signature = '—';

  List<RunRecord> _history = const [];

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

  bool get _llmInstalled => AppServices.instance.llmModelPath != null;
  bool get _layaInstalled =>
      AppServices.instance.layaModelPath != null &&
      AppServices.instance.layaTokenizerPath != null;

  List<TypedQuestion> get _layaQuestions {
    final shared = AppServices.instance.layaQuestions;
    if (shared.isNotEmpty) return shared;
    final id = widget.store.selectedTemplateId;
    for (final t in kLayaTemplates) {
      if (t.id == id) return t.questions;
    }
    return kLayaTemplates.first.questions;
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
    await widget.store.saveUserPrompt(_userCtrl.text);
    await widget.store.saveSystemPrompt(_systemCtrl.text);
    await widget.store.saveLlmConfig(_config);

    setState(() {
      _running = true;
      _output = '';
      _stopReason = '—';
      _promptTokens = 0;
      _outputTokens = 0;
      _latencyMs = 0;
      _signature = '—';
    });
    try {
      if (_mode == RunMode.llm) {
        await _runLlm(system, user);
      } else {
        await _runLaya(user);
      }
    } catch (e) {
      if (mounted) showSnack(context, 'Erro na execução: $e', error: true);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _runLlm(String system, String user) async {
    final services = AppServices.instance;
    final modelPath = services.llmModelPath;
    if (modelPath == null) {
      showSnack(context,
          'Modelo GGUF não instalado. Descarrega o GGUF na aba Modelos.',
          error: true);
      return;
    }
    final engine =
        await services.ensureLlm(modelPath: modelPath, config: _config);
    final messages = [
      if (system.isNotEmpty) ChatMessage('system', system),
      ChatMessage('user', user),
    ];
    final buffer = StringBuffer();
    final startedAt = DateTime.now();
    GenEnd? endOrNull;
    await for (final ev in engine.generate(messages: messages, config: _config)) {
      if (ev is GenDelta) {
        buffer.write(ev.text);
        if (mounted) setState(() => _output = buffer.toString());
      } else if (ev is GenEnd) {
        endOrNull = ev;
      }
    }
    final output = buffer.toString();
    final end = endOrNull ??
        GenEnd(
          promptTokens: await engine.countTokens(user),
          outputTokens: 0,
          latencyMs: 0,
          stopReason: 'aborted',
        );
    final signature = runSignature(
      modelId: engine.modelId,
      prompt: user,
      params: _config.toJson(),
      systemPrompt: system.isEmpty ? null : system,
    );
    final record = RunRecord(
      id: '${signature}_${startedAt.microsecondsSinceEpoch}',
      startedAt: startedAt,
      kind: 'llm',
      modelId: engine.modelId,
      prompt: user,
      systemPrompt: system.isEmpty ? null : system,
      params: _config.toJson(),
      output: output,
      promptTokens: end.promptTokens,
      outputTokens: end.outputTokens,
      latencyMs: end.latencyMs,
      signature: signature,
      stopReason: end.stopReason,
    );
    await _finishRun(record);
    if (mounted) {
      setState(() {
        _output = output;
        _stopReason = end.stopReason;
        _promptTokens = end.promptTokens;
        _outputTokens = end.outputTokens;
        _latencyMs = end.latencyMs;
        _signature = signature;
      });
    }
  }

  Future<void> _runLaya(String user) async {
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
    final questions = _layaQuestions;
    final request = LayaRequest(state: user, questions: questions);
    final startedAt = DateTime.now();
    final response = await engine.decide(request);
    final output = _summarize(response);
    final signature = runSignature(
      modelId: engine.modelId,
      prompt: user,
      params: {
        'laya_config': widget.store.layaConfig.toJson(),
        'questions': [for (final q in questions) q.toJson()],
      },
    );
    final record = RunRecord(
      id: '${signature}_${startedAt.microsecondsSinceEpoch}',
      startedAt: startedAt,
      kind: 'laya',
      modelId: engine.modelId,
      prompt: user,
      params: request.toJson(),
      output: output,
      promptTokens: response.inputTokens,
      outputTokens: response.outputTokens,
      latencyMs: response.latencyMs,
      signature: signature,
      stopReason: 'decided',
    );
    await _finishRun(record);
    if (mounted) {
      setState(() {
        _output = output;
        _stopReason = 'decided';
        _promptTokens = response.inputTokens;
        _outputTokens = response.outputTokens;
        _latencyMs = response.latencyMs;
        _signature = signature;
      });
    }
  }

  String _summarize(LayaResponse response) {
    final buf = StringBuffer();
    for (final e in response.answers.entries) {
      final a = e.value;
      buf.writeln('${e.key}: ${describeAnswer(a)}');
      final probs = a.probabilities.entries.toList()
        ..sort((x, y) => y.value.compareTo(x.value));
      buf.writeln('  probabilities: ' +
          probs.map((p) => '${p.key}=${p.value.toStringAsFixed(3)}').join(' | '));
      buf.writeln('  confidence=${a.confidence.toStringAsFixed(3)} · '
          'answer_confidence=${a.answerConfidence.toStringAsFixed(3)} · '
          'act_probability=${a.actProbability.toStringAsFixed(3)}');
    }
    buf.writeln('usage: input=${response.inputTokens} · '
        'output=${response.outputTokens} · latency=${response.latencyMs} ms');
    return buf.toString().trimRight();
  }

  Future<void> _finishRun(RunRecord record) async {
    await widget.store.addRun(record);
    if (!mounted) return;
    setState(() => _history = widget.store.runs);
  }

  Future<void> _copyJson(RunRecord record) async {
    await Clipboard.setData(ClipboardData(text: prettyJson(record.toJson())));
    if (mounted) {
      showSnack(context, 'JSON do registo copiado');
    }
  }

  Future<void> _saveGolden(RunRecord record) async {
    await widget.store.setGolden(record);
    if (mounted) {
      showSnack(context, 'Golden guardado para a assinatura ${record.signature}');
    }
  }

  void _compareGolden(RunRecord record) {
    final golden = widget.store.goldenFor(record.signature);
    if (golden == null) {
      showSnack(context,
          'Sem golden registado para a assinatura ${record.signature} — toca em "Guardar golden".',
          error: true);
      return;
    }
    final diff = diffRuns(record, golden);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Comparação golden'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            MetricRow('assinatura', record.signature),
            MetricRow('golden', golden.signature),
            MetricRow(
                'saída idêntica', diff.identicalOutput ? 'sim ✔' : 'não ✘'),
            if (diff.firstDivergence != null) ...[
              const SizedBox(height: 8),
              Text('Primeira divergência:',
                  style: Theme.of(ctx).textTheme.labelLarge),
              SelectableText(diff.firstDivergence!),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Fechar'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final services = AppServices.instance;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const SectionHeader('Prompts'),
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
        const SectionHeader('Modo'),
        SegmentedButton<RunMode>(
          segments: const [
            ButtonSegment(
                value: RunMode.llm, label: Text('LLM MiniCPM5-2B')),
            ButtonSegment(value: RunMode.laya, label: Text('Laya (decisor)')),
          ],
          selected: {_mode},
          onSelectionChanged: (s) => setState(() => _mode = s.first),
        ),
        if (_mode == RunMode.laya)
          const InfoBanner(
            'Em modo Laya o user prompt é o `state`; as perguntas tipadas vêm '
            'do template selecionado no separador Laya.',
            icon: Icons.rule,
          ),
        if (_mode == RunMode.llm && !_llmInstalled)
          const InfoBanner(
            'Modelo MiniCPM5-2B (GGUF) não instalado. '
            'Descarrega o GGUF na aba Modelos.',
            icon: Icons.warning_amber,
          ),
        if (_mode == RunMode.laya && !_layaInstalled)
          const InfoBanner(
            'Kit ONNX do Laya não instalado. Descarrega o kit na aba Modelos.',
            icon: Icons.warning_amber,
          ),
        const SectionHeader('Parâmetros essenciais (defaults determinísticos)'),
        LlmConfigEditor(
          config: _config,
          compact: true,
          onChanged: (c) => setState(() => _config = c),
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: _running ? null : _run,
          icon: _running
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.play_arrow),
          label: Text(_running ? 'A executar…' : 'Executar'),
        ),
        const SectionHeader('Saída'),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant),
            borderRadius: BorderRadius.circular(8),
          ),
          child: SelectableText(
            _output.isEmpty ? 'sem saída' : _output,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          ),
        ),
        const SectionHeader('Métricas'),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            children: [
              MetricRow('tokens in / out', '$_promptTokens / $_outputTokens'),
              MetricRow('latência', '$_latencyMs ms'),
              MetricRow('stop_reason', _stopReason),
              MetricRow('fingerprint da execução', _signature),
            ],
          ),
        ),
        SectionHeader(
          'Histórico (${_history.length})',
          trailing: _history.isEmpty
              ? null
              : TextButton(
                  onPressed: () async {
                    await widget.store.clearRuns();
                    if (mounted) {
                      setState(() => _history = widget.store.runs);
                      showSnack(context, 'Histórico limpo');
                    }
                  },
                  child: const Text('Limpar'),
                ),
        ),
        if (_history.isEmpty)
          const InfoBanner(
            'Sem execuções registadas. As corridas aparecem aqui com métricas, '
            'assinatura e comparação golden.',
            icon: Icons.history,
          ),
        for (final record in _history) _RunRecordTile(
          record: record,
          hasGolden: widget.store.goldenFor(record.signature) != null,
          onCopy: () => _copyJson(record),
          onGolden: () => _saveGolden(record),
          onCompare: () => _compareGolden(record),
        ),
        services.llm == null && services.laya == null
            ? const InfoBanner(
                'Motores ainda não ligados a esta build — as execuções '
                'mostram erro claro em vez de rebentar.',
                icon: Icons.info_outline,
              )
            : const SizedBox.shrink(),
      ],
    );
  }
}

class _RunRecordTile extends StatelessWidget {
  const _RunRecordTile({
    required this.record,
    required this.hasGolden,
    required this.onCopy,
    required this.onGolden,
    required this.onCompare,
  });

  final RunRecord record;
  final bool hasGolden;
  final VoidCallback onCopy;
  final VoidCallback onGolden;
  final VoidCallback onCompare;

  @override
  Widget build(BuildContext context) {
    final t = record.startedAt.toLocal();
    final when =
        '${t.year.toString().padLeft(4, '0')}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Chip(
                    label: Text(record.kind),
                    visualDensity: VisualDensity.compact),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(record.modelId,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall),
                ),
                Text(when, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
            const SizedBox(height: 4),
            MetricRow('prompt', record.prompt),
            MetricRow('tokens in / out',
                '${record.promptTokens} / ${record.outputTokens}'),
            MetricRow('latência', '${record.latencyMs} ms'),
            MetricRow('stop_reason', record.stopReason ?? '—'),
            MetricRow('assinatura', record.signature),
            const SizedBox(height: 4),
            Wrap(
              spacing: 4,
              children: [
                TextButton.icon(
                  onPressed: onCopy,
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('Copiar JSON'),
                ),
                TextButton.icon(
                  onPressed: onGolden,
                  icon: const Icon(Icons.save_alt, size: 16),
                  label: const Text('Guardar golden'),
                ),
                TextButton.icon(
                  onPressed: onCompare,
                  icon: Icon(
                    hasGolden ? Icons.rule : Icons.rule_outlined,
                    size: 16,
                  ),
                  label: Text(hasGolden ? 'Comparar golden' : 'Comparar (sem golden)'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}