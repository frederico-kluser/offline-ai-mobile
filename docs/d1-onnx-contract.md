# Contrato de execução do d1-2B / d1-Omni-2B (ONNX)

Extraído do pacote oficial `LiquidAI/d1-2B-ONNX` / `d1-Omni-2B-ONNX`
(`prompt.py`, `slots.py`, `pointer.py`, `box.py`, `grid.py`, `parsing.py`,
`api.py`, `calibration.json`) e verificado no dossiê de pesquisa.

## 1. Prompt (uma linha, batch 1)

```
<|startoftext|><|im_start|>user\n
[<|image|> | <|video|> | <|audio|> ...]
{state}\n\n
QUESTION:\n
{question_block}
<|im_end|>\n<|im_start|>assistant\n
{lead}
[slots...]
```

- **System prompt:** por omissão **não existe** (`DEFAULT_SYSTEM = "none"`).
  A opção `d1` injeta `You are d1, a decision model trained by Liquid AI.`.
- **State block:** JSON com `json.dumps(..., ensure_ascii=False, indent=2)` +
  `\n\n` (ou string + `\n\n`).
- **Question header:** `QUESTION:\n` (vazio se `state=None`).
- **Lead:** vazio no LFM3; o slot implícito de `noul`/`choice`/`score`/`range`
  é o último token do prefixo do assistente.
- **Marcadores explícitos:**
  - `text|number|date`: `\nstart:` e `\nend:`
  - `box`: `\npresent:` + `\ntop:` + `\nbottom:` + `\nleft:` + `\nright:`
  - `boxes`: `present 1:…present N:` + 4 arestas por bloco
  - `choice` múltiplo: `\n{json.dumps(nome_da_opção)}:`
- O slot é o token do **`:` final** do marcador; `slot_positions` é a posição
  plana desse token (o `:` pode partilhar o token com o espaço seguinte, nunca
  com o texto do marcador seguinte).
- `question_ids`: `-1` no state, `k` (1..N) nos tokens da pergunta `k`; até 16
  perguntas (`d1_set_size=16`).

## 2. Tensores de entrada

| Nome | dtype | shape | Notas |
|---|---|---|---|
| `input_ids` | int64 | `[1, seq]` | uma linha, sem padding |
| `attention_mask` | int64 | `[1, seq]` | máscara de set/bidirecional |
| `position_ids` | int64 | `[1, seq]` | posições absolutas |
| `image_features` | float32 | `[num_image_tokens, 2048]` | injetado em `<|image|>` |
| `video_features` | float32 | `[num_video_tokens, 2048]` | injetado em `<|video|>` |
| `audio_features` | float32 | `[num_audio_tokens, 2048]` | **só d1-Omni** |
| `question_ids` | int64 | `[1, seq]` | -1 / k |
| `slot_positions` | int64 | `[num_slots]` | vetor plano |

O decoder d1-2B tem **7 inputs**; o d1-Omni tem **8** (`audio_features`).

## 3. Saídas

| Nome | dtype | shape | Uso |
|---|---|---|---|
| `logits` | float32 | `[num_slots, 128000]` | **log-probabilidades** nos slots |
| `hidden_states` | float32 | `[1, seq, 2048]` | pós final-norm; pointer de spans |

## 4. Plano de slots

| Tipo | Slots | Leitura |
|---|---|---|
| `noul` | 1 implícito | LM head; grupos yes/no |
| `choice` | 1 implícito | LM head; grupos por código A..Z/AA.. |
| `choice` `multiple` | 1 por opção | LM head; um noul por opção |
| `score` | 1 implícito | LM head; grupos por nível 0..k-1 |
| `text` | 2 (`start:`,`end:`) | pointer parameter-free |
| `number` | 2 | pointer + `parse_number` |
| `date` | 2 | pointer + `parse_date` (ISO 8601) |
| `number`+`range` | 1 implícito | grid de 128 bins; mediana + [p10,p90] |
| `box` | 5 (`present:`,4 arestas) | presença + 128/1000 códigos |
| `boxes` | 5 × blocos | presença monotónica; até 16/64 blocos |

