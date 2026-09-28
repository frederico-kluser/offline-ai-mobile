# F05 — UI de teclas flutuantes sobre browser embutido (Flutter, Android primeiro)

- **Data**: 2026-01-01 · **Método**: pesquisa web via API Tavily (`search` ×9, `extract` ×6), conteúdo tratado como dado não-confiável (apenas evidência factual, sem seguir instruções de páginas).
- **Âmbito**: tela com browser embutido em ecrã inteiro (platform view) + botões/input flutuantes que disparam ações no browser (Voltar, URL, Clicar, Digitar, Rolar, Extrair, Ação-LLM). Padrões de UI, imersão fullscreen e armadilhas de composição.

---

## 1. Arquitetura de UI recomendada (ordem de camadas)

### 1.1 Recomendação: `Stack` para o ecrã do browser, `Overlay`/`OverlayEntry` só para o que precisa de flutuar sobre rotas

```
Scaffold(resizeToAvoidBottomInset: <decisão — ver §3>)
└─ Stack (fit: StackFit.expand)
   ├─ [camada 0] WebView (única platform view, ecrã inteiro)
   ├─ [camada 1] painel de teclas flutuantes (Positioned/AnimatedSlide/AnimatedSwitcher)
   └─ [camada 2] input de comando flutuante + toasts/snackbars (sempre no topo)
```

