/// ab_browser — camada de browser partilhada do monorepo `offline-ai-mobile`.
///
/// Vocabulário fechado de ações ([BrowserAction], 13 kinds), snapshot compacto
/// da página ([PageSnapshot] com refs estáveis `e1..eN` + `docId`/`refEpoch`),
/// ponte JS `window.__oai` (bridge), controlador abstrato + implementação
/// `flutter_inappwebview`, piloto Laya ([BrowserPilot], o "System One" tipado)
/// e ferramentas `browser_*` para o tool loop.
library;

export 'src/browser_action.dart';
export 'src/browser_bridge_js.dart';
export 'src/browser_controller.dart';
export 'src/browser_page_state.dart';
export 'src/browser_pilot.dart';
export 'src/browser_tools.dart';
export 'src/webview_browser_controller.dart';
