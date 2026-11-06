/// Ecrã 4 — Modelos: catálogo LFM3/d1, perfilador de hardware, benchmark real,
/// downloads multi-ficheiro verificados e gestão do que está instalado.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../services/device_capability_service.dart';
import '../services/download_manager.dart';
import '../services/model_registry.dart';
import '../services/store.dart';
import 'app_services.dart';
import 'common.dart';
import 'config_sheets.dart';

class ModelsTab extends StatefulWidget {
  const ModelsTab({super.key, required this.store});

  final AppStore store;

  @override
  State<ModelsTab> createState() => _ModelsTabState();
}

class _ModelsTabState extends State<ModelsTab> {
  String? _destDir;
  String? _destError;
  Map<String, String> _installed = const {};
  final Map<String, DownloadProgress> _progress = {};
  final Map<String, StreamSubscription<DownloadProgress>> _subs = {};
  HardwareProfileReport? _hardware;
  HardwareBenchmarkResult? _benchmark;
  bool _probing = false;
  String? _hardwareError;

  final DeviceCapabilityService _capabilities = DeviceCapabilityService();

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    for (final sub in _subs.values) {
      sub.cancel();
    }
    super.dispose();
  }

  Future<void> _init() async {
    try {
      final dir = await AppServices.resolveModelsDir();
      if (dir == null) {
        throw StateError('pasta de documentos indisponível');
      }
      final installed = await AppServices.instance.refreshInstalled(dir);
      if (!mounted) return;
      setState(() {
        _destDir = dir;
        _destError = null;
        _installed = installed;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _destError = 'Não foi possível obter a pasta de destino: $e';
      });
    }
    await _probeHardware();
  }

  Future<void> _probeHardware() async {
    if (_probing) return;
    setState(() {
      _probing = true;
      _hardwareError = null;
    });
    try {
      final report = await _capabilities.evaluateStaticCapabilities();
      AppServices.instance.hardware = report;
      if (!mounted) return;
      setState(() => _hardware = report);
    } catch (e) {
      if (!mounted) return;
      setState(() => _hardwareError =
          'Perfilador indisponível (canal nativo não ligado): $e');
    } finally {
      if (mounted) setState(() => _probing = false);
    }
  }

  Future<void> _runBenchmark() async {
    final bundle = AppServices.instance.activeTextBundle;
    if (bundle == null) {
      showSnack(context,
          'Instala primeiro o LFM3-1.7B (QAD-Q4_0) para medir o dispositivo.',
          error: true);
      return;
    }
    setState(() => _probing = true);
    try {
      final services = AppServices.instance;
      final engine =
          await services.ensureLlm(bundle: bundle, config: widget.store.llmConfig);
      final result = await _capabilities.benchmarkLoaded(
        engine: engine,
        modelId: engine.modelId,
        config: widget.store.llmConfig,
      );
      if (!mounted) return;
      setState(() {
        _benchmark = result;
        _hardware = _hardware?.copyWith(
          measuredPrefillTokPerSec: result.prefillTokPerSec,
          measuredDecodeTokPerSec: result.decodeTokPerSec,
        );
      });
      AppServices.instance.hardware = _hardware;
    } catch (e) {
      if (mounted) showSnack(context, 'Benchmark falhou: $e', error: true);
    } finally {
      if (mounted) setState(() => _probing = false);
    }
  }

  void _startDownload(ModelBundle bundle) {
    final dest = _destDir;
    if (dest == null) {
      showSnack(context, 'Pasta de destino indisponível.', error: true);
      return;
    }
    final sub = AppServices.instance.downloads.download(bundle, dest).listen(
      (p) {
        if (!mounted) return;
        setState(() => _progress[bundle.id] = p);
        switch (p.state) {
          case DownloadState.done:
            AppServices.instance.refreshInstalled(dest).then((_) {
              if (mounted) {
                setState(() => _installed = AppServices.instance.installed);
              }
            });
            showSnack(context, '${bundle.label}: instalado');
          case DownloadState.error:
            showSnack(context, '${bundle.label}: ${p.message}', error: true);
          case DownloadState.cancelled:
            showSnack(context, '${bundle.label}: download cancelado');
          default:
            break;
        }
      },
      onError: (Object e) {
        if (mounted) {
          showSnack(context, 'Erro no download: $e', error: true);
        }
      },
      onDone: () => _subs.remove(bundle.id),
    );
    _subs[bundle.id] = sub;
    setState(() => _progress[bundle.id] = DownloadProgress(
          bundleId: bundle.id,
          state: DownloadState.downloading,
          fraction: 0,
          message: 'a começar…',
          receivedBytes: 0,
          totalBytes: bundle.totalBytes,
        ));
  }

  Future<void> _cancelDownload(ModelBundle bundle) async {
    await AppServices.instance.downloads.cancel(bundle.id);
    if (mounted) showSnack(context, '${bundle.label}: cancelamento pedido');
  }

  Future<void> _delete(ModelBundle bundle) async {
    final dest = _destDir;
    if (dest == null) return;
    try {
      await AppServices.instance.downloads.delete(bundle.id, dest);
      final installed = await AppServices.instance.refreshInstalled(dest);
      if (mounted) {
        setState(() => _installed = installed);
        showSnack(context, '${bundle.label}: ficheiros apagados');
      }
    } catch (e) {
      if (mounted) showSnack(context, 'Erro ao apagar: $e', error: true);
    }
  }

  Future<void> _verify(ModelBundle bundle) async {
    final dest = _destDir;
    if (dest == null) return;
    final r = await AppServices.instance.downloads.verify(bundle, dest);
    if (!mounted) return;
    showSnack(
      context,
      r.ok
          ? '${bundle.label}: SHA-256 de todos os ficheiros confere'
          : '${bundle.label}: ${r.error}',
      error: !r.ok,
    );
  }

  Future<void> _openConfig(ModelBundle bundle) async {
    final changed = bundle.isD1
        ? await showD1ConfigSheet(context, widget.store)
        : await showLlmConfigSheet(context, widget.store);
    if (changed && mounted) {
      showSnack(context, 'Configuração guardada');
    }
  }

  @override
  Widget build(BuildContext context) {
    final hardware = _hardware;
    final benchmark = _benchmark;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const SectionHeader('Perfil do dispositivo'),
        if (_hardwareError != null)
          InfoBanner(_hardwareError!, icon: Icons.developer_board_off),
        if (hardware != null)
          _HardwareCard(
            report: hardware,
            benchmark: benchmark,
            probing: _probing,
            onRefresh: _probeHardware,
            onBenchmark: _runBenchmark,
          )
        else if (_probing)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          ),
        SectionHeader('Destino dos modelos'),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Pasta de destino (documents dir):',
                  style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 4),
              SelectableText(_destDir ?? '— indisponível —',
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
              const SizedBox(height: 4),
              const Text(
                'Espelho: github.com/frederico-kluser/lfm3-mobile-models '
                '(release models-lfm3-suite-v1) · fallback: Hugging Face oficial',
                style: TextStyle(fontSize: 11),
              ),
            ],
          ),
        ),
        if (_destError != null)
          InfoBanner(_destError!, icon: Icons.folder_off, color: Colors.red),
        SectionHeader(
          'Geradores LFM3 (${kGeneratorBundles.length})',
          trailing: TextButton.icon(
            onPressed: _init,
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('Atualizar'),
          ),
        ),
        for (final bundle in kGeneratorBundles)
          _BundleCard(
            bundle: bundle,
            installedPath: _installed[bundle.id],
            progress: _progress[bundle.id],
            busy: _subs.containsKey(bundle.id),
            onDownload: () => _startDownload(bundle),
            onCancel: () => _cancelDownload(bundle),
            onDelete: () => _delete(bundle),
            onVerify: () => _verify(bundle),
            onOpenConfig: () => _openConfig(bundle),
          ),
        SectionHeader('Decisores d1 (${kD1Bundles.length})'),
        for (final bundle in kD1Bundles)
          _BundleCard(
            bundle: bundle,
            installedPath: _installed[bundle.id],
            progress: _progress[bundle.id],
            busy: _subs.containsKey(bundle.id),
            onDownload: () => _startDownload(bundle),
            onCancel: () => _cancelDownload(bundle),
            onDelete: () => _delete(bundle),
            onVerify: () => _verify(bundle),
            onOpenConfig: () => _openConfig(bundle),
          ),
        const SizedBox(height: 24),
      ],
    );
  }
}

