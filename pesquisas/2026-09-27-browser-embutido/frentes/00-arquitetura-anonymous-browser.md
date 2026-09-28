# 00 — Arquitetura de controlo do `anonymous-browser` (estudo para replicação em Flutter + WebView)

> Estudo do projeto local `/home/ondokai/Projects/anonymous-browser/` (sem web). Objetivo: extrair a
> **arquitetura de controlo** (vocabulário de ações, estado da página, payload de decisão, loop de decisão,
> execução no browser, guardrails e handoff humano) para a replicarmos numa app Flutter com browser embutido
> (WebView) e um LLM local 2.5B + decisor rápido local. Todas as citações são `ficheiro:linha` do repo de origem.
>
> Arquitetura em 4 camadas:
>
> ```
> ┌────────────────────────────────────────────────────────────────────────┐
> │ autopilot.py  — decisão por passo: Jev (tipado) → MiMo (texto) → humano│
> │   observa (view) → decide (state+questions) → act → regista (tape)     │
> ├────────────────────────────────────────────────────────────────────────┤
> │ llm.py        — contratos de modelo: jev(state,questions) | chat_json  │
> │                 | chat_vision | clm_local (decisor local, drop-in)     │
> ├────────────────────────────────────────────────────────────────────────┤
> │ daemon.py ("foxd") + client.py — socket AF_UNIX JSON-lines, token 0600 │
> │   commands: goto/act/view/snapshot/ask/human/record/tape/…             │
> ├────────────────────────────────────────────────────────────────────────┤
> │ core.py + view.js — motor de ações/replay (seletores+fingerprint) e    │
> │   "vista limpa" da página │ botwall.py (muros→handoff) │ gate.py │      │
> │   loopguard.py (guarda determinística) │ watchdog.py (página travada)  │
> └────────────────────────────────────────────────────────────────────────┘
> ```
>
> Nota: existem **três vocabulários de ações** empilhados (decisão / fio do daemon / receita-replay) — ver §1.

---

## 1. Vocabulário de ações

### 1.1 Nível de decisão — operações que o decisor escolhe (`autopilot.py`)

Conjunto fixo `OPS` em `agent/anonagent/autopilot.py:35-51` (14 operações, cada uma com a sua descrição que vai
para o modelo como `criteria`):

| Operação | Significado (parâmetro que carrega) | Execução |
|---|---|---|
| `CLICK` | clicar num elemento da lista (`ref` obrigatório) | daemon `act op=click node=<nó>` |
| `TYPE_TEXT` | digitar num campo (`ref` + `text` gerado pelo MiMo) | daemon `act op=fill` com `value` |
| `PRESS_ENTER` | Enter no campo acabado de preencher (sem botão submit visível) | daemon `act op=press value=Enter` |
| `SCROLL_DOWN` / `SCROLL_UP` | rolar (elemento provavelmente abaixo/acima) | daemon `act op=press value=PageDown/PageUp` |
| `WAIT` | página a carregar/redirect/verificação a correr | `time.sleep(3.0)` local (`autopilot.py:898-899`) |
| `SELECT` | escolher opção de `<select>` (`ref` + opção) | daemon `act op=select` com label da opção |
| `CHECK_EMAIL` | abrir caixa descartável (verificação por e-mail) | `check_email()` (`autopilot.py:905-953`) |
| `DONE` | objetivo cumprido na página | extrai saídas + confirmação visual |
| `BLOCKED` | nenhuma ação avança (precisa de humano) | vision rescue → pergunta ao humano |
| `LOOK_AGAIN` | informação insuficiente para decidir em segurança | **abstenção**: nunca é executada (`decide()` trata como fallback, `autopilot.py:761-762`) |
| `GO_BACK` | voltar no histórico (navegação para parte errada do site) | daemon `act op=back` (`autopilot.py:891-892`) |
| `CLOSE_TAB` | fechar a aba atual (aberta por engano) | daemon `act op=close-tab` (`autopilot.py:893-894`) |

O mapeamento decisão→fio está em `Autopilot.act()` (`autopilot.py:841-903`) e `_node_req()`
(`autopilot.py:838-839`): todo pedido é `{'cmd':'act','op':…,'node':…,'role','label','why'[:300], 'value', …}`.
Detalhes notáveis:

- **Fallback de clique**: clique com timeout (CSS mal carregado/sobreposição) é refeito por teclado —
  `Enter`, ou `Space` em checkbox/radio/switch (`autopilot.py:849-856`).
- **Texto a digitar nunca vem do decisor tipado**: se `d['text']` vier vazio, o MiMo gera-o
  (`mimo_text`, `autopilot.py:649-659`); o texto usa placeholders `{{email}}`, `{{password}}`, `{{code}}` e
  variáveis do utilizador, resolvidos pela camada de confiança (`params_for`, `autopilot.py:819-835`), nunca
  valores inventados pelo modelo (`RULES`, `autopilot.py:132-138`).
- `CHECK_EMAIL` espera a caixa, filtra links **do próprio site** (domínio registável do `start_url`, e-mail é
  dado não confiável — só o link/código extraído é usado) e escolhe o link de verificação com uma pergunta
  tipada `choice` ao Jev (`autopilot.py:929-946`).

### 1.2 Nível de fio — comandos do socket AF_UNIX JSON-lines (`daemon.py` + `client.py`)

