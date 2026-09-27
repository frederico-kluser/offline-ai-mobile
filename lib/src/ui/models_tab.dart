/// Tela 4 — Modelos: catálogo descarregável (GGUF MiniCPM5-2B + kit ONNX
/// Laya), estado instalado, download com progresso, apagar ficheiros e
/// abertura da configuração dos motores.
library;

import 'dart:async';

import 'package:flutter/material.dart';

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
  }

  void _startDownload(ModelArtifact artifact) {
    final dest = _destDir;
    if (dest == null) {
      showSnack(context, 'Pasta de destino indisponível.', error: true);
      return;
    }
    final sub =
        AppServices.instance.downloads.download(artifact, dest).listen(
      (p) {
        if (!mounted) return;
        setState(() => _progress[artifact.id] = p);
        switch (p.state) {
          case DownloadState.done:
            AppServices.instance.refreshInstalled(dest).then((_) {
              if (mounted) setState(() {});
            });
            showSnack(context, '${artifact.label}: instalado');
          case DownloadState.error:
            showSnack(context, '${artifact.label}: ${p.message}', error: true);
          case DownloadState.cancelled:
            showSnack(context, '${artifact.label}: download cancelado');
          default:
            break;
        }
      },
      onError: (Object e) {
        if (mounted) {
          showSnack(context, 'Erro no download: $e', error: true);
        }
      },
      onDone: () => _subs.remove(artifact.id),
    );
    _subs[artifact.id] = sub;
    setState(() => _progress[artifact.id] = DownloadProgress(
          artifactId: artifact.id,
          state: DownloadState.downloading,
          fraction: 0,
          message: 'a começar…',
          receivedBytes: 0,
          totalBytes: artifact.totalBytes,
        ));
  }

  Future<void> _cancelDownload(ModelArtifact artifact) async {
    await AppServices.instance.downloads.cancel(artifact.id);
    if (mounted) {
      showSnack(context, '${artifact.label}: cancelamento pedido');
    }
  }

  Future<void> _delete(ModelArtifact artifact) async {
    final dest = _destDir;
    if (dest == null) return;
    try {
      await AppServices.instance.downloads.delete(artifact.id, dest);
      final installed = await AppServices.instance.refreshInstalled(dest);
      if (mounted) {
        setState(() => _installed = installed);
        showSnack(context, '${artifact.label}: ficheiros apagados');
      }
    } catch (e) {
      if (mounted) showSnack(context, 'Erro ao apagar: $e', error: true);
    }
  }

  void _openConfig(ModelArtifact artifact) {
    if (artifact.kind == 'llm-gguf') {
      showLlmConfigSheet(context, widget.store).then((saved) {
        if (saved && mounted) {
          showSnack(context, 'Configuração do LLM guardada');
        }
      });
    } else {
      showLayaConfigSheet(context, widget.store).then((saved) {
        if (saved && mounted) {
          showSnack(context, 'Configuração do Laya guardada');
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const SectionHeader('Destino dos modelos'),
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
            ],
          ),
        ),
        if (_destError != null)
          InfoBanner(_destError!,
              icon: Icons.folder_off, color: Colors.red),
        SectionHeader(
          'Catálogo (${kModelCatalog.length})',
          trailing: TextButton.icon(
            onPressed: _init,
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('Atualizar'),
          ),
        ),
        for (final artifact in kModelCatalog)
          _ArtifactCard(
            artifact: artifact,
            installedPath: _installed[artifact.id],
            progress: _progress[artifact.id],
            busy: _subs.containsKey(artifact.id),
            onDownload: () => _startDownload(artifact),
            onCancel: () => _cancelDownload(artifact),
            onDelete: () => _delete(artifact),
            onOpenConfig: () => _openConfig(artifact),
          ),
      ],
    );
  }
}

class _ArtifactCard extends StatelessWidget {
  const _ArtifactCard({
    required this.artifact,
    required this.installedPath,
    required this.progress,
    required this.busy,
    required this.onDownload,
    required this.onCancel,
    required this.onDelete,
    required this.onOpenConfig,
  });

  final ModelArtifact artifact;
  final String? installedPath;
  final DownloadProgress? progress;
  final bool busy;
  final VoidCallback onDownload;
  final VoidCallback onCancel;
  final VoidCallback onDelete;
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
                  child: Text(artifact.label,
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(fontWeight: FontWeight.bold)),
                ),
                Chip(
                  label: Text(artifact.kind),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(artifact.description,
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 4),
            MetricRow('tamanho', '${artifact.sizeLabel} (${artifact.files.length} ficheiro(s))'),
            MetricRow(
              'estado',
              installed ? 'instalado' : 'não instalado',
            ),
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
                if (installed)
                  OutlinedButton.icon(
                    onPressed: onDelete,
                    icon: const Icon(Icons.delete_outline, size: 16),
                    label: const Text('Apagar'),
                  ),
                if (installed)
                  TextButton.icon(
                    onPressed: onOpenConfig,
                    icon: const Icon(Icons.settings, size: 16),
                    label: const Text('Abrir config'),
                  ),
              ],
            ),
            if (downloading && progress != null)
              Text(
                '${(progress!.fraction * 100).toStringAsFixed(1)}%',
                style: Theme.of(context).textTheme.labelSmall,
              ),
          ],
        ),
      ),
    );
  }
}