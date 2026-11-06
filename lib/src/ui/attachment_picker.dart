/// Seletor de anexos multimodais e chips de apresentação.
///
/// Usa `file_selector` (plugin oficial, Android/iOS/desktop): o utilizador
/// escolhe imagem, vídeo ou áudio e a app guarda o caminho local. A conversão
/// para RGB/PCM/vídeo acontece na camada de engenharia.
library;

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../domain/media_attachment.dart';

class AttachmentPicker {
  const AttachmentPicker();

  static const Map<MediaKind, List<String>> _extensions = {
    MediaKind.image: ['png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp'],
    MediaKind.video: ['mp4', 'mov', 'm4v', 'webm', 'mkv'],
    MediaKind.audio: ['wav', 'mp3', 'm4a', 'aac', 'ogg', 'flac'],
  };

  Future<MediaAttachment?> pick(MediaKind kind) async {
    final group = XTypeGroup(
      label: kind.label,
      extensions: _extensions[kind],
    );
    final file = await openFile(acceptedTypeGroups: [group]);
    if (file == null) return null;
    final f = File(file.path);
    int? bytes;
    try {
      bytes = await f.length();
    } catch (_) {
      bytes = null;
    }
    return MediaAttachment(
      kind: kind,
      path: file.path,
      label: file.name.isEmpty ? file.path : file.name,
      bytes: bytes,
    );
  }

  Future<List<MediaAttachment>> pickMany(MediaKind kind,
      {int limit = 4}) async {
    final group = XTypeGroup(
      label: kind.label,
      extensions: _extensions[kind],
    );
    final files = await openFiles(acceptedTypeGroups: [group]);
    final out = <MediaAttachment>[];
    for (final file in files.take(limit)) {
      final f = File(file.path);
      int? bytes;
      try {
        bytes = await f.length();
      } catch (_) {
        bytes = null;
      }
      out.add(MediaAttachment(
        kind: kind,
        path: file.path,
        label: file.name.isEmpty ? file.path : file.name,
        bytes: bytes,
      ));
    }
    return out;
  }
}

/// Botões "Imagem / Vídeo / Áudio" para o compositor.
class AttachmentButtons extends StatelessWidget {
  const AttachmentButtons({
    super.key,
    required this.onPick,
    this.enabled = true,
  });

  final ValueChanged<MediaKind> onPick;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 4,
      children: [
        for (final kind in MediaKind.values)
          OutlinedButton.icon(
            onPressed: enabled ? () => onPick(kind) : null,
            icon: Icon(
              switch (kind) {
                MediaKind.image => Icons.image_outlined,
                MediaKind.video => Icons.video_library_outlined,
                MediaKind.audio => Icons.graphic_eq,
              },
              size: 18,
            ),
            label: Text(kind.label),
          ),
      ],
    );
  }
}

/// Lista de anexos com remoção.
class AttachmentStrip extends StatelessWidget {
  const AttachmentStrip({
    super.key,
    required this.attachments,
    required this.onRemove,
  });

  final List<MediaAttachment> attachments;
  final ValueChanged<int> onRemove;

  @override
  Widget build(BuildContext context) {
    if (attachments.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (var i = 0; i < attachments.length; i++)
            InputChip(
              avatar: Icon(
                switch (attachments[i].kind) {
                  MediaKind.image => Icons.image,
                  MediaKind.video => Icons.movie,
                  MediaKind.audio => Icons.audiotrack,
                },
                size: 16,
              ),
              label: Text(
                attachments[i].label,
                overflow: TextOverflow.ellipsis,
              ),
              onDeleted: () => onRemove(i),
            ),
        ],
      ),
    );
  }
}

/// Pré-visualização simples de uma imagem local.
class LocalImagePreview extends StatelessWidget {
  const LocalImagePreview({
    super.key,
    required this.path,
    this.height = 160,
  });

  final String path;
  final double height;

  @override
  Widget build(BuildContext context) {
    final f = File(path);
    if (!f.existsSync()) {
      return const InfoText('imagem não encontrada');
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.file(
        f,
        height: height,
        width: double.infinity,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) =>
            const InfoText('pré-visualização indisponível'),
      ),
    );
  }
}

class InfoText extends StatelessWidget {
  const InfoText(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: Theme.of(context).textTheme.bodySmall,
      );
}