class _HardwareCard extends StatelessWidget {
  const _HardwareCard({
    required this.report,
    required this.benchmark,
    required this.probing,
    required this.onRefresh,
    required this.onBenchmark,
  });

  final HardwareProfileReport report;
  final HardwareBenchmarkResult? benchmark;
  final bool probing;
  final VoidCallback onRefresh;
  final VoidCallback onBenchmark;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tierColor = switch (report.tier) {
      DeviceSupportTier.unsupported => scheme.error,
      DeviceSupportTier.tier1Basic => Colors.orange,
      DeviceSupportTier.tier2Standard => Colors.blue,
      DeviceSupportTier.tier3Pro => Colors.green,
    };
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(report.tier.label,
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(
                              fontWeight: FontWeight.bold, color: tierColor)),
                ),
                Chip(
                  label: Text(report.tier.explanation),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 8),
            MetricRow('RAM total / livre',
                '${report.totalRamMb} MB / ${report.availableRamMb} MB'),
            MetricRow('disco livre', '${report.freeStorageMb} MB'),
            MetricRow('núcleos de performance', '${report.performanceCores}'),
            MetricRow('ARM dotprod / i8mm',
                '${report.hasArmDotProd ? 'sim' : 'não'} / ${report.hasArmI8mm ? 'sim' : 'não'}'),
            MetricRow('GPU/Metal', report.hasGpuAcceleration ? 'sim' : 'não'),
            MetricRow('simulador iOS', report.isIosSimulator ? 'sim' : 'não'),
            if (report.measuredPrefillTokPerSec != null)
              MetricRow('prefill medido',
                  '${report.measuredPrefillTokPerSec!.toStringAsFixed(1)} tok/s'),
            if (report.measuredDecodeTokPerSec != null)
              MetricRow('decode medido',
                  '${report.measuredDecodeTokPerSec!.toStringAsFixed(1)} tok/s'),
            if (benchmark != null) ...[
              const SizedBox(height: 4),
              InfoBanner(
                '${benchmark!.recommendation} (${benchmark!.modelId})',
                icon: Icons.speed,
              ),
            ],
            const Divider(height: 16),
            Text('Matriz de compatibilidade',
                style: Theme.of(context)
                    .textTheme
                    .labelLarge
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            for (final e in report.modelCompatibilityMatrix.entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 3,
                      child: Text(e.key,
                          style: Theme.of(context).textTheme.bodySmall),
                    ),
                    Expanded(
                      flex: 2,
                      child: Text(
                        e.value,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: e.value.startsWith('SUPORTADO')
                                  ? Colors.green
                                  : e.value.startsWith('LENTO')
                                      ? Colors.orange
                                      : scheme.error,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: probing ? null : onRefresh,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Atualizar perfil'),
                ),
                FilledButton.tonalIcon(
                  onPressed: probing ? null : onBenchmark,
                  icon: probing
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.speed, size: 16),
                  label: const Text('Testar compatibilidade real'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _BundleCard extends StatelessWidget {
  const _BundleCard({
    required this.bundle,
    required this.installedPath,
    required this.progress,
    required this.busy,
    required this.onDownload,
    required this.onCancel,
    required this.onDelete,
    required this.onVerify,
    required this.onOpenConfig,
  });

  final ModelBundle bundle;
  final String? installedPath;
  final DownloadProgress? progress;
  final bool busy;
  final VoidCallback onDownload;
  final VoidCallback onCancel;
  final VoidCallback onDelete;
  final VoidCallback onVerify;
  final VoidCallback onOpenConfig;

  @override
  Widget build(BuildContext context) {
    final installed = installedPath != null;
    final downloading = busy && (progress?.state == DownloadState.downloading);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(bundle.label,
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(fontWeight: FontWeight.bold)),
                ),
                Chip(
                  label: Text(bundle.kind),
                  visualDensity: VisualDensity.compact,
                ),
                if (bundle.family == ModelFamily.lfm2Legacy)
                  const Padding(
                    padding: EdgeInsets.only(left: 4),
                    child: Chip(
                      label: Text('LFM2 legado'),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(bundle.description,
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 4),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                CapabilityChip('texto'),
                if (bundle.supportsThinking) CapabilityChip('think'),
                if (bundle.supportsVision) CapabilityChip('visão'),
                if (bundle.supportsVideo) CapabilityChip('vídeo'),
                if (bundle.supportsAudio) CapabilityChip('áudio'),
                if (bundle.supportsTools) CapabilityChip('tools'),
                CapabilityChip(bundle.sizeLabel),
                CapabilityChip('${bundle.files.length} ficheiro(s)'),
                CapabilityChip(bundle.fullyVerified ? 'SHA verificado' : 'SHA pendente'),
              ],
            ),
            const SizedBox(height: 4),
            MetricRow('RAM livre / disco',
                '${bundle.minFreeRamMb} MB / ${bundle.minFreeDiskMb} MB'),
            MetricRow('tier mínimo', 'Tier ${bundle.tier}'),
            MetricRow('estado', installed ? 'instalado' : 'não instalado'),
            if (installedPath != null)
              SelectableText(installedPath!,
                  style:
                      const TextStyle(fontFamily: 'monospace', fontSize: 11)),
            if (progress != null && busy) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: progress!.fraction.clamp(0.0, 1.0)),
              const SizedBox(height: 4),
              Text(
                '${progress!.message} · '
                '${formatBytes(progress!.receivedBytes)} / ${formatBytes(progress!.totalBytes)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 4),
            Wrap(
              spacing: 4,
              children: [
                if (busy)
                  OutlinedButton.icon(
                    onPressed: onCancel,
                    icon: const Icon(Icons.close, size: 16),
                    label: const Text('Cancelar'),
                  )
                else if (!installed)
                  FilledButton.icon(
                    onPressed: onDownload,
                    icon: const Icon(Icons.download, size: 16),
                    label: const Text('Descarregar'),
                  ),
                if (installed) ...[
                  OutlinedButton.icon(
                    onPressed: onVerify,
                    icon: const Icon(Icons.verified_outlined, size: 16),
                    label: const Text('Verificar'),
                  ),
                  OutlinedButton.icon(
                    onPressed: onDelete,
                    icon: const Icon(Icons.delete_outline, size: 16),
                    label: const Text('Apagar'),
                  ),
                  TextButton.icon(
                    onPressed: onOpenConfig,
                    icon: const Icon(Icons.settings, size: 16),
                    label: const Text('Abrir config'),
                  ),
                ],
              ],
            ),
            if (downloading && progress != null)
              Text(
                '${(progress!.fraction * 100).toStringAsFixed(1)}%',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            if (bundle.notes.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(bundle.notes,
                  style: Theme.of(context).textTheme.labelSmall),
            ],
          ],
        ),
      ),
    );
  }
}
