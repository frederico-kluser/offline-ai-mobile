# Laya — especificação de encode/decode do decisor tipado (model.onnx, fp32)

Contrato exato do motor `LayaOnnxEngine` (`lib/src/engines/laya_engine_onnx.dart`) sobre o artefacto
`tools/laya_artifact/` — **export fp32 do checkpoint oficial `convaiinnovations/laya-typed-decisions`**
(Convai Innovations), gerado por `tools/laya_export_fp32.py`. Substitui o antigo kit 4-bit de
terceiros `m1rhan/laya-typed-decisions-ONNX` (428 MB, quantização `MatMulNBits` pensada para
browsers). A assinatura ONNX e o pipeline encode/decode **não mudam**; mudaram o modelo, a
calibração (§6) e os limites: `head_max_len` 192→**256**, `max_len` 512→**1024**.

**Fontes usadas** (por ordem de autoridade):

1. **Checkpoint oficial** `convaiinnovations/laya-typed-decisions` (Hugging Face) —
   `model.safetensors` (F16, 421M parâmetros; encoder `answerdotai/ModernBERT-large` + head de 2
   camadas), `rl_agent_config.json` (calibração), `tokenizer/`, `encoder/config.json`.
2. **Pacote Python `laya` 0.3.21** (PyPI) — `laya.common.DecisionModel.forward` (a assinatura 5→2
   exportada), `build_sequence`, `collate_items`, `clamp_temperature`, `answer_confidence`, e
   `laya.agent.Agent.system_one` (referência de decode). É a referência que este motor segue.
3. **`tools/laya_export_fp32.py`** (este repo) — export dynamo (`torch.onnx.export`, opset 18) do
   `DecisionModel` + fusão de external data em ficheiro único + validação (onnx.checker + paridade
   torch↔onnxruntime + tabela de fixtures §9).
4. **`rl_agent_config.json` oficial** (cópia em `tools/laya_artifact/rl_agent_config.json`):
   `max_len=1024`, `head_max_len=256`, tabelas de temperatura (§6).
5. Grafo `tools/laya_artifact/onnx/model.onnx` inspecionado com `onnx`: ir_version 10, opset 18
   **sem ops contrib `com.microsoft`** (fp32 puro; 1825 nós, 188 `MatMul`), 1.688.700.355 bytes,
   sha256 `0ef200f93f07fe1ea1a78d30d765384e53d1de17faee97a3f2f995e1be1d4d0b`.

## 1. Assinatura ONNX (confirmada no grafo exportado)

| | nome | dtype | shape | notas |
| --- | --- | --- | --- | --- |
| in | `input_ids` | int64 (`elem_type=7`) | `[1, seq_len]` | ids da sequência completa |
| in | `attention_mask` | int64 | `[1, seq_len]` | 1 em tokens reais (n=1: tudo a 1) |
| in | `marker_pos` | int64 | `[1, n_markers]` | posição de cada `[MASK]` de opção |
| in | `marker_mask` | **bool** (`elem_type=9`) | `[1, n_markers]` | 1 nas opções válidas |
| in | `qtype` | int64 | `[1]` | ver §2 |
| out | `logits` | float32 | `[1, n_markers]` | 1 score por marcador (pré-softmax) |
| out | `act_logits` | float32 | `[1, 2]` | gate escalate/answer (2-way) |

- **Batch fixo em 1**: `dim 0 = 1` é estático no grafo (export dynamo com `seq_len`/`n_markers`
  dinâmicos apenas). ⇒ cada pergunta é um `session.run` próprio (a latência é linear no nº de
  perguntas — doc §7).
- Export **head fundida**: 5 inputs → 2 outputs, opset 18 (`ai.onnx` apenas). Ao contrário do
  artefacto antigo, **não usa contrib-ops** (`MatMulNBits`) — pesos fp32 em `MatMul` comum.
- **`n_markers ≥ 2` obrigatório**: o head calcula `top2` das probabilidades (o branch `K=1` do
  `DecisionModel` PyTorch não sobrevive ao export dinâmico); o motor Dart rejeita perguntas com
  `< 2` opções antes de correr o grafo.

## 2. Índice `qtype`

