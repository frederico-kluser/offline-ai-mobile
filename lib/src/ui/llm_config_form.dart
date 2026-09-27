/// Editor de [LlmConfig] (compacto para a aba Prompts, completo para
/// LLM + Tools) e caixa de validação com as violações a vermelho.
library;

import 'package:flutter/material.dart';

import '../domain/llm_config.dart';

/// Caixa de validação: violações a vermelho (bloqueiam execuções).
class ValidationBox extends StatelessWidget {
  const ValidationBox(this.problems, {super.key, this.okMessage = 'Configuração válida'});

  final List<String> problems;
  final String okMessage;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (problems.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          border: Border.all(color: scheme.outlineVariant),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(Icons.check_circle_outline, size: 18, color: scheme.primary),
            const SizedBox(width: 8),
            Expanded(child: Text(okMessage)),
          ],
        ),
      );
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.error_outline, size: 18, color: scheme.onErrorContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Configuração inválida (${problems.length})',
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: scheme.onErrorContainer)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          for (final p in problems)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text('• $p',
                  style: TextStyle(color: scheme.onErrorContainer)),
            ),
        ],
      ),
    );
  }
}

/// Editor dos campos de [LlmConfig].
///
/// [compact] = só os parâmetros essenciais (temperature, maxTokens, seed,
/// enableThinking) com os defaults determinísticos; caso contrário, TODOS os
/// campos.
class LlmConfigEditor extends StatelessWidget {
  const LlmConfigEditor({
    super.key,
    required this.config,
    required this.onChanged,
    this.compact = false,
  });