Protocolo: 1 request JSON + token por conexão, 1 resposta JSON (`client.py:112-137`; token lido de ficheiro
0600 em RUNTIME, nunca argv/env — `client.py:1-2,112-117`; comparação `hmac.compare_digest` —
`daemon.py:2386-2388`). Tabela de dispatch em `daemon.py:1380-1387`:

```
note · goto · snapshot · act · view · ask · ask-take · wall-check · shot ·
wait-text · wait-js · eval · human · record · tape · task-sync · replay · stop
```

Mais comandos de controlo atendidos fora da fila (`daemon.py:2391-2431`): `ping`, `status`, `cancel`,
`human-answer`, `human-done`.

As **ops do comando `act`** (o que o browser executa de verdade) são o conjunto fechado do `_do`
(`daemon.py:2099-2151`):

| op | Parâmetros do request | Efeito no Playwright |
|---|---|---|
| `fill` | `value` (texto ou `{{var}}`), `params`/`secret_params`, `as`, `secret` | `loc.fill()` com fallback `keyboard.type()` para máscaras (`daemon.py:2076-2097`) |
| `click` | — | `loc.click(timeout=10000)` |
| `check` | — | `loc.check(timeout=10000)` |
| `select` | `value` = label da opção | `select_option(label)` → fallback por valor (`daemon.py:2122-2127`) |
| `press` | `value` = tecla (`Enter`, `Space`, `PageDown`, `F5`, …) | `loc.press` ou `page.keyboard.press` |
| `back` | — | `page.go_back(timeout=10000)` |
| `close-tab` | — | `page.close()` + adota aba restante (recusa se for a última, `daemon.py:2134-2140`) |
| `read-text` | `as` (nome da saída), `secret` | `loc.inner_text()` → registado como `{{nome}}` |

Endereçamento do alvo (3 modos, `c_act` `daemon.py:1966-2025`):
1. **`node`** — identidade estável do nó observado pelo `view` (WeakMap `window.__anonView`,
   `daemon.py:1478-1483`): **o modelo nunca escreve seletores**; o daemon valida conectado/visível/habilitado
   antes de agir e recusa nós stale (`stale: true`).
2. **`target`** — alvo gravado (receita/playbook): cadeia de seletores + fingerprint (`core.py:194-208`),
   resolvida com cura (`core.resolve` `core.py:235-252`).
3. **`ref`** — ref do `aria_snapshot(mode='ai')` (`aria-ref=eN`) com checagem de frescor
   (`daemon.py:2012-2023`, `core.ref_locator` `core.py:316-323`).

Comandos com parâmetros próprios: `goto {url ({{var}}), timeout}`, `wait-text {text, timeout}`,
`wait-js {js, timeout}` (só mundo isolado, sem `mw:`), `view` (sem parâmetros), `snapshot {full}`,
`shot {label}`, `ask {question, timeout, idle, wait, qid, done_check}`, `human {why, timeout}`,
`record {step, remember[]}`, `tape {record, want_html, want_shot}`, `eval {js, timeout}`.

### 1.3 Nível de receita/replay — conjunto FECHADO (`core.py`)

`ACTIONS = ('goto','wait-text','wait-js','click','fill','select','check','press','read-text','mail-new',
'mail-wait','human')` (`core.py:19-20`); qualquer outra ação é erro de validação/replay
(`core.py:481`). `TARGET_ACTIONS = {click, fill, select, check, read-text}` exigem `target`
(`core.py:21`). Status possíveis: `ok, dry-run-ok, needs-agent, timeout, error, bot-wall, handoff-failed,
gate-denied, cancelled` (`core.py:22-23`).

Parâmetros por passo (`core._act` `core.py:436-475`):
- `goto`: `url` (template `{{param}}`), `timeout` (def. 45000)
- `wait-text`: `text`, `timeout` (10000) · `wait-js`: `js`, `timeout` (30000)
- `fill`: `value` (com `{{param}}`) · `click`/`check`: só `target` · `press`: `key`
- `select`: `option {label, values}` · `read-text`: `output` (nome), `secret`
- `mail-new`: `mail {provider,label}`, `output` · `mail-wait`: `mail {host, path_prefix, code, extract,
  label, timeout}`, `output`
- `human`: `instructions`/`why`, `vendor`, `timeout_s` (def. 900)
- Todo `target` = `{fingerprint, candidates[], frame_path[]}`: fingerprint {role, name, tag, text, labels,
  attrs, in_shadow} + cadeia de candidatos de seletor por score (testid 100 > id estável 90 > role+name 85 >
  label 80 > placeholder 70 > name 65 > attr 60 > class 50 > text 40 > css 30 > xpath 25 —
  `core.candidate_specs` `core.py:128-151`), validados por `count()==1` + mesmo `uid` estrutural
  (`core.validate` `core.py:177-186`).

**Pós-condição gravada por ação** (`core.post_state` `core.py:288-309`): `{url, url_path, title, navigated,
text_added[5], text_excerpt, redirect_in_progress}` — no replay, `navigated + url_path` e `expect_text` são
verificados (`core.py:518-529`).

---

## 2. Estado da página e payload de decisão do Jev

### 2.1 Observação: a "vista limpa" (`view.js`, contrato em `view.contract.md`)