| tipo | índice |
| --- | --- |
| `choice` | 0 |
| `score` | 1 |
| `noul` | 2 |

Confirmado em `laya/common.py` (`QTYPES = {"choice": 0, "score": 1, "noul": 2}`) e no export.

> ⚠️ **Discrepância conhecida noutro ficheiro**: `lib/src/domain/laya_types.dart` expõe
> `QType.onnxIndex => index` (enum `noul, choice, score` ⇒ 0/1/2), o que está **errado** face ao
> modelo. O motor **não usa** `onnxIndex`: mapeia internamente (`choice→0, score→1, noul→2`).
> Correção sugerida ao domínio (fora do âmbito deste trabalho): `onnxIndex` devia devolver
> `{noul: 2, choice: 0, score: 1}[this]`.

## 3. Montagem da sequência (`build_sequence` do `laya.common`)

Formato:

```
[CLS] <type> question: <instruções> [SEP] [MASK] opt0 [MASK] opt1 ... [MASK] optN-1 [SEP] <state> [SEP]
```

Regras exatas (porte literal de `laya/common.py::build_sequence`):

1. **Scrub**: em instruções/opções/state, cada ocorrência literal de `[MASK]` é substituída por um
   espaço (as opções entram como marcadores, nunca como texto).
2. **Cabeçalho**: `headIds = encode("<type> question: <instruções>")` sem tokens especiais
   (`<type>` ∈ `choice|score|noul`).
3. **Opções** (`render_options`) em ordem de índice:
   - `choice`: `"nome: descrição"`; só `"nome"` quando a descrição é nula/vazia (critérios em lista
     viram `{c: null}`).
   - `score`: `"level i: <nível>"` para `i = 0..k-1`.
   - `noul`: `"false: <crit>"` e `"true: <crit>"`, pela por ordem `[false, true]` — **`p[1]` é
     P(true)**; defaults `"no, the statement does not hold"` / `"yes, the statement holds"` quando o
     critério é nulo/vazio. ⚠️ O domínio `NoulQuestion` pré-preenche `trueCriteria='sim'` /
     `falseCriteria='não'` (nunca vazios): quem chama com os defaults do domínio envia esses textos
     como critérios; para reproduzir os defaults da referência têm de ser passados explicitamente.
   Cada opção: `optIds[i] = [maskId] + encode(" " + opt)[:48]` (espaço à frente + cap de 48 tokens).
4. **Orçamento do head = 256 tokens** (`head_max_len` da calibração oficial):
   `optBudget = 256 − Σ|optIds|`; se `optBudget < 16`, encolhe todas as opções uniformemente:
   `per = max(4, (256 − 16) ÷ nOptions)` e `optIds[i] = optIds[i][:per]` (recalcula o budget).
   Depois `headIds = headIds[:max(8, optBudget)]`.
5. **Sequência**: `seq = [cls] + headIds + [sep]`; para cada opção: `markers.add(seq.length)` e
   `seq += optIds[i]`; `seq += [sep]`.
6. **State**: `room = max(0, maxLen − seq.length − 1)`; `st = encode(scrub(state))[:room]`
   (truncagem à direita — para `String` o estado serializa-se a si próprio; JSON tipo
   `json.dumps(ensure_ascii=False)` só para estados estruturados, que este contrato nem expõe).
   `seq += st + [sep]`; finalmente `seq = seq[:maxLen]` e `markers = markers.where(< maxLen)`.
7. **Validação**: se `markers.length != nOptions` ⇒ erro (opções não cabem em 256 tokens).

- `maxLen` = `LayaConfig.maxStateTokens` (por omissão **1024**, o `max_len` da calibração oficial).
- `LayaConfig.maxStateChars` (2000) pré-trunca o state em **caracteres** (do início) antes de
  tokenizar — otimização; a contagem fina é sempre do tokenizer e o budget real é do passo 6.
- Os ids especiais entram **por id**, nunca via `add_special_tokens`: `encode()` é sempre chamado
  com `add_special_tokens: false` (o `post_processor` `[CLS] A [SEP]` do tokenizer.json nunca é
  aplicado).

## 4. Colação dos tensores (uma pergunta por run)

Para cada pergunta (batch `n = 1` estático):

