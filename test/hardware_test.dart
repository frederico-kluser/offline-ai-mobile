/// Testes do perfilador de hardware e do benchmark.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_ai_mobile/src/domain/llm_config.dart';
import 'package:offline_ai_mobile/src/engines/llm_engine.dart';
import 'package:offline_ai_mobile/src/services/device_capability_service.dart';

class FakeChannel implements HardwareChannel {
  final Map<String, dynamic> _values;
  FakeChannel(this._values);

  @override
  Future<Map<dynamic, dynamic>> metrics() async => _values;
}

class FakeBenchEngine implements LlmEngine {
  @override
  bool get isLoaded => true;
  @override
  String get modelId => 'fake';
  @override
  Lfm3ModelKind get kind => Lfm3ModelKind.text;
  @override
  Lfm3ModelInfo? get info => null;
  @override
  Future<void> load({
    required String modelPath,
    required LlmConfig config,
    String? mmprojPath,
    Lfm3ModelKind kind = Lfm3ModelKind.text,
  }) async {}
  @override
  Future<void> unload() async {}
  @override
  Future<int> countTokens(String text) async => 10;
  @override
  Stream<GenEvent> generate({
    required List<ChatMessage> messages,
    required LlmConfig config,
    List<LlmMediaInput> media = const [],
    int? maxTokensOverride,
    String? systemPromptOverride,
  }) async* {
    yield const GenDelta('ok');
    yield const GenEnd(
      promptTokens: 100,
      outputTokens: 20,
      latencyMs: 1100,
      stopReason: 'eos',
      prefillMs: 100,
      decodeMs: 1000,
    );
  }
}

void main() {
  Map<String, dynamic> metrics({
    int total = 8000,
    int avail = 4000,
    int disk = 60000,
    bool dot = true,
    String platform = 'android',
  }) =>
      {
        'totalRamMb': total,
        'availableRamMb': avail,
        'freeStorageMb': disk,
        'performanceCores': 6,
        'logicalCores': 8,
        'hasArmDotProd': dot,
        'hasArmI8mm': false,
        'hasGpuAcceleration': false,
        'isIosSimulator': false,
        'platform': platform,
      };

  test('tiers por RAM total/livre', () {
    expect(
        DeviceCapabilityService.tierFor(
            totalRamMb: 3000, availableRamMb: 2000),
        DeviceSupportTier.unsupported);
    expect(
        DeviceCapabilityService.tierFor(
            totalRamMb: 4000, availableRamMb: 2000),
        DeviceSupportTier.tier1Basic);
    expect(
        DeviceCapabilityService.tierFor(
            totalRamMb: 6000, availableRamMb: 2500),
        DeviceSupportTier.tier2Standard);
    expect(
        DeviceCapabilityService.tierFor(
            totalRamMb: 8000, availableRamMb: 4000),
        DeviceSupportTier.tier3Pro);
  });

  test('matriz bloqueia por disco e por RAM', () async {
    final service = DeviceCapabilityService(
      channel: FakeChannel(metrics(avail: 4000, disk: 100)),
    );
    final report = await service.evaluateStaticCapabilities();
    expect(report.tier, DeviceSupportTier.tier3Pro);
    expect(report.modelCompatibilityMatrix.values.first,
        startsWith('BLOQUEADO'));

    final lowRam = DeviceCapabilityService(
      channel: FakeChannel(metrics(avail: 1200)),
    );
    final r2 = await lowRam.evaluateStaticCapabilities();
    expect(r2.modelCompatibilityMatrix.values.first, startsWith('RISCO OOM'));
  });

  test('matriz avisa CPU sem dotprod em Android', () async {
    final service = DeviceCapabilityService(
      channel: FakeChannel(metrics(dot: false)),
    );
    final report = await service.evaluateStaticCapabilities();
    expect(report.modelCompatibilityMatrix.values.first, startsWith('LENTO'));
  });

  test('benchmark calcula prefill/decode e recomenda', () async {
    final service = DeviceCapabilityService(channel: FakeChannel(metrics()));
    final result = await service.benchmarkLoaded(
      engine: FakeBenchEngine(),
      modelId: 'fake',
    );
    expect(result.prefillTokPerSec, closeTo(1000, 1));
    expect(result.decodeTokPerSec, closeTo(20, 1));
    expect(result.recommendation, contains('Bom'));
  });

  test('iOS simulador desativa GPU', () async {
    final service = DeviceCapabilityService(
      channel: FakeChannel(metrics(platform: 'ios')),
    );
    final report = await service.evaluateStaticCapabilities();
    expect(report.isIosSimulator, isFalse);
    expect(report.hasGpuAcceleration, isFalse);
  });
}
