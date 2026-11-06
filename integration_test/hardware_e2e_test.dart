/// E2E do canal nativo de hardware (Kotlin/Swift) num dispositivo real.
///
///   flutter test integration_test/hardware_e2e_test.dart -d <device>
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:offline_ai_mobile/src/services/device_capability_service.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('canal de hardware devolve métricas plausíveis', (t) async {
    final report = await DeviceCapabilityService().evaluateStaticCapabilities();
    expect(report.totalRamMb, greaterThan(0));
    expect(report.availableRamMb, greaterThan(0));
    expect(report.freeStorageMb, greaterThan(0));
    expect(report.performanceCores, greaterThan(0));
    expect(report.platform, isNotEmpty);
    expect(report.modelCompatibilityMatrix, isNotEmpty);
    // ignore: avoid_print
    print('HARDWARE: $report');
  });
}