- `L = seq.length`, `K = markers.length` (**K ≥ 2**);
- `input_ids = seq` (int64, `[1, L]`) — sem padding (n=1);
- `attention_mask = 1..1` (int64, `[1, L]`);
- `marker_pos = markers` (int64, `[1, K]`);
- `marker_mask = true..true` (bool, `[1, K]`);
- `qtype = [índice]` (int64, `[1]`).

A colação de referência (`collate_items`) faz pad à direita com `pad_id=50283` quando há batch
`n > 1` — não aplicável aqui (batch fixo 1).

## 5. Tokenizer (tokenizer.json do kit)

**Ficheiro byte-idêntico** ao `tokenizer/tokenizer.json` do checkpoint oficial
(sha256 `6c8aaa9a542084f2457eab775d4eeb51f92a70c0fd9de28d5edb0ddec3c08d30`; igual também ao do kit
4-bit antigo) ⇒ **a implementação Dart não muda** — a validação 25/25 da §9.1 mantém-se válida.

`tokenizer.json` **é BPE ByteLevel GPT-2, NÃO WordPiece** (`model.type = "BPE"`; `decoder.type =
"ByteLevel"`; normalizer `NFC`; pre-tokenizer `ByteLevel {add_prefix_space: false, use_regex: true}`)
— o nome `wordpiece_tokenizer.dart` mantém-se por contrato, a implementação é a que existe no
artefacto (BPE).

- vocab 50280 + added tokens até **50368**; merges 50009 pares no formato `[a, b]`.
- Tokens especiais: `[CLS]=50281`, `[SEP]=50282`, `[PAD]=50283`, `[MASK]=50284`, `[UNK]=50280`.
- **Added tokens** (matched antes do BPE, longest-match): placeholders PII (`|||IP_ADDRESS|||`=0,
  `|||EMAIL_ADDRESS|||`=50277, `|||PHONE_NUMBER|||`=50278), runs de espaços (50276=`"  "` …
  50254=24 espaços), especiais (`<|padding|>`, `<|endofline|>`, `[UNK]`…`[MASK]`, `[unused0..82]`).
- Pipeline de `encode(text)`: **NFC** → split por added tokens → split pelo regex GPT-2
  `'s|'t|'re|'ve|'m|'ll|'d| ?\p{L}+| ?\p{N}+| ?[^\s\p{L}\p{N}]+|\s+(?!\S)|\s+` → por pré-token,
  bytes UTF-8 → alfabeto `bytes_to_unicode` (GPT-2) → merges BPE (menor rank, todas as ocorrências
  do par por iteração) → ids.
- **Normalização = NFC** (como no ficheiro), implementada em Dart puro (tabelas canónicas geradas +
  composição algorítmica Hangul). Caso rápido: strings ASCII passam intactas.
- Desvios documentados face ao `tokenizers` HF: (a) matching de added tokens feito sobre texto já
  normalizado (HF distingue `normalized: false` para `<|padding|>`/`<|endofline|>`/`[UNK]`… — só
  importa se esses literais aparecerem **dentro** de texto não-NFC); (b) `decode()` existe para
  debug/testes, não é usado pelo motor.

## 6. Temperaturas (calibração real do checkpoint — `rl_agent_config.json` oficial)

`temperature` indexado por qtype; `temperature_by_options` por bucket `"qtype:size"` com
`size = 2 | 3-5 | 6-10 | 11+` (`k ≤ 2`, `k ≤ 5`, `k ≤ 10`, senão `11+`). Busca:
`temperature_by_options[bucket] ?? temperature[qtype]`.

```json
"temperature": [1.0148024559020996, 1.0374259948730469, 1.0575125217437744],
"temperature_by_options": {
  "choice:2": 1.9063563346862793, "choice:3-5": 1.7601518630981445,
  "choice:6-10": 1.0000158548355103, "choice:11+": 0.10058280825614929,
  "score:3-5": 1.2514300346374512, "noul:2": 1.983399510383606
}
```

- Os buckets `choice:*`, `score:3-5` e `noul:2` são idênticos aos do kit antigo; **mudou o fallback
  `temperature[qtype]`** (1.0148/1.0374/1.0575 vs 1.6369/1.2514/1.9834) — afeta `score` com
  `k ≠ 3-5` (e qualquer pergunta sem bucket).
