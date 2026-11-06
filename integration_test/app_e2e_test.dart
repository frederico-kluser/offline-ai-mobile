/// E2E de arranque da app sem modelos: shell, 5 destinos e navegação.
///
///   `flutter test integration_test/app_e2e_test.dart -d <device>`
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:offline_ai_mobile/src/services/store.dart';
import 'package:offline_ai_mobile/src/ui/app.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('arranca e navega pelos 5 destinos', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final store = await AppStore.load();
    await tester.pumpWidget(OfflineAiApp(store: store));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationDestination), findsNWidgets(5));
    expect(find.text('Prompts · LFM3'), findsWidgets);
    expect(find.text('d1'), findsOneWidget);
    expect(find.text('Browser'), findsOneWidget);
  });
}
