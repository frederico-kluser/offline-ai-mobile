/// anonymous-browser mobile — segunda versão do projeto desktop
/// `anonymous-browser`, no monorepo `offline-ai-mobile`.
///
/// Cascata: perceção determinística (snapshot) → decisor tipado (Jev online /
/// Laya local) → modelo de texto (MiMo online / MiniCPM5-2B local) → humano.
/// Nada destrutivo acontece sem o humano (gate fora de banda, timeout = negado).
library;

import 'package:flutter/material.dart';

import 'settings.dart';
import 'ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await AppSettings.load();
  runApp(AnonymousBrowserApp(settings: settings));
}

class AnonymousBrowserApp extends StatelessWidget {
  final AppSettings settings;
  const AnonymousBrowserApp({super.key, required this.settings});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'anonymous-browser',
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF1B2A4A),
        useMaterial3: true,
      ),
      home: HomePage(settings: settings),
    );
  }
}