O autopilot **não** manda DOM/HTML para o modelo. A observação é o resultado do comando `view`
(`Autopilot.observe` `autopilot.py:348-394`), que injeta `view.js` no mundo isolado do Camoufox
(`daemon.c_view` `daemon.py:1942-1964`) e devolve um JSON (contrato: `view.contract.md:17-26`):

| Chave | Conteúdo |
|---|---|
| `url`, `title` | URL atual e título (dado não confiável) |
| `text`, `text_truncated` | texto **visível no viewport**, ~6000 chars, orçado por prioridade (foco → centro do ecrã) |
| `scroll` | `{y, height, can_down, can_up}` |
| `dialog` | texto do diálogo aberto ou `null` |
| `output_hint` | pistas de saída **offscreen** (`[role=status/alert]`, `aria-live`, headings do `main`) — para o `goal_done` não celebrar só com o viewport (`view.contract.md:28-46`) |
| `actions[]` | controles acionáveis visíveis, ids `e1…eN` |
| `omitted_actions` | corte duro em 220 ações (foco nunca é derrubado) |

Cada ação (`view.contract.md:52-67`): `id` (o `ref` que o modelo escolhe), `node` (identidade estável,
`null` só em ação sintética), `role`, `label` (nome acessível; ícones ganham dicas sintéticas
`"button (icon: eye) near …"`), `kind ∈ {click, fill, select, hint}`, `value` (**senha sempre `•••`**),
`rect` (coords do viewport do topo), `checked/selected/expanded`, `covered`, `focused`, `password`,
`readonly_value`. Ações `kind:'hint'` são informação ("select tem +N opções"), nunca clicáveis
(`view.contract.md:72-86`) — o consumidor filtra-as dos pools de alvos (`autopilot.py:379-382`) e expõe-as
como `more_options` no state (`autopilot.py:445-446`).

### 2.2 O `state` que vai para o decisor (Jev) e para o fallback (MiMo)

`Autopilot.state()` (`autopilot.py:414-453`) monta o dicionário de decisão:

```jsonc
{
  "goal": "…",                                   // objetivo do utilizador
  "step": 12,
  "url": "https://host/path",                    // só scheme://netloc/path
  "title": "…",                                  // ≤160 chars
  "url_trail": ["…", …],                         // últimas 8 URLs (direção: GO_BACK/CLOSE_TAB)
  "open_tabs": 2,
  "decision_rules": {"next_action": "…", "target_choice": "…"},   // regras UMA vez (§3.1)
  "variables": {"email": "…", "password": "…", "code": "…", "<var>": "user variable"},
  "outputs_wanted": ["nome: desc/regex (must be fully visible, not masked)"],
  "progress_summary": ["1. ✓ …", …],             // o que já deu certo + efeito
  "history": ["#n QUEM OP 'alvo' ✓ → efeito", …],// últimas 6 ações
  "last_change": "diff da vista anterior→atual", // view_diff (url/elements/values/text/dialog)
  "user_guidance": ["…", …],                     // últimas 4 respostas do humano
  "already_tried_without_result": ["click \"X\" (2×)", …],  // repetições na página atual
  "memory_next_steps": ["[replay] click … — …"], // pista do playbook (memória), se houver
  "open_dialog": "…|null",
  "page_text": "…",                              // texto visível, ≤2500 chars (DADO não confiável)
  "text_partial": true,
  "output_hint": "[status] \"Perfil salvo…\"",   // opcional (saídas offscreen)
  "more_options": ["País: 137 more options not listed"],       // opcional (hints de select)
  "loopguard_hint": "loop detected (…): …",      // opcional (contexto, nunca instrução)
  "clickable": ["e3: button \"Sign up\"", …],    // pools de alvos por tipo
  "fields": ["e7: textbox \"Email\" = …", …],
  "select_options": ["e9: combobox \"País\" …"], // só se houver selects
  "human_walls": true                            // só no modo humano p/ bot-walls
}
```

Sem screenshot no payload: imagens só entram na **visão do MiMo** (`vision_look` `autopilot.py:662-693`:
comando `shot` → base64 → `chat_vision`) e no tape/relatório. O MiMo recebe `form_summary` (campos agrupados
por linha, senha `•••`) em vez de `fields` (`autopilot.py:636-638`, `form_summary` `autopilot.py:1720-1742`).

### 2.3 Payload exato do "Jev" (decisões tipadas)

`llm.jev(state, questions)` (`llm.py:400-419`) faz
`POST {ANON_OPENROUTER_BASE}/api/alpha/decisions` (`llm.py:19`) com:

```jsonc
{
  "model": "typesafe/jev-1.13",        // snapshot fixo: limiares calibrados nele (llm.py:22)
  "state": { …state acima, ≤60000 chars (MAX_STATE_CHARS, llm.py:26; _clip_state llm.py:355-365) },
  "questions": { … }
}
```

**Perguntas tipadas** (formatos em `autopilot.py:78` e `autopilot.py:611-627`):

