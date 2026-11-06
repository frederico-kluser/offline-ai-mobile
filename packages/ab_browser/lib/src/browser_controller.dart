/// Contrato do controlador do browser embutido.
///
/// Um único barramento de ações ([BrowserAction]) com três produtores (humano
/// pelas teclas flutuantes, Laya, MiniCPM5-2B). A implementação concreta
/// ([WebViewBrowserController]) injeta a ponte JS e executa cada ação dentro
/// da WebView; em testes usa-se um fake determinístico.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import 'browser_action.dart';
import 'browser_page_state.dart';

/// Resultado de uma ação (mesma forma do [ToolResult] do agente: status
/// explícito + motivo, nunca vazio nem ambíguo).
class ActionResult {
  /// `ok` | `no_results` | `error` — nunca vazio.
  final String status;
  final String output;
  final int durationMs;

  /// Motivo quando `status == 'error'` (ex.: `ref-not-found`, `bridge-missing`).
  final String? errorKind;

  /// Snapshot atualizado quando a ação o devolve (snapshot/extract/tap…).
  final PageSnapshot? snapshot;

  const ActionResult({
    required this.status,
    required this.output,
    required this.durationMs,
    this.errorKind,
    this.snapshot,
  });

  bool get ok => status == 'ok';

  factory ActionResult.ok(String output,
          {int durationMs = 0, PageSnapshot? snapshot}) =>
      ActionResult(
          status: 'ok',
          output: output,
          durationMs: durationMs,
          snapshot: snapshot);

  factory ActionResult.noResults(String output,
          {int durationMs = 0, PageSnapshot? snapshot}) =>
      ActionResult(
          status: 'no_results',
          output: output,
          durationMs: durationMs,
          snapshot: snapshot);

  factory ActionResult.error(String kind, String output,
          {int durationMs = 0}) =>
      ActionResult(
          status: 'error',
          output: output,
          durationMs: durationMs,
          errorKind: kind);
}

/// Evento do browser para a UI (carga de página, mudanças de estado).
class BrowserEvent {
  final String type; // 'page_started' | 'page_finished' | 'console'
  final String? url;
  final String? detail;

  const BrowserEvent(this.type, {this.url, this.detail});
}

/// Controlador abstrato do browser embutido.
abstract class BrowserController {
  /// A view nativa do browser (WebView em produção; SizedBox em testes).
  Widget buildView();

  /// A ponte JS está instalada e pronta (página carregada pelo menos uma vez).
  bool get isReady;

  /// URL atual (conhecido pelo controlador; `null` antes da 1ª carga).
  String? get currentUrl;

  /// Stream de eventos (carga de página, etc.).
  Stream<BrowserEvent> get events;

  /// Executa UMA ação do vocabulário. Nunca lança para erros de página:
  /// devolve [ActionResult] com `status: 'error'` e `errorKind` estável.
  Future<ActionResult> execute(BrowserAction action);

  /// Conveniência: `execute(BrowserSnapshot())` com o snapshot tipado.
  Future<PageSnapshot> snapshot();

  /// Carrega um URL (atalho de [BrowserNavigate]).
  Future<void> loadUrl(String url);

  Future<void> dispose();
}
