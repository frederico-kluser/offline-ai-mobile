/// Bottom sheets de configuração dos motores LFM3 e d1.
library;

import 'package:flutter/material.dart';

import '../services/store.dart';
import 'llm_config_form.dart';

/// Configuração completa do motor gerador LFM3.
Future<bool> showLlmConfigSheet(BuildContext context, AppStore store) async {
  var config = store.llmConfig;
  final saved = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setSheet) {
          final problems = config.validate();
          return Padding(
            padding:
                EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
            child: SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Configuração do motor LFM3',
                        style: Theme.of(ctx).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    LlmConfigEditor(
                      config: config,
                      onChanged: (c) => setSheet(() => config = c),
                    ),
                    const SizedBox(height: 8),
                    ValidationBox(problems),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.of(ctx).pop(false),
                          child: const Text('Cancelar'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: () => Navigator.of(ctx).pop(true),
                          child: const Text('Guardar'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    },
  );
  if (saved == true) {
    await store.saveLlmConfig(config);
  }
  return saved == true;
}

/// Configuração do decisor d1 (ONNX Runtime).
Future<bool> showD1ConfigSheet(BuildContext context, AppStore store) async {
  var config = store.d1Config;
  final saved = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setSheet) {
          return Padding(
            padding:
                EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
            child: SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Configuração do d1 (ONNX)',
                        style: Theme.of(ctx).textTheme.titleMedium),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: config.executionProvider,
                      decoration: const InputDecoration(
                        labelText: 'execution provider',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(
                            value: 'cpu', child: Text('cpu (determinismo)')),
                        DropdownMenuItem(
                            value: 'xnnpack', child: Text('xnnpack (rápido)')),
                        DropdownMenuItem(
                            value: 'coreml', child: Text('coreml (ANE/GPU iOS)')),
                      ],
                      onChanged: (v) => setSheet(() => config = config.copyWith(
                          executionProvider: v ?? 'xnnpack')),
                    ),
                    const SizedBox(height: 12),
                    _SheetIntField(
                      label: 'threads',
                      value: config.threads,
                      hint: 'threads nativas do ONNX Runtime',
                      onChanged: (v) =>
                          setSheet(() => config = config.copyWith(threads: v)),
                    ),
                    const SizedBox(height: 12),
                    _SheetIntField(
                      label: 'maxStateTokens',
                      value: config.maxStateTokens,
                      hint: 'state + perguntas numa linha',
                      onChanged: (v) => setSheet(
                          () => config = config.copyWith(maxStateTokens: v)),
                    ),
                    const SizedBox(height: 12),
                    _SheetIntField(
                      label: 'maxQuestions',
                      value: config.maxQuestions,
                      hint: '1..16 (contrato d1)',
                      onChanged: (v) => setSheet(
                          () => config = config.copyWith(maxQuestions: v)),
                    ),
                    const SizedBox(height: 12),
                    _SheetIntField(
                      label: 'imageMaxTokens',
                      value: config.imageMaxTokens,
                      hint: 'limite visual por imagem',
                      onChanged: (v) => setSheet(
                          () => config = config.copyWith(imageMaxTokens: v)),
                    ),
                    SwitchListTile.adaptive(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('usar fp16/GPU'),
                      subtitle: const Text('decoder_q4f16 + encoders fp16'),
                      value: config.useFp16,
                      onChanged: (v) =>
                          setSheet(() => config = config.copyWith(useFp16: v)),
                    ),
                    SwitchListTile.adaptive(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('manter sessões quentes'),
                      subtitle: const Text('menos latência, mais RAM'),
                      value: config.keepWarm,
                      onChanged: (v) =>
                          setSheet(() => config = config.copyWith(keepWarm: v)),
                    ),
                    if (config.validate().isNotEmpty)
                      ValidationBox(config.validate()),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => Navigator.of(ctx).pop(false),
                          child: const Text('Cancelar'),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: () => Navigator.of(ctx).pop(true),
                          child: const Text('Guardar'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    },
  );
  if (saved == true) {
    await store.saveD1Config(config);
  }
  return saved == true;
}

class _SheetIntField extends StatefulWidget {
  const _SheetIntField({
    required this.label,
    required this.value,
    required this.onChanged,
    this.hint,
  });

  final String label;
  final int value;
  final ValueChanged<int> onChanged;
  final String? hint;

  @override
  State<_SheetIntField> createState() => _SheetIntFieldState();
}

class _SheetIntFieldState extends State<_SheetIntField> {
  late final TextEditingController _ctrl =
      TextEditingController(text: '${widget.value}');

  @override
  void didUpdateWidget(covariant _SheetIntField old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value &&
        int.tryParse(_ctrl.text.trim()) != widget.value) {
      _ctrl.text = '${widget.value}';
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _ctrl,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: widget.hint,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
      onChanged: (s) {
        final v = int.tryParse(s.trim());
        if (v != null) widget.onChanged(v);
      },
    );
  }
}
