/// Página de run: browser embutido + autopilot ao vivo + gate humano + handoff
/// verificado. O equivalente mobile do `abctl run` (com tape e park).
library;

import 'dart:async';

import 'package:ab_browser/ab_browser.dart';
import 'package:ab_core/ab_core.dart';
import 'package:flutter/material.dart';

import '../backends/decision_backend.dart';
import '../backends/jev_online.dart';
import '../backends/laya_decision_backend.dart';
import '../backends/minicpm_text_backend.dart';
import '../backends/mimo_online.dart';
import '../backends/text_backend.dart';
import '../domain/mission.dart';
import '../domain/tape.dart';
import '../autopilot/autopilot.dart';
import '../autopilot/masking.dart';
import '../park.dart';
import '../settings.dart';

class RunPage extends StatefulWidget {
  final MissionRunState run;
  final AppSettings settings;

  const RunPage({super.key, required this.run, required this.settings});

  @override
  State<RunPage> createState() => _RunPageState();
}

class _RunPageState extends State<RunPage> implements AutopilotHost {
  late final WebViewBrowserController _browser;
  final Park _park = Park();
  final List<String> _log = [];
  Autopilot? _autopilot;
  bool _running = false;
  bool _handoff = false;
  String _status = 'pronto';

  @override
  void initState() {
    super.initState();
    _browser =
        WebViewBrowserController(initialUrl: widget.run.spec.startUrl);
  }

  @override
  void dispose() {
    _browser.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------ backends
  Future<DecisionBackend> _makeDecisionBackend() async {
    final spec = widget.run.spec;
    if (spec.decisionMode == DecisionMode.jevOnline) {
      return JevOnlineBackend(
        apiKey: widget.settings.openrouterKey,
        onTrace: (req, resp, {ms = 0, costUsd = 0}) =>
            _autopilot?.tape.llmCall(
                model: 'typesafe/jev-1.13',
                kind: 'decision',
                request: req,
                response: resp,
                ms: ms,
                costUsd: costUsd),
      );
    }
    final services = AppServices.instance;
    final modelPath = services.layaModelPath;
    final tokenizerPath = services.layaTokenizerPath;
    if (modelPath == null || tokenizerPath == null) {
      throw StateError(
          'kit Laya não instalado — usa o modo online ou descarrega os modelos na app de exemplo');
    }
    final engine = await services.ensureLaya(
      modelPath: modelPath,
      tokenizerPath: tokenizerPath,
      config: const LayaConfig(),
    );
    return LayaLocalDecisionBackend(engine: engine);
  }

  Future<TextBackend> _makeTextBackend() async {
    final spec = widget.run.spec;
    if (spec.textMode == TextMode.mimoOnline) {
      return MimoOnlineBackend(
        apiKey: widget.settings.openrouterKey,
        onTrace: (req, resp, {ms = 0, costUsd = 0}) => _autopilot?.tape.llmCall(
            model: 'xiaomi/mimo-v2.6-pro',
            kind: 'chat',
            request: req,
            response: resp == null ? null : {'content': resp},
            ms: ms,
            costUsd: costUsd),
      );
    }
    final services = AppServices.instance;
    final modelPath = services.llmModelPath;
    if (modelPath == null) {
      throw StateError(
          'MiniCPM5-2B não instalado — usa o modo online ou descarrega os modelos na app de exemplo');
    }
    final engine = await services.ensureLlm(
        modelPath: modelPath, config: const LlmConfig());
    return MinicpmLocalTextBackend(engine: engine, config: const LlmConfig());
  }

  // ------------------------------------------------------------ corrida
  Future<void> _start() async {
    if (_running) return;
    final spec = widget.run.spec;
    // Modos online precisam da chave OpenRouter (validada e guardada
    // criptografada nas definições).
    final needsKey = spec.decisionMode == DecisionMode.jevOnline ||
        spec.textMode == TextMode.mimoOnline;
    if (needsKey && !widget.settings.hasKey) {
      onLog('sem chave OpenRouter — adiciona nas definições '
          '(validada e guardada criptografada)');
      setState(() => _status = 'sem chave OpenRouter — ver definições');
      return;
    }
    setState(() {
      _running = true;
      _status = 'a correr…';
    });
    final scrubber = SecretScrubber();
    for (final e in spec.variables.entries) {
      if (spec.secretVariables.contains(e.key)) {
        scrubber.register(e.value, e.key);
      }
    }
    try {
      final decision = await _makeDecisionBackend();
      final text = await _makeTextBackend();
      final ap = Autopilot(
        run: widget.run,
        browser: _browser,
        decision: decision,
        text: text,
        host: this,
        scrubber: scrubber,
        bands: DecisionBands(
          auto: widget.settings.autoBand,
          min: widget.settings.minBand,
          doneMin: widget.settings.doneBand,
        ),
        onStep: (r) {
          if (mounted) setState(() {});
        },
      );
      _autopilot = ap;
      final outcome = await ap.runMission();
      if (mounted) {
        setState(() {
          _status = 'fim: ${outcome.name}';
        });
      }
    } catch (e) {
      onLog('ERRO: $e');
      if (mounted) setState(() => _status = 'erro: $e');
    } finally {
      await _park.saveRun(widget.run);
      if (mounted) setState(() => _running = false);
    }
  }

  // ------------------------------------------------------------ AutopilotHost
  @override
  void onLog(String line) {
    if (!mounted) return;
    setState(() => _log.add(line));
  }

  @override
  Future<bool> gateConfirm(GateRequest request) async {
    onLog('GATE: ${request.why}');
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _GateDialog(request: request),
    );
    return result ?? false; // timeout/fecho = NEGADO (fora de banda)
  }

