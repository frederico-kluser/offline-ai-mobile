/// Editor de [LlmConfig] (compacto para Prompts, completo nas Definições)
/// e caixa de validação com as violações a vermelho.
library;

import 'package:flutter/material.dart';

import '../domain/llm_config.dart';

/// Caixa de validação: violações a vermelho (bloqueiam execuções).
class ValidationBox extends StatelessWidget {
  const ValidationBox(this.problems,
      {super.key, this.okMessage = 'Configuração válida'});

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
              Icon(Icons.error_outline,
                  size: 18, color: scheme.onErrorContainer),
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
    final profile = DropdownButtonFormField<Lfm3Profile>(
      initialValue: config.profile,
      decoration: const InputDecoration(
        labelText: 'perfil LFM3',
        isDense: true,
        border: OutlineInputBorder(),
      ),
      items: [
        for (final p in Lfm3Profile.values)
          DropdownMenuItem(value: p, child: Text(p.label)),
      ],
      onChanged: (p) {
        if (p == null) return;
        onChanged(p == Lfm3Profile.custom
            ? config.copyWith(profile: p)
            : LlmConfig.forProfile(p));
      },
    );

    if (compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          profile,
          const SizedBox(height: 8),
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
                  hint: 'teto explícito',
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
            subtitle: 'bloco <think> (ON para tool-use complexo)',
            value: config.enableThinking,
            onChanged: (v) => onChanged(config.copyWith(enableThinking: v)),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        profile,
        const SizedBox(height: 8),
        Text('Amostragem (receita LFM3)',
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
        _DoubleSlider(
          label: 'repeat_penalty',
          value: config.repeatPenalty,
          min: 1,
          max: 1.5,
          divisions: 50,
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
        const SizedBox(height: 8),
        Text('Raciocínio e resposta',
            style: Theme.of(context).textTheme.labelLarge),
        _BoolTile(
          label: 'enableThinking',
          subtitle: 'bloco <think> (LFM3-1.7B/VL-2B; o Omni não tem)',
          value: config.enableThinking,
          onChanged: (v) => onChanged(config.copyWith(enableThinking: v)),
        ),
        _BoolTile(
          label: 'preserveThinking',
          subtitle: 'manter <think> de turnos antigos no contexto',
          value: config.preserveThinking,
          onChanged: (v) => onChanged(config.copyWith(preserveThinking: v)),
        ),
        _IntField(
          label: 'maxThinkingTokens',
          value: config.maxThinkingTokens,
          hint: 'teto do bloco <think> (1024 em mobile)',
          onChanged: (v) => onChanged(config.copyWith(maxThinkingTokens: v)),
        ),
        DropdownButtonFormField<ResponseFormat>(
          initialValue: config.responseFormat,
          decoration: const InputDecoration(
            labelText: 'response_format',
            isDense: true,
            border: OutlineInputBorder(),
          ),
          items: [
            for (final r in ResponseFormat.values)
              DropdownMenuItem(value: r, child: Text(r.wire)),
          ],
          onChanged: (r) {
            if (r != null) onChanged(config.copyWith(responseFormat: r));
          },
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
                hint: 'performance cores − 2',
                onChanged: (v) => onChanged(config.copyWith(threads: v)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _IntField(
                label: 'gpu_layers',
                value: config.gpuLayers,
                hint: '-1 todas, 0 CPU',
                onChanged: (v) => onChanged(config.copyWith(gpuLayers: v)),
              ),
            ),
          ],
        ),
        _IntField(
          label: 'context_size',
          value: config.contextSize,
          hint: '8K–32K em mobile (KV 12,29 KB/token FP16)',
          onChanged: (v) => onChanged(config.copyWith(contextSize: v)),
        ),
        Row(
          children: [
            Expanded(
              child: _IntField(
                label: 'n_batch',
                value: config.nBatch,
                onChanged: (v) => onChanged(config.copyWith(nBatch: v)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _IntField(
                label: 'n_ubatch',
                value: config.nUbatch,
                onChanged: (v) => onChanged(config.copyWith(nUbatch: v)),
              ),
            ),
          ],
        ),
        DropdownButtonFormField<KvCacheType>(
          initialValue: config.kvTypeK,
          decoration: const InputDecoration(
            labelText: 'KV cache',
            isDense: true,
            border: OutlineInputBorder(),
          ),
          items: const [
            DropdownMenuItem(
                value: KvCacheType.f16, child: Text('FP16 (12,29 KB/token)')),
            DropdownMenuItem(
                value: KvCacheType.q8_0, child: Text('Q8_0 (6,53 KB/token)')),
          ],
          onChanged: (t) {
            if (t != null) {
              onChanged(config.copyWith(kvTypeK: t, kvTypeV: t));
            }
          },
        ),
        _BoolTile(
          label: 'cache_prompt',
          subtitle: 'reutiliza o prefixo KV (essencial com deferred tools)',
          value: config.cachePrompt,
          onChanged: (v) => onChanged(config.copyWith(cachePrompt: v)),
        ),
        _BoolTile(
          label: 'flash_attn',
          subtitle: 'Flash Attention (Metal/CPU)',
          value: config.flashAttn,
          onChanged: (v) => onChanged(config.copyWith(flashAttn: v)),
        ),
        const SizedBox(height: 8),
        Text('Multimodal', style: Theme.of(context).textTheme.labelLarge),
        _IntField(
          label: 'image_max_tokens',
          value: config.imageMaxTokens,
          hint: '1024; baixa para 512 se o prefill for lento',
          onChanged: (v) => onChanged(config.copyWith(imageMaxTokens: v)),
        ),
        _DoubleSlider(
          label: 'video_fps',
          value: config.videoFps,
          min: 1,
          max: 4,
          divisions: 6,
          onChanged: (v) => onChanged(config.copyWith(videoFps: v)),
        ),
        const SizedBox(height: 8),
        Text('Áudio (LiquidCodec)',
            style: Theme.of(context).textTheme.labelLarge),
        _DoubleSlider(
          label: 'audio_temperature',
          value: config.audioTemperature,
          min: 0,
          max: 2,
          divisions: 40,
          onChanged: (v) => onChanged(config.copyWith(audioTemperature: v)),
        ),
        Row(
          children: [
            Expanded(
              child: _IntField(
                label: 'audio_top_k',
                value: config.audioTopK,
                onChanged: (v) => onChanged(config.copyWith(audioTopK: v)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _IntField(
                label: 'audio_window',
                value: config.audioWindow,
                onChanged: (v) => onChanged(config.copyWith(audioWindow: v)),
              ),
            ),
          ],
        ),
        _DoubleSlider(
          label: 'audio_repetition_penalty',
          value: config.audioRepeatPenalty,
          min: 1,
          max: 1.5,
          divisions: 50,
          onChanged: (v) =>
              onChanged(config.copyWith(audioRepeatPenalty: v)),
        ),
        _BoolTile(
          label: 'suppress_mixed',
          subtitle: 'ASR: não emitir <|mixed_start|>',
          value: config.suppressMixed,
          onChanged: (v) => onChanged(config.copyWith(suppressMixed: v)),
        ),
        _BoolTile(
          label: 'suppress_audio_out',
          subtitle: 'ASR: não emitir áudio de saída',
          value: config.suppressAudioOut,
          onChanged: (v) => onChanged(config.copyWith(suppressAudioOut: v)),
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
            Expanded(
                child: Text(label,
                    style: Theme.of(context).textTheme.bodySmall)),
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
