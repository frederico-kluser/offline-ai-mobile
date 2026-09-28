/// Browser embutido em ecrã inteiro com "teclas flutuantes" — a feature-alvo
/// do teste simples: o browser ocupa a tela toda e as nossas ações (botões e
/// input flutuantes) mandam ações para a página.
///
/// Arquitetura de UI (dossiê 05-ui-teclas-flutuantes.md):
///  - [Stack] com a WebView como ÚNICA platform view (camada 0, modo texture
///    layer) e teclas/input como widgets Flutter puros por cima;
///  - imersão `immersiveSticky` com restauro em dispose (edge-to-edge);
///  - `resizeToAvoidBottomInset: false`: o input flutuante sobe com
///    `MediaQuery.viewInsets.bottom` e o browser NÃO redimensiona;
///  - alvos de toque ≥48dp, dock colapsável arrastável só pelo handle.
///
/// Três produtores de ações sobre o MESMO barramento ([BrowserController]):
/// humano (teclas), Laya (piloto tipado) e MiniCPM5-2B (agente com tools).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../agent/tool_loop.dart';
import '../browser/browser_action.dart';
import '../browser/browser_controller.dart';
import '../browser/browser_page_state.dart';
import '../browser/browser_pilot.dart';
import '../browser/browser_tools.dart';
import '../browser/webview_browser_controller.dart';
import '../domain/llm_config.dart';
import '../services/store.dart';
import 'app_services.dart';

enum _InputMode { url, type, click, goal }

class BrowserPage extends StatefulWidget {
  const BrowserPage({
    super.key,
    required this.store,
    this.controller,
    this.startUrl = 'https://duckduckgo.com',
  });

  final AppStore store;

  /// Injetável para testes (por omissão, WebView real).
  final BrowserController? controller;
  final String startUrl;

