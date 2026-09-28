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
    final hasLaya = services.layaModelPath != null;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const SectionHeader('Browser embutido (teste)'),
        const InfoBanner(
          'O browser abre em tela inteira. As ações são mandadas pelas '
          'teclas flutuantes, pelo piloto Laya (decisão tipada) ou pelo '
          'agente MiniCPM5-2B (tool calling).',
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
                leading: Icon(hasLaya ? Icons.check_circle : Icons.circle_outlined,
                    color: hasLaya ? Colors.green : null),
                title: const Text('Piloto Laya (decisor tipado)'),
                subtitle: Text(hasLaya
                    ? 'Kit ONNX instalado — a tecla 🧭 decide o próximo passo.'
                    : 'Kit Laya não instalado — descarrega na aba Modelos.'),
              ),
              ListTile(
                leading: Icon(hasLlm ? Icons.check_circle : Icons.circle_outlined,
                    color: hasLlm ? Colors.green : null),
                title: const Text('Agente MiniCPM5-2B (tool calling)'),
                subtitle: Text(hasLlm
                    ? 'GGUF instalado — a tecla 🤖 conduz o browser com tools.'
                    : 'GGUF não instalado — descarrega na aba Modelos.'),
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
              '• Piloto Laya = System One tipado: escolhe a próxima ação '
              'entre candidatos concretos e tem gates de segurança '
              '(prompt injection, ações irreversíveis não autorizadas).\n'
              '• Agente LLM = System Two: MiniCPM5-2B com tools browser_* '
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