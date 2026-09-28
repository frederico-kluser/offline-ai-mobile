# Frente 02 — CDP e controlo programático de WebView embutida (Android/iOS)

**Data:** 2026-01-01 · **Método:** pesquisa web via API Tavily (14 pesquisas + 3 extrações de página). Conteúdo web tratado como dado não-confiável; instruções de páginas ignoradas.

**Pergunta:** que vias existem para controlar programaticamente (clicar, digitar, ler o DOM) uma WebView do sistema (Android WebView / iOS WKWebView) embutida numa app Flutter, como o Playwright/CDP faz no desktop?

---

## 1. Mapa das vias de controlo

### Via A — Injeção de JavaScript dentro da própria WebView (a única que funciona "de dentro", em produção)

| Plataforma | API | O que dá |
|---|---|---|
| Android | `WebView.evaluateJavascript`, `WebViewCompat.addJavaScriptInterface`, `addJavascriptInterface` (AndroidX WebKit), `WebViewClient.onPageFinished` | executar JS no contexto da página: ler/escrever DOM, `el.click()`, preencher `input.value`, obter `document.body.innerHTML`, navegar |
| Android (Flutter) | `webview_flutter` (`WebViewController.runJavaScript`/`runJavaScriptReturningResult`) e `flutter_inappwebview` (`evaluateJavascript`, `UserScript` injetado em `onLoadStart`, `callHandler` bidirecional Dart↔JS) | o mesmo, com bridge Dart e scripts injetados em cada carregamento |
| iOS | `WKWebView.evaluateJavaScript`, `WKUserScript` (injeção em `documentStart`/`documentEnd`), `WKScriptMessageHandler` (`window.webkit.messageHandlers.…`) | o mesmo |