- **Clamp obrigatório em [0.5, 5.0]** (`clamp_temperature` de `laya/common.py`, `TEMP_MIN/TEMP_MAX`).
  `choice:11+ = 0.1006` é rejeitado pela referência Python (que avisa com `RuntimeWarning`) e
  aplicado como **0.5**. O SDK JS não clampa — **este motor segue `Agent.system_one` (Python) e
  clampa**; fixtures com ≥11 opções divergem do JS SDK de propósito.

## 7. Decode (`Agent.system_one`)

Por pergunta, com `k = markers.length` e `z = logits[0, 0..k) / T`:

- `p = softmax(z)` (estável: subtrair o max); rounding final **4 casas decimais** (half-away-from-zero;
  ≈ `round(x, 4)` do Python, difere apenas em ties exatos).
- **`choice`**: `choice = keys[argmax p]`; `probabilities` = `p` por chave;
  `confidence = 1 − H(p)/log(k)` (entropia normalizada; `k < 2 ⇒ 1.0`).
- **`score`**: `score = Σ i·p[i]` (índice esperado 0-based, fracionário); `legend = {i: nível}`;
  `probabilities` por índice; `confidence` igual ao choice.
- **`noul`**: `noul = p[1]` (P(true)); `confidence = max(p[1], 1 − p[1])`;
  `probabilities = {false: p[0], true: p[1]}`.
- **`answer_confidence`** (todos os tipos) = `max(p[0..k))` clampado a [0,1] — a única confiança
  calibrada (`answer_confidence` de `laya/common.py`; ECE é medida sobre ela; ≠ `confidence`).
- **`act_probability`** = `softmax(act_logits[0])[0]` (probabilidade da classe 0 = answer, tal como
  `laya/onnx_agent.py`: softmax 2-way sobre `act_logits`, usa-se o índice 0). Em `LayaResponse` sai
  como `actProbability` (`action.act_probability` no wire).
- `usage.input_tokens` = Σ `|seq|` sobre todas as perguntas; `output_tokens = 0` (invariante).

## 8. Runtime, EP e threading

- Pacote: **`onnxruntime_v2`** (fork do `gtbluesky/onnxruntime_flutter`, 100% dart:ffi).
  Android empacota `com.microsoft.onnxruntime:onnxruntime-android`; iOS/macOS/Linux/Windows trazem
  libs próprias.
- **EP: CPU apenas, por determinismo.** O grafo fp32 já não depende de contrib-ops (o antigo
  `MatMulNBits` não era acelerado por NNAPI/QNN/CoreML), mas particionamentos heterogéneos variam
  numericamente entre devices — CPU EP é o ground truth (escopo: "mais determinismo que
  liberdade"). `LayaConfig.executionProvider` é aceite mas mapeado para CPU (`cpu`/`xnnpack` →
  CPU EP).
- Threading: `setIntraOpNumThreads(LayaConfig.threads)`; `GraphOptimizationLevel.ortEnableAll`.
- **Fora da UI thread**: `decide()` corre tokenização + montagem de tensores + `run` + decode num
  **Isolate persistente** criado em `load()` (mensagens só com dados simples; a sessão ORT vive no
  worker). Nunca inferência no isolate da UI.
- `run` sincrónico por pergunta dentro do worker (o grafo tem batch estático 1).

### 8.1 Falha de runtime

Se em device o runtime não carregar o modelo (`Load model failed`, ficheiro truncado, RAM
insuficiente…), o comportamento contratado é:

1. `load()` **não rebenta**: regista a mensagem exata do ORT em `_loadError` (o tokenizer carrega na
   mesma — a camada encode/decode fica funcional e testável).
2. `decide()` lança `StateError` com a mensagem exata do ORT empacotada:
   `LayaOnnxEngine: modelo ONNX não carregou no ONNX Runtime: <erro ORT>`.
3. `isLoaded` fica `false`; `unload()` é seguro.

### 8.2 Riscos conhecidos