  @override
  Future<String?> askHuman(String question) async {
    onLog('PERGUNTA: $question');
    final answer = await showModalBottomSheet<String?>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _AskSheet(question: question),
    );
    return answer; // null = park
  }

  @override
  Future<void> handoff(String why) async {
    if (!mounted) return;
    setState(() {
      _handoff = true;
      _status = 'handoff: $why';
    });
    onLog('HANDOFF: $why — assume o controlo e toca em "✔ Terminei"');
  }

  Future<void> _finishHandoff() async {
    // done_check: a confirmação do humano NÃO basta — o estado da página
    // tem de mudar (regra do desktop: verificar, não acreditar).
    final before = await _browser.snapshot();
    setState(() {
      _handoff = false;
      _running = true;
    });
    await Future<void>.delayed(const Duration(seconds: 1));
    final after = await _browser.snapshot();
    final verified = after.url != before.url ||
        after.text.hashCode != before.text.hashCode;
    onLog(verified
        ? 'handoff verificado: a página mudou — a continuar'
        : 'handoff SEM mudança detetada na página — a continuar (atenção)');
  }

  // ------------------------------------------------------------ UI
  @override
  Widget build(BuildContext context) {
    final run = widget.run;
    return Scaffold(
      appBar: AppBar(
        title: Text('missão: ${run.spec.goal}',
            maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'tape (auditoria)',
            icon: const Icon(Icons.receipt_long),
            onPressed: () => _showTape(),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            flex: 5,
            child: Stack(
              children: [
                Positioned.fill(child: _browser.buildView()),
                if (_handoff)
                  Positioned(
                    left: 8,
                    right: 8,
                    top: 8,
                    child: Card(
                      color: Colors.orange.shade100,
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Column(
                          children: [
                            Text(_status,
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold)),
                            const SizedBox(height: 4),
                            FilledButton.icon(
                              onPressed: _finishHandoff,
                              icon: const Icon(Icons.check),
                              label: const Text('✔ Terminei a ação'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(_status,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
                FilledButton.tonalIcon(
                  onPressed: _running ? null : _start,
                  icon: const Icon(Icons.play_arrow),
                  label: Text(_running ? 'a correr…' : '▶ correr'),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 3,
            child: ListView.builder(
              padding: const EdgeInsets.all(8),
              itemCount: _log.length,
              itemBuilder: (_, i) => Text(
                _log[_log.length - 1 - i],
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showTape() {
    final tape = _autopilot?.tape ?? Tape();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SizedBox(
        height: MediaQuery.of(ctx).size.height * 0.7,
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            const Text('Tape (mascarado) — auditoria da run',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            for (final e in tape.entries) Text(e.toString(), style: const TextStyle(fontSize: 11)),
          ],
        ),
      ),
    );
  }
}

/// Diálogo de gate NATIVO — fora de banda: sem auto-aprovação e com timeout
/// que NEGADA (120 s).
class _GateDialog extends StatefulWidget {
  final GateRequest request;
  const _GateDialog({required this.request});

  @override
  State<_GateDialog> createState() => _GateDialogState();
}

class _GateDialogState extends State<_GateDialog> {
  Timer? _timer;
  int _left = 120;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      setState(() => _left -= 1);
      if (_left <= 0) {
        t.cancel();
        Navigator.of(context).pop(false);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: const Icon(Icons.gpp_maybe, color: Colors.red),
      title: const Text('Ação irreversível?'),
      content: Text('${widget.request.why}\n\n'
          'Alvo: ${widget.request.label}\n'
          'Timeout ${_left}s = NEGADO.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Não')),
        FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Sim, autorizo')),
      ],
    );
  }
}

/// Cartão de pergunta ao humano (bottom sheet).
class _AskSheet extends StatefulWidget {
  final String question;
  const _AskSheet({required this.question});

  @override
  State<_AskSheet> createState() => _AskSheetState();
}

class _AskSheetState extends State<_AskSheet> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.question,
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            TextField(
              controller: _controller,
              autofocus: true,
              decoration: const InputDecoration(
                  border: OutlineInputBorder(), hintText: 'resposta…'),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(null),
                  child: const Text('assumir controlo (park)'),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: () =>
                      Navigator.of(context).pop(_controller.text.trim()),
                  child: const Text('responder'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
