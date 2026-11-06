/// Gera `manifest.json` a partir do catálogo Dart (fonte única de verdade).
///
///   dart run tools/dump_model_manifest.dart > ../lfm3-mobile-models/manifest.json
// ignore_for_file: avoid_print
library;

import 'dart:convert';

import 'package:offline_ai_mobile/src/services/model_registry.dart';

void main() {
  final bundles = <Map<String, dynamic>>[];
  for (final b in kModelCatalog) {
    bundles.add({
      'id': b.id,
      'label': b.label,
      'family': b.family.name,
      'kind': b.kind,
      'local_dir': b.localDirName,
      'main': b.mainFilename,
      'mmproj': b.mmprojFilename,
      'vision_encoder': b.visionEncoderFilename,
      'audio_encoder': b.audioEncoderFilename,
      'tokenizer': b.tokenizerFilename,
      'processor_config': b.processorConfigFilename,
      'total_bytes': b.totalBytes,
      'min_free_ram_mb': b.minFreeRamMb,
      'min_free_disk_mb': b.minFreeDiskMb,
      'tier': b.tier,
      'capabilities': {
        'vision': b.supportsVision,
        'video': b.supportsVideo,
        'audio': b.supportsAudio,
        'thinking': b.supportsThinking,
        'tools': b.supportsTools,
      },
      'license': b.license,
      'notes': b.notes,
      'files': [
        for (final f in b.files)
          {
            'filename': f.filename,
            'role': f.role.name,
            'bytes': f.bytes,
            'sha256': f.sha256,
            'source': f.url,
          },
      ],
    });
  }
  final out = {
    'schema': 1,
    'release': 'models-lfm3-suite-v1',
    'generated_at': DateTime.now().toUtc().toIso8601String(),
    'repository': 'frederico-kluser/lfm3-mobile-models',
    'upstream': 'https://huggingface.co/LiquidAI',
    'license': 'LFM Open License v1.0',
    'license_file': 'LICENSE',
    'license_sha256':
        '4d28ca14dedc0b3d0fcc2b3339f0e79931faa33874f3d24f522183a8fc70068c',
    'bundles': bundles,
  };
  print(const JsonEncoder.withIndent('  ').convert(out));
}