```jsonc
// noul (probabilidade calibrada de um juízo booleano) — NOUL = autopilot.py:78
"goal_done": {"type": "noul",
  "instructions": "Is every requirement of the GOAL satisfied by what is visible now?",
  "criteria": {"true": "All requirements satisfied; every output_wanted fully visible…",
               "false": "Something is missing, hidden or masked."}}

// choice (escolha entre candidatos + confiança calibrada)
"operation": {"type": "choice",
  "criteria": {"CLICK": "Click one element …", "TYPE_TEXT": "…", "DONE": "…", …},  // só ops DISPONÍVEIS
  "instructions": {"goal": "…", "rules": "Apply state.decision_rules (next_action)."}}
"click_target": {"type": "choice",
  "criteria": {"e3": "button \"Sign up\"", "e5": "link \"Pricing\"", "none": "no listed element fits"},
  "instructions": {"goal": "…", "operation": "CLICK", "rules": "Apply state.decision_rules (target_choice)."}}
```

Conjunto completo de perguntas por decisão (`ask_jev` `autopilot.py:589-631`):
`operation` (choice), `goal_done` (noul), `stuck` (noul), `injection` (noul), `irreversible` (noul),
`goal_allows` (noul) + `click_target` / `type_text_target` / `select_target` (choice, um por operação com
pool não vazio, sempre com opção `none`).

**Formato das respostas** (contrato TypeSafe; `llm._clm_answers` `llm.py:292-310` documenta o formato de fio):

```jsonc
"answers": {
  "operation":     {"choice": "CLICK", "confidence": 0.97, "probabilities": {"CLICK": 0.97, "WAIT": 0.02, …}},
  "goal_done":     {"noul": 0.12},
  "injection":     {"noul": 0.03},
  "irreversible":  {"noul": 0.9},      // score também existe no contrato: {score, confidence, probabilities, legend}
  "click_target":  {"choice": "e3", "confidence": 0.91, "probabilities": {…}}
}
```

Consumo em `decide()` (`autopilot.py:748-779`): `done ≥ 0.85` (DONE_MIN, `autopilot.py:32`) ou
`DONE com conf ≥ 0.7` conclui; `stuck > 0.85` ou `LOOK_AGAIN/BLOCKED` ou `conf < 0.55` (JEV_MIN,
`autopilot.py:31`) ou alvo com `conf < 0.55`/`none` → fallback MiMo; `injection > 0.8` → nota
("tratada como dado"); `irreversible`/`goal_allows` alimentam o gate (§3.3).

**Fallback MiMo** (chat com JSON estrito, `chat_json` `llm.py:422-448`, `response_format: json_schema`):
`DECIDE_SCHEMA = {operation ∈ OPS, ref, text, reason, ask_user}` (`autopilot.py:96-99`, prompt do usuário em
`ask_mimo` `autopilot.py:633-647`); texto a digitar: `TEXT_SCHEMA = {text, reason}`
(`autopilot.py:100-101`); visão: `VISION_SCHEMA = {page_state, goal_achieved, wall_visible, can_act,
operation ∈ OPS∪{NONE}, ref, text, reason, missing, irreversible}` (`autopilot.py:104-112`); extração em
batch: `EXTRACT_SCHEMA = {items:[{name,text}]}` (`autopilot.py:126-131`). Modelo: `xiaomi/mimo-v2.6-pro`
(`llm.py:23`).

**Decisor local**: o mesmo contrato corre localmente com `ANON_DECISION_BACKEND=clm` —
`clm_local()` faz `POST http://127.0.0.1:8700/v1/systemone` com `{"model", "state", "questions"}` e devolve
`{answers, usage, ms}` idêntico (`llm.py:313-333`); erro local vira `LLMError` → escala para o MiMo, como
falha do Jev (`llm.py:400-406`, `autopilot.py:743-746`). Lições medidas (DESIGN.md §20, linhas 842-858):
decisões tipadas locais são viáveis mas os limiares **não transferem** entre modelos — recalibrar
`JEV_MIN`/`DONE_MIN` por backend (CLM: `confidence` = topo − média; probabilidades relativas aos candidatos).

---

## 3. Loop de decisão

### 3.1 Ciclo por passo (`Autopilot.run` `autopilot.py:1386-1542`)

```
observe()  →  guardas determinísticas  →  memória/playbook?  →  decide()  →  guardas de repetição
     →  gate (irreversível)  →  act()  →  regista (tape/decision)  →  próxima iteração
```

1. **`observe()`** (`autopilot.py:348-394`): comando `view` → `acts` (indexados por `id`), `text`, `url`,
   `title`, `tabs`; calcula `last_diff` (efeito observado da ação anterior, `view_diff`
   `autopilot.py:1983-2017`) e alimenta o LoopGuard com `state_hash`.
2. **Guardas determinísticas antes de decidir**:
   - `off_site()` (`autopilot.py:1544-1566`): ação levou para fora do site do objetivo → `goto` à página
     anterior e ação marcada como tentada (máx. 3×).
   - `hard_block()` (`autopilot.py:1568-1570`): página curta com regex de bloqueio (403/WAF) → `rotate()`
     (`autopilot.py:1572-1587`): identidade/circuito Tor novos, só antes de haver progresso, máx. 3×; senão
     pergunta ao humano.
   - **Memória/playbook**: `play_step()` (`autopilot.py:539-581`) executa passos gravados **sem IA**
     (`exec_step` `autopilot.py:498-537`) enquanto o passo for `mode != 'ai'` e a `pre.url_path` casar.