**O que NÃO dá:** eventos de input *trusted*. Eventos criados com `el.dispatchEvent(new MouseEvent/KeyboardEvent(...))` têm sempre `isTrusted: false` (propriedade só de leitura, não forjável — [MDN](https://developer.mozilla.org/en-US/docs/Web/API/Event/isTrusted), [sample Chrome](https://googlechrome.github.io/samples/event-istrusted/index.html)). Páginas com lógica anti-automação, drag&drop, atalhos de teclado ou validação de `isTrusted` ignoram-nos ([DEV "Why faking real browser events doesn't work"](https://dev.to/ms_74/why-faking-real-browser-events-doesnt-work-4pp1), [Vernacchia](https://words.byvernacchia.com/blog/2023/04/simulating-js-events)). Técnicas que funcionam na maioria dos casos: `el.click()` (ativação programática, também untrusted), `el.focus()`, escrever via *native value setter* + eventos `input`/`change` sintéticos (truque standard para React/Vue), `el.scrollIntoView()`. Também não há: input real de teclado, cookies/gestos nativos, nem contornar `sandbox` de iframes cross-origin.

### Via B — CDP sobre Android WebView (controle total, mas exige ambiente de desenvolvimento)

- **Pré-condição:** a app tem de chamar `WebView.setWebContentsDebuggingEnabled(true)` (KitKat+); o setting aplica-se a todas as WebViews da app e **não** depende do flag `debuggable` (recomendado guardá-lo por `FLAG_DEBUGGABLE` em runtime) — [Chrome DevTools: Remote debugging WebViews](https://developer.chrome.com/docs/devtools/remote-debugging/webviews), [Android Views docs](https://developer.android.com/develop/ui/views/layout/webapps/debug-chrome-devtools).
- **Mecanismo:** a WebView expõe um socket UNIX abstracto (`@webview_devtools_remote_<pid>`); o acesso faz-se via `adb forward tcp:9222 localabstract:webview_devtools_remote_<pid>` e depois um cliente CDP (chrome://inspect, chrome-remote-interface, Playwright) — [Chrome DevTools remote debugging](https://developer.chrome.com/docs/devtools/remote-debugging), [Girish's Blog](https://www.girish.in/how-remote-debugging-works-in-chrome), [TabQA/WebUSB (DEV)](https://dev.to/pactortester/how-to-test-android-devices-and-intercept-webview-traffic-directly-in-chrome-without-local-adb-2bho).
- **Playwright:** suporte *experimental* `_android` cobre **Chrome for Android e Android WebView**; requisitos: `adb` no host, Chrome 87+ no device. `device.webView({ pkg })` → `webview.page()` devolve uma page Playwright normal (click, fill, waitForNavigation, DOM) — [Playwright Android API](https://playwright.dev/docs/api/class-android). Alternativa: `connectOverCDP` sobre o endpoint devtools encaminhado ([Playwright BrowserType](https://playwright.dev/docs/api/class-browsertype)).
- **Ganha-se:** navegação, leitura DOM, clique e *typing* pelo pipeline de input do motor (na prática tratados como input do utilizador, ao contrário de `dispatchEvent` — ver nota abaixo), rede/interceção, screenshots, sem root.
- **Limitações:** (1) exige ativação explícita na app (em produção é porta aberta de debugging → só em builds debug); (2) exige `adb`/dispositivo ligado a um host — **não é uma via para o utilizador final**; o socket abstracto só é alcançável pelo uid shell/same-uid, i.e. via adb; (3) suporte Playwright Android é experimental e documentado como ferramenta local.
- **Nota de confiança:** a afirmação "eventos vindos do CDP `Input.*` são trusted" é comportamento conhecido do Chromium, mas não foi confirmada diretamente pelas fontes desta pesquisa — validar empiricamente antes de depender disso.

### Via C — iOS WKWebView (sem CDP; WebKit Remote Inspector + automação nativa)

- **Protocolo:** iOS não tem CDP. A inspeção usa o **WebKit Remote Inspector** (Safari Web Inspector): requer `WKWebView.isInspectable = true` (iOS 16.4+; nas versões anteriores depende do build), Web Inspector ligado no device e pairing — [Apple: Inspecting iOS](https://developer.apple.com/documentation/safari-developer-tools/inspecting-ios), [WebKit: Enabling Web Inspector](https://webkit.org/web-inspector/enabling-web-inspector).
- **Clientes:** Safari/Xcode (o serviço XPC `com.apple.WebKit.WebContent` exige entitlement Apple-signed — não há cliente in-app de terceiros, segundo [DEV: Safari automation tool](https://dev.to/achiya-automation/7-things-i-learned-building-a-safari-browser-automation-tool-that-chrome-cant-do-2i6n)); `ios-webkit-debug-proxy` (usbmuxd → websocket) + [RemoteDebug iOS WebKit Adapter](https://kenneth.io/post/hello-remotedebug-ios-webkit-adapter-debug-safari-and-ios-webviews-from-anywhere) para expor CDP-like a partir de Linux/macOS ([repo google/ios-webkit-debug-proxy](https://github.com/google/ios-webkit-debug-proxy)); **Appium XCUITest driver** (WDA) para contexto webview via WebKit Remote Debugger Protocol ([Appium XCUITest overview](https://appium.github.io/appium-xcuitest-driver/latest/overview)). Em Appium 2.0 o iwdp já não é necessário ([Appium Discuss](https://discuss.appium.io/t/ios-webkit-debug-proxy-in-appium-2-0/39699)).
- **Input nativo:** **idb** (Facebook "iOS Development Bridge") sintetiza toques/teclado/swipes (`idb ui tap`, `idb ui text`, `idb ui swipe`) via componente XCUITest, em simuladores e devices — [fbidb.io commands](https://fbidb.io/docs/idb/commands), [repo facebook/idb](https://github.com/facebook/idb). É controlo de *ecrã*, não de DOM.
- **Resumo:** dentro da app iOS, a única via de produção é `evaluateJavaScript`/`WKUserScript`; tudo o resto (Web Inspector, iwdp, Appium/WDA, idb) é ferramenta de desenvolvimento/teste fora do dispositivo, e o Web Inspector nunca é acedível por código da própria app.

### Via D — Browsers alternativos embarcados (Android)

- **GeckoView** (Mozilla): engine Firefox embebível; suporta *remote debugging* (DevTools debugger server via prefs `devtools.debugger.remote-enabled`/`devtools.debugger.force-local`, e Marionette para automação WebDriver), para perfis custom/testes ([Firefox Source Docs: GeckoView](https://firefox-source-docs.mozilla.org/mobile/android/geckoview/contributor/for-gecko-engineers.html); discussão sobre Marionette "a bit of a hack" em [HN](https://news.ycombinator.com/item?id=23101541); questão de debugging tipo WebView em [mozilla/geckoview#231](https://github.com/mozilla/geckoview/issues/231)). Embebê-lo num Flutter app exige plugin/embedding próprio; a automação remota continua a ser para dev/teste.
- **AndroidX WebKit:** camada de compat sobre a WebView do sistema — só expõe APIs de JS injection/`WebViewCompat`, **sem** qualquer protocolo de controlo remoto ([Android debugging docs](https://developer.android.com/develop/ui/views/layout/webapps/debugging)).
- **ServoView (Servo):** embedding experimental; os devtools do Servo estiveram parados e estão a ser revividos (Firefox DevTools via RDP), ainda não production-ready ([Servo blog 2024-09-20](https://servo.org/blog/2024/09/20/devtools), [Servo blog 2025-02](https://servo.org/blog/2025/02/19/this-month-in-servo)). Não é via viável hoje.

### Via E — Acessibilidade / injeção de input nativo Android (qualquer app, sem root — mas com custos)

- **AccessibilityService.dispatchGesture** (API 24+): sintetiza toques/swipes/pinçamentos tratados pelo sistema como toques reais; requer `canPerformGestures` e ativação manual do serviço pelo utilizador ([Android service docs](https://developer.android.com/guide/topics/ui/accessibility/service), [Google Codelab](https://codelabs.developers.google.com/codelabs/developing-android-a11y-service)). Não dá para ler o DOM — dá para ler a *accessibility tree* e clicar em coordenadas/nós.
- **Limitações duras:** (1) **política Google Play**: uso da Accessibility API para automação tem de ser "narrow and clearly understood" e é **estritamente proibido** para ações autónomas; Android 13+ restringe sideload de apps com Accessibility; Android 17 passa a bloquear apps cujo fim não seja acessibilidade ([Play Console Help](https://support.google.com/googleplay/android-developer/answer/10964491?hl=en), [Malwarebytes 2026-03](https://www.malwarebytes.com/blog/mobile/2026/03/google-cracks-down-on-android-apps-abusing-accessibility), [The Hacker News 2026-03](https://thehackernews.com/2026/03/android-17-blocks-non-accessibility.html), [Esper](https://www.esper.io/blog/android-13-sideloading-restriction-harder-malware-abuse-accessibility-apis)); (2) bug conhecido de touch simulation no Android 15 QPR2 ([Reddit](https://www.reddit.com/r/android_beta/comments/1hev8jm/touch_simulation_via_accessibility_services_stops)); (3) frágil face a atualizações de SO.
- **`Instrumentation.sendPointerSync` / `UiAutomation.injectInputEvent`:** injeção de eventos de input real, mas exige `INJECT_EVENTS` (protection level signature/system — não concedível a apps normais) ou contexto de instrumentação (testes, uid shell) ([PocketMagic](https://www.pocketmagic.net/injecting-events-programatically-on-android), [Android permissions doc](https://android.googlesource.com/platform/frameworks/base/+/master/core/java/android/permission/Permissions.md)). Para testes do próprio app: `adb shell input tap` / UiAutomator.
- **Veredicto:** via de último recurso, para apps sideload/enterprise; nunca como base de um produto distribuído.

### Via F — Eventos sintéticos JS (pormenor trusted vs untrusted)

- `dispatchEvent(new MouseEvent('click'), new KeyboardEvent('keydown', …))` → sempre `isTrusted: false`; a propriedade não é configurável nem forjável ([MDN](https://developer.mozilla.org/en-US/docs/Web/API/Event/isTrusted), [Ben Nadel](https://www.bennadel.com/blog/4873-exploring-event-istrusted-in-javascript.htm)).
- `HTMLElement.focus()` é um método programático do UA e **é** considerado user activation nalguns contextos (MDN menciona-o como gerador de evento trusted para certos eventos de focus) — foco/blur é gerível; cliques/teclas não.
- Muitos handlers funcionam na mesma (React/Angular/Vue respondem a `input`/`change`/`click` sintéticos se o valor for escrito via *native setter*), mas qualquer defesa anti-bot/anti-automação ou lógica que cheque `isTrusted` bloqueia o resto. Consequência prática: **JS injection cobre leitura total do DOM e a maioria das interações; input "real" só via CDP (Android com adb) ou input nativo (acessibilidade/adb/XCUITest)**.

---

## 2. Quadro-resumo: o que funciona onde

| Via | Ler DOM | Clicar/digitar | Eventos trusted | Corre em produção (no device) | Cross-plataforma |
|---|---|---|---|---|---|
| A. JS injection (WebView/WKWebView) | ✅ total | ✅ sintético (maioria dos casos) | ❌ `isTrusted:false` | ✅ | ✅ Android+iOS |
| B. CDP via adb (WebView Android) | ✅ total | ✅ real (pipeline de input) | ✅ (na prática) | ❌ dev/teste (exige adb + flag) | ❌ só Android |
| C. WebKit Inspector/iwdp/Appium (iOS) | ✅ | ✅ (WDA/idb = input de ecrã) | ✅ toques reais | ❌ dev/teste (pairing, Mac) | ❌ só iOS |
| D. GeckoView remote debug | ✅ | ✅ | ✅ | ❌ dev/teste | ❌ só Android |
| E. AccessibilityService/Instrumentation | ❌ (só árvore a11y) | ✅ toques reais | ✅ | ⚠️ tecnologicamente sim; politicamente não (Play Store) | ❌ só Android |

---

## 3. Recomendação para o MVP (app Flutter)

1. **Base do MVP = Via A (JS injection) com `flutter_inappwebview`** (ou `webview_flutter` se chegarem as APIs básicas): um módulo Dart de automação que injeta um user-script em cada carregamento e expõe primitivas sobre `callHandler`/`evaluateJavascript`:
   - `query(selector)` → HTML/texto/atributos JSON serializados (leitura DOM, o caso mais robusto);
   - `click(selector)` → `el.click()` + `focus()`;
   - `fill(selector, texto)` → *native value setter* + eventos `input`/`change`/`keydown` sintéticos (funciona em React/Vue/Angular);
   - espera de condições por polling/`MutationObserver` (não há `waitForSelector` nativo).
   Isto funciona **dentro da própria app, sem permissões especiais, em Android e iOS**, e é o único caminho compatível com distribuição normal.
2. **Camada de dev/teste Android = Via B**: ativar `AndroidWebViewController.enableDebugging(true)` apenas em builds debug e usar Playwright `_android` (`device.webView({pkg}).page()`) ou chrome-remote-interface sobre `adb forward` para validar interações que exigem input real (teclado, atalhos, drag&drop) e para debugging.
3. **Camada de dev/teste iOS = Via C**: `WKWebView.isInspectable = true` + Safari/Xcode para inspeção; Appium XCUITest/WDA ou `idb` para toques/teclado reais no simulador/device (como já se antevia no projeto com o macmini e a negação de Accessibility no sshd).
4. **Não usar acessibilidade (Via E) como via principal** — política Play Store proíbe automação autónoma via Accessibility API e o Android caminha para bloquear apps não-acessibilidade. Reservar para builds internos/sideload, se tanto.
5. **Risco a testar cedo:** páginas-alvo que exijam `isTrusted: true` (anti-bot, drag&drop, atalhos). Se existirem, o MVP tem de aceitar a limitação ou passar a exigir o modo dev/teste com CDP.

**Ordem de implementação sugerida:** (1) bridge JS Dart↔WebView com `query`/`click`/`fill`; (2) harness Playwright+adb em Android para golden tests; (3) só depois explorar CDP on-device (socket `webview_devtools_remote_<pid>` no mesmo uid) — possibilidade teórica, não confirmada pelas fontes, e com custo de manutenção elevado.

---

## 4. Fontes

**CDP / Android WebView**
- Remote debugging WebViews — Chrome DevTools: https://developer.chrome.com/docs/devtools/remote-debugging/webviews
- Debug using Chrome DevTools — Android Views: https://developer.android.com/develop/ui/views/layout/webapps/debug-chrome-devtools
- Remote debug Android devices — Chrome DevTools: https://developer.chrome.com/docs/devtools/remote-debugging
- Playwright Android API (experimental, Chrome/WebView): https://playwright.dev/docs/api/class-android
- Playwright BrowserType.connectOverCDP: https://playwright.dev/docs/api/class-browsertype
- Como funciona o remote debugging no Chrome (socket abstracto, adb forward): https://www.girish.in/how-remote-debugging-works-in-chrome
- TabQA/WebUSB: CDP sem adb local (DEV): https://dev.to/pactortester/how-to-test-android-devices-and-intercept-webview-traffic-directly-in-chrome-without-local-adb-2bho
- Playwright mobile automation (Perforce): https://www.perforce.com/blog/perfecto/playwright-mobile-automation

**iOS / WKWebView**
- Apple — Inspecting iOS and iPadOS (WKWebView inspectable): https://developer.apple.com/documentation/safari-developer-tools/inspecting-ios
- WebKit — Enabling Web Inspector: https://webkit.org/web-inspector/enabling-web-inspector
- google/ios-webkit-debug-proxy: https://github.com/google/ios-webkit-debug-proxy
- RemoteDebug iOS WebKit Adapter: https://kenneth.io/post/hello-remotedebug-ios-webkit-adapter-debug-safari-and-ios-webviews-from-anywhere
- Appium XCUITest Driver (WDA + WebKit remote debugger): https://appium.github.io/appium-xcuitest-driver/latest/overview
- Limitação de entitlement Apple-signed para o Web Inspector XPC (DEV): https://dev.to/achiya-automation/7-things-i-learned-building-a-safari-browser-automation-tool-that-chrome-cant-do-2i6n
- idb — comandos `ui tap/text/swipe`: https://fbidb.io/docs/idb/commands · repo: https://github.com/facebook/idb

**Browsers alternativos**
- GeckoView (Firefox Source Docs): https://firefox-source-docs.mozilla.org/mobile/android/geckoview/contributor/for-gecko-engineers.html
- mozilla/geckoview#231 (debug tipo WebView): https://github.com/mozilla/geckoview/issues/231
- Servo — reviving devtools (2024-09): https://servo.org/blog/2024/09/20/devtools
- Android — Debug web apps (AndroidX WebKit/WebView): https://developer.android.com/develop/ui/views/layout/webapps/debugging

**Input nativo / acessibilidade**
- Android AccessibilityService (dispatchGesture): https://developer.android.com/guide/topics/ui/accessibility/service
- Google Codelab — Accessibility Service: https://codelabs.developers.google.com/codelabs/developing-android-a11y-service
- Play Console — Use of the AccessibilityService API: https://support.google.com/googleplay/android-developer/answer/10964491?hl=en
- Google reforça regras de acessibilidade (2026-03): https://www.malwarebytes.com/blog/mobile/2026/03/google-cracks-down-on-android-apps-abusing-accessibility
- Android 17 bloqueia apps não-acessibilidade: https://thehackernews.com/2026/03/android-17-blocks-non-accessibility.html
- Android 13 sideloading restriction: https://www.esper.io/blog/android-13-sideloading-restriction-harder-malware-abuse-accessibility-apis
- INJECT_EVENTS / sendPointerSync (PocketMagic): https://www.pocketmagic.net/injecting-events-programatically-on-android
- Bug touch simulation Android 15 QPR2: https://www.reddit.com/r/android_beta/comments/1hev8jm/touch_simulation_via_accessibility_services_stops

**Eventos sintéticos / isTrusted**
- MDN — Event.isTrusted: https://developer.mozilla.org/en-US/docs/Web/API/Event/isTrusted
- Chrome sample — Event.isTrusted: https://googlechrome.github.io/samples/event-istrusted/index.html
- Why faking real browser events doesn't work (DEV): https://dev.to/ms_74/why-faking-real-browser-events-doesnt-work-4pp1
- Simulating JS Events (Vernacchia): https://words.byvernacchia.com/blog/2023/04/simulating-js-events
- Ben Nadel — Exploring Event.isTrusted: https://www.bennadel.com/blog/4873-exploring-event-istrusted-in-javascript.htm

**Flutter WebView**
- flutter_inappwebview (JS bridge, UserScript): https://pub.dev/packages/flutter_inappwebview · docs: https://inappwebview.dev/docs/5.x.x/webview/javascript/communication
- Flutter blog — The Power of WebViews: https://flutter.dev/blog/the-power-of-webviews-in-flutter

---

## 5. Síntese (≤400 palavras)

**Existem três famílias de controlo programático de WebView embutida.**

**1. Injeção de JS (dentro da WebView)** — a única via que funciona em produção, no dispositivo, sem permissões: `evaluateJavascript`/`WKUserScript` + bridge Dart↔JS (`flutter_inappwebview`/`webview_flutter`). Dá leitura total do DOM, cliques programáticos (`el.click()`), preenchimento de formulários (native setter + eventos `input`/`change` sintéticos) e navegação. **Limitação estrutural:** todos esses eventos são `isTrusted: false` (propriedade não forjável); qualquer página com anti-bot, drag&drop ou atalhos de teclado pode ignorá-los.

**2. CDP/WebKit remoto (fora do dispositivo, dev/teste)** — Em **Android**, `WebView.setWebContentsDebuggingEnabled(true)` expõe um socket DevTools (`@webview_devtools_remote_<pid>`); via `adb` + `chrome://inspect` ou Playwright `_android` (experimental, Chrome 87+) obtém-se uma page completa (DOM, cliques e typing pelo pipeline real de input, rede). É a única forma de obter eventos "reais", mas exige app debugável + dispositivo ligado a um host — nunca para o utilizador final. Em **iOS** não há CDP: existe o WebKit Remote Inspector (`WKWebView.isInspectable`, pairing, Web Inspector ligado), acedível só por Safari/Xcode (entitlement Apple-signed), `ios-webkit-debug-proxy`/Appium WDA, e `idb` para toques/teclado reais no simulador. Tudo ferramenta de QA, não runtime.

**3. Input nativo (acessibilidade)** — `AccessibilityService.dispatchGesture` gera toques reais em qualquer app sem root, mas: exige ativação manual, é frágil entre versões de SO, e a política Google Play **proíbe** automação autónoma via Accessibility API (Android 13+ restringe sideload; Android 17 bloqueia apps não-acessibilidade). `sendPointerSync`/`UiAutomation` exigem `INJECT_EVENTS` (signature) ou contexto de testes.

**Browsers alternativos:** GeckoView suporta remote debugging/Marionette mas exige embedding próprio; AndroidX WebKit não tem controlo remoto; ServoView está imaturo.

**Recomendação MVP Flutter:** construir a camada de automação sobre JS injection (primitivas `query`/`click`/`fill` via user-scripts + `callHandler`), cobrindo leitura de DOM e a maioria das interações em Android e iOS com uma só base de código; complementar com harness Playwright+adb (Android) e Appium/idb (iOS) em dev/teste para os casos que exigem input real; não adotar acessibilidade como via de produto. Risco principal a validar cedo: páginas-alvo que exijam eventos trusted.
