/// Definições: chave OpenRouter (apresentação mascarada), modos de backend e
/// bandas de confiança recalibráveis.
library;

import 'package:flutter/material.dart';

import '../domain/mission.dart';
import '../settings.dart';

class SettingsPage extends StatefulWidget {
  final AppSettings settings;
  const SettingsPage({super.key, required this.settings});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _key;

  @override
  void initState() {
    super.initState();
    _key = TextEditingController(text: widget.settings.openrouterKey);
  }

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    widget.settings.openrouterKey = _key.text.trim();
    await widget.settings.save();
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('definições guardadas')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    return Scaffold(
      appBar: AppBar(title: const Text('definições')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _key,
            obscureText: true,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: 'chave OpenRouter (Jev + MiMo online)',
              helperText: 'atual: ${s.maskedKey} — nunca sai em logs nem tape',
            ),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<DecisionMode>(
            initialValue: s.decisionMode,
            decoration: const InputDecoration(
                border: OutlineInputBorder(), labelText: 'decisor por omissão'),
            items: const [
              DropdownMenuItem(
                  value: DecisionMode.jevOnline, child: Text('Jev online')),
              DropdownMenuItem(
                  value: DecisionMode.layaLocal, child: Text('Laya local')),
            ],
            onChanged: (v) async {
              s.decisionMode = v!;
              await s.save();
              setState(() {});
            },
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<TextMode>(
            initialValue: s.textMode,
            decoration: const InputDecoration(
                border: OutlineInputBorder(), labelText: 'texto por omissão'),
            items: const [
              DropdownMenuItem(
                  value: TextMode.mimoOnline, child: Text('MiMo online')),
              DropdownMenuItem(
                  value: TextMode.minicpmLocal, child: Text('MiniCPM5-2B local')),
            ],
            onChanged: (v) async {
              s.textMode = v!;
              await s.save();
              setState(() {});
            },
          ),
          const SizedBox(height: 16),
          Text('bandas de confiança (recalibrar por modelo)',
              style: Theme.of(context).textTheme.titleMedium),
          _bandSlider('auto (age sozinho)', s.autoBand, (v) async {
            s.autoBand = v;
            await s.save();
            setState(() {});
          }),
          _bandSlider('mínimo (abaixo = fallback)', s.minBand, (v) async {
            s.minBand = v;
            await s.save();
            setState(() {});
          }),
          _bandSlider('done (concluir)', s.doneBand, (v) async {
            s.doneBand = v;
            await s.save();
            setState(() {});
          }),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save),
            label: const Text('guardar'),
          ),
          const SizedBox(height: 24),
          const Text(
            'Modelos locais (Laya ONNX + MiniCPM5-2B GGUF): descarregados pela '
            'app de exemplo (aba Modelos) no diretório de documentos de cada app. '
            'Na app de exemplo corre `flutter test` e os downloads verificados por sha256.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Widget _bandSlider(String label, double value, ValueChanged<double> onChanged) {
    return Row(
      children: [
        SizedBox(width: 180, child: Text(label)),
        Expanded(
          child: Slider(
            value: value,
            min: 0.1,
            max: 0.99,
            divisions: 89,
            label: value.toStringAsFixed(2),
            onChanged: onChanged,
          ),
        ),
        Text(value.toStringAsFixed(2)),
      ],
    );
  }
}