3. **`decide()`** (`autopilot.py:732-801`) — a cascata:
   1. **Jev** (ou CLM local): 1 chamada, ~0,3 s, todas as perguntas tipadas em paralelo.
   2. **MiMo** assume quando: erro HTTP/timeout do Jev; abstenção (`LOOK_AGAIN`/`BLOCKED`); `conf < 0.55`;
      `stuck > 0.85`; alvo incerto (`none` ou `conf < 0.55`); `force_mimo` (repetição ou DONE não
      confirmado) (`autopilot.py:738-784`). O MiMo também **escreve todo o texto a digitar**
      (`mimo_text` `autopilot.py:649-659`) e **vê o screenshot** em modo visão (`chat_vision`
      `llm.py:456-463`).
   3. **Humano** quando os dois falham (BLOCKED com `ask_user`), nas repetições (§3.2), no gate (§3.3), em
      dados que só o utilizador tem, e em bot-walls (§3.4).
4. **DONE** exige evidência dupla: `try_extract()` (`autopilot.py:956-997` — regex local ou MiMo em batch,
   valores mascarados (`*•…`) não contam) + `conclusion_confirmed()` (`autopilot.py:695-700`) — o **print do
   ecrã vai ao MiMo** e a imagem pode CONTRADIZER o `done` (`autopilot.py:1448-1463`); 4 rejeições → pergunta
   ao humano.
5. **BLOCKED** tenta primeiro `vision_rescue()` (`autopilot.py:702-730`): MiMo com screenshot + contexto
   devolve uma ação concreta (máx. 3 rescues por run, `ANON_AGENT_RESCUES`); alvo fora da vista é ignorado;
   **um rescue nunca autoriza a si próprio** (`irreversible` recalculado com léxico de risco RISKY_LABEL,
   `autopilot.py:59-60,724-725`) — senão, pergunta ao humano.

### 3.2 O que o LoopGuard corta (e a escada de repetição)

**LoopGuard** (`loopguard.py`, doc `loopguard.py:1-12`) é uma guarda **determinística em Python puro, ZERO
modelo** que atua quando a navegação entra em loop iminente, antes de escalar para MiMo/humano. Sinais de
loop (`LoopGuard.signals` `loopguard.py:180-189`, janela de 6 observações):
- **assinatura repetida** ≥2×: `sig = (op, label, url_path)` (`autopilot.py:1483-1484`);
- **estado parado**: `state_hash(url_path, labels+valores, text[:400])` repetido ≥2× na janela — detecta
  A→B→A (`loopguard.py:48-55,171-173`);
- **`tried()` cresceu** 3 observações seguidas (`loopguard.py:175-178`).

Quando há sinal, `plan()` (`loopguard.py:90-148`) devolve **UMA** correção mecânica e segura, por ordem:
1. `FILL` de campo vazio com variável **conhecida** — placeholder só da tabela fixa pt/en
   (`FIELD_TABLE` `loopguard.py:23-27`): `{{email}}` sempre; `{{password}}` só em contexto de cadastro
   (SIGNUP_RX); `{{code}}` só quando já recebido (e não em cupom/CEP/username — NEGATIVE_RX);
   **nunca valor inventado, nunca em campo de busca** (SEARCH_RX, `loopguard.py:75-76`);
2. corrigir formato em erro de validação visível (só com EXATAMENTE 1 campo candidato);
3. `CLICK` de reveal benigno não tentado (eye/show/reveal/copy);
4. alternativa benigna única não tentada;
5. `REFRESH` determinístico (só sem campos preenchidos).

Proibições rígidas: cliques destrutivos/submit/compra/conta (`is_forbidden` `loopguard.py:58-63` +
`core.DESTRUCTIVE` `core.py:30-31`), segredos (`{{password}}`/`{{code}}`/secret_vars) só no host do
`start_url` (`loopguard.py:66-68,103-104`), orçamento **2 tentativas por assinatura, 5 por run**, nunca repete
(assinatura, valor) (`loopguard.py:19-20,192-200`). Máx. **1 rodada** por assinatura antes de escalar
(`autopilot.py:1670-1671`) — nunca posterga o humano.

**Escada de repetição** (`autopilot.py:1490-1505`): para `n_rep` de uma assinatura —
`3` (ou `5` em WAIT) → força o MiMo (vision rescue); `5` (ou `8` em WAIT) → vision rescue e senão **humano**.
Contadores persistem no estado da run (`save_sigs` `autopilot.py:1646-1648`) para o `--continue`.
Registo de cada decisão: evento `decision {who ∈ jev|clm|mimo|human|memory|loopguard, conf, op, target_id,
reason, ok, effect, cost_usd, llm_ms}` (`note_decision`/`record_decision` `autopilot.py:1613-1644`).

### 3.3 Handoff humano — quando e como

