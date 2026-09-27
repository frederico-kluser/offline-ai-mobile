/// Ponto de entrada: app offline de teste de prompts com Laya (decisor
/// tipado) e MiniCPM5-2B (LLM local).
library;

import 'package:flutter/material.dart';

import 'src/services/store.dart';
import 'src/ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await AppStore.load();
  runApp(OfflineAiApp(store: store));
}