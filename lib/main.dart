/// Ponto de entrada: app offline de teste de prompts com Laya (decisor
/// tipado) e MiniCPM5-2B (LLM local).
library;

import 'package:flutter/material.dart';

import 'package:ab_core/ab_core.dart';
import 'src/ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await AppStore.load();
  runApp(OfflineAiApp(store: store));
}