| Gatilho | Mecanismo |
|---|---|
| **Ação irreversível não autorizada** | `gated()` (`autopilot.py:1589-1600`): `irreversible > 0.6` OU léxico destrutivo no label (`core.DESTRUCTIVE` `core.py:30-31`) **E** `goal_allows < 0.7` → confirmação `[sim/não]` ao utilizador; **o objetivo do utilizador é a autorização** (uma run regista "ação irreversível autorizada pelo objetivo: Continue (Jev 0.98)"). Passos irreversíveis em receita passam pelo `gate.py` **fora de banda** (kdialog → zenity → TTY; sem `--yes` nem env que aprove sozinho; timeout = NEGADO — `gate.py:1-6,114-147`) |
| **Dado que só o utilizador tem** | `ask_user()` (`autopilot.py:1310-1334`): 1º cartão na página (`ask_in_page` `autopilot.py:1224-1291`), senão TTY, senão **park** → saída `needs-input` com o estado gravado e o browser aberto (`park` `autopilot.py:1823-1842`); retoma com `run --continue --answer "…"`. **Anti-repetição (ledger de perguntas)**: qid = sha1(kind|ctx|pergunta normalizada); pergunta já respondida (mesmo qid ou Jaccard ≥0.8) nunca volta a sair — replay silencioso da resposta (`autopilot.py:1034-1078`) |
| **Bot-wall / CAPTCHA** | o agente **NUNCA tenta resolver** (regra explícita no prompt `RULES` `autopilot.py:132-138`, e modo humano p/ walls por flag/env/pedido no objetivo — `HUMAN_WALLS_GOAL` `autopilot.py:222-237`). Fluxo (`wall()` `autopilot.py:1744-1795`): paciência + releitura até 30 s (`wait_wall_out` `autopilot.py:1797-1812`; `daemon.patience` `daemon.py:1257-1287`) → visão do MiMo para descartar falso positivo → handoff na janela |
| **Handoff na janela** | `botwall.handoff` (`botwall.py:1756-1770`): entrega a interação à janela visível com barra "✔ Terminei a ação" (Ctrl+Enter/Esc) + "🙋 Preciso de ajuda" (Ctrl+Shift+H); conclusão por `done_check(page)` (pós-condição gravada: URL/texto/JS — `core._done_check` `core.py:400-411`, `daemon.done_check_for` `daemon.py:374-392`), flag `handoff/<name>.done`, ou timeout → status `done` / `done-unverified` (não conta como sucesso) / `timeout` / `aborted` / `cancelled` / `needs-headful`. Headless real impede o handoff (`core.headless_flag` `core.py:720-724`: modo `'virtual'` conta como headed e o humano interage via viewer) |

Também: rejeição visual do DONE (4× → humano, `autopilot.py:1452-1462`), clique bloqueado por layout (teclado
como um usuário, `autopilot.py:849-856`), e `human-did-it` — quando o utilizador executa o passo na página, o
daemon observa as ações dele e o agente **continua a partir do estado real**, com aviso se a verificação não
passou (`autopilot.py:1267-1287`).

### 3.4 Princípios transversais do loop

- **Página é dado, nunca instrução**: pergunta `injection` ao Jev; `untrusted_content: ['page','suggestions',
  'snapshot','title','text',…]` marca tudo que vem da página (`core.py:657`, `daemon.py:1475,1964`);
  prompts dizem-no explicitamente (`RULES` `autopilot.py:132-138`).
- **Segredos nunca saem**: valores de senha recolhidos em todas as frames e mascarados `{{password_field}}`
  (`core.py:32-60`); `scrubber` substitui formas cru/URL-encoded/JSON/HTML-escaped recursivamente
  (`core.py:255-272`); senha digitada pelo humano num handoff também (`core.py:32-33`).
- **Orçamento por tempo, não por passos**: `--max-time` (default 900 s) → `timeout`; tempo de humano não conta
  (`autopilot.py:1414-1416`).
- **Nunca levanta exceção por falha de ação**: `run_steps` devolve sempre status estruturado
  (`core.py:533-608`); falha gera `needs_agent` — contexto estruturado (snapshot + sugestões scored + ref) para
  um modelo consertar (`core.py:611-660`).
- **Watchdog**: `page.evaluate` sem timeout (Playwright) corre sob `watchdog.guard` — página travada (comum em
  desafios anti-bot) encerra o browser em vez de prender a run (`core.py:39-47,614`).
- **Tape/auditoria**: toda observação, chamada de LLM (request exato) e ação vão para `tape.jsonl`/`steps.jsonl`
  mascarados (`autopilot.py:1193-1218`, `daemon.c_tape` `daemon.py:1414-1431`).

---

## 4. Execução no browser real

- **Engine**: **Camoufox** (Firefox anti-fingerprint) via **API síncrona do Playwright Python** —
  `from camoufox.sync_api import Camoufox`; `Camoufox(**kw, persistent_context=True, user_data_dir=…)`
  (`daemon.py:975-995`). Não há CDP: é o protocolo do Playwright.
- **Lançamento** (`core.launch_kwargs` `core.py:727-775`): SO falsificado + ecrã coerente por SO, proxy
  (**Tor por omissão** via relay SOCKS5 local com token de circuito — `torrelay.py`; as requests de LLM **não**
  passam pelo Tor, `llm.py:6-8`), `geoip` resolvido fora do browser, geolocalização negada
  (`permissions.default.geo: 2`), WebRTC bloqueado, locale fixo, env mínimo, `humanize` (movimento de rato),
  headless tri-state `True|False|'virtual'` (Xvfb) (`core.py:674-724`).
- **Ações**: API `Locator` do Playwright — `loc.click/fill/check/select_option/press/inner_text`,
  `page.goto/go_back/keyboard.press/close` (`daemon._do` `daemon.py:2099-2151`, `c_goto` `daemon.py:1433-1454`,
  `c_wait` `daemon.py:2153-2184`); fill com fallback de teclado real para máscaras (`_fill_val`
  `daemon.py:2076-2097`); esperas fatiadas ≤500 ms para o cancelamento funcionar (`sliced`
  `daemon.py:1175-1186`).
