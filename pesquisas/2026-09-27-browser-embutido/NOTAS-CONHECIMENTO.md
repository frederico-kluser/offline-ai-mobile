# Browser embutido + teclas flutuantes — notas de conhecimento (2026-09-27)

> **Pedido**: analisar profundamente como rodar um browser dentro do app e
> controlar as ações pelo **Laya** e pela **LLM**, como no projeto
> `anonymous-browser`; browser em tela inteira com botões/input como teclas
> flutuantes que mandam ações; teste simples; sem emulador; testar no macmini.
>
> **Método**: 6 frentes de estudo em paralelo (5 pesquisas web via Tavily +
> 1 estudo do código do `anonymous-browser`) — relatórios completos em
> [`frentes/`](frentes/). Este ficheiro consolida decisões e o que foi
> implementado.

---

## 1. Decisões (com a frente que as fundamentou)

| # | Decisão | Fundamento |
| --- | --- | --- |
| D1 | Motor: **`flutter_inappwebview` 6.x** escondido atrás do nosso `BrowserController` (plano B: `webview_flutter` 4.x — troca só `webview_browser_controller.dart`) | `frentes/01`: único com UserScript `AT_DOCUMENT_START` + bridge tipada + popups; ⚠️ estável parado há 2 anos → abstração é obrigatória |
| D2 | Via de controlo: **JS injection dentro da WebView** (CDP/adb só para dev/teste; acessibilidade NUNCA como produto — política Play Store) | `frentes/02` |
| D3 | Arquitetura em cascata: **perceção determinística → Laya (System One tipado) → MiniCPM5-2B (System Two, tool calling) → humano**; estado/retries/políticas vivem em código | `frentes/03`, espelha `anonymous-browser` (`frentes/00`) |
| D4 | Estado da página = **snapshot compacto** (refs estáveis `e1..eN` + roles + nomes acessíveis + texto ≤4k), NUNCA DOM cru nem screenshots | `frentes/03/04`; payload: 100+ linhas HTML → 2–3 linhas |
| D5 | Refs com **`docId` + `refEpoch`** (MutationObserver): ações de outro documento → `stale-doc`; DOM mudado → aviso `stale-ref` | `frentes/04` — "o que impede ações sobre DOMs desatualizados" |
| D6 | UI: `Stack` com a WebView como **única platform view** (camada 0, texture layer) + teclas/input em widgets Flutter puros por cima; `immersiveSticky` + `resizeToAvoidBottomInset: false` | `frentes/05` |
| D7 | Gate de segurança do piloto (igual ao `gate.py`): **prompt injection** e **ações irreversíveis não autorizadas** → handoff humano, nunca execução | `frentes/00` (autopilot.py, gate.py) |
| D8 | Senhas **nunca** saem em claro do snapshot (`•••`) | `frentes/00` (contrato do `view.js`) |
| D9 | Vocabulário de ações **fechado e tipado** (13 ações); `eval` (JS arbitrário) existe MAS só para o humano; modelo nunca escreve seletores | `frentes/00/03` (AgentOccam: subtrair ações melhora resultados) |

## 2. O que foi implementado (`lib/src/browser/`, `lib/src/ui/browser_*`)

```
teclas flutuantes (humano) ─┐
piloto Laya (choice tipado) ─┼─→ BrowserAction ─→ BrowserController ─→ ponte JS (window.__oai) ─→ página
agente MiniCPM5-2B (tools) ─┘
```

- **`browser_action.dart`** — vocabulário fechado: `navigate, back, forward,
  reload, tap(ref), tap_at(x,y), type(ref,text,submit), scroll(dx,dy),
  select(ref,value), snapshot, extract, eval, stop`; JSON com `kind` estável +
  `canonicalKey` para deteção de ciclos (como o `LoopGuard` do app).
- **`browser_page_state.dart`** — `PageSnapshot`/`PageElement` com refs,
  `docId`/`refEpoch`, `toCompactText()` para prompts (600–900 tokens).
- **`browser_bridge_js.dart`** — ponte `window.__oai.{ping,snapshot,act}`:
  refs lazy `data-oai-ref`, MutationObserver→`refEpoch`, clique
  pointerdown→click + `el.click()`, **native value setter** + `input`/`change`
  (React/Vue/Angular), `requestSubmit()`, `elementFromPoint` para `tap_at`,
  passwords `•••`, erros explícitos (`ref-not-found`, `stale-doc`,
  `not-editable`, …).
- **`webview_browser_controller.dart`** — implementação sobre
  `flutter_inappwebview`: UserScript em `AT_DOCUMENT_START` **e reinjeção em
  `onLoadStop`** (Android antigo não garante a primeira), normalização do
  retorno JS (Android devolve strings JSON codificadas), timeout 8s por ação,
  orçamento de payload 200KB, navegação nativa para `navigate/back/forward`.
- **`browser_pilot.dart`** — o "Jev" local: gera candidatos CONCRETOS do
  snapshot (o modelo só escolhe chaves fechadas — nunca inventa refs), pedido
  `LayaRequest` com 6 perguntas tipadas (`next_action` + `goal`, `stuck`,
  `injection`, `irreversible`, `goal_allows`) e bandas de confiança:
  **≥0.8 `act` · 0.5–0.8 `escalate` (LLM) · <0.5 `abstain` (humano)** +
  gates D7. ⚠️ Limiares configuráveis: os do Jev não transferem para o Laya.
- **`browser_tools.dart`** — 7 tools `browser_*` para o `ToolLoop`
  (`snapshot/goto/click/type/select/scroll/extract`) + system prompt do
  agente-browser (observar → agir → observar, 1 ação de cada vez).
