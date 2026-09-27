# Laya — especificação de encode/decode do decisor tipado (model_q4.onnx)

Contrato exato do motor `LayaOnnxEngine` (`lib/src/engines/laya_engine_onnx.dart`) sobre o artefacto
`tools/laya_artifact/` (checkpoint `typed-decisions` exportado para ONNX por
`m1rhan/laya-typed-decisions-ONNX`).

**Fontes usadas** (por ordem de autoridade):

1. **README do repositório do artefacto** (`m1rhan/laya-typed-decisions-ONNX`, Hugging Face) — o
   ficheiro `README.md` prometido em `tools/laya_artifact/` **não existe no diretório local** (só
   `config.json`, `tokenizer.json`, `tokenizer_config.json`, `onnx/model_q4.onnx`); o contrato abaixo
   foi recuperado do README publicado nesse repo e **confirmado por inspeção do grafo ONNX**.
2. **SDK JS oficial `@receptron/laya` 0.1.2** (npm) — `dist/sequence.js` (`buildSequence`,
   `renderOptions`, `toInternal`, `tempBucket`, `confidenceFromProbs`) e `dist/laya.js` (`systemOne`).
3. **Pacote Python `laya` 0.3.20** (PyPI) — `laya/common.py` (`build_sequence`, `collate_items`,
   `clamp_temperature`, `answer_confidence`) e `laya/onnx_agent.py` (corre o ONNX com exatamente
   estes 5 inputs e decodifica). É a referência `Agent.system_one` que este motor segue.
4. **Configs de calibração** `rl_agent_config.json` (convaiinnovations/laya) e `laya_config.json`
   (receptron/laya-onnx): `max_len=512`, `head_max_len=192`, tabela de temperaturas (§6).
5. Grafo `onnx/model_q4.onnx` inspecionado com `onnx` (ir_version 10, opset 18 + `com.microsoft`).

## 1. Assinatura ONNX (confirmada no README do artefacto **e** no grafo)

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
  dinâmicos apenas). ⇒ cada pergunta é um `session.run` próprio (é por isso que a latência é linear
  no nº de perguntas — doc §7).
- O export é **head fundida**: 5 inputs → 2 outputs (120 nós `MatMulNBits`, opset 18).

## 2. Índice `qtype`

| tipo | índice |
| --- | --- |
| `choice` | 0 |
| `score` | 1 |
| `noul` | 2 |

Confirmado em `laya/common.py` (`QTYPES = {"choice": 0, "score": 1, "noul": 2}`) e no README do
artefacto (`qtype int64, 0=choice/1=score/2=noul`).

> ⚠️ **Discrepância conhecida noutro ficheiro**: `lib/src/domain/laya_types.dart` expõe
> `QType.onnxIndex => index` (enum `noul, choice, score` ⇒ 0/1/2), o que está **errado** face ao
> modelo. O motor **não usa** `onnxIndex`: mapeia internamente (`choice→0, score→1, noul→2`).
> Correção sugerida ao domínio (fora do âmbito deste trabalho): `onnxIndex` devia devolver
> `{noul: 2, choice: 0, score: 1}[this]`.

## 3. Montagem da sequência (`build_sequence` do SDK/`laya.common`)

Formato:

```
[CLS] <type> question: <instruções> [SEP] [MASK] opt0 [MASK] opt1 ... [MASK] optN-1 [SEP] <state> [SEP]
```

Regras exatas (portes literais de `@receptron/laya/dist/sequence.js` e `laya/common.py`):

1. **Scrub**: em instruções/opções/state, cada ocorrência literal de `[MASK]` é substituída por um
   espaço (as opções entram como marcadores, nunca como texto).
2. **Cabeçalho**: `headIds = encode("<type> question: <instruções>")` sem tokens especiais
   (`<type>` ∈ `choice|score|noul`).
