/// Perfilador de hardware do telemóvel e recomendador de modelos LFM3/d1.
///
/// Fase 1 (estática): lê RAM total/livre, disco, núcleos de performance e
/// instruções ARM via MethodChannel `offline_ai_mobile/hardware` (Kotlin no
/// Android, Swift no iOS). Sem plugins, o canal devolve um erro claro e a UI
/// mostra "indisponível" em vez de rebentar.
///
/// Fase 2 (dinâmica): carrega um GGUF pequeno, mede prefill/decode reais e
/// ajusta `context_size`, `image_max_tokens` e o modo de raciocínio.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../domain/llm_config.dart';
import '../engines/llm_engine.dart';

enum DeviceSupportTier {
  unsupported,
  tier1Basic,
  tier2Standard,
  tier3Pro,
}

extension DeviceSupportTierX on DeviceSupportTier {
  String get label => switch (this) {
        DeviceSupportTier.unsupported => 'Não suportado',
        DeviceSupportTier.tier1Basic => 'Tier 1 · 4 GB',
        DeviceSupportTier.tier2Standard => 'Tier 2 · 6 GB',
        DeviceSupportTier.tier3Pro => 'Tier 3 · 8 GB+',
      };

  String get explanation => switch (this) {
        DeviceSupportTier.unsupported =>
          'menos de 3,5 GB de RAM total ou 1,1 GB livres',
        DeviceSupportTier.tier1Basic =>
          'LFM3-1.7B QAD-Q4_0 (4K–8K) e d1-omni-600M',
        DeviceSupportTier.tier2Standard =>
          'todos os LFM3 individualmente (8K–32K) + d1 GGUF',
        DeviceSupportTier.tier3Pro =>
          'd1 ONNX completo, vídeo 2 fps, LiveASR e cascata co-residente',
      };
}

/// Métricas lidas do sistema (MethodChannel).
class HardwareMetrics {
  final int totalRamMb;
  final int availableRamMb;
  final int freeStorageMb;
  final int performanceCores;
  final int logicalCores;
  final bool hasArmDotProd;
  final bool hasArmI8mm;
  final bool hasGpuAcceleration;
  final bool isIosSimulator;
  final String platform;

  const HardwareMetrics({
    required this.totalRamMb,
    required this.availableRamMb,
    required this.freeStorageMb,
    required this.performanceCores,
    this.logicalCores = 0,
    this.hasArmDotProd = false,
    this.hasArmI8mm = false,
    this.hasGpuAcceleration = false,
    this.isIosSimulator = false,
    this.platform = 'unknown',
  });

  factory HardwareMetrics.fromMap(Map<dynamic, dynamic> raw) => HardwareMetrics(
        totalRamMb: (raw['totalRamMb'] as num?)?.toInt() ?? 0,
        availableRamMb: (raw['availableRamMb'] as num?)?.toInt() ?? 0,
        freeStorageMb: (raw['freeStorageMb'] as num?)?.toInt() ?? 0,
        performanceCores: (raw['performanceCores'] as num?)?.toInt() ?? 0,
        logicalCores: (raw['logicalCores'] as num?)?.toInt() ?? 0,
        hasArmDotProd: raw['hasArmDotProd'] as bool? ?? false,
        hasArmI8mm: raw['hasArmI8mm'] as bool? ?? false,
        hasGpuAcceleration: raw['hasGpuAcceleration'] as bool? ?? false,
        isIosSimulator: raw['isIosSimulator'] as bool? ?? false,
        platform: raw['platform'] as String? ??
            (Platform.isIOS ? 'ios' : (Platform.isAndroid ? 'android' : 'other')),
      );
}

/// Canal de hardware injetável (testes usam um fake).
abstract class HardwareChannel {
  Future<Map<dynamic, dynamic>> metrics();
}

class MethodChannelHardware implements HardwareChannel {
  static const MethodChannel channel =
      MethodChannel('offline_ai_mobile/hardware');

  const MethodChannelHardware();

  @override
  Future<Map<dynamic, dynamic>> metrics() async {
    final raw = await channel.invokeMethod<Map<dynamic, dynamic>>(
      'getHardwareMetrics',
    );
    if (raw == null) {
      throw StateError('canal de hardware devolveu null');
    }
    return raw;
  }
}

/// Relatório estático + medições dinâmicas.
class HardwareProfileReport {
  final int totalRamMb;
  final int availableRamMb;
  final int freeStorageMb;
  final int performanceCores;
  final bool hasArmDotProd;
  final bool hasArmI8mm;
  final bool hasGpuAcceleration;
  final bool isIosSimulator;
  final double? measuredPrefillTokPerSec;
  final double? measuredDecodeTokPerSec;
  final DeviceSupportTier tier;
  final Map<String, String> modelCompatibilityMatrix;
  final String platform;