- **Como o resultado volta ao agente**: resposta JSON única por request (`client.call` `client.py:112-137`) —
  `{ok, step, action, primary (código Playwright do seletor aceite), url, text_added, value/secret/as, timing,
  untrusted_content}` (`daemon.py:2062-2074`) — mais o que `after()` acrescenta (`daemon.py:1191-1255`):
  deteção de bot-wall (`{'ok': false, 'status': 'bot-wall', 'exit': 6, 'botwall': {verdict, saved, entry}}`),
  resultado de handoff (`handoff: {status, by, duration_s, note}`), timeout (`exit: 5`), `gate-denied`,
  `wall-resolved` (ação não executada porque o muro bloqueou; humano resolveu → repetir).
- **Gravação**: cada ação vira um passo em `steps.jsonl` (sessão) com pre/post, timing, target fingerprint +
  candidatos — é isso que `recipe extract` transforma em receita (`daemon.c_record`/`post_step`
  `daemon.py:2237-2269`).
- **Checagem de alvo em replay**: cura por cadeia de candidatos + verificação de fingerprint (recusa elemento
  errado na posição certa — tag/role/nome acessível por similaridade ≥0.85, `core.fp_check` `core.py:223-232`).

---

## 5. Transposição para mobile (Flutter + WebView + LLM local 2.5B + decisor rápido local)

### 5.1 O que é ESSENCIAL copiar

1. **Contratos de ação em 3 camadas, conjuntos fechados**: vocabulário de decisão tipado (operações + alvo por
   `ref`), vocabulário de execução (fill/click/select/press/back/close/read-text) e vocabulário de receita
   (goto/wait/click/fill/… + `human`). Conjuntos fechados = validação determinística + auditoria.
   No mobile: mesmas 3 camadas, com `act` a falar com a WebView por `runJavaScriptReturningResult`.
2. **Endereçamento por identidade de nó, nunca seletores do modelo** (`node` + WeakMap, `daemon.py:1478-1483`)
   + deteção de staleness. Em WebView inverte-se a ordem: primeiro o port do `view.js` (WeakMap + validação
   conectado/visível/habilitado), depois — quando quisermos persistir ações — a cadeia de candidatos com
   fingerprint (`candidate_specs` `core.py:128-151`) e cura.
3. **A "vista limpa" é a interface crítica**: portar `view.js` + `view.contract.md` (só controles acionáveis
   visíveis, nome acessível, senha `•••`, texto visível com orçamento e prioridade, `output_hint` offscreen,
   ações sintéticas de informação, corte com `omitted_actions`). Isto substitui DOM/screenshot como input do
   decisor e é o que torna um decisor rápido local viável (poucos tokens).
4. **Payload de decisão tipado** (`state` compacto + perguntas `noul`/`choice` com probabilidades calibradas)
   para o **decisor rápido local** — o contrato `clm_local` (`llm.py:313-333`) é literalmente o alvo: mesmo
   envelope `{answers: {qid: {noul|choice|score, confidence, probabilities}}}`; limiares (`JEV_MIN 0.55`,
   `DONE_MIN 0.85`) como configuração, **recalibrados por modelo** (lição do DESIGN.md §20).
5. **Cascata de decisão**: decisor rápido (tipado, ~ms) → LLM local 2.5B (texto a digitar, fallback de decisão,
   extração, visão se houver multimodal) → humano. Regras: o texto é **sempre** do modelo gerador com
   placeholders `{{var}}` resolvidos pela camada de confiança; abstenção explícita (`LOOK_AGAIN`/`BLOCKED`) é
   um estado de primeira classe; "o objetivo do utilizador é a autorização".
6. **Guardrails determinísticos (zero LLM)**: LoopGuard completo (assinaturas, state_hash, tabela fixa de
   campos, orçamento 2/5, nunca ações destrutivas), escada de repetição Jev→MiMo→humano, guarda off-site,
   gate de irreversibilidade (`irreversible > 0.6` + léxico destrutivo + `goal_allows < 0.7` → confirmação).
   Em mobile o gate é um diálogo nativo — manter o princípio **fora de banda, sem auto-aprovação, timeout =
   negado**.
7. **Handoff humano**: nunca resolver CAPTCHAs/anti-bot; paciência+releitura antes de incomodar; cartão de
   pergunta com **done_check verificado** (o utilizador diz "terminei" mas só o estado da página confirma);
   `needs-input` com estado persistido + retomada idempotente; **ledger anti-repetição de perguntas**
   (qid + similaridade). No mobile: overlay/bottom-sheet com botão "✔ Terminei" + verificação + persistência
   da run (equivalente ao `park`).
8. **Higiene de dados**: texto de página marcado `untrusted_content` (dado, nunca instrução), pergunta
   `injection`, scrubber de segredos em tudo (logs, tape, snapshots), senhas nunca em observações.
9. **Auditoria e efeito**: evento de decisão `{who, conf, op, target_id, reason, ok, effect}` com o diff do
   efeito observado na iteração seguinte; tape com os prompts exatos; budget por tempo.

### 5.2 O que NÃO se aplica (ou é substituível)