3. **Opções** (`renderOptions`) em ordem de índice:
   - `choice`: `"nome: descrição"`; só `"nome"` quando a descrição é nula/vazia (critérios em lista
     viram `{c: null}`).
   - `score`: `"level i: <nível>"` para `i = 0..k-1`.
   - `noul`: `"false: <crit>"` e `"true: <crit>"`, pela por ordem `[false, true]` — **`p[1]` é
     P(true)**; defaults `"no, the statement does not hold"` / `"yes, the statement holds"` quando o
     critério é nulo/vazio. ⚠️ O domínio `NoulQuestion` pré-preenche `trueCriteria='sim'` /
     `falseCriteria='não'` (nunca vazios): quem chama com os defaults do domínio envia esses textos
     como critérios; para reproduzir os defaults da referência têm de ser passados explicitamente.
   Cada opção: `optIds[i] = [maskId] + encode(" " + opt)[:48]` (espaço à frente + cap de 48 tokens).
4. **Orçamento do head = 192 tokens** (`head_max_len`):
   `optBudget = 192 − Σ|optIds|`; se `optBudget < 16`, encolhe todas as opções uniformemente:
   `per = max(4, (192 − 16) ÷ nOptions)` e `optIds[i] = optIds[i][:per]` (recalcula o budget).
   Depois `headIds = headIds[:max(8, optBudget)]`.
5. **Sequência**: `seq = [cls] + headIds + [sep]`; para cada opção: `markers.add(seq.length)` e
   `seq += optIds[i]`; `seq += [sep]`.
6. **State**: `room = max(0, maxLen − seq.length − 1)`; `st = encode(scrub(state))[:room]`
   (truncagem à direita — para `String` o estado serializa-se a si próprio; JSON tipo
   `json.dumps(ensure_ascii=False)` só para estados estruturados, que este contrato nem expõe).
   `seq += st + [sep]`; finalmente `seq = seq[:maxLen]` e `markers = markers.where(< maxLen)`.
7. **Validação**: se `markers.length != nOptions` ⇒ erro (opções não cabem em 192 tokens).

- `maxLen` = `LayaConfig.maxStateTokens` (por omissão **512**, o `max_len` de calibração).
- `LayaConfig.maxStateChars` (2000) pré-trunca o state em **caracteres** (do início) antes de
  tokenizar — otimização; a contagem fina é sempre do tokenizer e o budget real é o do passo 6.
- Os ids especiais entram **por id**, nunca via `add_special_tokens`: `encode()` é sempre chamado
  com `add_special_tokens: false` (o `post_processor` `[CLS] A [SEP]` do tokenizer.json nunca é
  aplicado).

## 4. Colação dos tensores (uma pergunta por run)

Para cada pergunta (batch `n = 1` estático):

- `L = seq.length`, `K = markers.length`;
- `input_ids = seq` (int64, `[1, L]`) — sem padding (n=1);
- `attention_mask = 1..1` (int64, `[1, L]`);
- `marker_pos = markers` (int64, `[1, K]`);
- `marker_mask = true..true` (bool, `[1, K]`);
- `qtype = [índice]` (int64, `[1]`).

A colação de referência (`collate_items`) faz pad à direita com `pad_id=50283` quando há batch
`n > 1` — não aplicável aqui (batch fixo 1).

## 5. Tokenizer (tokenizer.json do artefacto)

`tokenizer.json` **é BPE ByteLevel GPT-2, NÃO WordPiece** (`model.type = "BPE"`; `decoder.type =
"ByteLevel"`; normalizer `NFC`; pre-tokenizer `ByteLevel {add_prefix_space: false, use_regex: true}`)
— o nome `wordpiece_tokenizer.dart` mantém-se por contrato, a implementação é a que existe no
artefacto (BPE).

- vocab 50280 + added tokens até **50368**; merges 50009 pares no formato `[a, b]`.
- Tokens especiais: `[CLS]=50281`, `[SEP]=50282`, `[PAD]=50283`, `[MASK]=50284`, `[UNK]=50280`.
- **Added tokens** (matched antes do BPE, longest-match): placeholders PII (`|||IP_ADDRESS|||`=0,
  `|||EMAIL_ADDRESS|||`=50277, `|||PHONE_NUMBER|||`=50278), runs de espaços (50276=`"  "` …
  50254=24 espaços), especiais (`<|padding|>`, `<|endoftext|>`, `[UNK]`…`[MASK]`, `[unused0..82]`).
