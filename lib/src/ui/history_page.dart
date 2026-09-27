/// Página "Histórico de execuções" — a lista de corridas vive FORA da página
/// de prompts (uma página = um objetivo).
library;

import 'package:flutter/material.dart';

import '../domain/run_record.dart';
import '../services/store.dart';
import 'common.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key, required this.store});

  final AppStore store;

  static Future<void> open(BuildContext context, AppStore store) =>
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => HistoryPage(store: store)),
      );

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  late List<RunRecord> _runs = widget.store.runs;

  Future<void> _copyJson(RunRecord record) async {
    showJsonDialog(context, 'Registo ${record.signature}', record.toJson());
  }

  Future<void> _saveGolden(RunRecord record) async {
    await widget.store.setGolden(record);
    if (!mounted) return;
    showSnack(context, 'Golden guardado para ${record.signature}');
  }

  Future<void> _compareGolden(RunRecord record) async {
    final golden = widget.store.goldenFor(record.signature);
    if (golden == null) {
      showSnack(context, 'Sem golden para esta assinatura — guarda um primeiro',
          error: true);
      return;
    }
    final diff = diffRuns(golden, record);
    if (!mounted || !context.mounted) return;
    showJsonDialog(context, 'Comparação golden', {
      'assinatura_golden': diff.signatureA,
      'assinatura_execucao': diff.signatureB,
      'saida_identica': diff.identicalOutput,
      'primeira_divergencia': diff.firstDivergence ?? '—',
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Histórico (${_runs.length})'),
        actions: [
          if (_runs.isNotEmpty)
            TextButton(
              onPressed: () async {
                await widget.store.clearRuns();
                if (!mounted || !context.mounted) return;
                setState(() => _runs = widget.store.runs);
                showSnack(context, 'Histórico limpo');
              },
              child: const Text('Limpar'),
            ),
        ],
      ),
      body: _runs.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: InfoBanner(
                  'Sem execuções registadas. As corridas aparecem aqui com '
                  'métricas, assinatura e comparação golden.',
                  icon: Icons.history,
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                for (final record in _runs)
                  RunRecordTile(
                    record: record,
                    hasGolden: widget.store.goldenFor(record.signature) != null,
                    onCopy: () => _copyJson(record),
                    onGolden: () => _saveGolden(record),
                    onCompare: () => _compareGolden(record),
                  ),
                const SizedBox(height: 24),
              ],
            ),
    );
  }
}

/// Cartão de um registo de execução (partilhado com a app inteira).
class RunRecordTile extends StatelessWidget {
  const RunRecordTile({
    super.key,
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
                  label: Text(
                      hasGolden ? 'Comparar golden' : 'Comparar (sem golden)'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}