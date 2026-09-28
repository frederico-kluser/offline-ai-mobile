/// Smoke test real da UI: arranque, navegação pelos 4 destinos, validação de
/// prompts, banners de modelos em falta e persistência do [AppStore].
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:offline_ai_mobile/src/domain/llm_config.dart';
import 'package:offline_ai_mobile/src/domain/run_record.dart';
import 'package:offline_ai_mobile/src/services/store.dart';
import 'package:offline_ai_mobile/src/ui/app.dart';
import 'package:offline_ai_mobile/src/ui/prompts_tab.dart';

Future<AppStore> _mockStore() async {
  SharedPreferences.setMockInitialValues({});
  return AppStore.load();
}

/// Ecrã alto de teste: os formulários são longos e queremos os controlos
/// todos construídos e hit-testáveis (sem scroll de precisão no smoke test).
void _bigScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 4200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Finder _inTab<T extends Widget>(Finder matcher) =>
    find.descendant(of: find.byType(T), matching: matcher);

Future<void> _tapDestination(WidgetTester tester, String label) async {
  await tester.tap(find.descendant(
      of: find.byType(NavigationBar), matching: find.text(label)));
  await tester.pumpAndSettle();
}

int _selectedIndex(WidgetTester tester) =>
    tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex;

void main() {
  testWidgets('arranca com os 5 destinos e navega entre telas', (tester) async {
    _bigScreen(tester);
    final store = await _mockStore();
    await tester.pumpWidget(OfflineAiApp(store: store));
    await tester.pumpAndSettle();

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationDestination), findsNWidgets(5));

    // Prompts (inicial).
    expect(_selectedIndex(tester), 0);
    expect(find.text('Executar').hitTestable(), findsOneWidget);
    expect(find.text('LLM MiniCPM5-2B').hitTestable(), findsOneWidget);
    expect(find.text('Laya (decisor)').hitTestable(), findsOneWidget);

    // Laya.
    await _tapDestination(tester, 'Laya');
    expect(_selectedIndex(tester), 1);
    expect(find.text('Decidir').hitTestable(), findsOneWidget);
    expect(find.text('Ver JSON').hitTestable(), findsOneWidget);
    expect(find.text('Configuração do Laya').hitTestable(), findsOneWidget);

    // Tools (demo de tool calling primeiro; configuração em página própria).
    await _tapDestination(tester, 'Tools');
    expect(_selectedIndex(tester), 2);
    expect(find.text('Correr agente').hitTestable(), findsOneWidget);
    expect(find.text(AppStore.defaultTask).hitTestable(), findsOneWidget);

    // Modelos.
    await _tapDestination(tester, 'Modelos');
    expect(_selectedIndex(tester), 3);
    expect(find.text('Destino dos modelos').hitTestable(), findsOneWidget);
    expect(
        find.text('MiniCPM5-2B · GGUF Q8_0').hitTestable(), findsOneWidget);
    expect(find.text('Laya typed-decisions · ONNX 4-bit').hitTestable(),
        findsOneWidget);

    // Browser (cartão de entrada da feature de browser embutido).
    await _tapDestination(tester, 'Browser');
    expect(_selectedIndex(tester), 4);
    expect(find.text('Abrir browser (tela inteira)').hitTestable(),
        findsOneWidget);
    expect(find.text('Piloto Laya (decisor tipado)').hitTestable(),
        findsOneWidget);
    expect(find.text('Agente MiniCPM5-2B (tool calling)').hitTestable(),
        findsOneWidget);
  });

  testWidgets('Prompts valida entradas e avisa modelo em falta', (tester) async {
    _bigScreen(tester);
    final store = await _mockStore();
    await tester.pumpWidget(OfflineAiApp(store: store));
    await tester.pumpAndSettle();

    // User prompt vazio → SnackBar de validação (nunca rebenta).
    await tester.tap(find.text('Executar').hitTestable());
    await tester.pumpAndSettle();
    expect(find.text('Escreve um user prompt antes de executar.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));

    // Com prompt, mas sem GGUF instalado → aviso de modelo em falta.
    final userField = _inTab<PromptsTab>(find.byType(TextField)).at(1);
    await tester.enterText(userField, 'Olá mundo');
    await tester.tap(find.text('Executar').hitTestable());
    await tester.pumpAndSettle();
    expect(
        find.text('Modelo GGUF não instalado. Descarrega o GGUF na aba Modelos.'),
        findsOneWidget);
    await tester.pump(const Duration(seconds: 6));

    // O banner de modelo em falta continua visível na tela.
    expect(
        _inTab<PromptsTab>(find.textContaining('não instalado')), findsWidgets);
  });

  testWidgets('Modelos mostra catálogo e destino mesmo sem path_provider',
      (tester) async {
    _bigScreen(tester);
    final store = await _mockStore();
    await tester.pumpWidget(OfflineAiApp(store: store));
    await tester.pumpAndSettle();

    await _tapDestination(tester, 'Modelos');
    // Sem plugin de ficheiros em testes: mostra o destino em falta sem crash.
    expect(find.textContaining('indisponível').hitTestable(), findsWidgets);
    expect(find.text('Descarregar').hitTestable(), findsNWidgets(2)); // Q8_0 + kit Laya
  });

  test('AppStore persiste configuração, corridas e goldens', () async {
    final store = await _mockStore();

    // Defaults determinísticos.
    expect(store.llmConfig.seed, 42);
    expect(store.llmConfig.minP, 0.0);
    expect(store.layaConfig.executionProvider, 'xnnpack');

    // Round-trip de configuração.
    await store.saveLlmConfig(store.llmConfig.copyWith(maxTokens: 256));
    expect(store.llmConfig.maxTokens, 256);
    await store.saveLayaConfig(store.layaConfig.copyWith(threads: 2));
    expect(store.layaConfig.threads, 2);

    // Corrida + golden + diffRuns.
    const cfg = LlmConfig();
    final signature = runSignature(
      modelId: 'modelo-teste',
      prompt: 'olá',
      params: cfg.toJson(),
    );
    final record = RunRecord(
      id: '${signature}_1',
      startedAt: DateTime.utc(2026, 1, 1),
      kind: 'llm',
      modelId: 'modelo-teste',
      prompt: 'olá',
      params: cfg.toJson(),
      output: 'mundo',
      promptTokens: 1,
      outputTokens: 1,
      latencyMs: 5,
      signature: signature,
      stopReason: 'eos',
    );
    await store.addRun(record);
    expect(store.runs, hasLength(1));
    expect(store.runs.first.output, 'mundo');

    await store.setGolden(record);
    expect(store.goldenFor(signature)?.output, 'mundo');

    final diff = diffRuns(record, store.goldenFor(signature)!);
    expect(diff.identicalOutput, isTrue);

    final divergent = RunRecord(
      id: '${signature}_2',
      startedAt: DateTime.utc(2026, 1, 2),
      kind: 'llm',
      modelId: 'modelo-teste',
      prompt: 'olá',
      params: cfg.toJson(),
      output: 'mundo!',
      promptTokens: 1,
      outputTokens: 1,
      latencyMs: 5,
      signature: signature,
      stopReason: 'eos',
    );
    final diff2 = diffRuns(divergent, record);
    expect(diff2.identicalOutput, isFalse);
    expect(diff2.firstDivergence, isNotNull);
  });
}