- Pipeline de `encode(text)`: **NFC** → split por added tokens → split pelo regex GPT-2
  `'s|'t|'re|'ve|'m|'ll|'d| ?\p{L}+| ?\p{N}+| ?[^\s\p{L}\p{N}]+|\s+(?!\S)|\s+` → por pré-token,
  bytes UTF-8 → alfabeto `bytes_to_unicode` (GPT-2) → merges BPE (menor rank, todas as ocorrências
  do par por iteração) → ids.
- **Normalização = NFC** (como no ficheiro), implementada em Dart puro (tabelas canónicas geradas +
  composição algorítmica Hangul). Caso rápido: strings ASCII passam intactas.
- Desvios documentados face ao `tokenizers` HF: (a) matching de added tokens feito sobre texto já
  normalizado (HF distingue `normalized: false` para `<|padding|>`/`<|endoftext|>`/`[UNK]`… — só
  importa se esses literais aparecerem **dentro** de texto não-NFC); (b) `decode()` existe para
  debug/testes, não é usado pelo motor.

## 6. Temperaturas (calibração real do checkpoint)

`temperature` indexado por qtype; `temperature_by_options` por bucket `"qtype:size"` com
`size = 2 | 3-5 | 6-10 | 11+` (`k ≤ 2`, `k ≤ 5`, `k ≤ 10`, senão `11+`). Busca:
`temperature_by_options[bucket] ?? temperature[qtype]`.

```json
"temperature": [1.6369030475616455, 1.2514300346374512, 1.983399510383606],
"temperature_by_options": {
  "choice:2": 1.9063563346862793, "choice:3-5": 1.7601518630981445,
  "choice:6-10": 1.0000158548355103, "choice:11+": 0.10058280825614929,
  "score:3-5": 1.2514300346374512, "noul:2": 1.983399510383606
}
```

**Clamp obrigatório em [0.5, 5.0]** (`clamp_temperature` de `laya/common.py`, `TEMP_MIN/TEMP_MAX`).
Efeito prático: `choice:11+ = 0.1006` é rejeitado pela referência Python e aplicado como **0.5**
(sharpening de 10× publicado como 0.99 seria desonesto — ver docstring do próprio clamp). O SDK JS
não clampa — **este motor segue `Agent.system_one` (Python) e clampa**; fixtures com ≥11 opções
divergem do JS SDK de propósito.

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

- Pacote: **`onnxruntime_v2` 1.23.2+2** (fork do `gtbluesky/onnxruntime_flutter`, 100% dart:ffi).
  Android empacota `com.microsoft.onnxruntime:onnxruntime-android:1.23.2`; iOS/macOS/Linux/Windows
  trazem libs próprias (Linux: `libonnxruntime.so.1.22.0`).
- **EP: CPU apenas.** O artefacto usa `MatMulNBits` (op contrib `com.microsoft`, 4-bit simétrico
  block 32, 120 nós). NNAPI/QNN/CoreML **não são usados**: não aceleram `MatMulNBits` (doc §15) e
  particionamentos heterogéneos só adicionam cópia. `LayaConfig.executionProvider` é aceite mas
  mapeado para CPU (`cpu`/`xnnpack` → CPU EP; nunca NNAPI/QNN).
- Threading: `setIntraOpNumThreads(LayaConfig.threads)`; `GraphOptimizationLevel.ortEnableAll`.
- **Fora da UI thread**: `decide()` corre tokenização + montagem de tensores + `run` + decode num
  **Isolate persistente** criado em `load()` (mensagens só com dados simples; a sessão ORT vive no
  worker). Nunca inferência no isolate da UI.
- `run` sincrónico por pergunta dentro do worker (o grafo tem batch estático 1).

### 8.1 Falha de runtime (MatMulNBits em falta)

O caminho esperado é carregar: `MatMulNBits` é contrib-op incluído no AAR oficial
`onnxruntime-android:1.23.2` e no `libonnxruntime.so.1.22.0` do plugin; **verificado neste
trabalho** com `onnxruntime` CPU 1.30 (desktop Linux): o `model_q4.onnx` carrega e infere
normalmente (fixtures §9 produzem logits válidos).

