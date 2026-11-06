/// ab_core — núcleo partilhado do monorepo `offline-ai-mobile`.
///
/// Domínio (decisões tipadas, config determinística, registos), motores
/// (llama.cpp FFI do MiniCPM5-2B e ONNX Runtime do Laya), tokenizador WordPiece,
/// agente (chat template MiniCPM5, tool loop, ferramentas), guardrails
/// determinísticas ([LoopGuard]) e serviços (catálogo/download de modelos,
/// store persistente).
///
/// Partilhado pela app de exemplo (`offline_ai_mobile`, na raiz) e pela app
/// `anonymous_browser_mobile` (`apps/anonymous-browser`).
library;

export 'src/agent/minicpm5_chat.dart';
export 'src/agent/tool_loop.dart';
export 'src/agent/tools.dart';
export 'src/domain/laya_types.dart';
export 'src/domain/llm_config.dart';
export 'src/domain/run_record.dart';
export 'src/domain/templates.dart';
export 'src/domain/tool_spec.dart';
export 'src/engines/laya_engine.dart';
export 'src/engines/laya_engine_onnx.dart';
export 'src/engines/llm_engine.dart';
export 'src/engines/llm_engine_llama.dart';
export 'src/guardrails/loop_guard.dart';
export 'src/laya/wordpiece_tokenizer.dart';
export 'src/services/app_services.dart';
export 'src/services/download_manager.dart';
export 'src/services/model_registry.dart';
export 'src/services/store.dart';