  const HardwareProfileReport({
    required this.totalRamMb,
    required this.availableRamMb,
    required this.freeStorageMb,
    required this.performanceCores,
    required this.hasArmDotProd,
    required this.hasArmI8mm,
    required this.hasGpuAcceleration,
    required this.isIosSimulator,
    this.measuredPrefillTokPerSec,
    this.measuredDecodeTokPerSec,
    required this.tier,
    required this.modelCompatibilityMatrix,
    this.platform = 'unknown',
  });

  HardwareProfileReport copyWith({
    double? measuredPrefillTokPerSec,
    double? measuredDecodeTokPerSec,
  }) =>
      HardwareProfileReport(
        totalRamMb: totalRamMb,
        availableRamMb: availableRamMb,
        freeStorageMb: freeStorageMb,
        performanceCores: performanceCores,
        hasArmDotProd: hasArmDotProd,
        hasArmI8mm: hasArmI8mm,
        hasGpuAcceleration: hasGpuAcceleration,
        isIosSimulator: isIosSimulator,
        measuredPrefillTokPerSec:
            measuredPrefillTokPerSec ?? this.measuredPrefillTokPerSec,
        measuredDecodeTokPerSec:
            measuredDecodeTokPerSec ?? this.measuredDecodeTokPerSec,
        tier: tier,
        modelCompatibilityMatrix: modelCompatibilityMatrix,
        platform: platform,
      );

  Map<String, dynamic> toJson() => {
        'total_ram_mb': totalRamMb,
        'available_ram_mb': availableRamMb,
        'free_storage_mb': freeStorageMb,
        'performance_cores': performanceCores,
        'has_arm_dotprod': hasArmDotProd,
        'has_arm_i8mm': hasArmI8mm,
        'has_gpu_acceleration': hasGpuAcceleration,
        'is_ios_simulator': isIosSimulator,
        'platform': platform,
        'measured_prefill_tok_s': measuredPrefillTokPerSec,
        'measured_decode_tok_s': measuredDecodeTokPerSec,
        'tier': tier.name,
        'matrix': modelCompatibilityMatrix,
      };
}

/// Resultado do micro-benchmark.
class HardwareBenchmarkResult {
  final double prefillTokPerSec;
  final double decodeTokPerSec;
  final int loadMs;
  final int sampleTokens;
  final String modelId;
  final String notes;

  const HardwareBenchmarkResult({
    required this.prefillTokPerSec,
    required this.decodeTokPerSec,
    required this.loadMs,
    required this.sampleTokens,
    required this.modelId,
    this.notes = '',
  });

  String get recommendation {
    if (decodeTokPerSec >= 25) {
      return 'Excelente: ativa contexto até 32K e vídeo 2 fps.';
    }
    if (decodeTokPerSec >= 8) {
      return 'Bom: mantém 8K e limita image_max_tokens a 512.';
    }
    if (decodeTokPerSec >= 5) {
      return 'Marginal: usa LFM3-1.7B com enable_thinking=false.';
    }
    return 'Lento: usa o d1-omni-600M ou um modelo menor.';
  }

  Map<String, dynamic> toJson() => {
        'prefill_tok_s': prefillTokPerSec,
        'decode_tok_s': decodeTokPerSec,
        'load_ms': loadMs,
        'sample_tokens': sampleTokens,
        'model_id': modelId,
        'notes': notes,
        'recommendation': recommendation,
      };
}

class DeviceCapabilityService {
  final HardwareChannel channel;

  DeviceCapabilityService({HardwareChannel? channel})
      : channel = channel ?? const MethodChannelHardware();

  /// Fase 1: verificação estática instantânea.
  Future<HardwareProfileReport> evaluateStaticCapabilities() async {
    final raw = await channel.metrics();
    return profileFromMetrics(HardwareMetrics.fromMap(raw));
  }

  /// Puro: transforma métricas num relatório (testável sem plugins).
  HardwareProfileReport profileFromMetrics(HardwareMetrics m) {
    final tier = tierFor(
      totalRamMb: m.totalRamMb,
      availableRamMb: m.availableRamMb,
    );
    return HardwareProfileReport(
      totalRamMb: m.totalRamMb,
      availableRamMb: m.availableRamMb,
      freeStorageMb: m.freeStorageMb,
      performanceCores: m.performanceCores,
      hasArmDotProd: m.hasArmDotProd,
      hasArmI8mm: m.hasArmI8mm,
      hasGpuAcceleration: m.hasGpuAcceleration,
      isIosSimulator: m.isIosSimulator,
      tier: tier,
      modelCompatibilityMatrix: buildMatrix(
        tier: tier,
        availableRamMb: m.availableRamMb,
        freeStorageMb: m.freeStorageMb,
        hasArmDotProd: m.hasArmDotProd,
        platform: m.platform,
      ),
      platform: m.platform,
    );
  }

