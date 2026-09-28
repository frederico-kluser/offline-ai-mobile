/// Implementação do [BrowserController] sobre `flutter_inappwebview` 6.x —
/// o motor escolhido no dossiê 01-webviews-flutter.md (UserScript em
/// AT_DOCUMENT_START + bridge tipada), escondido atrás da nossa abstração
/// (plano B: `webview_flutter`, trocando só este ficheiro).
///
/// Responsabilidades:
///  - injetar a ponte [kBrowserBridgeJs] no document start e REINJETAR em
///    cada `onLoadStop` (Android antigo não garante AT_DOCUMENT_START);
///  - mapear [BrowserAction] → navegação nativa OU `window.__oai.act(...)`;
///  - normalizar o retorno JS (Android devolve strings JSON codificadas);
///  - anexar `doc_id`/`ref_epoch` do último snapshot às ações (o DOM pode
///    ter mudado — a ponte rejeita com `stale-doc`/`stale-ref`).
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'browser_action.dart';
import 'browser_bridge_js.dart';
import 'browser_controller.dart';
import 'browser_page_state.dart';

/// Normaliza um texto do utilizador para URL (adiciona `https://`).
String? normalizeBrowserUrl(String input) {
  var s = input.trim();
  if (s.isEmpty) return null;
  if (s == 'about:blank') return s;
  if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(s)) {
    s = 'https://$s';
  }
  final uri = Uri.tryParse(s);
  if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
    return null;
  }
  return s;
}

/// Decodifica o retorno de `evaluateJavascript`: no Android o valor vem JSON
/// codificado (às vezes 2×); no iOS vem direto. Tenta sempre o caminho
/// determinístico mais profundo que der parse.
Object? decodeJsPayload(Object? raw) {
  Object? v = raw;
  for (var i = 0; i < 2; i++) {
    if (v is! String) break;
    try {
      v = jsonDecode(v);
    } catch (_) {
      break;
    }
  }
  return v;
}

class WebViewBrowserController implements BrowserController {
  WebViewBrowserController({this.initialUrl = 'about:blank'});

  final String initialUrl;

  final GlobalKey _key = GlobalKey();
  InAppWebViewController? _web;
  PageSnapshot? _lastSnapshot;
  String? _currentUrl;
  bool _ready = false;

  final StreamController<BrowserEvent> _events =
      StreamController<BrowserEvent>.broadcast();

  /// Orçamento de payload JS (<256 KB — TransactionTooLarge / WKScriptMessage).
  static const int maxJsBytes = 200 * 1024;
  static const Duration actionTimeout = Duration(seconds: 8);