Se em device o runtime **não** carregar o modelo (p.ex. build mínima sem contrib-ops — o sintoma é
o ORT devolver `No such file`/`is not a registered function/op`/`Load model failed` ao criar a
sessão), o comportamento contratado é:

1. `load()` **não rebenta**: regista a mensagem exata do ORT em `_loadError` (o tokenizer carrega na
   mesma — a camada encode/decode fica funcional e testável).
2. `decide()` lança `StateError` com a mensagem exata do ORT empacotada:
   `LayaOnnxEngine: model_q4.onnx não carregou no ONNX Runtime: <erro ORT>`.
3. `isLoaded` fica `false`; `unload()` é seguro.

Este caso não foi observado em desktop (o modelo carrega); a verificação em Android device real
continua obrigatória (doc §15: benchmark interno 2 Android + 1 iPhone).

### 8.2 Riscos conhecidos

- `microsoft/onnxruntime#23004`: `MatMulNBits` int4 ≥10× mais lento que int8 em CPU móvel — medir;
  se confirmado, re-export int8 (falhou no export atual: `ShapeInferenceError`) ou ExecuTorch `.pte`.
- `act_logits` do checkpoint satura (valores ~±4000) ⇒ `act_probability` ≈ 0 ou 1; é esperado.
- `choice:11+` com temperatura clamped para 0.5: >20 opções degradam (doc §3.4) — preferir ≤20.

## 9. Fixtures de verificação (oráculo Python vs Dart)

Reproduzíveis com `python3 + onnxruntime + tokenizers` (pipeline da §3–§7) sobre
`tools/laya_artifact/`. Exemplo (state de ticket, 3 perguntas) — ids da sequência, marcadores,
logits e respostas decodificadas (4 dp, T clamped):

| pergunta | k | T | probs | resposta | confidence | answer_conf | act_prob |
| --- | --- | --- | --- | --- | --- | --- | --- |
| department (choice) | 3 | 1.7602 | 0.8256/0.1030/0.0714 | `billing` | 0.4713 | 0.8256 | 1.0 |
| urgency (noul) | 2 | 1.9834 | 0.2750/0.7250 | `noul=0.7250` | 0.7250 | 0.7250 | 1.0 |
| frustration (score) | 3 | 1.2514 | 0.0127/0.4628/0.5244 | `score=1.5117` | 0.3167 | 0.5244 | 1.0 |

(state: `"Customer: my invoice was charged twice and nobody answers the phone!"`; seq department =
`[50281, 22122, 1953, 27, 6758, 2285, 22139, 436, 32, 50282, 50284, 33484, …]`, markers `[10, 21, 29]`.)
Os 3 exemplos completos (tokens + logits + respostas) foram gerados pelo oráculo e usados para
validar o tokenizer e o decode Dart token-a-token.

### 9.1 Resultado da validação executada (2026-09-27)

- **Tokenizer Dart vs HF `tokenizers` 0.23**: 25/25 casos com ids idênticos (ASCII, acentos PT/ES,
  decompostos NFC, runs de espaços/tabs/newlines, contrações, CJK, added tokens
  `|||EMAIL_ADDRESS|||`, `[MASK]` literal, palavras longas) e 25/25 no `decode` (com
  `skip_special_tokens` como no HF).
- **Engine Dart vs oráculo Python (`onnxruntime` 1.30 CPU) sobre o `model_q4.onnx` real**: 8/8
  perguntas (3 fixtures: choice/noul/score, EN+PT) com `probabilities`, `choice`, `score`, `noul`,
  `confidence`, `answer_confidence`, `act_probability` e `input_tokens` **idênticos** (4 dp). A
  sessão `onnxruntime_v2` (ORT 1.22 desktop, plugin Linux) carregou o artefacto em ~0.8 s — o
  caminho §8.1 não foi acionado. O mesmo teste validou `StateError` em `decide()` sem `load()` e o
  `unload()` limpo. (O teste temporário foi removido depois da verificação; reproduzir com as
  fixtures acima.)
- Corrida via `flutter test` (o pacote `onnxruntime_v2` importa `package:flutter/services.dart`,
  logo o `dart run` puro não chega); em device Android a verificação obrigatória continua por fazer
  (§8.2).