  static Future<void> open(BuildContext context, AppStore store) {
    return Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => BrowserPage(store: store),
      fullscreenDialog: true,
    ));
  }

  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage> {
  late final BrowserController _browser =
      widget.controller ?? WebViewBrowserController(initialUrl: widget.startUrl);

  final TextEditingController _input = TextEditingController();
  final ScrollController _logScroll = ScrollController();

  _InputMode _mode = _InputMode.url;
  PageSnapshot? _snapshot;
  final List<String> _log = [];
  final List<String> _history = [];
  String _goal = '';
  String _lastTypeText = '';
  String _status = '';
  bool _busy = false;
  bool _dockCollapsed = false;
  double _dockOffset = 0;
  Timer? _statusTimer;

  @override
  void initState() {
    super.initState();
    // Imersão total (teclas flutuantes são o único chrome).
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _addLog('browser pronto — usa as teclas ou define um objetivo');
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _input.dispose();
    _logScroll.dispose();
    _browser.dispose();
    // Restauro do chrome do sistema (edge-to-edge é o default moderno).
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  // ------------------------------------------------------------------ ações

  Future<void> _dispatch(BrowserAction action) async {
    setState(() => _busy = true);
    final r = await _browser.execute(action);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _history.add(action.canonicalKey);
      if (_history.length > 20) _history.removeAt(0);
      if (r.snapshot != null) _snapshot = r.snapshot;
      final out = r.output.replaceAll(RegExp(r'\s+'), ' ');
      _setStatus('${r.status}: ${out.length > 140 ? out.substring(0, 140) : out}');
      _addLog('${action.kind} → ${r.status}: $out');
    });
  }

  void _setStatus(String s) {
    _statusTimer?.cancel();
    setState(() => _status = s);
    _statusTimer = Timer(const Duration(seconds: 6), () {
      if (mounted) setState(() => _status = '');
    });
  }

  void _addLog(String line, {bool merge = false}) {
    final clean = line.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (clean.isEmpty) return;
    if (merge && _log.isNotEmpty && _log.last.startsWith('…') && _log.last.length < 800) {
      _log[_log.length - 1] = '${_log.last} $clean';
      return;
    }
    _log.add(merge ? '… $clean' : clean);
    if (_log.length > 60) _log.removeAt(0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScroll.hasClients) {
        _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
      }
    });
  }

  // ------------------------------------------------------------- piloto Laya

  Future<void> _pilotStep() async {
    if (_goal.trim().isEmpty) {
      _setStatus('define primeiro o objetivo (tecla 🎯)');
      setState(() => _mode = _InputMode.goal);
      return;
    }
    final services = AppServices.instance;
    final modelPath = services.layaModelPath;
    final tokenizerPath = services.layaTokenizerPath;
    if (modelPath == null || tokenizerPath == null) {
      _setStatus('kit Laya não instalado — descarrega na aba Modelos');
      return;
    }
    setState(() => _busy = true);
    try {
      final engine = await services.ensureLaya(
        modelPath: modelPath,
        tokenizerPath: tokenizerPath,
        config: const LayaConfig(),
      );
      final pilot = BrowserPilot(engine: engine);
      final page = _snapshot ?? await _browser.snapshot();
      final decision = await pilot.run(
        objective: _goal,
        page: page,
        history: List.of(_history),
        userHint: _lastTypeText,
      );
      if (!mounted) return;
      _addLog('piloto: ${decision.note}');
      switch (decision.disposition) {
        case PilotDisposition.act:
          await _dispatch(decision.action!);
        case PilotDisposition.escalate:
          _setStatus('confiança média — a escalar para o agente LLM');
          await _runAgent(suggestion: decision.note);
        case PilotDisposition.done:
          _setStatus('objetivo cumprido ✔');
        case PilotDisposition.abstain:
          _setStatus('piloto abstém-se — decide pelas teclas');
      }
    } catch (e) {
      _setStatus('erro no piloto: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ----------------------------------------------------------- agente MiniCPM

  Future<void> _runAgent({String suggestion = ''}) async {
    if (_goal.trim().isEmpty) {
      _setStatus('define primeiro o objetivo (tecla 🎯)');
      setState(() => _mode = _InputMode.goal);
      return;
    }
    final services = AppServices.instance;
    final modelPath = services.llmModelPath;
    if (modelPath == null) {
      _setStatus('modelo GGUF não instalado — descarrega na aba Modelos');
      return;
    }
    setState(() => _busy = true);
    try {
      final config = widget.store.llmConfig;
      final engine =
          await services.ensureLlm(modelPath: modelPath, config: config);
      final tools = browserTools(_browser, typeText: () => _lastTypeText);
      final loop = services.makeToolLoop(llm: engine, tools: tools);
      if (loop == null) {
        _setStatus('ToolLoop indisponível nesta build');
        return;
      }
      final prompt = suggestion.isEmpty
          ? _goal
          : '$_goal\n\nContexto do piloto: $suggestion';
      await for (final ev in loop.run(
        userPrompt: prompt,
        systemPrompt: kBrowserAgentSystemPrompt,
        config: config,
      )) {
        if (!mounted) continue;
        setState(() {
          switch (ev) {
            case LoopText(:final text):
              _addLog(text, merge: true);
            case LoopToolCall(:final call, :final step):
              _addLog('p$step 🔧 ${call.name}(${call.args})');
            case LoopToolResult(:final result, :final step):
              _addLog('p$step → ${result.output}');
            case LoopGuardTrip(:final reason, :final detail):
              _addLog('guardrail: ${reason.name} ($detail)');
            case LoopEnd(:final result):
              _addLog('agente: ${result.answer}');
              _setStatus('agente terminou (${result.stopReason.name})');
          }
        });
      }
    } catch (e) {
      _setStatus('erro no agente: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ------------------------------------------------------------------ input

  void _submitInput() {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    switch (_mode) {
      case _InputMode.url:
        _dispatch(BrowserNavigate(text));
      case _InputMode.type:
        // Sintaxe: "e12 texto…" (ref + texto) ou só "texto" (campo focado).
        final m = RegExp(r'^(e\d+)\s+(.+)$', dotAll: true).firstMatch(text);
        final ref = m?.group(1) ?? '';
        final body = m?.group(2) ?? text;
        _lastTypeText = body;
        _dispatch(BrowserType(ref: ref, text: body, submit: true));
      case _InputMode.click:
        _dispatch(BrowserTap(text));
      case _InputMode.goal:
        setState(() => _goal = text);
        _setStatus('objetivo definido');
        _addLog('objetivo: $text');
    }
  }

  Future<void> _openElementsSheet() async {
    final page = _snapshot ?? await _browser.snapshot();
    if (!mounted) return;
    setState(() => _snapshot = page);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('Elementos da página (toca para clicar)',
                  style: Theme.of(ctx).textTheme.titleMedium),
            ),
            if (page.elements.isEmpty)
              const ListTile(
                leading: Icon(Icons.visibility_off_outlined),
                title: Text('Sem elementos interativos visíveis.'),
              ),
            for (final e in page.elements)
              ListTile(
                dense: true,
                leading: Icon(e.isEditable ? Icons.text_fields : Icons.touch_app,
                    size: 20),
                title: Text('${e.ref} · ${e.role.isNotEmpty ? e.role : e.tag} '
                    '"${e.name}"'),
                subtitle: e.value == null ? null : Text('valor: ${e.value}'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  _dispatch(BrowserTap(e.ref));
                },
              ),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          // Camada 0 — a ÚNICA platform view (textura na cena Flutter).
          Positioned.fill(child: _browser.buildView()),
          // Faixa de estado (topo, translúcida).
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: _topStrip(context),
            ),
          ),
          // Log flutuante (colapsável).
          if (_log.isNotEmpty)
            Positioned(
              left: 8,
              right: 8,
              bottom: 120 + bottomInset + _dockOffset,
              child: _logPanel(context),
            ),
          // Input flutuante (sobe com o teclado, browser não redimensiona).
          Positioned(
            left: 8,
            right: 8,
            bottom: 64 + bottomInset + _dockOffset,
            child: _floatingInput(context),
          ),
          // Dock de teclas flutuantes.
          Positioned(
            left: 8,
            right: 8,
            bottom: 8 + bottomInset + _dockOffset,
            child: _dock(context),
          ),
        ],
      ),
    );
  }

  Widget _topStrip(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        children: [
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          Expanded(
            child: Text(
              _status.isNotEmpty
                  ? _status
                  : (_browser.currentUrl ?? 'about:blank'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close, size: 20),
            tooltip: 'Fechar browser',
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
    );
  }

  Widget _logPanel(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 96,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListView.builder(
        controller: _logScroll,
        itemCount: _log.length,
        itemBuilder: (_, i) => Text(
          _log[i],
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
        ),
      ),
    );
  }

  Widget _floatingInput(BuildContext context) {
    final hint = switch (_mode) {
      _InputMode.url => 'URL… (Enter para navegar)',
      _InputMode.type => 'texto para a página ("e12 texto" ou só texto)',
      _InputMode.click => 'ref do elemento para clicar (ex.: e3)',
      _InputMode.goal => 'objetivo do piloto/agente…',
    };
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(12),
      child: TextField(
        controller: _input,
        minLines: 1,
        maxLines: 2,
        textInputAction: TextInputAction.go,
        onSubmitted: (_) => _submitInput(),
        decoration: InputDecoration(
          hintText: hint,
          isDense: true,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          filled: true,
          suffixIcon: IconButton(
            icon: const Icon(Icons.send, size: 20),
            tooltip: 'Enviar ação',
            onPressed: _submitInput,
          ),
        ),
      ),
    );
  }

  Widget _dock(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(16),
      color: scheme.surfaceContainerHigh.withValues(alpha: 0.92),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle: arrastar move o dock (snap a 2 posições), tocar colapsa.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragUpdate: (d) {
              setState(() {
                _dockOffset =
                    (_dockOffset - d.delta.dy).clamp(0.0, 260.0);
              });
            },
            onVerticalDragEnd: (_) {
              setState(() =>
                  _dockOffset = _dockOffset > 130 ? 260.0 : 0.0);
            },
            onTap: () => setState(() => _dockCollapsed = !_dockCollapsed),
            child: SizedBox(
              height: 24,
              child: Icon(Icons.drag_handle,
                  size: 18, color: scheme.onSurfaceVariant),
            ),
          ),
          if (!_dockCollapsed)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Row(
                children: [
                  _key(Icons.arrow_back, 'Voltar',
                      () => _dispatch(const BrowserBack())),
                  _key(Icons.arrow_forward, 'Avançar',
                      () => _dispatch(const BrowserForward())),
                  _key(Icons.refresh, 'Recarregar',
                      () => _dispatch(const BrowserReload())),
                  _key(Icons.link, 'URL', () => setState(() {
                        _mode = _InputMode.url;
                        _input.text = _browser.currentUrl ?? '';
                      })),
                  _key(Icons.keyboard, 'Digitar', () => setState(() {
                        _mode = _InputMode.type;
                      })),
                  _key(Icons.ads_click, 'Clicar', () => setState(() {
                        _mode = _InputMode.click;
                      })),
                  _key(Icons.map_outlined, 'Mapa', _openElementsSheet),
                  _key(Icons.keyboard_arrow_down, 'Rolar ↓',
                      () => _dispatch(const BrowserScroll(0, 0.6))),
                  _key(Icons.keyboard_arrow_up, 'Rolar ↑',
                      () => _dispatch(const BrowserScroll(0, -0.6))),
                  _key(Icons.route_outlined, 'Piloto (Laya)', _pilotStep),
                  _key(Icons.smart_toy_outlined, 'Agente (LLM)',
                      () => _runAgent()),
                  _key(Icons.flag_outlined, 'Objetivo', () => setState(() {
                        _mode = _InputMode.goal;
                      })),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _key(IconData icon, String tooltip, VoidCallback onPressed) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: IconButton(
        onPressed: _busy ? null : onPressed,
        tooltip: tooltip,
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        icon: Icon(icon, size: 22),
      ),
    );
  }
}