  @override
  Widget buildView() => InAppWebView(
        key: _key,
        initialUrlRequest: URLRequest(url: WebUri(initialUrl)),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          transparentBackground: false,
          useShouldOverrideUrlLoading: true,
          mediaPlaybackRequiresUserGesture: false,
          supportZoom: true,
          // Dev/teste: permite Safari Web Inspector / chrome://inspect.
          isInspectable: true,
        ),
        initialUserScripts: UnmodifiableListView<UserScript>([
          UserScript(
            source: kBrowserBridgeJs,
            injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
          ),
        ]),
        onWebViewCreated: (c) {
          _web = c;
        },
        onLoadStart: (c, url) {
          _currentUrl = url?.toString();
          _lastSnapshot = null; // refs do documento anterior caducaram
          _events.add(BrowserEvent('page_started', url: _currentUrl));
        },
        onLoadStop: (c, url) async {
          // Reassegura a ponte (WebViews antigas ignoram AT_DOCUMENT_START).
          try {
            await c.evaluateJavascript(source: kBrowserBridgeJs);
          } catch (_) {}
          _ready = true;
          _currentUrl = url?.toString() ?? _currentUrl;
          _events.add(BrowserEvent('page_finished', url: _currentUrl));
        },
        onConsoleMessage: (c, msg) {
          _events.add(BrowserEvent('console', detail: msg.message));
        },
        onReceivedError: (c, request, error) {
          _events.add(BrowserEvent('console',
              url: request.url?.toString(),
              detail: 'erro de carga: ${error.description}'));
        },
      );

  @override
  bool get isReady => _ready && _web != null;

  @override
  String? get currentUrl => _currentUrl;

  @override
  Stream<BrowserEvent> get events => _events.stream;

  @override
  Future<PageSnapshot> snapshot() async {
    final r = await execute(const BrowserSnapshot());
    return r.snapshot ??
        _lastSnapshot ??
        const PageSnapshot(url: '', title: '', text: '', elements: []);
  }

  @override
  Future<void> loadUrl(String url) async {
    await execute(BrowserNavigate(url));
  }

  @override
  Future<ActionResult> execute(BrowserAction action) async {
    final sw = Stopwatch()..start();
    final web = _web;
    if (web == null) {
      return ActionResult.error(
          'no-webview', 'WebView ainda não criada', durationMs: sw.elapsedMilliseconds);
    }
    try {
      switch (action) {
        case BrowserNavigate(:final url):
          final u = normalizeBrowserUrl(url);
          if (u == null) {
            return ActionResult.error('bad-url', 'URL inválido: "$url"',
                durationMs: sw.elapsedMilliseconds);
          }
          if (u.length * 2 > maxJsBytes) {
            return ActionResult.error('payload-too-large', 'URL demasiado longo',
                durationMs: sw.elapsedMilliseconds);
          }
          final done = events
              .firstWhere((e) => e.type == 'page_finished')
              .timeout(const Duration(seconds: 15), onTimeout: () => const BrowserEvent('timeout'));
          await web.loadUrl(urlRequest: URLRequest(url: WebUri(u)));
          final ev = await done;
          if (ev.type == 'timeout') {
            return ActionResult.error(
                'timeout', 'a carga de $u não terminou em 15s (página continua a carregar?)',
                durationMs: sw.elapsedMilliseconds);
          }
          _currentUrl = u;
          return ActionResult.ok('navegado para $u',
              durationMs: sw.elapsedMilliseconds);

        case BrowserBack():
          if (await web.canGoBack() == true) {
            await web.goBack();
            return ActionResult.ok('voltou atrás',
                durationMs: sw.elapsedMilliseconds);
          }
          return ActionResult.noResults('sem histórico para voltar',
              durationMs: sw.elapsedMilliseconds);

        case BrowserForward():
          if (await web.canGoForward() == true) {
            await web.goForward();
            return ActionResult.ok('avançou',
                durationMs: sw.elapsedMilliseconds);
          }
          return ActionResult.noResults('sem histórico para avançar',
              durationMs: sw.elapsedMilliseconds);

        case BrowserReload():
          await web.reload();
          return ActionResult.ok('recarregado',
              durationMs: sw.elapsedMilliseconds);

        case BrowserEval(:final code):
          if (code.length * 2 > maxJsBytes) {
            return ActionResult.error('payload-too-large', 'JS demasiado longo',
                durationMs: sw.elapsedMilliseconds);
          }
          final raw = await web
              .evaluateJavascript(source: code)
              .timeout(actionTimeout);
          return ActionResult.ok('${decodeJsPayload(raw) ?? 'null'}',
              durationMs: sw.elapsedMilliseconds);

        case BrowserStop():
          return ActionResult.ok('parado (handoff)',
              durationMs: sw.elapsedMilliseconds);

        default:
          return _runBridgeAction(action, sw);
      }
    } on TimeoutException {
      return ActionResult.error(
          'timeout', 'a ação ${action.kind} não respondeu em ${actionTimeout.inSeconds}s',
          durationMs: sw.elapsedMilliseconds);
    } catch (e) {
      return ActionResult.error('exception', '${action.kind}: $e',
          durationMs: sw.elapsedMilliseconds);
    }
  }

  Future<ActionResult> _runBridgeAction(
      BrowserAction action, Stopwatch sw) async {
    final web = _web!;
    // Payload com doc_id/ref_epoch do último snapshot (validação stale-*).
    final payload = <String, dynamic>{
      ...action.toJson(),
      if (_lastSnapshot != null) ...{
        'doc_id': _lastSnapshot!.docId,
        'ref_epoch': _lastSnapshot!.refEpoch,
      },
    };
    final jsArg = jsonEncode(jsonEncode(payload));
    if (jsArg.length * 2 > maxJsBytes) {
      return ActionResult.error(
          'payload-too-large', 'ação demasiado grande para o canal JS',
          durationMs: sw.elapsedMilliseconds);
    }
    final raw = await web
        .evaluateJavascript(source: 'window.__oai.act($jsArg)')
        .timeout(actionTimeout);
    final decoded = decodeJsPayload(raw);
    if (decoded is! Map) {
      return ActionResult.error(
          'bridge-missing',
          'a ponte JS não respondeu (window.__oai ausente?) — '
          'tenta recarregar a página',
          durationMs: sw.elapsedMilliseconds);
    }
    final map = Map<String, dynamic>.from(decoded);
    PageSnapshot? snap;
    if (map['snapshot'] is Map) {
      snap = PageSnapshot.fromJson(
          Map<String, dynamic>.from(map['snapshot'] as Map));
      _lastSnapshot = snap;
      _currentUrl = snap.url.isNotEmpty ? snap.url : _currentUrl;
    }
    final status = map['status'] as String? ?? 'error';
    return ActionResult(
      status: status,
      output: (map['output'] ?? '').toString(),
      durationMs: sw.elapsedMilliseconds,
      errorKind: map['error_kind'] as String?,
      snapshot: snap,
    );
  }

  @override
  Future<void> dispose() async {
    await _events.close();
    _web = null;
    _ready = false;
  }
}