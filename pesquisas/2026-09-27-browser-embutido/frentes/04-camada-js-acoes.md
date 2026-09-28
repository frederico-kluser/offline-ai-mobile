# Frente 04 — Camada JS de ações em WebView embutida (Flutter)

**Data:** 2026-01-01 · **Método:** pesquisa web via Tavily (14 pesquisas + 4 extrações integrais)
**Âmbito:** serializar a página atual num "mapa" compacto para LLM, executar ações (clicar por ref, preencher inputs, rolar, selecionar, submeter) e ler resultados — dentro de Android WebView / iOS WKWebView via `flutter_inappwebview`. Conteúdo web tratado só como evidência factual.

---

## 1. Serializar o DOM para o LLM: quatro representações e a escolha

| Representação | O que é | Custos/ganhos | Referências |
|---|---|---|---|
| **Accessibility tree (ARIA)** | Árvore que o browser já constrói para leitores de ecrã: roles, nomes acessíveis, estados, foco; elimina `div`/`span` decorativos | Campo de formulário que eram **100+ linhas de HTML → "poucas linhas"** de snapshot; é a via do Playwright MCP / Chrome DevTools MCP | [arXiv 2511.19477](https://arxiv.org/html/2511.19477v1), [playwright.dev/mcp/introduction](https://playwright.dev/mcp/introduction) |
| **Simplified HTML** | DOM podado (sem `<script>`/`<style>`/attrs de estilo), texto preservado | Mais fiel ao markup quando a a11y tree está incompleta (canvas wrappers, SPAs más), mas payload muito maior | [Building Browser Agents](https://arxiv.org/html/2511.19477v1), [MERJ: the agent-readable web](https://merj.com/blog/the-agent-readable-web-serving-the-right-representation-to-the-right-crawler) |
| **Set-of-Marks (SoM)** | Marcas alfanuméricas sobrepostas em regiões da imagem (screenshot + bounding boxes) | Resolve elementos sem semântica (canvas/WebGL, ícones); exige modelo de visão; mais caro | [arXiv 2310.11441](https://arxiv.org/html/2310.11441v2), [microsoft/SoM](https://github.com/microsoft/SoM) |
| **Híbrido (recomendado)** | a11y-like tree textual + refs + `rect` por nó, screenshot opcional | É a arquitetura convergente: camada de percepção desacoplada da camada de execução (tool calls por ref) | [arXiv 2511.19477](https://arxiv.org/html/2511.19477v1) |

**Refs estáveis — como os grandes fazem:**

- **Playwright MCP**: cada tool devolve uma árvore de elementos acessíveis com refs únicas no formato YAML `- heading "todos" [level=1] [ref=e3]`; as tools `click`/`type` recebem `ref` → interação determinística, sem coordenadas ([playwright.dev/mcp/snapshots](https://playwright.dev/mcp/snapshots)).
- **WebArena/BrowserGym**: IDs gerados ao atravessar a árvore DOM/a11y; "com IDs de elemento, a seleção torna-se um problema de classificação n-way, eliminando ambiguidade" ([webarena.dev/static/paper.pdf](https://webarena.dev/static/paper.pdf)). O BrowserGym injeta um `bid` único em DOM **e** AXTree, com bounding boxes ([getmaxim.ai](https://www.getmaxim.ai/blog/browsergym-web-agent-automation)).
- **Midscene.js**: o LLM devolve IDs curtos de elementos que o runtime mapeia para nós reais (ex.: resposta `{"elements":[{"id":"5e4476af29"}]}`) ([nearform.com](https://nearform.com/digital-community/midscene-js-assessing-a-natural-language-ai-testing-tool)).

**Regra prática:** refs atribuídas no runtime (`data-xref="a1"`, `a2`, …), **versionadas por época** (`refEpoch`): quando o DOM muda muito (MutationObserver com contagem de mutações), incrementa-se a época e o Dart sabe que o mapa antigo caducou — é o "element reference versioning" do arXiv 2511.19477.

---

## 2. Contrato JS ↔ Dart (proposta)

Canal: `flutter_inappwebview` — Dart→JS via `callAsyncJavaScript`/`evaluateJavascript` (devolver **sempre JSON string**; no Android o retorno vem como string JSON a decodificar); JS→Dart via `window.flutter_inappwebview.callHandler('agentBridge', payload)`. Um único namespace injetado como UserScript `AT_DOCUMENT_START` (ver armadilhas §5): `window.__agent = {...}`.

### 2.1 Funções expostas ao Dart

| Função JS | Argumentos JSON | Retorno JSON |
|---|---|---|
| `__agent.snapshot(opts)` | `{maxNodes?, maxChars?, includeHidden:false, includeText:true, viewportOnly:false}` | `SnapshotResult` |
| `__agent.act(cmd)` | `ActionCommand` | `ActionResult` |
| `__agent.read(opts)` | `{ref?, mode:"text"\|"value"\|"html"\|"main"}` | `{ok, text, url, title}` |
| `__agent.state()` | — | `{url, title, readyState, refEpoch, scroll:{x,y,w,h}, pendingNetwork}` |
| `__agent.ping()` | — | `{v:1}` (sanity check da injeção) |

### 2.2 Formatos JSON

```json
// SnapshotResult
{
  "v": 1, "docId": "b7f2…", "refEpoch": 3,
  "url": "https://…", "title": "…",
  "nodes": [
    {"ref":"a1","role":"textbox","name":"Email","tag":"input","type":"email",
     "value":"","disabled":false,"visible":true,
     "rect":[12,340,280,40], "frameId": null}
  ],
  "text": "texto principal limpo (ver §6)",
  "truncated": false, "droppedNodes": 0
}
```

```json
// ActionCommand (Dart → JS)
{"id":"cmd-42","type":"click|fill|select|check|scroll|submit|key|wait",
 "ref":"a1","value":"texto ou option value",
 "options":{"smooth":false,"timeoutMs":5000,"clear":true}}
```

```json
// ActionResult (JS → Dart)
{"id":"cmd-42","ok":true,
 "error": null,
 "effects":{"urlChanged":false,"domChanged":true,"newRefEpoch":true},
 "observed":{"clickedTag":"button","valueAfter":"ana@…"}}
```

**Regras do contrato:**
1. Todo `ref` é validado no JS: inexistente → `{"ok":false,"error":{"code":"STALE_REF"}}` e sugestão de resnapshot. Guardar no JS um *fallback path* (CSS path curto) por ref para auto-recuperação.
2. `docId` = hash de `location.href + contagem de nós`; se o Dart enviar `docId` esperado e divergir, o JS devolve `URL_CHANGED` sem executar — evita agir sobre a página errada.
3. `act` é **assíncrono e com efeitos observados** (mudou URL? DOM mudou? epoch novo?) para o agente de orquestração saber quando pedir novo snapshot.
4. Ações críticas (submit, navegação externa) passam por política em Dart **antes** de chegar ao JS (a camada de tool/safety fica fora da página — padrão do [arXiv 2511.19477](https://arxiv.org/html/2511.19477v1)).
5. Orçamentos: `maxChars` do snapshot (~20–40 KB), timeout por ação, e um contador de scroll steps (§4).

---

## 3. Técnicas essenciais (padrões snippet-level)

### 3.1 Refs estáveis no DOM

```js
const seen = new WeakMap(); let n = 0, epoch = 1;
function refOf(el) {
  let r = seen.get(el);
  if (!r) { r = 'a' + (++n); seen.set(el, r); el.setAttribute('data-xref', r); }
  return r;
}
const byRef = (r) => document.querySelector(`[data-xref="${r}"]`);
```

- Percorrer **apenas elementos interativos + contêineres de texto**: `a, button, input, select, textarea, [role=button|link|textbox|checkbox|combobox], [onclick], [contenteditable=true]`, mais headings/paragraphs principais.
- `querySelectorAll` **não atravessa shadow roots** — recorrência manual (§5).

### 3.2 Clique sintético

```js
// 1.ª linha: basta na maioria dos casos (dispara também o default action do <a>/<label>)
el.click();
// 2.ª linha: quando há listeners em mousedown/mouseup ou validação por sequência
for (const t of ['pointerdown','mousedown','pointerup','mouseup','click'])
  el.dispatchEvent(new MouseEvent(t, {bubbles:true, cancelable:true, view:window}));
// Formulários: usar requestSubmit() em vez de submit()
form.requestSubmit(btn);   // dispara validação + evento 'submit'
```

`element.click()` e `dispatchEvent` geram eventos **`isTrusted: false`** — ver §5.1 ([MDN Event.isTrusted](https://developer.mozilla.org/en-US/docs/Web/API/Event/isTrusted), [bennadel.com](https://www.bennadel.com/blog/4873-exploring-event-istrusted-in-javascript.htm)).

### 3.3 Preencher inputs controlados (React/Vue/Angular)

```js
function setValue(el, v) {
  const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement
              : el instanceof HTMLSelectElement   ? HTMLSelectElement
              : HTMLInputElement;
  const setter = Object.getOwnPropertyDescriptor(proto.prototype, 'value')?.set;
  setter ? setter.call(el, v) : (el.value = v);        // contorna o setter "enganado" pelo React
  el.dispatchEvent(new Event('input',  {bubbles:true}));
  el.dispatchEvent(new Event('change', {bubbles:true}));
}
```

- É exatamente o padrão documentado: chamar o *native value setter* (React sobrepõe `value`) e depois despachar `change` para forçar re-render ([coryrylan.com](https://coryrylan.com/blog/trigger-input-updates-with-react-controlled-inputs), [benjaminray.com](https://benjaminray.com/codebase/updating-input-and-triggering-onchange-event-in-react)).
- **Checkboxes/radios** (React): setter de `checked` + `dispatchEvent(new MouseEvent('click', {bubbles:true}))` — não respondem a `change` como os de texto ([coryrylan.com](https://coryrylan.com/blog/trigger-input-updates-with-react-controlled-inputs)).
- **`<select>`**: `el.value = v; el.dispatchEvent(new Event('change', {bubbles:true}))` ([plainenglish.io](https://javascript.plainenglish.io/how-to-programmatically-set-the-value-of-a-select-element-using-javascript-f152fad36452)).
- **contenteditable / editores ricos** (Quill, ProseMirror): `el.focus(); document.execCommand('insertText', false, v)` — dispara `beforeinput`/`input` naturais; fallback `InputEvent('input', {bubbles:true, data:v, inputType:'insertText'})` ([MDN contenteditable](https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Global_attributes/contenteditable)).
- **Date pickers mascarados** (`input[type=date]`): valor ISO `yyyy-mm-dd` via native setter + `input`/`change`; pickers custom (flatpickr etc.) só com clique por ref nas células do calendário.
- **Não usar** `el.value = x` sozinho em apps React/Vue: o visual muda mas o estado não — a UI "não faz nada" ([dev.to/ms_74](https://dev.to/ms_74/why-faking-real-browser-events-doesnt-work-4pp1)).

### 3.4 Scroll, lazy-load, espera

```js
el.scrollIntoView({block:'center', inline:'nearest'}); // antes de clicar em elemento fora do viewport
window.scrollBy({top: innerHeight * 0.8, behavior:'instant'});
```

- **Lazy-load / infinite scroll**: `IntersectionObserver` no sentinela do rodapé; rolar em passos e esperar estabilização ([lucaspaganini.com](https://www.lucaspaganini.com/academy/intersection-observer-and-infinite-scroll-in-a-visual-way), [logrocket.com](https://blog.logrocket.com/react-infinite-scroll)).
- **Espera por DOM estável**: `MutationObserver` com debounce (ex.: silêncio de 300 ms ⇒ estável) + `requestIdleCallback` para captar pós-render; nunca `sleep` fixo cego.
- **Lazy-load pode nunca terminar** ⇒ impor orçamento (`maxScrollSteps`, ex. 10) e reportar `truncated:true` ao Dart.

### 3.5 SPA: detectar navegação sem reload

```js
// monkey-patch (injetado AT_DOCUMENT_START)
const _ps = history.pushState, _rs = history.replaceState;
history.pushState = function(...a){ _ps.apply(this,a); fire('nav'); };
history.replaceState = function(...a){ _rs.apply(this,a); fire('nav'); };
addEventListener('popstate', () => fire('nav'));
addEventListener('hashchange', () => fire('nav'));
// fire('nav') → atualiza docId/refEpoch e notifica Dart via callHandler
```

- `popstate` só dispara em back/forward — **não** deteta `pushState` feito pela app ([stackoverflow 65325933](https://stackoverflow.com/questions/65325933/pure-javascript-to-detect-spa-dom-ready-and-page-change), [gist mohammedrahman-e2x](https://gist.github.com/mohammedrahman-e2x/de230e8361ef11817c3a1ad7bf9d0ade)).
- Quando existir **Navigation API** (`navigation.addEventListener('navigate')`) é a solução robusta; Baseline desde 2026 ([web.dev](https://web.dev/blog/baseline-navigation-api)). Detetar `document.readyState` + observer em `<body>` para SPAs com substituição total do root.

### 3.6 Ler resultados sem boilerplate

- `innerText` = texto **visível** (respeita CSS, força reflow); `textContent` = todo o texto incluindo oculto ([MDN textContent](https://developer.mozilla.org/en-US/docs/Web/API/Node/textContent), [perfectionkills.com](https://perfectionkills.com/the-poor-misunderstood-innerText)). Para "texto visível da página": `innerText` de `document.body` é o melhor primeiro passo.
- Heurística de conteúdo principal: `article`, `[role=main]`, `main`, `<article>` com maior razão texto/tags; cortar `nav, header, footer, aside, [role=navigation], [aria-hidden=true], script, style, noscript`.
- Alternativa robusta: algoritmo tipo **Readability** (Mozilla) — pontua blocos por densidade de texto/parágrafos e extrai só o artigo; ideal para páginas de conteúdo longo.
- Devolver ao LLM texto truncado com orçamento (`maxChars`) + indicar `truncated`.

---

## 4. Leitura de resultados (ciclo fechado)

Depois de `act`, o resultado lê-se com `__agent.read` ou com um snapshot delta:
1. `act` devolve `effects.{urlChanged, domChanged, newRefEpoch}`;
2. se `newRefEpoch` → novo `snapshot()` (mapa novo) antes do próximo passo do agente;
3. para "ler resultado" pontual (ex.: texto após submit), `read({ref, mode:"text"})` é mais barato que um snapshot completo.

---

## 5. Armadilhas

### 5.1 `isTrusted` — a grande barreira
- Eventos criados por `click()`/`dispatchEvent` têm `isTrusted: false` **e a propriedade é read-only** — não há forma legítima de a forjar a partir de JS na página ([MDN](https://developer.mozilla.org/en-US/docs/Web/API/Event/isTrusted), [bennadel.com](https://www.bennadel.com/blog/4873-exploring-event-istrusted-in-javascript.htm)).
- Handlers anti-bot/formulários sensíveis ignoram eventos não-fiáveis ("a UI ficou parada, nada aconteceu") ([dev.to/ms_74](https://dev.to/ms_74/why-faking-real-browser-events-doesnt-work-4pp1)).
- **Contornos possíveis, por ordem de preferência:**
  1. **Estado do framework** em vez do DOM: setters nativos + eventos `input`/`change` resolvem 95% dos casos (React/Vue/Angular);
  2. **Input nativo**: em Android WebView a alternativa real é injetar toques/injeção a nível de `InputEvent`/`MotionEvent` nativo (fora do JS); em WKWebView não há equivalente público — o JS é o teto. Playwright/Cypress conseguem `isTrusted: true` porque usam CDP `Input.dispatchMouseEvent`, abaixo do sandbox JS ([dev.to/ms_74](https://dev.to/ms_74/why-faking-real-browser-events-doesnt-work-4pp1), [CDP Input](https://chromedevtools.github.io/devtools-protocol/tot/Input/));
  3. **Gancho de runtime** (só em contexto de automação própria): interceptar `addEventListener` e envolver o handler com um evento-proxy — é um bypass frágil e anti-detetável, não recomendado para produção;
  4. Fallbacks de UX: clicar via `.focus()` + `Enter` sintético quando o handler reage a teclado (também `isTrusted:false`, mas muitas UIs só validam o clique).

### 5.2 Cross-origin iframes
- `iframe.contentDocument` é `null` quando o origin difere — **sem exceção**; o JS da página pai não alcança nem lê o frame ([stackoverflow 29337304](https://stackoverflow.com/questions/29337304/how-to-detect-a-click-inside-of-an-iframe-cross-domain-aka-prevent-click-frau)).
- Solução: injetar o UserScript **em todos os frames** (`forMainFrameOnly: false` no iOS; no Android as `allowedOrigins` dos UserScripts — [inappwebview.dev](https://inappwebview.dev/docs/webview/javascript/user-scripts)) e agregar mapas por `frameId`; ações dentro do frame certo.
- Último recurso: clique por **coordenadas absolutas** no retângulo do iframe (o toque passa para o browser).

### 5.3 Shadow DOM
- **Open**: `el.shadowRoot` acessível; `querySelector` normal **não** entra — recorrer manualmente: `walk(node) → node.shadowRoot ? walk(node.shadowRoot) : children` ([qaskills.sh](https://qaskills.sh/blog/playwright-iframe-shadow-dom-guide)).
- **Closed**: `shadowRoot` devolve `null`; inacessível a partir da página (mesmo o Playwright não penetra). Alternativas: atributos públicos do host, rede, ou clique pelas coordenadas do host ([virtuosoqa.com](https://www.virtuosoqa.com/post/automated-shadow-dom-testing), [yotam.net](https://yotam.net/posts/piercing-the-shadow-root-using-cdp)).
- Eventos atravessam fronteiras de shadow via `composed: true` — clicks sintéticos continuam a funcionar nos nós internos que se consigam obter.

### 5.4 Canvas / WebGL
- Sem DOM por definição: a única ação é clique/tecla **por coordenadas** (+ screenshot/Set-of-Marks para decidir onde) ([dev.to/askui](https://dev.to/askui/automating-webgl-canvas-based-website-oce)).

### 5.5 Injeção em Flutter/WebView
- **Android não garante ordem de `AT_DOCUMENT_START`**: sem `WebViewFeature.DOCUMENT_START_SCRIPT`, o script "entra o mais cedo possível", potencialmente depois de outros recursos ([inappwebview.dev](https://inappwebview.dev/docs/webview/javascript/user-scripts)) ⇒ defensivo: expor `window.__agent` como *lazy singleton* e o Dart chama `ping()` com retry antes de agir.
- `forMainFrameOnly` é **iOS only**; no Android a filtragem de frames usa `allowedOrigins` (padrões de origem próprios) — diferenças de comportamento entre plataformas a testar explicitamente.
- `evaluateJavascript` no Android devolve o valor como **string JSON** (muitas vezes `null` para `undefined`); tamanhos grandes de retorno podem truncar ⇒ fragmentar snapshots grandes ou usar `callHandler` (JS→Dart) para empurrar dados.
- O JS corre no mundo da página: a app-alvo pode detetar/neutralizar `window.__agent`; considerar Content World (iOS `WKContentWorld`, Android `WebViewCompat.addDocumentStartJavaScript` com world próprio) para isolar — mas atenção: nesse mundo não se veem os listeners da página.

### 5.6 Outras
- **React 17+** delega eventos na raiz: listeners sintéticos funcionam desde que os eventos burbulhem; mas o *controlled input* continua a exigir o native setter (§3.3).
- **Refs caducam**: qualquer re-render que substitua nós invalida refs ⇒ `refEpoch` + `STALE_REF` + re-snapshot obrigatório.
- **`form.submit()` não dispara validação nem o evento `submit`** — usar `requestSubmit()` (ou o botão).
- **Scroll em `<div>` roláveis**: `window.scrollBy` não basta; detetar o ancestral com `overflow: auto|scroll` e usar `el.scrollTop`/`scrollIntoView`.
- **Deteção de automação**: telemetria de eventos (`isTrusted`), `navigator.webdriver`, timing — em app própria isto não é problema de ToS, mas pode quebrar sites que rejeitam bots ([datadome.co](https://datadome.co/threat-research/how-new-headless-chrome-the-cdp-signal-are-impacting-bot-detection)).

---

## 6. Tamanhos de payload (referências medidas)

- Campo de formulário: **100+ linhas de HTML → "poucas linhas"** de accessibility snapshot ([arXiv 2511.19477](https://arxiv.org/html/2511.19477v1)).
- Playwright MCP: saída de texto estruturado "muito mais barata que dumps de DOM ou screenshots" e legível por qualquer LLM textual ([playwright.dev/mcp/introduction](https://playwright.dev/mcp/introduction)).
- Orçamentos recomendados para o nosso `SnapshotResult`: nós interativos ilimitados mas com ~1–2 linhas cada; texto principal cortado a ~20–40 KB com flag `truncated`; screenshot só quando há canvas ou o modelo for multimodal.

---

## 7. Fontes

1. Building Browser Agents: Architecture, Security… — https://arxiv.org/html/2511.19477v1
2. Playwright MCP · Introduction — https://playwright.dev/mcp/introduction
3. Playwright MCP · Snapshots (refs `[ref=e3]`) — https://playwright.dev/mcp/snapshots
4. WebArena: A Realistic Web Environment… (action space por IDs de elemento) — https://webarena.dev/static/paper.pdf
5. Web agent automation with BrowserGym (bid único em DOM/AXTree) — https://www.getmaxim.ai/blog/browsergym-web-agent-automation
6. Set-of-Mark Prompting… — https://arxiv.org/html/2310.11441v2 · https://github.com/microsoft/SoM
7. Midscene.js: assessing a natural language AI testing tool — https://nearform.com/digital-community/midscene-js-assessing-a-natural-language-ai-testing-tool
8. MDN · Event.isTrusted — https://developer.mozilla.org/en-US/docs/Web/API/Event/isTrusted
9. Ben Nadel · Exploring Event.isTrusted — https://www.bennadel.com/blog/4873-exploring-event-istrusted-in-javascript.htm
10. Why faking real browser events doesn't work — https://dev.to/ms_74/why-faking-real-browser-events-doesnt-work-4pp1
11. CDP · Input domain (dispatchMouseEvent) — https://chromedevtools.github.io/devtools-protocol/tot/Input/
12. Trigger Input Updates with React Controlled Inputs — https://coryrylan.com/blog/trigger-input-updates-with-react-controlled-inputs
13. Updating Input and Triggering onChange Programmatically in React — https://benjaminray.com/codebase/updating-input-and-triggering-onchange-event-in-react
14. MDN · Node.textContent (vs innerText) — https://developer.mozilla.org/en-US/docs/Web/API/Node/textContent
15. The poor, misunderstood innerText — https://perfectionkills.com/the-poor-misunderstood-innerText
16. flutter_inappwebview · Javascript User Scripts (AT_DOCUMENT_START, forMainFrameOnly, allowedOrigins) — https://inappwebview.dev/docs/webview/javascript/user-scripts
17. Pure JS to detect SPA DOM ready and page change — https://stackoverflow.com/questions/65325933/pure-javascript-to-detect-spa-dom-ready-and-page-change
18. Detect URL changes in SPA from injected script — https://gist.github.com/mohammedrahman-e2x/de230e8361ef11817c3a1ad7bf9d0ade
19. Navigation API — Baseline Newly Available — https://web.dev/blog/baseline-navigation-api
20. Intersection observer and infinite scroll in a visual way — https://www.lucaspaganini.com/academy/intersection-observer-and-infinite-scroll-in-a-visual-way
21. 3 ways to implement infinite scroll in React — https://blog.logrocket.com/react-infinite-scroll
22. Playwright iframe & Shadow DOM guide (closed shadow roots) — https://qaskills.sh/blog/playwright-iframe-shadow-dom-guide
23. Automated Shadow DOM Testing — https://www.virtuosoqa.com/post/automated-shadow-dom-testing
24. Piercing the Shadow Root Using CDP — https://yotam.net/posts/piercing-the-shadow-root-using-cdp
25. How to detect a click inside of a cross-domain iframe — https://stackoverflow.com/questions/29337304/how-to-detect-a-click-inside-of-an-iframe-cross-domain-aka-prevent-click-frau
26. Automating WebGL/Canvas-based Website — https://dev.to/askui/automating-webgl-canvas-based-website-oce
27. Programmatic select value — https://javascript.plainenglish.io/how-to-programmatically-set-the-value-of-a-select-element-using-javascript-f152fad36452
28. MDN · contenteditable — https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Global_attributes/contenteditable
29. The agent-readable web (simplified HTML / markdown para agents) — https://merj.com/blog/the-agent-readable-web-serving-the-right-representation-to-the-right-crawler
30. Accessibility Tree and AI Agents — https://www.webyes.com/blogs/accessibility-tree-ai-agents

---

## Síntese (≤400 palavras)

**Mapa da página.** Use representação híbrida: árvore semelhante à accessibility tree (roles, nomes, estados, valores) + refs estáveis + `rect` + texto principal limpo. É o padrão convergente do Playwright MCP (`[ref=e3]`), WebArena/BrowserGym (`bid`) e do survey "Building Browser Agents": um campo de HTML de 100+ linhas reduz-se a 2–3 linhas, e a camada de percepção fica desacoplada da camada de execução. Refs atribuídas no runtime (`data-xref`), com `refEpoch` para invalidação quando o DOM muda, e fallback de CSS path para refs caducadas.

**Contrato JS↔Dart.** Um namespace `window.__agent` injetado como UserScript `AT_DOCUMENT_START` com `snapshot(opts)`, `act(cmd)`, `read(opts)`, `state()`, `ping()`. Tudo JSON: `SnapshotResult` (docId, refEpoch, nodes[], text, truncated), `ActionCommand` (id, type, ref, value), `ActionResult` (ok, error{code}, effects{urlChanged, domChanged, newRefEpoch}). Dart→JS por `callAsyncJavaScript`, JS→Dart por `callHandler('agentBridge')`. Validação estrita de ref (`STALE_REF`), `docId` para não agir sobre a página errada, orçamentos de tamanho e timeouts.

**Ações.** Clique: `el.click()` e, quando preciso, sequência pointer/mouse events; formulários com `requestSubmit()` (nunca `submit()`). Inputs controlados: *native value setter* (`Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call`) + `input`/`change` — essencial em React; checkbox/radio com setter de `checked` + `click`; `select.value` + `change`; contenteditable com `execCommand('insertText')`. Scroll: `scrollIntoView` + scroll do ancestral rolável, `IntersectionObserver` para lazy-load, `MutationObserver` com debounce para estabilidade; orçamento de passos para infinite scroll. SPA: monkey-patch de `pushState`/`replaceState` + `popstate` + `hashchange` (Navigation API quando existir). Leitura: `innerText` para texto visível, heurísticas `main`/`article` tipo Readability para remover boilerplate.

**Armadilhas.** `isTrusted` é read-only e inforjável em JS — eventos sintéticos podem ser ignorados; contorna-se pelo estado do framework ou, em Android, por input nativo (WKWebView não tem equivalente). Cross-origin iframes: `contentDocument` nulo; injetar em todos os frames (`forMainFrameOnly:false` no iOS, `allowedOrigins` no Android). Shadow DOM closed é inacessível (só atributos do host/coordenadas); open exige walk recursivo. Canvas/WebGL só por coordenadas. Android não garante a ordem de `AT_DOCUMENT_START` (usar `ping()` com retry) e `evaluateJavascript` devolve strings JSON a decodificar.
