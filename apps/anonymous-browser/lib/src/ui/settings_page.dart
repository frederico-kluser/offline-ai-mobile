/// Definições: cadastro da chave OpenRouter (validada e guardada
/// CRIPTOGRAFADA), modos de backend e bandas de confiança recalibráveis.
library;

import 'package:flutter/material.dart';

import '../domain/mission.dart';
import '../key_vault.dart';
import '../settings.dart';

class SettingsPage extends StatefulWidget {
  final AppSettings settings;
  const SettingsPage({super.key, required this.settings});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _key;
  late final KeyVault _vault;
  bool _validating = false;
  KeyValidation? _lastValidation;

  @override
  void initState() {
    super.initState();
    _key = TextEditingController();
    _vault = KeyVault(store: SecureKeyStore());
  }

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _validateAndSave() async {
    setState(() {
      _validating = true;
      _lastValidation = null;
    });
    final v = await _vault.validateAndSave(_key.text);
    if (!mounted) return;
    setState(() {
      _validating = false;
      _lastValidation = v;
    });
    if (v.valid) {
      widget.settings.openrouterKey = _key.text.trim();
      _key.clear();
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('chave validada e guardada: ${v.summary}')));
    }
  }

  Future<void> _testCurrent() async {
    setState(() {
      _validating = true;
      _lastValidation = null;
    });
    final current = await _vault.readKey();
    final v = current == null
        ? const KeyValidation(valid: false, error: 'não há chave guardada')
        : await _vault.validate(current);
    if (!mounted) return;
    setState(() {
      _validating = false;
      _lastValidation = v;
    });
  }

  Future<void> _removeKey() async {
    await _vault.deleteKey();
    widget.settings.openrouterKey = '';
    if (!mounted) return;
    setState(() => _lastValidation = null);
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('chave removida do cofre')));
  }

  Future<void> _save() async {
    await widget.settings.save();
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('definições guardadas')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    final v = _lastValidation;
    return Scaffold(
      appBar: AppBar(title: const Text('definições')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('chave OpenRouter (Jev + MiMo online)',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(
            controller: _key,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: 'sk-or-… (colar a tua chave)',
              helperText: s.hasKey
                  ? 'guardada: ${s.maskedKey} — escreve outra para substituir'
                  : 'ainda sem chave guardada',
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              FilledButton.icon(
                onPressed: _validating ? null : _validateAndSave,
                icon: _validating
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.verified_user),
                label: const Text('validar e guardar'),
              ),
              const SizedBox(width: 8),
              if (s.hasKey)
                TextButton(
                  onPressed: _validating ? null : _testCurrent,
                  child: const Text('testar atual'),
                ),
              const Spacer(),
              if (s.hasKey)
                TextButton(
                  onPressed: _validating ? null : _removeKey,
                  child: const Text('remover'),
                ),
            ],
          ),
          if (v != null) ...[
            const SizedBox(height: 8),
            Card(
              color: v.valid ? Colors.green.shade50 : Colors.red.shade50,
              child: ListTile(
                leading: Icon(v.valid ? Icons.check_circle : Icons.error,
                    color: v.valid ? Colors.green : Colors.red),
                title: Text(v.summary),
                subtitle: v.valid
                    ? const Text(
                        'guardada criptografada (Keychain/Keystore)')
                    : const Text('nada foi guardado'),
              ),
            ),
          ],
          const SizedBox(height: 8),
          const Text(
            'A chave valida-se contra GET /api/v1/key do OpenRouter (sem gastar '
            'créditos) e só fica guardada se a API a aceitar. Fica cifrada no '
            'cofre do telemóvel (Keychain iOS / Keystore AES-GCM Android) — '
            'nunca em preferências, logs ou tape.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const Divider(height: 32),
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
            label: const Text('guardar preferências'),
          ),
          const SizedBox(height: 24),
          const Text(
            'Modelos locais (Laya ONNX + MiniCPM5-2B GGUF): descarregados pela '
            'app de exemplo (aba Modelos) no diretório de documentos de cada app.',
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
