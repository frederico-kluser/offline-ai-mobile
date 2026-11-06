# Especificação partilhada: controlo do agente `anonymous-browser` (desktop ↔ mobile)

Contrato comum entre o projeto desktop [`anonymous-browser`](https://github.com/frederico-kluser/anonymous-browser)
(`agent/anonagent/`) e a app mobile [`apps/anonymous-browser`](../apps/anonymous-browser/)
(deste monorepo). Quando um lado mudar o contrato, este documento e o outro
lado acompanham. Fontes: `autopilot.py`, `llm.py`, `core.py`, `loopguard.py` do
desktop; dossiê [`pesquisas/2026-09-27-browser-embutido/frentes/00-arquitetura-anonymous-browser.md`](../pesquisas/2026-09-27-browser-embutido/frentes/00-arquitetura-anonymous-browser.md).

## 1. Vocabulário de decisão (conjunto fechado)

`CLICK · TYPE_TEXT · PRESS_ENTER · SCROLL_DOWN · SCROLL_UP · WAIT · SELECT ·
GO_BACK · DONE · BLOCKED` (mobile) — o desktop acrescenta `CHECK_EMAIL` e
`CLOSE_TAB`; `LOOK_AGAIN` não existe em nenhum (abstenção tratada em código).
O alvo vem SEMPRE por ref estável (`e1..eN`) — o modelo nunca escreve seletores.

## 2. Payload de decisão (`state`)

Chaves obrigatórias: `goal, step, url (scheme://host/path), title ≤160,
url_trail (≤8), decision_rules, variables (SÓ nomes/descrições — valores nunca),
outputs_wanted, outputs_status (veredito calculado em código), historico_curto,
progress_summary, last_change, user_guidance (≤4), already_tried_without_result,
page_text (untrusted(), ≤2500), text_partial, clickable, fields` + opcionais
`select_options, loopguard_hint, human_walls, memory_next_steps (untrusted)`.

Pools: `ref: role "nome" [ = valor]` — senhas sempre `•••`.

## 3. Perguntas tipadas

| id | tipo | papel |
|---|---|---|
| `operation` | choice | a operação entre as DISPONÍVEIS (só com pool) |
| `goal_done` | noul | ≥ `DONE_MIN 0.85` conclui (com evidência de saídas) |
| `stuck` | noul | > `0.85` → fallback de texto |
| `injection` | noul | ≥ `0.50` + padrão determinístico → breaker |
| `irreversible` | noul | > `0.6` → gate (com `goal_allows`) |
| `goal_allows` | noul | ≥ `0.7` autoriza (o objetivo é a autorização) |
| `*_target` | choice | alvo por ref + `none` (abstenção de alvo) |

Formato de resposta: `{qid: {choice, confidence, probabilities}}` / `{noul: p}`.
Bandas: `JEV_AUTO 0.60` (age sozinho) · `JEV_MIN 0.50` (abaixo = fallback) —
**recalibradas por modelo** (Laya ≠ Jev; os limiares nunca transferem).

## 4. Cascata

decisor tipado (Jev online `typesafe/jev-1.13` / Laya local) → modelo de texto
(MiMo `xiaomi/mimo-v2.6-pro` / MiniCPM5-2B local) → humano. O texto a digitar é
SEMPRE do modelo gerador com placeholders `{{email}}/{{password}}/{{code}}`
resolvidos pela camada de confiança — nunca valores inventados.

## 5. Gate (fora de banda)

`irreversible > 0.6` OU rótulo casa `DESTRUCTIVE`/`RISKY_LABEL` (não-link) →
confirmação humana; `goal_allows ≥ 0.7` passa sem gate ("o objetivo do
utilizador é a autorização"); **timeout = negado**; um resgate de texto nunca
autoriza a si próprio (`goal_allows = 0` + léxico recalcado).

## 6. Firewall de injeção

Texto de página é DADO (`untrusted()`); dois andares sem modelo: padrões de
INSTRUÇÃO DIRIGIDA (PT+EN no mobile; só EN no desktop — S5) + noul `injection`.
Hostil → nada executa, humano decide (ou `note` só com registo).

## 7. Escada e orçamentos

Repetição da assinatura `(op, alvo)`: 3 → modelo de texto · 5 → humano
(WAIT: 5/8); orçamento 2 por assinatura e 5 correções por run; orçamento por
TEMPO (`max_time`), nunca por passos.

## 8. Higiene

Segredos registados no scrubber e mascarados em tudo (tape, logs, pools,
extrações): formas crua/URL-encoded/JSON/HTML-escaped → `{{nome}}`; senhas
digitadas → `{{password_field}}`/`•••`; `STATE/accounts.jsonl`-equivalente
nunca é copiado nem ingerido.

## 9. Handoff humano

Nunca resolver CAPTCHA/muros; perguntas com ledger anti-repetição (qid =
sha1(kind|ctx|pergunta) + Jaccard ≥ 0.8); "✔ Terminei" tem de ser VERIFICADO
pelo estado da página (`done_check`), nunca pela palavra do humano; park/retoma
idempotente.

## 10. Auditoria

Cada decisão regista `{who, conf, op, target_id, reason, ok, effect}` + as
chamadas de LLM (request exato) no tape, mascarado. O tape é a memória de
qualquer análise posterior.
