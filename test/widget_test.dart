/// Smoke tests da UI: 5 destinos, validação de prompts, catálogo LFM3,
/// decisor d1 e persistência.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:offline_ai_mobile/src/domain/llm_config.dart';
import 'package:offline_ai_mobile/src/domain/run_record.dart';
import 'package:offline_ai_mobile/src/services/model_registry.dart';
import 'package:offline_ai_mobile/src/services/store.dart';
import 'package:offline_ai_mobile/src/ui/app.dart';
import 'package:offline_ai_mobile/src/ui/prompts_tab.dart';

Future<AppStore> _mockStore() async {
  SharedPreferences.setMockInitialValues({});
  return AppStore.load();
}

void _bigScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 5200);
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

    expect(_selectedIndex(tester), 0);
    expect(find.text('Executar').hitTestable(), findsOneWidget);
    expect(find.text('Prompts · LFM3'), findsWidgets);

    await _tapDestination(tester, 'd1');
    expect(_selectedIndex(tester), 1);
    expect(find.text('Decidir').hitTestable(), findsOneWidget);
    expect(find.text('Template d1'), findsOneWidget);
    expect(find.textContaining('Perguntas (7)'), findsOneWidget);

    await _tapDestination(tester, 'Tools');
    expect(_selectedIndex(tester), 2);
    expect(find.text('Correr agente').hitTestable(), findsOneWidget);
    expect(find.text(AppStore.defaultTask).hitTestable(), findsOneWidget);
    expect(find.textContaining('Deferred Tool Search'), findsWidgets);

    await _tapDestination(tester, 'Modelos');
    expect(_selectedIndex(tester), 3);
    expect(find.text('Perfil do dispositivo'), findsOneWidget);
    expect(find.textContaining('Geradores LFM3'), findsOneWidget);
    expect(
        find.text('LFM3-1.7B · QAD-Q4_0 (essencial)').hitTestable(),
        findsOneWidget);

    await _tapDestination(tester, 'Browser');
    expect(_selectedIndex(tester), 4);
    expect(find.text('Abrir browser (tela inteira)').hitTestable(),
        findsOneWidget);
    expect(find.text('Piloto d1 (decisor tipado)').hitTestable(),
        findsOneWidget);
    expect(find.text('Agente LFM3 (tool calling)').hitTestable(),
        findsOneWidget);
  });

  testWidgets('Prompts valida entradas e avisa modelo em falta', (tester) async {
    _bigScreen(tester);
    final store = await _mockStore();
    await tester.pumpWidget(OfflineAiApp(store: store));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Executar').hitTestable());
    await tester.pumpAndSettle();
    expect(find.text('Escreve um user prompt antes de executar.'),
        findsOneWidget);
    await tester.pump(const Duration(seconds: 6));

    final userField = _inTab<PromptsTab>(find.byType(TextField)).at(1);
    await tester.enterText(userField, 'Olá mundo');
    await tester.tap(find.text('Executar').hitTestable());
    await tester.pumpAndSettle();
    expect(
        find.text(
            'Nenhum modelo LFM3 instalado. Descarrega um bundle na aba Modelos.'),
        findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('Modelos mostra catálogo e destino sem path_provider',
      (tester) async {
    _bigScreen(tester);
    final store = await _mockStore();
    await tester.pumpWidget(OfflineAiApp(store: store));
    await tester.pumpAndSettle();

    await _tapDestination(tester, 'Modelos');
    expect(find.textContaining('indisponível').hitTestable(), findsWidgets);
    expect(find.text('Descarregar').hitTestable(), findsWidgets);
    expect(find.textContaining('d1-2B-ONNX'), findsWidgets);
  });

  testWidgets('d1 mostra as dez primitivas no seletor', (tester) async {
    _bigScreen(tester);
    final store = await _mockStore();
    await tester.pumpWidget(OfflineAiApp(store: store));
    await tester.pumpAndSettle();
    await _tapDestination(tester, 'd1');
    await tester.tap(find.byIcon(Icons.add_circle_outline).hitTestable());
    await tester.pumpAndSettle();
    expect(find.text('Escolha múltipla'), findsOneWidget);
    expect(find.text('Intervalo numérico'), findsOneWidget);
    expect(find.text('Até N caixas (boxes)'), findsOneWidget);
  });

  test('AppStore persiste configuração, corridas e goldens', () async {
    final store = await _mockStore();

    expect(store.llmConfig.seed, 42);
    expect(store.llmConfig.profile, Lfm3Profile.agent);
    expect(store.d1Config.executionProvider, 'xnnpack');

    await store.saveLlmConfig(store.llmConfig.copyWith(maxTokens: 256));
    expect(store.llmConfig.maxTokens, 256);
    await store.saveD1Config(store.d1Config.copyWith(threads: 2));
    expect(store.d1Config.threads, 2);

    const cfg = LlmConfig();
    final signature = runSignature(
      modelId: 'modelo-teste',
      prompt: 'olá',
      params: cfg.toJson(),
    );
    final record = RunRecord(
      id: '${signature}_1',
      startedAt: DateTime.utc(2026, 1, 1),
      kind: 'lfm3',
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
    expect(diffRuns(record, store.goldenFor(signature)!).identicalOutput, isTrue);
  });

  test('catálogo tem os 11 bundles e os hashes conhecidos', () {
    expect(kModelCatalog.length, 11);
    final text = modelById('lfm3-1.7b-q4_0')!;
    expect(text.mainFilename, 'LFM3-1.7B-QAD-Q4_0.gguf');
    expect(text.files.first.sha256, startsWith('43a7d09a'));
    final d1 = modelById('d1-2b-onnx-q4f16')!;
    expect(d1.isOnnx, isTrue);
    expect(d1.supportsVision, isTrue);
  });
}