| Conceito | Porquê não se aplica / substituto |
|---|---|
| **Tor, relay SOCKS por circuito, geoip, rotação de identidade, isolamento socks-auth** (`identity.py`, `torrelay.py`, `rotate()`) | Num telemóvel o tráfego é o do aparelho. O padrão transponível é apenas "rotação de sessão" (limpar cookies/estado) em bloqueio duro, se fizer sentido. |
| **Camoufox fingerprint spoofing** (SO falsificado, ecrã, `humanize`, WebRTC block, locale fixo, headless tri-state + Xvfb + `viewer.py`) | A WebView tem o fingerprint real do dispositivo; anti-detecção não é objetivo. O handoff passa a ser UI nativa (não viewer remoto). |
| **Playwright Locator/replay de receita completo** (candidatos, cura, `aria-ref`, `needs_agent` com refs vivos) | Substituir por bridge JS da WebView (injeção `view.js`, WeakMap, `evaluateJavascript`). A semântica (fingerprint + cadeia de candidatos + pós-condições) mantém-se; a implementação muda. |
| **gate via kdialog/zenity/TTY** (`gate.py`) | Substituir por diálogo nativo Flutter — mesma semântica (fora de banda, negação por timeout). |
| **`mail.py` (caixas descartáveis) e contas em `accounts.jsonl`** | Só se a app tiver fluxos de registo. O princípio (conteúdo de e-mail é dado não confiável; só o link/código extraído é usado, host exato) é transponível. |
| **Posicionamento de rato/hit-test de cobertura** | Touch UI: manter apenas o filtro de visibilidade/enabled; `covered`/`humanize` perdem relevância. |
| **Multi-abas (`CLOSE_TAB`, `open_tabs`)** | WebView mobile: 0-1 abas; manter `GO_BACK` (histórico) e dropar `CLOSE_TAB` ou reduzi-lo. |

### 5.3 Delta mobile específico

- `view.js` corre igual via injeção JS (mundo isolado ≈ `UserScript`/`runJavaScript` na WebView); manter a
  regra "a página nunca vê o estado do agente" (`view.js:1-3`).
- Screenshot para verificação visual: `WebViewController.takeScreenshot` (equivalente ao `shot`).
- Watchdog: timeouts em TODA a chamada JS (a WebView também tem `evaluate` sem timeout conceptual) e deteção
  de processo de conteúdo morto → "página não responde" (`core._unresponsive_context` `core.py:624-635`).
- Persistência da run (`RUNTIME/autopilot/<name>.json` equivalente) para sobreviver a crashes/app em background
  — mobile agrava (OS mata processos).

---

## Síntese final (desenho de controlo essencial, ≤500 palavras)

O controlo tem 4 camadas: (1) **observação** — uma "vista limpa" da página (só controles acionáveis visíveis,
ids estáveis `e1…eN`, nome acessível, senha `•••`, texto visível orçado, pistas de saída offscreen), sem DOM
nem screenshot; (2) **decisão tipada** — um decisor rápido (Jev/CLM, ~0,3 s, contrato `state + questions
noul/choice/score → answers com probabilidades calibradas`) escolhe 1 de 14 operações fechadas (CLICK,
TYPE_TEXT, SELECT, PRESS_ENTER, SCROLL_*, WAIT, CHECK_EMAIL, GO_BACK, CLOSE_TAB, DONE, BLOCKED, LOOK_AGAIN) e
o alvo por `ref`, numa única chamada com ~8 perguntas atómicas (operação, alvo por operação, goal_done, stuck,
injection, irreversible, goal_allows); (3) **fallback gerativo** — um LLM (MiMo 2.6 Pro; no nosso caso um
2.5B local) assume quando o decisor erra/abstém/fica abaixo de `conf 0.55`, escreve TODO o texto a digitar
(com placeholders `{{email}}/{{password}}/{{code}}` resolvidos pela camada de confiança, nunca pelo modelo) e
analisa o screenshot antes de concluir/resgatar; (4) **humano** — para ações irreversíveis não autorizadas
pelo objetivo (gate fora de banda, timeout = negado), dados que só ele tem (cartão na página + `needs-input`
persistido + ledger anti-repetição de perguntas) e bot-walls/CAPTCHAs (nunca resolvidos pela IA; handoff na
janela com "✔ Terminei a ação" **verificado por done_check**).

Entre camadas vivem guardas **determinísticas, zero LLM**: LoopGuard (assinatura repetida, hash de estado
parado, tried() crescente → UMA correção mecânica segura: fill de variável conhecida, reveal, refresh — com
orçamento 2/assinatura, 5/run e proibição absoluta de ações destrutivas), escada de repetição
3/5 → MiMo → humano, guarda de saída do site, e gate léxico-destrutivo. Toda ação passa por um daemon com
socket autenticado onde o modelo **nunca escreve seletores** (identidade de nó validada) e tudo fica gravado
com `{who, conf, op, alvo, why, ok, effect}` para auditoria e receita.

Para o Flutter: copiar os contratos (operações fechadas, payload tipado, vista limpa, placeholders,
guardrails, gate e handoff verificado); descartar Tor/fingerprint/anti-detecção; implementar `view.js` +
WeakMap via bridge JS da WebView, decisor local com limiares recalibrados e LLM 2.5B como gerador de
texto/fallback — mantendo a invariante central: **decisão é classificação tipada barata, texto é geração
cara, e nada destrutivo acontece sem o humano.**
