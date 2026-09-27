/// Página "Definições do LLM" — a configuração completa do MiniCPM5-2B vive
/// FORA do fluxo principal (progressive disclosure).
///
/// Devolve o [LlmConfig] editado via `Navigator.pop(context, config)`.
library;

import 'package:flutter/material.dart';

import '../domain/llm_config.dart';
import 'common.dart';
import 'llm_config_form.dart';

class LlmSettingsPage extends StatefulWidget {
  const LlmSettingsPage({super.key, required this.config});

  final LlmConfig config;

  /// Abre a página e devolve a configuração guardada (ou `null` se sair sem
  /// guardar).
  static Future<LlmConfig?> open(BuildContext context, LlmConfig current) =>
      Navigator.push<LlmConfig>(
        context,
        MaterialPageRoute(builder: (_) => LlmSettingsPage(config: current)),
      );

  @override
  State<LlmSettingsPage> createState() => _LlmSettingsPageState();
}

class _LlmSettingsPageState extends State<LlmSettingsPage> {
  late LlmConfig _config = widget.config;

  @override
  Widget build(BuildContext context) {
    final problems = _config.validate();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Definições do LLM'),
        actions: [
          IconButton(
            tooltip: 'Repor defaults determinísticos',
            icon: const Icon(Icons.restart_alt),
            onPressed: () => setState(() => _config = const LlmConfig()),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, _config),
            child: const Text('Guardar'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const InfoBanner(
            'Defaults seguem a receita oficial anti-loop do MiniCPM5-2B '
            '(temperature 1.0 · top_p 0.95 · min_p 0.0 · seed fixa · DRY '
            'ligado). Valores fora destes aumentam o risco de loops.',
            icon: Icons.tune,
          ),
          const SizedBox(height: 8),
          LlmConfigEditor(
            config: _config,
            onChanged: (c) => setState(() => _config = c),
          ),
          const SizedBox(height: 8),
          ValidationBox(problems),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}