- **RAM/footprint fp32**: ~1,69 GB de pesos + ativações (seq até 1024) ⇒ pico de ~2,2 GB por sessão.
  No iOS o Jetsam mata apps com footprint excessivo — medir em device real antes de prometer
  (doc §15: benchmark interno 2 Android + 1 iPhone). NÃO usar o emulador Android para isto
  (restrição do utilizador).
- **Latência**: fp32 CPU é mais lento que o 4-bit antigo (referência desktop do Laya: ~370 ms para
  batch 4×96 tokens em 20 threads); medir ms/decisão em device.
- `act_logits` pode saturar (valores grandes) ⇒ `act_probability` ≈ 0 ou 1; é esperado.
- `choice:11+` com temperatura clamped para 0.5: >20 opções degradam (doc §3.4) — preferir ≤20.
- **`K ≥ 2`**: perguntas com 1 opção são rejeitadas pelo motor (§1); não há branch `K=1` no grafo.

## 9. Fixtures de verificação (oráculo Python vs Dart)

Reproduzíveis com `tools/laya_export_fp32.py` (que também gera esta tabela) ou com
`python3 + onnxruntime + tokenizers` sobre `tools/laya_artifact/` (pipeline §3–§7). As definições
exatas das perguntas vivem em `FIXTURE_QUESTIONS_EN/PT` do script de export.

State EN: `"Customer: my invoice was charged twice and nobody answers the phone!"`

| pergunta | k | T | probs | resposta | confidence | answer_conf | act_prob |
| --- | --- | --- | --- | --- | --- | --- | --- |
| department (choice) | 3 | 1.7602 | 0.8590/0.0782/0.0628 | `billing` | 0.5415 | 0.8590 | 1.0 |
| urgency (noul) | 2 | 1.9834 | 0.3050/0.6950 | `noul=0.6950` | 0.6950 | 0.6950 | 1.0 |
| frustration (score) | 3 | 1.2514 | 0.0175/0.4066/0.5759 | `score=1.5585` | 0.3133 | 0.5759 | 1.0 |

State PT: `"Cliente: faturaram-me duas vezes o mesmo mês e ninguém responde ao telefone!"`

| pergunta | k | T | probs | resposta | confidence | answer_conf | act_prob |
| --- | --- | --- | --- | --- | --- | --- | --- |
| departamento (choice) | 3 | 1.7602 | 0.5685/0.2979/0.1336 | `faturacao` | 0.1345 | 0.5685 | 1.0 |
| urgencia (noul) | 2 | 1.9834 | 0.4038/0.5962 | `noul=0.5962` | 0.5962 | 0.5962 | 1.0 |

### 9.1 Resultado da validação executada (2026-09-28)

- **Export** (`tools/laya_export_fp32.py`, torch 2.14 dynamo, opset 18): `onnx.checker` OK;
  grafo com a assinatura exata da §1 (batch 1 estático, `seq_len`/`n_markers` dinâmicos).
- **Paridade torch (checkpoint oficial) vs onnxruntime 1.30 (CPU) sobre o `model.onnx` exportado**:
  5/5 fixtures (choice/noul/score, EN+PT) com **argmax idêntico**; pior desvio absoluto
  1,9e-6 em `logits` e 1,5e-3 em `act_logits` (campos saturados; irrelevante após softmax).
- **Tokenizer Dart vs HF `tokenizers`**: 25/25 ids e decodes idênticos (validação de 2026-09-27) —
  mantém-se válida porque o `tokenizer.json` é **byte-idêntico** ao do kit antigo (sha256 acima).
- **Engine Dart vs oráculo Python** sobre o novo artefacto: ver §9.2.

### 9.2 Validação do engine Dart (fixtures acima)

**2026-09-28, `flutter test` sobre `tools/laya_artifact/` (desktop Linux, ORT do plugin
`onnxruntime_v2`)**: 5/5 perguntas (3 EN + 2 PT) com `probabilities`, `choice`, `score`, `noul`,
`confidence`, `answer_confidence`, `act_probability` **e `input_tokens`** idênticos ao oráculo
Python (4 dp). O teste temporário foi removido depois da verificação (convenção desta secção);
reproduzir com as fixtures acima. Verificação em device Android/iPhone continua obrigatória
(§8.2 — **sem emulador Android**, restrição do utilizador).