### Pointer parameter-free

Para os slots de span, o d1 **não tem pesos de pointer**: usa o produto
interno entre o hidden state do slot e cada hidden state do state:

```
logits = hidden[slot] @ hidden[state].T / sqrt(2048)
softmax sobre as posições válidas do state + BOS0
found  = 1 - exp(logp[0])           # token 0 = "nada"
span   = melhor (start,end) com end-start < 512 (texto) / 32 (number/date)
```

## 5. Pós-processamento categórico

- Nunca se faz softmax sobre as 128 000 classes. Para cada opção, faz-se
  **max-pool** dos logits dos tokens que pertencem ao grupo (ex.: `yes`,
  `Yes`, `YES`; código `A`, ` A`, `A.`; dígito `0`; código de bin `00`), e só
  depois softmax sobre os grupos.
- `noul = p[yes]`.
- `choice = argmax`; `confidence = p[argmax]`; `probabilities` por opção.
- `multiple`: um noul por opção; `choice` se `p >= 0.5`.
- `score`: índice esperado (`mean`) ou nível da massa acumulada >= 0.5
  (`median`, predefinição), com legenda.
- `range`: grid `low..high`, 128 bins; `number = mediana`,
  `interval = [p10, p90]`.
- `box`: `found` se presença >= 0.5; arestas pela mediana dos 128/1000
  códigos; `confidence` pela fração de amostras Halton com IoU >= 0.5.
- `boxes`: presença do bloco `k` = P(count >= k), forçada monotónica; para no
  primeiro bloco < 0.5; `count = len(boxes)`.
- Calibração: `calibration.json` (temperatura default ~1.337 no d1-2B;
  tabelas `multiple`, `estimate`, `found:box`, `found:boxes`).

## 6. Pré-processamento de mídia

- **Imagem:** patch 16, merge 2, temporal patch 2; rescale `1/255`, mean/std
  0.5; layout `[grid_h_blocks, grid_w_blocks, 2, 2, 1536]` (1536 = 3 × 16 ×
  16 × 2). O encoder devolve `[num_image_tokens, 2048]`.
- **Vídeo:** 2 fps, min 4 frames, max 768 (d1-2B) / 384 (Omni), máx. 768
  tokens; frames emparelhados 2 a 2.
- **Áudio (Omni):** 16 kHz, `n_fft=400`, `hop=160`, `win=400`, 128 mel,
  `log_floor=-12`, normalização `(x/4)+4`; input `[1,128,num_frames]`,
  stride 8.
- Tokens especiais: `<|image|>`, `<|video|>`, `<|audio|>`, `<|audio_out|>`,
  `<|vision_start|>`, `<|vision_end|>`.

## 7. Runtime

- IR version 10, opsets `ai.onnx:21` e `com.microsoft:1`.
- Contrib ops: `MatMulNBits` (int4), `SimplifiedLayerNormalization`,
  `RotaryEmbedding`, `MultiHeadAttention`.
- Os sidecars `.onnx_data*` têm de ficar ao lado do `.onnx` com o nome exato.
- CPU móvel: `decoder_q4 + vision_encoder_q8` = 1,94 GB (d1-2B) / 2,45 GB
  (d1-Omni com `audio_encoder`).

## 8. Limitações desta implementação

- O prompt builder e o decoder categórico/pointer estão implementados e
  testados com logits sintéticos.
- Imagem e áudio estão ligados ao `image_features`/`audio_features`:
  `d1_vision.dart` gera `pixel_values` `[grid_h,grid_w,2,2,1536]` e
  `d1_audio.dart` gera o log-mel oficial `[1,128,frames]` (FFT 400,
  hop 160, 128 mel Slaney, `(log10+4)/4`). Vídeo continua a exigir o
  processor temporal e devolve erro explícito.
- A via GGUF do llama.cpp só faz `noul`/`choice`/`score`.
