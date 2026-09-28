# Frente 01 — Webviews em Flutter (estado da arte 2025–2026)

**Âmbito**: browser embutido (WebView fullscreen) para app Flutter que corre LLMs locais, com controlo por ações injetadas (JS) vindas de botões flutuantes e de um decisor local. Android primeiro, iOS depois.
**Método**: pesquisa web via API Tavily (15 pesquisas + 4 extrações de página), executada em **2026-09-28**. Todo o conteúdo web é dado não-confiável tratado apenas como evidência factual.
**Prefixo de data fixo** (`2026-01-01-...`) por decisão do projeto; a data real de pesquisa é a indicada acima.

---

## 1. Recomendação concreta (TL;DR)

**Usar `flutter_inappwebview` 6.x como motor do browser embutido, escondido atrás de uma camada de abstração própria (`BrowserEngine`), e manter `webview_flutter` 4.x como plano B/fallback de engenharia.**

Porquê `flutter_inappwebview` para este caso de uso específico:

1. **Injeção de JS no `document start`** com `UserScript`/`initialUserScripts` (`UserScriptInjectionTime.AT_DOCUMENT_START`) — essencial para um agente que injeta ações antes de o DOM da página estar pronto. O `webview_flutter` estável **não expõe API de UserScripts** (a API `WebViewController` só traz `addJavaScriptChannel`, `runJavaScript`, `runJavaScriptReturningResult` — ver [API WebViewController](https://pub.dev/documentation/webview_flutter/latest/webview_flutter/WebViewController-class.html)).
2. **Bridge Dart↔JS rica e assíncrona**: `addJavaScriptHandler` + `window.flutter_inappwebview.callHandler(...)` aceita argumentos tipados (números, bools, listas, mapas) e devolve `Future` para o JS — muito melhor para um protocolo de ações LLM do que `postMessage` de string única ([docs de comunicação](https://inappwebview.dev/docs/webview/javascript/communication)).
3. **Popups / `target=_blank` / `window.open`** com `onCreateWindow` + `supportMultipleWindows` + WebView secundária com `windowId` — o `webview_flutter` não expõe `onCreateWindow` (links `target=_blank` não abrem).
4. **Extras de agente**: `HeadlessWebView` (executar ações offscreen para o decisor local), `takeScreenshot`, `getHtml`, `findAllAsync`, `getScrollPosition`, `onEnterFullscreen/onExitFullscreen` (vídeo HTML5 fullscreen), `onDownloadStartRequest` (Android), `onPermissionRequest`.
5. **Tipos de retorno de `evaluateJavascript`**: devolve `dynamic` estruturado (JSON) sem forçar `JSON.stringify` manual em todos os call-sites.

**Contrapeso (porque escondemos atrás de abstração)**: o `flutter_inappwebview` estável (**6.1.5**) está estagnado há ~2 anos (publicado ~out/2024) e o **6.2.0-beta.3** (~fev/2026) ainda não tem estável anunciado — a [discussão #2646](https://github.com/pichillilorenzo/flutter_inappwebview/discussions/2646) (jun/2025) pediu o plano de release do 6.2.0 e ficou **sem resposta**. Já o `webview_flutter` (publisher oficial `flutter.dev`) está em **4.14.1** (~jul/2026) e sobe sistematicamente o mínimo de SDK. Ou seja: **mais features vs. mais garantia de manutenção**.

**Se os requisitos forem reduzidos** (sem popups, sem downloads, sem injeção no `document start`, sem vídeo fullscreen — ex.: só navegar e injetar ações após `onPageFinished`), **`webview_flutter` 4.x é a escolha mais segura** e elimina um risco de manutenção. Para um "browser embutido" controlado por agente, os requisitos acima parecem todos necessários, logo vence o `flutter_inappwebview`.

---

## 2. Tabela comparativa

| Critério | `webview_flutter` 4.14.x (oficial, flutter.dev) | `flutter_inappwebview` 6.x (inappwebview.dev) | Impacto no browser embutido |
|---|---|---|---|
| Versão atual | **4.14.1** (~jul/2026); 4.14.0 exigiu Flutter 3.38/Dart 3.10 | Estável **6.1.5** (~out/2024); prerelease **6.2.0-beta.3** (~fev/2026) | Manutenção: vence `webview_flutter`; features: vence `inappwebview` |
| Compat. Flutter | 4.14.x → Flutter ≥3.38; 4.13.x → ≥3.32; 4.11 → ≥3.27; 4.9 → ≥3.24 (implementações por plataforma retrocedem) | 6.1.5 → Flutter ≥3.24, Dart ≥3.5 | Com Flutter 3.3x mais antigo, fixar `webview_flutter` 4.13.x ou usar `inappwebview` |
| Plataformas | Android (SDK 24+), iOS 13+, macOS 10.15+ | Android (minSdk 19, compileSdk 34, AGP ≥7.3), iOS 12+, macOS, Windows, web (Linux no 6.2.0-beta) | Android-first: ambos ok |
| Motor | `android.webkit.WebView` / `WKWebView` (federado: `webview_flutter_android`/`_ios`/`_macos`) | Mesmos motores + wrappers (pacotes `flutter_inappwebview_android`/`_ios`/...) | Paridade de renderização |
| Executar JS | `runJavaScript` (fire-and-forget), `runJavaScriptReturningResult` → `Future<Object>` (tenta parsear `bool`/`num`) | `evaluateJavascript` (devolve `dynamic` estruturado), `callAsyncJavaScript` (JS assíncrono) | `inappwebview` melhor para payloads estruturados |
| Injeção no load | Sem API de UserScripts; `JavaScriptChannel` (`window.<name>.postMessage`) existe desde o início do contexto em Android (`addJavascriptInterface`); resto injeta-se em `onPageFinished` | `UserScript` com `AT_DOCUMENT_START`/`AT_DOCUMENT_END` + `initialUserScripts` | Crítico para ações de agente; ⚠ ver caveat Android abaixo |
| Bridge Dart↔JS | `addJavaScriptChannel`/`removeJavaScriptChannel` (só strings) | `addJavaScriptHandler`/`callHandler` com argumentos tipados e `Future` de resposta | `inappwebview` vence claramente |
| Popups / `target=_blank` | **Não suportado** (sem `onCreateWindow`; `window.open` cai no vazio) | `onCreateWindow` + `supportMultipleWindows` + `javaScriptCanOpenWindowsAutomatically` + WebView `windowId` (ex.: [interceptar popups, jan/2025](https://iwritecodesometimes.net/2025/01/23/intercepting-web-popups-in-flutter-inappwebview)) | Necessário para web real |
| File upload | `setOnShowFileSelector` (Android; iOS 14.1+) + `file_picker`/câmara tem de ser plugada à mão ([issue #118836](https://github.com/flutter/flutter/issues/118836)) | `onFilePicker` / `onFilePickerWithFileContent` + settings de captura | Ambos exigem trabalho manual com câmara |
| Downloads | **Sem `DownloadListener`** ([issue #89657](https://github.com/flutter/flutter/issues/89657), aberta desde 2021) — workaround: intercetar navegação + `dio`/`DownloadManager` | `onDownloadStartRequest` (principalmente Android; iOS mais limitado) | Risco médio em ambos; planear download manual |
| Permissões (câmara/mic/geo) | `onPermissionRequest` na criação do controlador, cobertura desigual ([issue #56871](https://github.com/flutter/flutter/issues/56871)) | `onPermissionRequest` (Android/iOS 15+) + `permission_handler` ([guia WebRTC](https://inappwebview.dev/docs/5.x.x/web-rtc)) | `inappwebview` mais completo |
| Vídeo HTML5 fullscreen | **Problema conhecido** ([#47508](https://github.com/flutter/flutter/issues/47508), [#45464](https://github.com/flutter/flutter/issues/45464), [#144974](https://github.com/flutter/flutter/issues/144974), bug iOS 26 [#176015](https://github.com/flutter/flutter/issues/176015)) | `onEnterFullscreen`/`onExitFullscreen`, `iframeAllowFullscreen`, `allowsPictureInPictureMediaPlayback` ([settings](https://inappwebview.dev/docs/webview/in-app-weview-settings)) | Se o browser precisa de vídeo, `inappwebview` |
| Cookies / storage | `WebViewCookieManager.getCookies` (4.14.0), `clearLocalStorage` separado de `clearCache` | `CookieManager` completo (get/set/remove, HTTP-only) | Empate técnico |
| Headless / screenshots | Não | `HeadlessWebView`, `takeScreenshot`, `getHtml`, `findAllAsync` | Decisor LLM pode observar sem UI |
| Zoom/viewport | Sem API direta de zoom (controla-se por `<meta viewport>`) | `enableViewportScale`, `useWideViewPort`, `setZoom`/zoom controls | `inappwebview` vence |
| Renderização Android | Platform View (virtual display / hybrid composition / HCPP) | Igual (platform view) | Ver armadilhas §5 |

Alternativas testadas na pesquisa e **descartadas**: `flutter_webview_plugin` (abandonado; só referido em artigos antigos), wrappers finos tipo `webview_all`/`flutter_webview_communication` (camada por cima dos dois grandes, sem ganho). Não há um terceiro player credível em 2025–2026: a escolha é binária.

---

## 3. Frente 2 — Executar JavaScript a partir de Dart

- **Síncrono/assíncrono**: `webview_flutter.runJavaScriptReturningResult(expr)` devolve `Future<Object>` — na prática `bool`, `num` ou `String`; objetos JS complexos **não** voltam tipados, há que devolver `JSON.stringify(...)` e desserializar em Dart (relatos de devolução literal `{}`: [SO 76048861](https://stackoverflow.com/questions/76048861/flutter-runjavascriptreturning-result-returns)). `flutter_inappwebview.evaluateJavascript` devolve `dynamic` já convertido (JSON), e `callAsyncJavaScript` espera `await` de promises — preferível para ações LLM que podem demorar.
- **Canais Dart→JS**: sem "canal" ativo Dart→JS em nenhum dos plugins: injeta-se código (`runJavaScript`/`evaluateJavascript`) que chama funções da página. O sentido JS→Dart é que usa canais (`postMessage` no `webview_flutter`; `callHandler` no `inappwebview`).
- **Disponibilidade do canal**: `addJavaScriptChannel` expõe `window.<name>.postMessage` desde o início do contexto JS em Android (por baixo é `addJavascriptInterface` — [ref. Android](https://developer.android.com/reference/android/webkit/WebView)); a página pode usá-lo antes de `onPageFinished`. Mas *código* que queiras correr no `document start` (instalar hooks, monkey-patches, listeners) só é fiável com `UserScript AT_DOCUMENT_START` do `inappwebview`.
  - ⚠ **Caveat oficial Android**: com `AT_DOCUMENT_START`, se `WebViewFeature.DOCUMENT_START_SCRIPT` não existir no WebView do dispositivo, **não há garantia** de injeção antes de outros recursos ([docs User Scripts](https://inappwebview.dev/docs/webview/javascript/user-scripts)). Convém ter fallback: re-injetar também em `onLoadStart`/`onLoadStop`.
- **Limites de payload**:
  - iOS/WKWebView: tipos permitidos em mensagens são `NSNumber`, `NSString`, `NSDate`, `NSArray`, `NSDictionary`, `NSNull` (documentação da Apple citada em [onebigfunction](https://onebigfunction.com/ios/2016/12/14/iOS-javascript-communication)); relatos de **limite ~1 MB** em `postMessage` para o handler ([diamantidis](https://diamantidis.github.io/2020/02/02/two-way-communication-between-ios-wkwebview-and-web-page)).
  - Android: mensagens grandes nos canais podem rebentar o transporte Binder → `TransactionTooLargeException` (mesma classe de problemas do Android em geral: [OnePageCRM](https://developer.onepagecrm.com/blog/handling-transactiontoolargeexception-android)).
  - **Regra prática para o protocolo de ações**: mensagens < ~256 KB; para DOM/screenshots grandes, passar por ficheiro/URI ou fatiar (`chunk`); nunca transportar HTML completo por canal — usar `getHtml()`/`evaluateJavascript` com recortes.

---

## 4. Frente 3 — Fullscreen / immersive / teclado

- **Modos**: `SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky)` dá fullscreen sticky (barras só aparecem ao deslizar da borda); `SystemUiMode.immersive` e `leanBack` são as alternativas ([guia dartling.dev](https://dartling.dev/toggle-full-screen-mode-in-flutter)).
- **Android 15+ (targetSdk 35)**: edge-to-edge é **imposto** pela plataforma; a partir do Flutter 3.27 o default passou a edge-to-edge e, com `flutter.targetSdkVersion` (Flutter 3.32+), a app alvo Android 15 ([breaking change oficial](https://docs.flutter.dev/release/breaking-changes/default-systemuimode-edge-to-edge), [docs Android](https://developer.android.com/develop/ui/views/layout/edge-to-edge), [análise LeanCode](https://leancode.co/blog/mastering-edge-to-edge-in-flutter)). Isto quer dizer: **o WebView já desenha por baixo das barras por omissão** — cuidado com o conteúdo por baixo do status bar/gesture pill (usar `SafeArea`, `MediaQuery.viewPadding`, `SystemUiOverlayStyle`).
- **Combinação perigosa**: `immersiveSticky` **não redimensiona** a janela quando o teclado aparece → o teclado **sobrepõe-se** ao WebView e esconde inputs. Comportamentos conhecidos:
  - Input tapado pelo teclado: [SO 67286328](https://stackoverflow.com/questions/67286328/flutter-webview-text-input-gets-hidden-by-soft-keyboard).
  - Estratégias: manter `Scaffold.resizeToAvoidBottomInset: true` com modo edge-to-edge (a janela redimensiona); ou `false` + reposicionar via `WidgetsBindingObserver.didChangeMetrics`/`flutter_keyboard_visibility`; e validar `android:windowSoftInputMode` no manifest (com fullscreen/immersive o `adjustResize` deixa de funcionar como esperado, Android clássico).
  - No `webview_flutter` 3.x documentava-se explicitamente que *hybrid composition* tem suporte de teclado e *virtual display* tem problemas de teclado ([pub.dev 3.0.4](https://pub.dev/packages/webview_flutter/versions/3.0.4)).
- **Recomendação desenho**: o WebView ocupa o ecrã inteiro; os botões flutuantes ficam numa `Stack` por cima (Flutter composita acima do platform view); barras de sistema a `immersiveSticky` só para leitura, mas **entrar em modo "input" deve sair de immersive** para o teclado funcionar de forma previsível.

---

## 5. Frente 4–5 — Downloads, uploads, permissões, popups, e problemas conhecidos

### Downloads
- `webview_flutter`: sem `DownloadListener` ([#89657](https://github.com/flutter/flutter/issues/89657)); workaround usual: `NavigationDelegate.onNavigationRequest` → descarregar com `dio`/`DownloadManager` + guardar com `path_provider`/SAF. Falha para `blob:` e para URLs geradas por POST.
- `inappwebview`: `onDownloadStartRequest` (Android); no iOS o download nativo (`WKDownloadDelegate`, iOS 14.5+) é mais espinhoso — **validar no protótipo** antes de prometer.

### File upload
- `webview_flutter`: `setOnShowFileSelector` existe (ver [PlatformWebViewController](https://pub.dev/documentation/webview_flutter_platform_interface/latest/webview_flutter_platform_interface/PlatformWebViewController-class.html)); é preciso abrir um file picker e devolver caminhos; captura por câmara exige permissões e paths `FileProvider` ([#118836](https://github.com/flutter/flutter/issues/118836), [SO 60289932](https://stackoverflow.com/questions/60289932/is-there-a-way-of-making-a-flutter-webview-use-android-camera-for-file-upload-h)).
- `inappwebview`: `onFilePicker`/`onFilePickerWithFileContent` com opções de captura.

### Permissões (câmara, mic, geolocalização)
- Nenhum dos dois resolve sozinho: pedir ao SO com `permission_handler` e responder ao pedido do WebView (`onPermissionRequest` / `MediaCapturePermissionRequest`). Referência de integração real (WebRTC/Whereby): [docs Whereby](https://docs.whereby.com/whereby-for-mobile-development/in-flutter), [inappwebview WebRTC](https://inappwebview.dev/docs/5.x.x/web-rtc).

### Popups / `target=_blank`
- `webview_flutter`: sem suporte — links com `target=_blank` não abrem; workaround frágil (interceptar e carregar na mesma WebView).
- `inappwebview`: padrão comprovado — `supportMultipleWindows: true` + `javaScriptCanOpenWindowsAutomatically: true` + `onCreateWindow` → criar `InAppWebView(windowId: createWindowAction.windowId)` (escondido ou em sheet) e depois mover/carregar a URL na WebView principal ([exemplo 2025](https://iwritecodesometimes.net/2025/01/23/intercepting-web-popups-in-flutter-inappwebview), [docs](https://inappwebview.dev/docs/webview/in-app-webview)).

### Problemas conhecidos (armadilhas)
1. **Renderização em Android (Platform Views)**: o WebView é um *platform view* — `virtual display` tem latência/cópia extra de buffer e problemas de teclado/gestos; `hybrid composition` tem melhor fidelidade de input mas custo de composição; o Flutter atual tem **HCPP (Hybrid Composition++)** em API 34+ com Vulkan que mitiga o custo ([docs Flutter](https://docs.flutter.dev/platform-integration/android/platform-views)). Bug de "conteúdo não atualizado visualmente" reportado em fev/2025: [#162865](https://github.com/flutter/flutter/issues/162865). Flash preto ao montar é comum ([#26771](https://github.com/flutter/flutter/issues/26771)).
2. **Gesture arena / scroll**: WebView dentro de `ListView`/`ScrollView` → conflito de gestos; `gestureRecognizers` do widget aceita fábricas de recognizers, e `EagerGestureRecognizer` faz o WebView **roubar todos os pointers** dentro dos seus limites ([docs AndroidView](https://api.flutter.dev/flutter/widgets/AndroidView/gestureRecognizers.html), issue [#35394](https://github.com/flutter/flutter/issues/35394)). ⚠ **Risco direto para os botões flutuantes**: testar que um recognizer agressivo não engole toques destinados aos overlays; em regra, overlays Flutter numa `Stack` por cima ganham o hit-test, mas o comportamento difere entre virtual display e hybrid composition.
3. **Zoom/viewport**: sem API de zoom no `webview_flutter`; `userScalable=no` só se a página respeitar ([SO 59873300](https://stackoverflow.com/questions/59873300/disabling-pinch-zoom-in-flutter-teams-webview)); no `inappwebview` há `enableViewportScale` e controlos de zoom ([settings](https://inappwebview.dev/docs/webview/in-app-weview-settings)). Testar reflow de texto e pinch num telemóvel real.
4. **Teclado Android**: ver §4 — inputs escondidos, `adjustResize` vs fullscreen, edge-to-edge forçado.
5. **Lifecycle e memória**: Android exige teardown explícito do WebView (parar execução, desligar da hierarquia, `destroy()`) ou vazam-se referências de Context e recursos nativos ([guia oficial Android — manage WebView memory](https://developer.android.com/develop/ui/views/layout/webapps/manage-webview-memory)). Em Flutter: `dispose()` do controlador no `State.dispose`, evitar reconstruir a WebView em builds repetidos, vigiar com [DevTools Memory](https://docs.flutter.dev/tools/devtools/memory). Um browser embutido longevo (muitas navegações) acumula memória do processo renderer — considerar reciclar a WebView (destruir/recriar) a cada N navegações.
6. **Vídeo fullscreen** não funciona de forma fiável no `webview_flutter` (vários issues abertos, incluindo bug iOS 26 em 2025/2026 — [#176015](https://github.com/flutter/flutter/issues/176015)).
7. **HTTP claro** (ex.: servidor do LLM local em `http://192.168.x.x` ou `http://10.0.2.2`): Android 9+ bloqueia cleartext por omissão — configurar `networkSecurityConfig`/`usesCleartextTraffic` (background: [#33464](https://github.com/flutter/flutter/issues/33464)). Relevante para esta app!
8. **APIs que sobem o mínimo de SDK**: `webview_flutter` 4.14 exige Flutter 3.38 — com toolchain 3.3x fixar 4.13.x (Flutter 3.32) ou 4.11.x (3.27) e aceitar menos features (`onSSlAuthError` é 4.13+, cookies 4.14+).

---

## 6. Plano de implementação sugerido (síntese acionável)

1. **Abstração própria** `BrowserEngine` (interface: `load`, `eval`, `evalJson`, `onDocumentStart(script)`, `sendAction`, `onActionFromPage`, `screenshot`, `onPopup`, `onDownload`, `dispose`) com 2 implementações (`InAppWebViewEngine`, `WebviewFlutterEngine`) — protege contra a estagnação do `inappwebview`.
2. **Protocolo de ações** em JSON pequeno (<256 KB), com ids/fatias para DOM grande; JS injetado no `document start` instala o "runtime de ações" (fila + ack) e é reinstalado em `onLoadStop` como fallback.
3. **Fullscreen**: ecrã do browser com `SystemUiMode.immersiveSticky` + `SafeArea` para overlays; ao focar input, sair de immersive e usar resize (`resizeToAvoidBottomInset: true`) — testar em Android 15 (edge-to-edge forçado).
4. **Cuidados de Android**: `networkSecurityConfig` para o servidor local do LLM; teardown do WebView no dispose; testar botões flutuantes sobre a WebView em ambos os modos de composição.
5. **Protótipo de espinha dorsal** (1–2 dias) para validar: `AT_DOCUMENT_START` em WebView Android antigo vs recente, `onCreateWindow`, upload com câmara, download, e teclado com `immersiveSticky`. Estes são os pontos que a documentação não garante.

---

## 7. Fontes (URLs consultadas)

**Plugins / versões / manutenção**
- https://pub.dev/packages/flutter_inappwebview (6.1.5; prerelease 6.2.0-beta.3; requisitos Flutter ≥3.24, Dart ^3.5, compileSdk 34)
- https://pub.dev/packages/webview_flutter (4.14.1, publisher flutter.dev; Android SDK 24+, iOS 13+)
- https://pub.dev/packages/webview_flutter/changelog (4.14.0 → Flutter 3.38/Dart 3.10; 4.13.1 → 3.32; 4.11 → 3.27; 4.9 → 3.24 + macOS)
- https://pub.dev/packages/flutter_inappwebview/versions/6.2.0-beta.3
- https://github.com/pichillilorenzo/flutter_inappwebview/discussions/2646 (sem resposta sobre 6.2.0 estável)
- https://blog.codemagic.io/inappwebview-the-real-power-of-webviews-in-flutter
- https://flutter.dev/blog/the-power-of-webviews-in-flutter (gestureRecognizers)

**API JavaScript / bridges**
- https://pub.dev/documentation/webview_flutter/latest/webview_flutter/WebViewController-class.html
- https://inappwebview.dev/docs/webview/javascript/communication
- https://inappwebview.dev/docs/webview/javascript/user-scripts (caveat Android `DOCUMENT_START_SCRIPT`)
- https://betterprogramming.pub/webview-javascript-injection-with-user-scripts-flutter-inappwebview-6-46d9969353a4
- https://stackoverflow.com/questions/76048861/flutter-runjavascriptreturning-result-returns
- https://onebigfunction.com/ios/2016/12/14/iOS-javascript-communication (tipos permitidos WKScriptMessage)
- https://diamantidis.github.io/2020/02/02/two-way-communication-between-ios-wkwebview-and-web-page
- https://developer.onepagecrm.com/blog/handling-transactiontoolargeexception-android

**Fullscreen / edge-to-edge / teclado**
- https://docs.flutter.dev/release/breaking-changes/default-systemuimode-edge-to-edge
- https://developer.android.com/develop/ui/views/layout/edge-to-edge
- https://leancode.co/blog/mastering-edge-to-edge-in-flutter
- https://dartling.dev/toggle-full-screen-mode-in-flutter
- https://stackoverflow.com/questions/67286328/flutter-webview-text-input-gets-hidden-by-soft-keyboard
- https://pub.dev/packages/webview_flutter/versions/3.0.4 (hybrid composition vs virtual display e teclado)

**Downloads / uploads / permissões / popups**
- https://github.com/flutter/flutter/issues/89657 (DownloadListener)
- https://github.com/flutter/flutter/issues/118836 (file chooser Android)
- https://stackoverflow.com/questions/60289932/is-there-a-way-of-making-a-flutter-webview-use-android-camera-for-file-upload-h
- https://github.com/flutter/flutter/issues/56871 (permissões)
- https://docs.whereby.com/whereby-for-mobile-development/in-flutter
- https://inappwebview.dev/docs/5.x.x/web-rtc
- https://inappwebview.dev/docs/webview/in-app-webview (`supportMultipleWindows`, `onCreateWindow`)
- https://iwritecodesometimes.net/2025/01/23/intercepting-web-popups-in-flutter-inappwebview

**Problemas conhecidos (render, gestos, zoom, vídeo, memória)**
- https://docs.flutter.dev/platform-integration/android/platform-views (HCPP, virtual display, hybrid composition)
- https://api.flutter.dev/flutter/widgets/AndroidView/gestureRecognizers.html
- https://github.com/flutter/flutter/issues/35394 (scroll aninhado com WebView)
- https://github.com/flutter/flutter/issues/162865 (conteúdo não atualizado, fev/2025)
- https://github.com/flutter/flutter/issues/47508 · /45464 · /36568 · /144974 · /176015 (vídeo fullscreen)
- https://developer.android.com/develop/ui/views/layout/webapps/manage-webview-memory
- https://docs.flutter.dev/tools/devtools/memory
- https://stackoverflow.com/questions/59873300/disabling-pinch-zoom-in-flutter-teams-webview
- https://inappwebview.dev/docs/webview/in-app-weview-settings (`enableViewportScale`, `allowsInlineMediaPlayback`, `iframeAllowFullscreen`)
- https://github.com/flutter/flutter/issues/33464 (HTTP cleartext)
