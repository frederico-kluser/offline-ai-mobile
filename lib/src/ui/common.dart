/// Widgets utilitários partilhados (banners, métricas, barras de
/// probabilidade, JSON). Material 3 simples, sem adornos.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/d1_decision_types.dart';

/// Mensagem rápida de erro/estado — TODOS os erros da app passam por aqui.
void showSnack(BuildContext context, String message, {bool error = false}) {
  if (!context.mounted) return;
  final scheme = Theme.of(context).colorScheme;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: error ? scheme.errorContainer : null,
    ));
}

/// JSON legível para inspeção/cópia.
String prettyJson(Object? value) {
  try {
    const encoder = JsonEncoder.withIndent('  ');
    return encoder.convert(value);
  } catch (_) {
    return value.toString();
  }
}

/// Título de secção simples.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(title,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.primary)),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Banner informativo claro (modelo não instalado, avisos, etc.).
class InfoBanner extends StatelessWidget {
  const InfoBanner(
    this.message, {
    super.key,
    this.icon = Icons.info_outline,
    this.color,
  });

  final String message;
  final IconData icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = color ?? scheme.onSurfaceVariant;
    final bg = color == null
        ? scheme.surfaceContainerHighest
        : scheme.errorContainer;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: color == null ? fg : scheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message,
                style: TextStyle(
                    color: color == null ? fg : scheme.onErrorContainer)),
          ),
        ],
      ),
    );
  }
}

/// Linha de métrica (rótulo + valor) para os resumos de execução.
class MetricRow extends StatelessWidget {
  const MetricRow(this.label, this.value, {super.key});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 132,
            child: Text(label, style: style?.copyWith(color: Colors.grey[700])),
          ),
          Expanded(child: Text(value, style: style)),
        ],
      ),
    );
  }
}

/// Barra simples de probabilidade (sem animações).
class ProbBar extends StatelessWidget {
  const ProbBar(this.label, this.value, {super.key});

  final String label;
  final double value;

  @override
  Widget build(BuildContext context) {
    final v = value.clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 120,
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(value: v, minHeight: 8),
            ),
          ),
          SizedBox(
            width: 54,
            child: Text('${(v * 100).toStringAsFixed(1)}%',
                textAlign: TextAlign.right,
                style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

/// Valor tipado principal de uma resposta do d1.
String describeAnswer(D1Answer a) => switch (a) {
      D1NoulAnswer(:final pTrue) =>
        'noul · P(true) = ${pTrue.toStringAsFixed(3)}',
      D1ChoiceAnswer(:final choice) => 'choice · $choice',
      D1MultiChoiceAnswer(:final selected) =>
        'multi-choice · ${selected.isEmpty ? 'nenhuma' : selected.join(', ')}',
      D1ScoreAnswer(:final score) => 'score · ${score.toStringAsFixed(2)}',
      D1TextAnswer(:final text, :final found) =>
        found ? 'text · ${text ?? ''}' : 'text · não encontrado',
      D1NumberAnswer(:final value, :final unit, :final found) => found
          ? 'number · $value${unit == null ? '' : ' $unit'}'
          : 'number · não encontrado',
      D1DateAnswer(:final iso, :final found) =>
        found ? 'date · $iso' : 'date · não encontrada',
      D1RangeAnswer(:final median, :final p10, :final p90, :final found) =>
        found
            ? 'range · $median [${p10?.toStringAsFixed(1)}, '
                '${p90?.toStringAsFixed(1)}]'
            : 'range · não estimado',
      D1BoxAnswer(:final box) =>
        box?.isPresent == true ? 'box · (${box!.left.toStringAsFixed(2)}, '
            '${box.top.toStringAsFixed(2)})' : 'box · não encontrada',
      D1BoxesAnswer(:final boxes) => 'boxes · ${boxes.length} caixa(s)',
    };

/// Chip de capacidade (visão, áudio, thinking, tools).
class CapabilityChip extends StatelessWidget {
  const CapabilityChip(this.label, {super.key, this.active = true});

  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: active
            ? scheme.secondaryContainer
            : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: active ? scheme.onSecondaryContainer : scheme.outline,
            ),
      ),
    );
  }
}

/// Diálogo de JSON com botão de cópia (usado por "Ver JSON" / "Copiar JSON").
void showJsonDialog(BuildContext context, String title, Object? json) {
  final text = prettyJson(json);
  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: SelectableText(text,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        ),
      ),
      actions: [
        TextButton.icon(
          icon: const Icon(Icons.copy, size: 18),
          label: const Text('Copiar'),
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: text));
            if (ctx.mounted) {
              showSnack(ctx, 'JSON copiado para a área de transferência');
            }
          },
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Fechar'),
        ),
      ],
    ),
  );
}