  static DeviceSupportTier tierFor({
    required int totalRamMb,
    required int availableRamMb,
  }) {
    if (totalRamMb < 3500 || availableRamMb < 1100) {
      return DeviceSupportTier.unsupported;
    }
    if (totalRamMb <= 4500 || availableRamMb < 1700) {
      return DeviceSupportTier.tier1Basic;
    }
    if (totalRamMb <= 6500 || availableRamMb < 2500) {
      return DeviceSupportTier.tier2Standard;
    }
    return DeviceSupportTier.tier3Pro;
  }

  Map<String, String> buildMatrix({
    required DeviceSupportTier tier,
    required int availableRamMb,
    required int freeStorageMb,
    required bool hasArmDotProd,
    required String platform,
  }) {
    String check(
      int reqRamMb,
      int reqDiskMb, {
      bool needsDotProd = false,
    }) {
      if (freeStorageMb < reqDiskMb) {
        return 'BLOQUEADO: disco insuficiente (requer $reqDiskMb MB)';
      }
      if (availableRamMb < reqRamMb) {
        return 'RISCO OOM: RAM livre ($availableRamMb MB) abaixo de '
            '$reqRamMb MB';
      }
      if (needsDotProd && !hasArmDotProd && platform == 'android') {
        return 'LENTO: CPU sem ARM dotprod (< 5 tok/s estimado)';
      }
      return 'SUPORTADO (ótimo)';
    }

    return {
      'LFM3-1.7B (QAD-Q4_0 · texto + tool search)':
          check(1350, 1100, needsDotProd: true),
      'LFM3-VL-2B (Q4_K_M + mmproj-Q8_0 · visão/vídeo)':
          check(1800, 1300, needsDotProd: true),
      'LFM3-Audio-2B (Q4_K_M + mmproj-Q8_0 · ASR/TTS)':
          check(1990, 1500, needsDotProd: true),
      'LFM3-Omni-2B (Q4_K_M + mmproj-Q4_K_M · omni)':
          check(1920, 1400, needsDotProd: true),
      'd1-2B / d1-Omni-2B (GGUF · noul/choice/score)':
          check(1450, 1350),
      'd1-2B / d1-Omni-2B (ONNX q4f16 · todas as primitivas)':
          check(2450, 2250),
      'Cascata co-residente (d1-omni-600M + LFM3-1.7B)':
          check(2400, 1800, needsDotProd: true),
    };
  }

  /// Fase 2: micro-benchmark em processo. O chamador fornece um motor já
  /// carregado (ou carrega-o antes) para não duplicar a lógica de paths.
  Future<HardwareBenchmarkResult> benchmarkLoaded({
    required LlmEngine engine,
    required String modelId,
    LlmConfig config = const LlmConfig(),
    int sampleTokens = 32,
  }) async {
    final sw = Stopwatch()..start();
    final prompt = List<String>.filled(48, 'contexto local').join(' ');
    final buf = StringBuffer();
    GenEnd? end;
    await for (final ev in engine.generate(
      messages: [
        const ChatMessage('system', 'Responde de forma breve.'),
        ChatMessage('user', '$prompt\nDiz apenas: ok.'),
      ],
      config: config.copyWith(
        maxTokens: sampleTokens,
        enableThinking: false,
        cachePrompt: false,
      ),
      maxTokensOverride: sampleTokens,
    )) {
      if (ev is GenDelta) buf.write(ev.text);
      if (ev is GenEnd) end = ev;
    }
    final elapsed = sw.elapsedMilliseconds;
    final prefillMs = end?.prefillMs ?? 0;
    final decodeMs = end?.decodeMs ?? mathMax(1, elapsed - prefillMs);
    final prefillBase = prefillMs > 0 ? prefillMs : mathMax(1, elapsed);
    final prefillTok = (end?.promptTokens ?? prompt.length) /
        prefillBase *
        1000;
    final decodeTok = (end?.outputTokens ?? sampleTokens) /
        mathMax(1, decodeMs) *
        1000;
    return HardwareBenchmarkResult(
      prefillTokPerSec: prefillTok.isFinite ? prefillTok : 0,
      decodeTokPerSec: decodeTok.isFinite ? decodeTok : 0,
      loadMs: 0,
      sampleTokens: end?.outputTokens ?? 0,
      modelId: modelId,
      notes: end?.error ?? '',
    );
  }
}

int mathMax(int a, int b) => a > b ? a : b;