- **`browser_page.dart`** — página fullscreen (immersiveSticky) com as
  **teclas flutuantes**: ↩ ↪ ⟳ · 🔗 URL · ⌨ Digitar · 📄 Mapa (lista de
  elementos, tocar = clicar) · ↓ ↑ · 🧭 Piloto · 🤖 Agente · 🎯 Objetivo —
  input flutuante único com modos (url/type/click/goal), log flutuante,
  dock colapsável/arrastável (só pelo handle), alvos ≥48dp.
- **`browser_tab.dart`** — 5.º destino da NavigationBar com o cartão-resumo.
- **`test/browser_test.dart`** — 20 testes: round-trip do vocabulário,
  snapshot/refs, contrato da ponte, bandas + gates do piloto, contrato das
  tools (com `FakeBrowser`).

## 3. Como se testa (macmini, sem emulador)

```bash
ssh macmini 'cd /Volumes/Ext2TB/Projects/offline-ai-mobile && git pull'
ssh macmini 'cd /Volumes/Ext2TB/Projects/offline-ai-mobile && zsh -l -c "flutter pub get && flutter analyze && flutter test"'
ssh macmini 'cd /Volumes/Ext2TB/Projects/offline-ai-mobile && zsh -l -c "flutter build ios --simulator"   # compilação iOS'
```

No device real (iPhone): `flutter run` / `./instalar-iphone.sh` — o teste
manual da feature é: aba **Browser** → **Abrir browser** → usar as teclas.

## 4. Limites conhecidos (honestos, do teste simples)

1. **`isTrusted: false`** — eventos sintéticos JS podem ser ignorados por
   páginas com anti-bot; contorna-se com native setters, mas drag&drop e
   atalhos não funcionam. Fallback real: CDP/adb (só dev) ou humano.
2. **iframes cross-origin, shadow DOM fechado, canvas/WebGL** não são
   acionáveis (reportados como erro explícito).
3. **Performance**: WebView + inferência local no mesmo processo compete por
   CPU/RAM (o pedido assumiu: qualidade > performance).
4. **`AT_DOCUMENT_START` sem garantia em Android antigo** → mitigado com
   reinjeção em `onLoadStop` + `ping()`; se a ponte faltar, as ações devolvem
   `bridge-missing` com instrução de recarregar.
5. **Teclado**: `resizeToAvoidBottomInset: false` mantém o browser estável;
   inputs DENTRO da página podem ficar cobertos pelo teclado (testar no
   device; "modo input" sai do immersive é follow-up).
6. **Manutenção do `flutter_inappwebview`** (estável parado) — daí a
   abstração `BrowserController`; a migração para `webview_flutter` mexe em
   1 ficheiro.

## 5. Follow-ups (não feitos de propósito — teste simples)

- [ ] Confirmar no device: AT_DOCUMENT_START, teclado+immersive, toques nas
      teclas por cima da WebView (TLHC vs virtual display).
- [ ] `hover`/`wait` no vocabulário (agentes web usam; MVP deliberou fora).
- [ ] Handoff humano verificado por `done_check` (o `anonymous-browser` exige
      confirmação do ESTADO da página, não a palavra do humano).
- [ ] Persistência da run (park/retomada — mobile agrava: OS mata processos).
- [ ] Escada de repetição do LoopGuard → humano (hoje: corte + fallback).
- [ ] Set-of-Marks (screenshot + marcas) quando houver VLM.
- [ ] Harness Playwright+adb para golden tests do browser em dev (frente 02).

## 6. Mapa para o `anonymous-browser` (o que se copiou / deixou)

| Conceito (`frentes/00`) | Aqui |
| --- | --- |
| Vocabulários fechados de decisão/execução/receita | `BrowserAction` (13 kinds) + tools `browser_*` |
| "Vista limpa" (`view.js`, contract) | ponte `window.__oai.snapshot()` (refs, roles, nomes, texto podado, senha `•••`) |
| Payload Jev: state + questions tipadas | `LayaRequest` (state prosa + 6 `choice`) — contrato `POST /v1/systemone` do doc Laya |
| Bandas conf<0.55/done≥0.85… | bandas `autoThreshold/escalateThreshold` configuráveis (Laya ≠ Jev) |
| Cascata Jev→MiMo→humano | Laya→MiniCPM5-2B→teclas (handoff) |
| `gate.py` (irreversível/injeção) | gates `injection`/`irreversible`+`goal_allows` no piloto |
| LoopGuard + escada de repetição | `LoopGuard` existente do app (max steps, ciclos, SER@4) |
| Endereçamento por nó (WeakMap), nunca seletores | refs `data-oai-ref` + `docId`/`refEpoch` |
| Tor/fingerprint/Camoufox/Playwright/mail/multi-abas | **não se aplica** (mobile, app próprio) |

## 7. Fontes

- Frentes (com URLs de todas as fontes): [`frentes/00`](frentes/00-arquitetura-anonymous-browser.md),
  [`01`](frentes/01-webviews-flutter.md), [`02`](frentes/02-cdp-e-controlo.md),
  [`03`](frentes/03-agentes-llm-browser.md), [`04`](frentes/04-camada-js-acoes.md),
  [`05`](frentes/05-ui-teclas-flutuantes.md).
- Projeto de referência: `/home/ondokai/Projects/anonymous-browser` (estudo em `frentes/00`).
- Código: `lib/src/browser/*`, `lib/src/ui/browser_tab.dart`,
  `lib/src/ui/browser_page.dart`, `test/browser_test.dart`.