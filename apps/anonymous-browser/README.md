# anonymous-browser mobile (`anonymous_browser_mobile`)

**Segunda versão do projeto desktop [`anonymous-browser`](https://github.com/frederico-kluser/anonymous-browser)**,
como app mobile, construída sobre as tecnologias do monorepo `offline-ai-mobile`
(Flutter, Laya typed-decisions, MiniCPM5-2B, WebView embutida).

Filosofia herdada do desktop: **decisão é classificação tipada barata, texto é
geração cara, e nada destrutivo acontece sem o humano.**

## O que é

Um navegador com agente: o utilizador escreve um **objetivo** (missão) e a app
navega sozinha — com decisor tipado, modelo de texto, guardrails determinísticas
e gate humano. Corre com **IA online** (Jev + MiMo, OpenRouter) e **IA local no
telemóvel** (Laya ONNX + MiniCPM5-2B GGUF), selecionável por missão.

```
observar (snapshot refs e1..eN) → guardas (muro/injeção) → decidir (cascata)
   → gate (irreversível) → escada de repetição → atuar → tape → repete
```

## Cascata de decisão (port de `autopilot.py`)

| Nível | Online | Local (no telemóvel) |
|---|---|---|
| Decisor tipado ("System One") | Jev `typesafe/jev-1.13` (endpoint Decisions do OpenRouter) | Laya typed-decisions (ONNX, ab_core) |
| Modelo de texto ("System Two") | MiMo `xiaomi/mimo-v2.6-pro` | MiniCPM5-2B (GGUF via llama.cpp, ab_core) |
| Humano | gate nativo (fora de banda, **timeout = negado**), perguntas, handoff verificado | igual |

Bandas por omissão: `auto ≥ 0.60` age · `]0.50, 0.60[` cede ao texto · `< 0.50`
escala · `goal_done ≥ 0.85` conclui — **recalibráveis** nas definições (os
limiares do Jev não transferem para o Laya).

## O que foi portado do desktop (e onde)

| Conceito (desktop `anonymous-browser`) | Aqui |
|---|---|
| `autopilot.OPS` (vocabulário fechado de operações) | `lib/src/domain/ops.dart` (10 ops: sem `CLOSE_TAB`/`CHECK_EMAIL`) |
| `Autopilot.state()` + `ask_jev()` (payload tipado) | `lib/src/domain/decision_payload.dart` |
| `llm.jev()` / `llm.chat_json` (OpenRouter) | `lib/src/backends/jev_online.dart`, `mimo_online.dart` |
| `llm.py` KEY_FILE (`openrouter.env` 0600) | `lib/src/key_vault.dart` — cofre cifrado (Keychain iOS / Keystore AES-GCM Android) + **validação** em `GET /api/v1/key` antes de persistir |
| `llm.clm_local()` (decisor local, contrato idêntico) | `lib/src/backends/laya_decision_backend.dart` |
| `untrusted()` + `INJECT_PATTERNS` (firewall) | `lib/src/autopilot/untrusted.dart` — **PT+EN** (desktop só EN) |
| `core.DESTRUCTIVE`/`RISKY_LABEL`/`BLOCK_RX` | `lib/src/autopilot/risk_lexicon.dart` |
| `gate.py` / `Autopilot.gated()` | `lib/src/autopilot/gate.dart` + diálogo nativo em `run_page.dart` |
| Escada de repetição 3/5 (WAIT 5/8) + orçamentos | `lib/src/autopilot/ladder.dart` |
| Ledger anti-repetição de perguntas (qid + Jaccard) | `lib/src/autopilot/question_ledger.dart` |
| `scrubber` de segredos + `{{var}}` (camada de confiança) | `lib/src/autopilot/masking.dart` |
| `tape.jsonl` mascarado | `lib/src/domain/tape.dart` |
| `park`/`--continue` (retoma) | `lib/src/park.dart` |
| `view.js` (vista limpa, refs estáveis) | ponte `window.__oai` do `packages/ab_browser` (snapshot + `docId`/`refEpoch`) |
| LoopGuard do desktop | `packages/ab_core` (`LoopGuard`) + escada própria |

**Regras absolutas mantidas:** o agente nunca resolve CAPTCHA/muros (handoff
humano); texto de página é DADO embrulhado em `untrusted()`; segredos nunca
saem em claro (tape/log/pools mascarados; senhas `•••`); ação irreversível sem
autorização do objetivo passa sempre pelo humano.

## Estrutura

```
lib/src/domain/      ops · mission (spec+run state) · decision_payload · tape
lib/src/backends/    decision_backend · jev_online · laya_local · text_backend · mimo · minicpm
lib/src/autopilot/   autopilot (loop) · gate · ladder · masking · untrusted · risk_lexicon · question_ledger
lib/src/             settings · park
lib/src/ui/          home (missões) · run (browser+gate+handoff) · settings
test/                masking · injection+gate · payload · escada+ledger · cascata (fakes)
```

Partilhado (monorepo): `packages/ab_core` (motores Laya/MiniCPM, agente,
guardrails, serviços, `AppServices`) e `packages/ab_browser` (vocabulário de
ações, snapshot, ponte JS, controlador WebView, piloto).

## Testar (sempre no macmini)

```bash
ssh macmini 'zsh -c "export PATH=/Volumes/Ext2TB/dev-tools/flutter/bin:\$PATH && \
  cd /Volumes/Ext2TB/Projects/offline-ai-mobile.worktrees/anonimous-browser-mobile && \
  flutter pub get && flutter analyze && flutter test && \
  cd apps/anonymous-browser && flutter pub get && flutter analyze && flutter test"'
```

## Modelos locais

Laya (kit ONNX fp32) e MiniCPM5-2B (GGUF Q8_0) seguem o catálogo do `ab_core`
(`kModelCatalog`) — descarregar na app de exemplo (aba **Modelos**), com
verificação sha256. Sem modelos instalados, os modos locais falham com mensagem
clara e a missão pode correr em modo online.

## Pendências (v1)

- [ ] Descarregamento de modelos dentro desta app (hoje: app de exemplo).
- [ ] `SELECT` com valor escolhido pelo decisor (hoje: literais do objetivo).
- [ ] Extração de saídas pelo modelo de texto (hoje: regex local).
- [ ] Persistência do tape em ficheiro JSONL (hoje: em memória + park do estado).
- [ ] Handoff com `done_check` rico (hoje: deteção de mudança de página).