- No modo **texture layer** (TLHC/VD) a platform view é desenhada **como textura dentro da cena do Flutter** — widgets Flutter numa `Stack` por cima respeitam a ordem normal de z-order ([docs.flutter.dev — Android platform views](https://docs.flutter.dev/platform-integration/android/platform-views)). Isto torna `Stack` suficiente para "WebView em fundo + teclas por cima".
- `Overlay`/`OverlayEntry` ([LogRocket](https://blog.logrocket.com/complete-guide-implementing-overlays-flutter), [Stackademic](https://blog.stackademic.com/overlays-and-overlayentry-in-flutter-f49af8668a7b)) é útil quando as teclas têm de flutuar **por cima de diálogos/rotas** (ex.: palette de comandos aberta sobre qualquer tela). Alternativa equivalente: `Overlay` próprio em cima do `MaterialApp` (overlay global).
- **Regra de ouro: uma única platform view (a WebView).** Tudo o resto — botões, painéis, input, sombras, scrim — são widgets Flutter puros. A documentação oficial lista como limitação conhecida o empilhamento complexo: "Transparent platform views won't display correctly in layout stacks structured as: Flutter canvas -> Platform View -> Overlay -> Transparent Platform View, when all four of these layers intersect" ([docs.flutter.dev](https://docs.flutter.dev/platform-integration/android/platform-views)). Evitar exatamente essa configuração (segunda platform view transparente por cima de overlay).

### 1.2 Modo de composição Android (o que está por baixo das teclas)

| Modo | Como renderiza | Implicação para overlays |
| --- | --- | --- |
| **TLHC** (TextureLayerHybridComposition — predefinido via `PlatformViewsService.initSurfaceAndroidView`) | View nativa numa textura desenhada pelo Flutter | Overlays Flutter por cima com ordem normal de `Stack` |
| **VD** (Virtual Display, `initAndroidView`) | Pixels passam por buffers gráficos intermédios | Jank em updates de alta frequência (scroll rápido); overlays ok, mas custo de memória/desenho |
| **HC** (Hybrid Composition, `initExpensiveAndroidView`) | View real na hierarquia Android | Antes do Android 10 copiava cada frame GPU→RAM→GPU (custo por frame); a partir do Android 10 uma só cópia |
| **HCPP** (opt-in: meta-data `io.flutter.embedding.android.EnableHcpp`) | Sincronização nativa de transações | Requer Android API 34+ com Vulkan; menos overhead que HC; mantém a limitação de overlay stacking |

Fonte: [docs.flutter.dev — Android platform views](https://docs.flutter.dev/platform-integration/android/platform-views) e [KINTO Tech Blog](https://blog.kinto-technologies.com/posts/2024-12-17-flutter-platform-view-android-en) (confirma: `initSurfaceAndroidView`→TLHC/HC, `initAndroidView`→TLHC/VD, `initExpensiveAndroidView`→HC; se a view nativa contiver `SurfaceView` há fallback para VD ou HC).

## 2. Layout das teclas flutuantes

- **Barra/dock flutuante inferior** (input de comando + fila de teclas) com **handle de arrastar** para colapsar para um cluster compacto (tipo SpeedDial: [`flutter_speed_dial`](https://fluttergems.dev/floating-action-button), [`drag_speed_dial`](https://pub.dev/packages/drag_speed_dial) — FAB com drag-to-position + speed dial).
- **Alvos de toque**: Material 3 recomenda ≥ 48×48 dp (~9 mm; gama recomendada física 7–10 mm) ([Material 3 — structure](https://m3.material.io/foundations/designing/structure)); widgets Material do Flutter (`IconButton` etc.) impõem 48 pt mínimos por predefinição — violações vêm de `GestureDetector` custom sem área expandida ([Deque Axe DevTools Mobile](https://docs.deque.com/devtools-mobile/2025.7.2/en/ios-touch-target-size)). Apple HIG: controlo default 44×44 pt, mínimo 28×28 pt ([Apple HIG — Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)). Em ecrã inteiro com uma mão: colocar teclas primárias no **arco de alcance do polegar** e respeitar *safe zones* (notch, home indicator, cantos arredondados) ([Game-Ace — Effective game UI](https://game-ace.com/blog/effective-game-ui)).
- **Feedback háptico**: usar háptica como confirmação (ex.: `HapticFeedback.selectionClick`/`mediumImpact` ao disparar ações e ao colapsar/expandir o painel); a Apple recomenda háptica *para além* de cues áudio ([Apple HIG — Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)).
- **Input de comando tipo command palette** (padrão para Ação-LLM/URL/Clicar/Digitar): input sempre focado ao abrir, comandos recentes primeiro, fuzzy matching ("stpr" → "Set priority"), comandos desativados **cinzentos e no lugar** com motivo (esconder faz pensar que não existe), estado de erro/offline nunca bloqueia o overlay inteiro, animações de reflow limitadas a ~120 ms ([Setproduct — Command Palette UI Design](https://www.setproduct.com/blog/command-palette-ui-design-guide)). A mesma fonte documenta a convergência atual "palette = prompt de IA" (referências: Raycast AI, Notion AI, Cursor Cmd+K inline) — relevante para a tecla Ação-LLM: o input flutuante pode aceitar linguagem natural em vez de comandos aninhados.
- **Padrões de overlay sobre conteúdo "ao vivo"** (Steam/Discord): hotkey/gesto de toggle que mostra/esconde sem interromper o conteúdo; posição, transparência e atalhos configuráveis; janelas fixáveis (pin) ([Discord — Game Overlay 101](https://support.discord.com/hc/en-us/articles/217659737-Game-Overlay-101)). Transpor: gesto/tecla de toggle do painel, opacidade/posição persistidas, teclas fixáveis.

## 3. Fullscreen/imersão e teclado virtual

### 3.1 Imersão

- API principal: `SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky)` — barras escondidas, aparecem temporariamente com swipe e voltam a esconder; para mostrar só a status bar: `SystemUiMode.manual` com `overlays: [SystemUiOverlay.top]` + `SystemChrome.setSystemUIChangeCallback` para reagir quando o utilizador revela as barras ([SO #69804533](https://stackoverflow.com/questions/69804533/is-there-a-way-for-systemchrome-systemuimode-to-always-show-top-status-bar-but-h), [api.flutter.dev — setEnabledSystemUIMode](https://api.flutter.dev/flutter/services/SystemChrome/setEnabledSystemUIMode.html)).
- **Armadilha de target SDK**: com target Android SDK 15 (API 35) a app usa `SystemUiMode.edgeToEdge` por predefinição e os restantes modos **não funcionam sem migração**; com target SDK 16 (API 36+) o edge-to-edge é obrigatório — **não há opt-out** e os outros modos não funcionam ([api.flutter.dev](https://api.flutter.dev/flutter/services/SystemChrome/setEnabledSystemUIMode.html)). Conclusão prática: desenhar as teclas para edge-to-edge e usar `immersiveSticky` como *refinamento* (esconder barras), nunca depender dele para o layout.
- Bugs conhecidos ao alternar modos: status bar preta ao trocar immersive↔edgeToEdge ([flutter#95403](https://github.com/flutter/flutter/issues/95403)); flags de system UI têm de ser repostas nas transições ([flutter#187207](https://github.com/flutter/flutter/pull/187207)). Mitigação: reaplicar o modo no `WidgetsBindingObserver.didChangeAppLifecycleState` e evitar alternâncias frequentes.
- **SafeArea vs conteúdo sob a status bar**: em modo immersive a `SafeArea` colapsa quando as barras estão escondidas e "salta" quando o swipe as revela temporariamente; preferir `MediaQuery.padding`/`SafeArea` para o *conteúdo da página*, e posicionar as teclas com offsets próprios + `setSystemUIChangeCallback` para animar quando as barras aparecem. Em `immersiveSticky` o próprio WebView pode ficar sob a status bar — ok para a página, mas as teclas não devem ficar permanentemente sob ela.

### 3.2 Teclado virtual + WebView + input flutuante

- Predefinição Flutter/Android: `adjustResize` → o `FlutterView` (e a WebView dentro dele) é redimensionado quando o teclado abre; `Scaffold.resizeToAvoidBottomInset: true` + `MediaQuery.viewInsetsOf(context).bottom` empurram o input ([Fluttersensei — Flutter Keyboard Handling](https://fluttersensei.com/blog/flutter-keyboard-handling)).
- **Estratégia recomendada para o nosso caso**: manter a WebView com tamanho fixo e tratar o input flutuante como overlay — `resizeToAvoidBottomInset: false` + posicionar o input com `MediaQuery.viewInsets.bottom` (fica por cima do teclado sem redimensionar o browser). Cuidado com overflow e com a margem inferior em edge-to-edge.
- Problemas documentados: WebView que não redimensiona com o teclado em Android (`windowSoftInputMode`/adjustResize) ([Microsoft Q&A](https://learn.microsoft.com/en-us/answers/questions/5545630/soft-keyboard-overlaps-input-in-android-webview-bu), [flutter_webview_plugin#379](https://github.com/fluttercommunity/flutter_webview_plugin/issues/379)); bug de foco de input dentro do WebView no iOS 17.2 que deslocava a área ([flutter_inappwebview#1947](https://github.com/pichillilorenzo/flutter_inappwebview/issues/1947)). Testar inputs DENTRO da página (teclado da web) separadamente do input Flutter flutuante. Pacote de apoio: [`keyboard_safe`](https://pub.dev/packages/keyboard_safe).

## 4. Armadilhas de platform views (2025-2026)

1. **Z-order/overlays**: limitação oficial de "complex overlay stacking" (ver §1.1) — nunca ter `Flutter canvas → Platform View → Overlay → Transparent Platform View` com as 4 camadas a intersectar-se ([docs.flutter.dev](https://docs.flutter.dev/platform-integration/android/platform-views)).
2. **Clip/Opacity/Transform**: em Android (VD/HC) a platform view "não respeita widgets Flutter como Clip, Opacity, Transform"; FPS mais baixo; pode interferir com gestos ([Medium — chuvak-pavel](https://chuvak-pavel.medium.com/integrating-platformview-into-flutter-android-158f7ae9c0d2), evidência ao nível do excerto). No iOS aplica-se o contrário: aceita transforms/clips/opacity via Dart ([docs.flutter.dev — iOS platform views](https://docs.flutter.dev/platform-integration/ios/platform-views)). → Sombra/blur/scrim das teclas devem ser widgets Flutter **irmãos** da WebView, nunca envolvidos à volta dela.
3. **Performance**: VD acrescenta buffers intermédios (jank em scroll rápido); HC pré-Android 10 copiava frames por inteiro; HCPP exige API 34+ + Vulkan ([docs.flutter.dev](https://docs.flutter.dev/platform-integration/android/platform-views)). A presença de `SurfaceView` na view nativa força fallback de modo ([KINTO](https://blog.kinto-technologies.com/posts/2024-12-17-flutter-platform-view-android-en)) — validar em runtime em dispositivos reais.
4. **Gestos**: conflitos documentados: scroll do Flutter que passa para a WebView ([flutter#171697](https://github.com/flutter/flutter/issues/171697)), scroll da WebView que deixa de funcionar após diálogo ([flutter#101626](https://github.com/flutter/flutter/issues/101626)), platform view no iOS 26 que deixa de receber toques após a primeira interação ([flutter#191267](https://github.com/flutter/flutter/issues/191267)), conflito scale vs pan ([flutter#13101](https://github.com/flutter/flutter/issues/13101)). → Não colocar gestos globais do Flutter (pan na página) por cima da WebView; as ações "Rolar/Clicar/Digitar" devem ser **programáticas** (avaliar JS/injeção), não gestos sintéticos por cima da view.
5. **Manual view invalidation** (documentação Android): em certos modos a view nativa precisa de invalidação manual para repintar — sintoma típico: conteúdo da WebView "congelado" após overlays Flutter por cima ([docs.flutter.dev](https://docs.flutter.dev/platform-integration/android/platform-views)).

## 5. Gestos vs botões: arrastar, snap e persistência

- Arrastar só pelo **handle** com `LongPressDraggable` (não rouba toques normais; o `Draggable` simples pode capturar taps que eram para a WebView) — [docs.flutter.dev cookbook — Drag a UI element](https://docs.flutter.dev/cookbook/effects/drag-a-widget), [LogRocket — Draggable/DragTarget](https://blog.logrocket.com/drag-and-drop-ui-elements-in-flutter-with-draggable-and-dragtarget).
- **Snap a bordas** no fim do drag (alinhamentos predefinidos com preview nos alvos) e **persistência de posição** via storage plugável (ex.: `SharedPreferences`): padrão já embalado em [`snap_floater`](https://pub.dev/packages/snap_floater) (snap a alinhamentos predefinidos, show/hide programático, auto-hide durante ações assíncronas, aware de safe area/padding de bordas, persistência entre arranques). Referência alternativa: [`drag_speed_dial`](https://pub.dev/packages/drag_speed_dial).
- Recomendação de UX: toque = ação imediata (não arrastar); long-press ou handle dedicado = reposicionar; vibração háptica no snap; posição guardada por orientação (retrato/paisagem têm layouts distintos — [Game-Ace](https://game-ace.com/blog/effective-game-ui)).

## 6. Resumo de decisões de UI

| Decisão | Padrão | Fonte |
| --- | --- | --- |
| Ordem de camadas | `Stack`: WebView (única platform view) → teclas → input/toasts | docs.flutter.dev platform-views |
| Overlay global | `OverlayEntry` só para conteúdo sobre rotas/diálogos | LogRocket / Stackademic |
| Teclas | dock inferior colapsável + SpeedDial; ≥48 dp; háptica | Material 3, Deque, Apple HIG |
| Input | command palette com fuzzy, recentes, desativados visíveis, erros não bloqueiam | Setproduct |
| Imersão | edge-to-edge como base + `immersiveSticky`; `setSystemUIChangeCallback` | api.flutter.dev, SO |
| Teclado | `resizeToAvoidBottomInset:false` + `MediaQuery.viewInsets` para input flutuante | Fluttersensei, Microsoft Q&A |
| Drag | `LongPressDraggable` por handle + snap a bordas + persistir posição | docs.flutter.dev, snap_floater |

## Fontes

- https://docs.flutter.dev/platform-integration/android/platform-views
- https://docs.flutter.dev/platform-integration/ios/platform-views
- https://api.flutter.dev/flutter/services/SystemChrome/setEnabledSystemUIMode.html
- https://github.com/flutter/flutter/pull/187207 · https://github.com/flutter/flutter/issues/95403 · https://github.com/flutter/flutter/issues/164428
- https://stackoverflow.com/questions/69804533/is-there-a-way-for-systemchrome-systemuimode-to-always-show-top-status-bar-but-h
- https://blog.kinto-technologies.com/posts/2024-12-17-flutter-platform-view-android-en
- https://chuvak-pavel.medium.com/integrating-platformview-into-flutter-android-158f7ae9c0d2
- https://blog.logrocket.com/complete-guide-implementing-overlays-flutter · https://blog.stackademic.com/overlays-and-overlayentry-in-flutter-f49af8668a7b
- https://github.com/flutter/flutter/issues/171697 · /issues/101626 · /issues/191267 · /issues/13101
- https://fluttersensei.com/blog/flutter-keyboard-handling · https://learn.microsoft.com/en-us/answers/questions/5545630/soft-keyboard-overlaps-input-in-android-webview-bu · https://github.com/fluttercommunity/flutter_webview_plugin/issues/379 · https://github.com/pichillilorenzo/flutter_inappwebview/issues/1947 · https://pub.dev/packages/keyboard_safe
- https://m3.material.io/foundations/designing/structure · https://docs.deque.com/devtools-mobile/2025.7.2/en/ios-touch-target-size · https://developer.apple.com/design/human-interface-guidelines/accessibility
- https://game-ace.com/blog/effective-game-ui · https://support.discord.com/hc/en-us/articles/217659737-Game-Overlay-101 · https://www.setproduct.com/blog/command-palette-ui-design-guide
- https://docs.flutter.dev/cookbook/effects/drag-a-widget · https://blog.logrocket.com/drag-and-drop-ui-elements-in-flutter-with-draggable-and-dragtarget · https://pub.dev/packages/snap_floater · https://pub.dev/packages/drag_speed_dial · https://fluttergems.dev/floating-action-button

---

## Síntese final (≤400 palavras)

**Arquitetura**: use um `Stack` com a WebView como **única platform view** (camada 0) e todas as teclas/input como widgets Flutter puros por cima (camadas 1-2). No modo texture layer (TLHC, predefinido) a WebView é uma textura dentro da cena do Flutter, portanto a ordem do `Stack` funciona como qualquer widget. Reserve `Overlay`/`OverlayEntry` para o que tem de flutuar sobre rotas/diálogos (ex.: palette de comandos). Evite rigorosamente o padrão documentado como partido — "Flutter canvas → Platform View → Overlay → Transparent Platform View" —, ou seja, nunca uma segunda platform view transparente acima do overlay.

**Teclas**: dock inferior flutuante (input de comando + fila de teclas: Voltar, URL, Clicar, Digitar, Rolar, Extrair, Ação-LLM) com handle de arrastar que colapsa para um SpeedDial. Alvos ≥48×48 dp (Material 3; widgets Material já cumprem, `GestureDetector` custom não), posição no arco do polegar, feedback háptico ao disparar. Input tipo command palette: foco mantido, recentes primeiro, fuzzy matching, comandos desativados visíveis com motivo, erros nunca bloqueiam o overlay — e pronto para linguagem natural (padrão "AI palette" de Raycast/Cursor/Notion).

**Imersão**: desenhe para edge-to-edge (obrigatório em target API 36, sem opt-out) e use `SystemUiMode.immersiveSticky` como refinamento; reaja a `setSystemUIChangeCallback` para animar as teclas quando o swipe revela as barras; reaplicar o modo no ciclo de vida (há bugs de status bar preta ao alternar modos). SafeArea para a página; offsets próprios para as teclas.

**Teclado**: predefinição `adjustResize` redimensiona WebView + layout; para o input flutuante, prefira `resizeToAvoidBottomInset: false` + `MediaQuery.viewInsets.bottom` (input por cima do teclado, browser estável). Testar à parte inputs dentro da página.

**Armadilhas platform views**: Clip/Opacity/Transform não aplicáveis à view nativa em Android (VD/HC) — sombras/scrim são widgets irmãos; VD janky em scroll rápido; HCPP (API 34+/Vulkan) melhora HC; `SurfaceView` nativa força fallback de modo; gestos Flutter por cima da WebView conflitam (issues #171697/#101626/#191267) — ações "Clicar/Digitar/Rolar" programáticas, não gestos sintéticos.

**Drag**: `LongPressDraggable` só pelo handle (não roubar taps da WebView), snap a bordas no release, posição persistida por orientação (padrão `snap_floater`).