  final LlmConfig config;
  final ValueChanged<LlmConfig> onChanged;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _DoubleSlider(
            label: 'temperature',
            value: config.temperature,
            min: 0,
            max: 2,
            divisions: 40,
            onChanged: (v) => onChanged(config.copyWith(temperature: v)),
          ),
          Row(
            children: [
              Expanded(
                child: _IntField(
                  label: 'maxTokens',
                  value: config.maxTokens,
                  hint: 'teto de tokens (512)',
                  onChanged: (v) => onChanged(config.copyWith(maxTokens: v)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _IntField(
                  label: 'seed',
                  value: config.seed,
                  hint: 'fixa, nunca -1',
                  onChanged: (v) => onChanged(config.copyWith(seed: v)),
                ),
              ),
            ],
          ),
          _BoolTile(
            label: 'enableThinking',
            subtitle: 'modo thinking do chat template (ON p/ tool-use complexo)',
            value: config.enableThinking,
            onChanged: (v) => onChanged(config.copyWith(enableThinking: v)),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Amostragem (receita oficial MiniCPM5-2B)',
            style: Theme.of(context).textTheme.labelLarge),
        _DoubleSlider(
          label: 'temperature',
          value: config.temperature,
          min: 0,
          max: 2,
          divisions: 40,
          onChanged: (v) => onChanged(config.copyWith(temperature: v)),
        ),
        _DoubleSlider(
          label: 'top_p',
          value: config.topP,
          min: 0,
          max: 1,
          divisions: 20,
          onChanged: (v) => onChanged(config.copyWith(topP: v)),
        ),
        Row(
          children: [
            Expanded(
              child: _IntField(
                label: 'top_k',
                value: config.topK,
                onChanged: (v) => onChanged(config.copyWith(topK: v)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _IntField(
                label: 'seed',
                value: config.seed,
                hint: 'fixa, nunca -1',
                onChanged: (v) => onChanged(config.copyWith(seed: v)),
              ),
            ),
          ],
        ),
        _DoubleSlider(
          label: 'min_p',
          value: config.minP,
          min: 0,
          max: 1,
          divisions: 20,
          onChanged: (v) => onChanged(config.copyWith(minP: v)),
        ),
        const SizedBox(height: 8),
        Text('Repetição e DRY (anti-loop)',
            style: Theme.of(context).textTheme.labelLarge),
        _DoubleSlider(
          label: 'repeat_penalty',
          value: config.repeatPenalty,
          min: 0.8,
          max: 1.5,
          divisions: 70,
          onChanged: (v) => onChanged(config.copyWith(repeatPenalty: v)),
        ),
        Row(
          children: [
            Expanded(
              child: _IntField(
                label: 'repeat_last_n',
                value: config.repeatLastN,
                onChanged: (v) => onChanged(config.copyWith(repeatLastN: v)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _IntField(
                label: 'maxTokens',
                value: config.maxTokens,
                hint: 'teto explícito',
                onChanged: (v) => onChanged(config.copyWith(maxTokens: v)),
              ),
            ),
          ],
        ),
        _DoubleSlider(
          label: 'presence_penalty',
          value: config.presencePenalty,
          min: -2,
          max: 2,
          divisions: 80,
          onChanged: (v) => onChanged(config.copyWith(presencePenalty: v)),
        ),
        _DoubleSlider(
          label: 'frequency_penalty',
          value: config.frequencyPenalty,
          min: -2,
          max: 2,
          divisions: 80,
          onChanged: (v) => onChanged(config.copyWith(frequencyPenalty: v)),
        ),
        _BoolTile(
          label: 'dry_enabled',
          subtitle: 'sampler DRY — defesa anti-loop mais robusta (λ=0.8, β=1.75)',
          value: config.dryEnabled,
          onChanged: (v) => onChanged(config.copyWith(dryEnabled: v)),
        ),
        _DoubleSlider(
          label: 'dry_multiplier (λ)',
          value: config.dryMultiplier,
          min: 0,
          max: 2,
          divisions: 40,
          onChanged: (v) => onChanged(config.copyWith(dryMultiplier: v)),
        ),
        _DoubleSlider(
          label: 'dry_base (β)',
          value: config.dryBase,
          min: 1,
          max: 4,
          divisions: 60,
          onChanged: (v) => onChanged(config.copyWith(dryBase: v)),
        ),
        Row(
          children: [
            Expanded(
              child: _IntField(
                label: 'dry_allowed_length',
                value: config.dryAllowedLength,
                onChanged: (v) => onChanged(config.copyWith(dryAllowedLength: v)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _IntField(
                label: 'dry_penalty_last_n',
                value: config.dryPenaltyLastN,
                onChanged: (v) => onChanged(config.copyWith(dryPenaltyLastN: v)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text('Runtime e contexto',
            style: Theme.of(context).textTheme.labelLarge),
        Row(
          children: [
            Expanded(
              child: _IntField(
                label: 'threads',
                value: config.threads,
                hint: 'big_cores − 1',
                onChanged: (v) => onChanged(config.copyWith(threads: v)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _IntField(
                label: 'gpu_layers',
                value: config.gpuLayers,
                hint: '0 = CPU',
                onChanged: (v) => onChanged(config.copyWith(gpuLayers: v)),
              ),
            ),
          ],
        ),
        _IntField(
          label: 'context_size',
          value: config.contextSize,
          hint: '8k–16k em 8 GB de RAM',
          onChanged: (v) => onChanged(config.copyWith(contextSize: v)),
        ),
        _BoolTile(
          label: 'cache_prompt',
          subtitle: 'amplifica divergência entre execuções — off nas corridas de verificação',
          value: config.cachePrompt,
          onChanged: (v) => onChanged(config.copyWith(cachePrompt: v)),
        ),
        _BoolTile(
          label: 'enableThinking',
          subtitle: 'modo thinking do chat template (ON p/ tool-use complexo)',
          value: config.enableThinking,
          onChanged: (v) => onChanged(config.copyWith(enableThinking: v)),
        ),
      ],
    );
  }
}

class _DoubleSlider extends StatelessWidget {
  const _DoubleSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(child: Text(label, style: Theme.of(context).textTheme.bodySmall)),
            Text(value.toStringAsFixed(3),
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          label: value.toStringAsFixed(3),
          onChanged: onChanged,
        ),
      ],
    );
  }
}

class _IntField extends StatefulWidget {
  const _IntField({
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
  State<_IntField> createState() => _IntFieldState();
}

class _IntFieldState extends State<_IntField> {
  late final TextEditingController _ctrl =
      TextEditingController(text: '${widget.value}');

  @override
  void didUpdateWidget(covariant _IntField old) {
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

class _BoolTile extends StatelessWidget {
  const _BoolTile({
    required this.label,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final String label;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile.adaptive(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(label, style: Theme.of(context).textTheme.bodySmall),
      subtitle: subtitle == null
          ? null
          : Text(subtitle!, style: Theme.of(context).textTheme.labelSmall),
      value: value,
      onChanged: onChanged,
    );
  }
}