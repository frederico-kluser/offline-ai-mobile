/// Shell da app: tema Material 3 simples (seed teal) + NavigationBar com os
/// 5 destinos. Sem animações extra, sem gradientes.
library;

import 'package:flutter/material.dart';

import '../services/store.dart';
import 'browser_tab.dart';
import 'laya_tab.dart';
import 'models_tab.dart';
import 'prompts_tab.dart';
import 'tools_tab.dart';

class OfflineAiApp extends StatelessWidget {
  const OfflineAiApp({super.key, required this.store});

  final AppStore store;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Offline AI — Teste de Prompts',
      theme: ThemeData(
        colorSchemeSeed: Colors.teal,
        useMaterial3: true,
      ),
      home: HomeShell(store: store),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.store});

  final AppStore store;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  static const List<String> _titles = [
    'Prompts',
    'Laya (decisor tipado)',
    'Tools',
    'Modelos',
    'Browser',
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_titles[_index])),
      body: IndexedStack(
        index: _index,
        children: [
          PromptsTab(store: widget.store),
          LayaTab(store: widget.store),
          ToolsTab(store: widget.store),
          ModelsTab(store: widget.store),
          BrowserTab(store: widget.store),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.edit_note),
            label: 'Prompts',
          ),
          NavigationDestination(
            icon: Icon(Icons.fact_check_outlined),
            label: 'Laya',
          ),
          NavigationDestination(
            icon: Icon(Icons.handyman_outlined),
            label: 'Tools',
          ),
          NavigationDestination(
            icon: Icon(Icons.storage_outlined),
            label: 'Modelos',
          ),
          NavigationDestination(
            icon: Icon(Icons.public),
            label: 'Browser',
          ),
        ],
      ),
    );
  }
}