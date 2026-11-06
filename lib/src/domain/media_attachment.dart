/// Anexos multimodais do compositor (imagem, vídeo, áudio).
library;

enum MediaKind { image, video, audio }

extension MediaKindX on MediaKind {
  String get wire => name;

  String get label => switch (this) {
        MediaKind.image => 'Imagem',
        MediaKind.video => 'Vídeo',
        MediaKind.audio => 'Áudio',
      };

  String get iconName => switch (this) {
        MediaKind.image => 'image',
        MediaKind.video => 'video',
        MediaKind.audio => 'audio',
      };

  static MediaKind? fromWire(String? s) {
    for (final k in MediaKind.values) {
      if (k.wire == s) return k;
    }
    return null;
  }
}

/// Um ficheiro anexado ao pedido. O caminho é local (a app é offline); a
/// codificação para o motor (RGB/AAC/PCM) acontece na camada de engenharia.
class MediaAttachment {
  final MediaKind kind;
  final String path;
  final String label;
  final int? bytes;
  final String? sha256;
  final double? durationSeconds;

  const MediaAttachment({
    required this.kind,
    required this.path,
    required this.label,
    this.bytes,
    this.sha256,
    this.durationSeconds,
  });

  String get extension {
    final i = path.lastIndexOf('.');
    return i < 0 ? '' : path.substring(i + 1).toLowerCase();
  }

  Map<String, dynamic> toJson() => {
        'kind': kind.wire,
        'path': path,
        'label': label,
        if (bytes != null) 'bytes': bytes,
        if (sha256 != null) 'sha256': sha256,
        if (durationSeconds != null) 'duration_seconds': durationSeconds,
      };

  factory MediaAttachment.fromJson(Map<String, dynamic> j) => MediaAttachment(
        kind: MediaKindX.fromWire(j['kind'] as String?) ?? MediaKind.image,
        path: j['path'] as String,
        label: j['label'] as String? ?? j['path'] as String,
        bytes: (j['bytes'] as num?)?.toInt(),
        sha256: j['sha256'] as String?,
        durationSeconds: (j['duration_seconds'] as num?)?.toDouble(),
      );
}
