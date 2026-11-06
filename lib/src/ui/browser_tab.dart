/// Separador de entrada do browser embutido: uma página = um objetivo.
/// A UI completa (browser em tela inteira + teclas flutuantes) vive em
/// [BrowserPage] e abre por push — aqui fica o cartão-resumo e o botão.
library;

import 'package:flutter/material.dart';

import '../services/store.dart';
import 'app_services.dart';
import 'browser_page.dart';
import 'common.dart';

class BrowserTab extends StatefulWidget {
  const BrowserTab({super.key, required this.store});

  final AppStore store;

  @override
  State<BrowserTab> createState() => _BrowserTabState();
}

class _BrowserTabState extends State<BrowserTab> {
  @override
  void initState() {
    super.initState();
    AppServices.instance.ensureInstalledKnown().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final services = AppServices.instance;
    final hasLlm = services.llmModelPath != null;
    final hasD1 = services.activeD1Bundle != null;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const SectionHeader('Browser embutido (teste)'),
        const InfoBanner(
          'O browser abre em tela inteira. As ações são mandadas pelas '
          'teclas flutuantes, pelo piloto d1 (decisão tipada) ou pelo '
          'agente LFM3 (tool calling).',
          icon: Icons.public,
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          icon: const Icon(Icons.open_in_full),
          label: const Text('Abrir browser (tela inteira)'),
          onPressed: () => BrowserPage.open(context, widget.store),
        ),
        const SizedBox(height: 16),
        const SectionHeader('Motores de controlo'),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: Icon(hasD1 ? Icons.check_circle : Icons.circle_outlined,
                    color: hasD1 ? Colors.green : null),
                title: const Text('Piloto d1 (decisor tipado)'),
                subtitle: Text(hasD1
                    ? 'Decisor instalado — a tecla 🧭 decide o próximo passo.'
                    : 'Decisor d1 não instalado — descarrega na aba Modelos.'),
              ),
              ListTile(
                leading: Icon(hasLlm ? Icons.check_circle : Icons.circle_outlined,
                    color: hasLlm ? Colors.green : null),
                title: const Text('Agente LFM3 (tool calling)'),
                subtitle: Text(hasLlm
                    ? 'Modelo instalado — a tecla 🤖 conduz o browser com tools.'
                    : 'Modelo LFM3 não instalado — descarrega na aba Modelos.'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        const SectionHeader('Como funciona'),
        const Card(
          child: Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              '• Teclas flutuantes = ações diretas (voltar, URL, clicar, '
              'digitar, rolar, mapa de elementos).\n'
              '• Piloto d1 = System One tipado: escolhe a próxima ação '
              'entre candidatos concretos e tem gates de segurança '
              '(prompt injection, ações irreversíveis não autorizadas).\n'
              '• Agente LFM3 = System Two: tool calling com tools browser_* '
              'e guardrails anti-loop.\n'
              '• Tudo passa pelo mesmo barramento de ações validado '
              '(refs estáveis + deteção de DOM desatualizado).',
            ),
          ),
        ),
      ],
    );
  }
}