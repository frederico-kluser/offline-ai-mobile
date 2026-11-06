# Modelos LFM3 + d1 — guia definitivo

Este documento explica **o que é cada modelo**, **para que serve**, **como o usar na app**, **que bundle
instalar** e **onde o descarregar**. É a referência dos modelos da versão definitiva do projeto
(`main` = `9ce4da7`).

> **Regra de ouro:** o modelo não vem no git nem no APK. A app descarrega o bundle para a pasta privada,
> verifica o SHA-256 e instala atomicamente. O espelho GitHub serve os GGUF/mmproj; os grafos ONNX do d1
> vêm do Hugging Face oficial (a app faz fallback automático).

## 1. Visão geral

| Família | Parâmetros | Motor | Para que serve | Bundle na app |
|---|---:|---|---|---|
| **LFM3-1.7B** | 1,7 B | llama.cpp + libmtmd | texto, raciocínio `<think>`, agente, tool calling, JSON | `lfm3-1.7b-q4_0` (essencial), `q4_k_m`, `q8_0` |
| **LFM3-VL-2B** | 2 B | llama.cpp + libmtmd | imagem, OCR, pointing/grounding, vídeo a 2 fps | `lfm3-vl-2b-q4_k_m` |
| **LFM3-Audio-2B** | 2 B | llama.cpp + libmtmd | ASR, LiveASR, TTS 24 kHz, voz-texto entrelaçado | `lfm3-audio-2b-q4_k_m` |
| **LFM3-Omni-2B** | 2 B | llama.cpp + libmtmd | texto + imagem + vídeo com banda sonora + áudio | `lfm3-omni-2b-q4_k_m` |
| **d1-2B** | 2 B | llama.cpp (GGUF) / ONNX Runtime | decisor tipado de 10 primitivas, sem gerar texto | `d1-2b-q4_k_m` (parcial) / `d1-2b-onnx-q4` (completo) |
| **d1-Omni-2B** | 2 B | llama.cpp / ONNX Runtime | d1 com áudio e perguntas faladas | `d1-omni-2b-q8_0` (parcial) / `d1-omni-2b-onnx-q4` (completo) |
| **d1-omni-600M** | 600 M | llama.cpp | fallback de baixa RAM; **LFM2 legado**, não LFM3 | `d1-omni-600m-legacy-q8_0` |

**Regra prática:** para *gerar* texto usa LFM3; para *decidir* sem gerar usa d1.

## 2. Como instalar e usar na app

1. Abre **Modelos LFM3** e vê o perfilador de hardware (Tier 1/2/3, RAM, disco, dotprod/i8mm).
2. Instala primeiro o **LFM3-1.7B QAD-Q4_0** (1,05 GB) — é o modelo de texto/agente.
3. Instala o modelo da modalidade que precisas:
   - imagem/vídeo → **LFM3-VL-2B**;
   - áudio/ASR → **LFM3-Audio-2B**;
   - tudo, incluindo vídeo com som → **LFM3-Omni-2B**;
   - decisões → **d1-2B-ONNX q4** (todas as primitivas) e **d1-Omni-2B-ONNX q4** se houver áudio.
4. Em **Prompts · LFM3**, escreve o prompt e anexa ficheiros. A app escolhe o modelo instalado compatível
   com os anexos; podes sempre fixar o modelo no seletor.
5. Em **Decisões d1**, escolhe o template, preenche o `state`, adiciona perguntas (e anexos, se aplicável)
   e executa. As respostas são tipadas, com probabilidades, spans e caixas.

> A app nunca descarrega pesos sem pedires. O download tem progresso, retoma com HTTP `Range`, verifica
> o SHA-256 e só depois renomeia o `.part` para o ficheiro final.

## 3. LFM3-1.7B — texto, raciocínio e agente

### O que é
Modelo de linguagem **LFM3** de 1,7 mil milhões de parâmetros, com arquitetura **tri-híbrida**:
24 camadas = 13 convoluções curtas (kernel 7) + 5 atenções de janela deslizante (256) + 6 atenções
globais. Só as 6 globais fazem crescer o KV cache: **12,29 KB/token** em F16 e **6,53 KB/token** em
Q8_0. Contexto configurado na app: 8 192 tokens por omissão, até 32 768 em mobile (os metadados do
checkpoint anunciam 262 144).

### Para que serve
- conversa e instruções em português/inglês;
- raciocínio separado em `<think>` (com teto `maxThinkingTokens`);
- **tool calling** com o formato XML do LFM3 e **Deferred Tool Search**
  (`search_tools` → `<additional_tools>`);
- respostas JSON com schema, agente, matemática/STEM e benchmarks de prompt.

### Como usar
- **Prompts**: perfil `Agente / tools` (temperatura 0.1, top_k 50, top_p 1.0, min_p 0, repeat 1.1);
  ativa/desativa `thinking`; o texto do raciocínio aparece separado.
- **LLM + Tools**: o agente recebe 50+ ferramentas deferidas; a timeline mostra chamadas, resultados e
  cortes do LoopGuard.
- **Browser**: o agente LFM3 é o "System Two" do browser (tool calls `browser_*`).
- Para matemática usa o perfil `Matemática / STEM` (temperatura 1.0, top_k 20, top_p 0.95).

### Bundles e downloads

| Bundle | Ficheiro | Tamanho | RAM/tier | Download |
|---|---|---:|---|---|
| `lfm3-1.7b-q4_0` | `LFM3-1.7B-QAD-Q4_0.gguf` | 1,05 GB | ~1,35 GB · Tier 1 | [espelho](https://github.com/frederico-kluser/lfm3-mobile-models/releases/download/models-lfm3-suite-v1/LFM3-1.7B-QAD-Q4_0.gguf) · [HF](https://huggingface.co/LiquidAI/LFM3-1.7B-GGUF/resolve/main/LFM3-1.7B-QAD-Q4_0.gguf?download=true) |
| `lfm3-1.7b-q4_k_m` | `LFM3-1.7B-Q4_K_M.gguf` | 1,10 GB | ~1,40 GB · Tier 1 | [espelho](https://github.com/frederico-kluser/lfm3-mobile-models/releases/download/models-lfm3-suite-v1/LFM3-1.7B-Q4_K_M.gguf) · [HF](https://huggingface.co/LiquidAI/LFM3-1.7B-GGUF/resolve/main/LFM3-1.7B-Q4_K_M.gguf?download=true) |
| `lfm3-1.7b-q8_0` | `LFM3-1.7B-Q8_0.gguf` | 1,85 GB | ~2,40 GB · Tier 3 | [espelho](https://github.com/frederico-kluser/lfm3-mobile-models/releases/download/models-lfm3-suite-v1/LFM3-1.7B-Q8_0.gguf) · [HF](https://huggingface.co/LiquidAI/LFM3-1.7B-GGUF/resolve/main/LFM3-1.7B-Q8_0.gguf?download=true) |

**SHA-256:** QAD-Q4_0 `43a7d09a…a7452` · Q4_K_M `3793e1e6…c93c4` · Q8_0 `8f6b2418…20b6`
(completos no `manifest.json` e no `SHA256SUMS.txt`).

**Notas:** QAD = Quantization-Aware Distillation; a receita de agente é temperatura 0.1, top_k 50,
top_p 1.0, min_p 0 e repeat 1.1. Se tiveres 8 GB+, o Q8_0 dá mais qualidade; o QAD-Q4_0 é o melhor
rácio qualidade/RAM.

## 4. LFM3-VL-2B — visão, OCR, grounding e vídeo

### O que é
Modelo **vision-language** LFM3 de 2 B, com um `mmproj` (projetor `lfm3vl`) que liga o encoder visual ao
LLM. Recebe imagens e vídeo a **2 fps**; o template de vídeo agrupa pares de frames e antecipa cada par
com `<X.X seconds>`. Contexto por omissão 16 384; `image_max_tokens` 1024.

### Para que serve
- descrever imagens, OCR e leitura de tabelas/documentos;
- **pointing/grounding**: coordenadas normalizadas `point_2d`/`bbox_2d` em `[0,1000]`;
- vídeo de curta duração a 2 fps;
- base visual para o modo `Omni` quando precisas de som.

A UI atual desenha caixas do **d1** sobre a imagem; o VL devolve as coordenadas no texto, mas ainda não
há overlay automático para `point_2d`/`bbox_2d` do VL.

### Como usar
- **Prompts**: escolhe o perfil `Visão / vídeo`; anexa uma imagem (PNG/JPEG) ou um vídeo (MP4).
- Templates CT-03 (OCR/pointing) e CT-04 (vídeo 2 fps) mostram o formato esperado.
- A app pré-processa a imagem para lados múltiplos de 32, limita o lado maior a 1024 px e passa o
  `mmproj` ao `libmtmd`.
- O vídeo é extraído a 2 fps pelo canal nativo; a app envia os frames como bitmaps `mergeable`/`is_video`.

### Bundle e downloads

| Ficheiro | Tamanho | Download |
|---|---:|---|
| `LFM3-VL-2B-Q4_K_M.gguf` | 1,10 GB | [espelho](https://github.com/frederico-kluser/lfm3-mobile-models/releases/download/models-lfm3-suite-v1/LFM3-VL-2B-Q4_K_M.gguf) · [HF](https://huggingface.co/LiquidAI/LFM3-VL-2B-GGUF/resolve/main/LFM3-VL-2B-Q4_K_M.gguf?download=true) |
| `mmproj-LFM3-VL-2B-Q8_0.gguf` | 203 MB | [espelho](https://github.com/frederico-kluser/lfm3-mobile-models/releases/download/models-lfm3-suite-v1/mmproj-LFM3-VL-2B-Q8_0.gguf) · [HF](https://huggingface.co/LiquidAI/LFM3-VL-2B-GGUF/resolve/main/mmproj-LFM3-VL-2B-Q8_0.gguf?download=true) |

**Bundle:** `lfm3-vl-2b-q4_k_m` (1,30 GB, ~1,80 GB RAM, Tier 2). **SHA-256:**
`56dac2e1…f21eb` (pesos) + `c5c5b58d…918ab` (mmproj).

## 5. LFM3-Audio-2B — ASR, voz e TTS

### O que é
Modelo **áudio-texto** LFM3 de 2 B com projetor `lfm3a`. Entrada **16 kHz mono**; saída de fala
**LiquidCodec a 24 kHz**. Suporta ASR, LiveASR (streaming), TTS e conversação voz-texto entrelaçada.

### Para que serve
- transcrever áudio (WAV 16 kHz) e responder sobre o que foi dito;
- **spoken tools**: o utilizador fala e o modelo chama ferramentas;
- gerar fala (TTS) e voz entrelaçada com texto.

### Como usar
- **Prompts**: perfil `Áudio ASR (texto)` para transcrição/resposta; perfil `Áudio TTS / voz` para
  fala. Anexa um WAV PCM16 mono 16 kHz.
- O perfil ASR usa temperatura 0, `suppressMixed` e `suppressAudioOut` para não misturar fala na
  resposta; o TTS pré-preenche `<|audio_start|>`.
- O `GenEnd.audioSamples` reporta as amostras PCM de 24 kHz produzidas pelo LiquidCodec; a UI atual
  mostra essa métrica, mas **não reproduz o áudio** (ver limitações).
- **CT-05** cobre ASR, TTS, spoken tools e WAV de 16 kHz.

### Bundle e downloads

| Ficheiro | Tamanho | Download |
|---|---:|---|
| `LFM3-Audio-2B-Q4_K_M.gguf` | 1,10 GB | [espelho](https://github.com/frederico-kluser/lfm3-mobile-models/releases/download/models-lfm3-suite-v1/LFM3-Audio-2B-Q4_K_M.gguf) · [HF](https://huggingface.co/LiquidAI/LFM3-Audio-2B-GGUF/resolve/main/LFM3-Audio-2B-Q4_K_M.gguf?download=true) |
| `mmproj-LFM3-Audio-2B-Q8_0.gguf` | 304 MB | [espelho](https://github.com/frederico-kluser/lfm3-mobile-models/releases/download/models-lfm3-suite-v1/mmproj-LFM3-Audio-2B-Q8_0.gguf) · [HF](https://huggingface.co/LiquidAI/LFM3-Audio-2B-GGUF/resolve/main/mmproj-LFM3-Audio-2B-Q8_0.gguf?download=true) |

**Bundle:** `lfm3-audio-2b-q4_k_m` (1,40 GB, ~2,0 GB RAM, Tier 2). **SHA-256:**
`9a773289…25be2` + `2b6648b1…0e365`.

## 6. LFM3-Omni-2B — tudo, incluindo vídeo com som

### O que é
Modelo **omni-modal** LFM3 de 2 B que combina texto, imagem, áudio e **vídeo com banda sonora**. Não tem
modo `<think>`. O template `MTMD_VIDEO_TEMPLATE_LFM3_OMNI` intercala o segmento da banda sonora após
cada par de frames. Contexto 16 384; áudio 16 kHz; vídeo 2 fps.

### Para que serve
- descrever um vídeo e o som em conjunto;
- perguntas sobre imagem + áudio + texto no mesmo pedido;
- casos em que o VL ou o Audio sozinhos não chegam.

### Como usar
- **Prompts**: perfil `Omni-modal`; anexa vídeo (MP4 com áudio) ou imagem/áudio.
- O canal nativo extrai frames a 2 fps **e** a banda sonora para WAV 16 kHz; o motor passa os frames e
  o áudio ao `libmtmd`.
- Sem `thinking`; a app valida e desativa se tentares ativar.
- Validação real: clipe de 2 s com tom → `"Um som de sinto de um sino."` (iOS 1,2 s; Android 293 s no
  emulador x86_64).

### Bundle e downloads

| Ficheiro | Tamanho | Download |
|---|---:|---|
| `LFM3-Omni-2B-Q4_K_M.gguf` | 1,10 GB | [espelho](https://github.com/frederico-kluser/lfm3-mobile-models/releases/download/models-lfm3-suite-v1/LFM3-Omni-2B-Q4_K_M.gguf) · [HF](https://huggingface.co/LiquidAI/LFM3-Omni-2B-GGUF/resolve/main/LFM3-Omni-2B-Q4_K_M.gguf?download=true) |
| `mmproj-LFM3-Omni-2B-Q4_K_M.gguf` | 292 MB | [espelho](https://github.com/frederico-kluser/lfm3-mobile-models/releases/download/models-lfm3-suite-v1/mmproj-LFM3-Omni-2B-Q4_K_M.gguf) · [HF](https://huggingface.co/LiquidAI/LFM3-Omni-2B-GGUF/resolve/main/mmproj-LFM3-Omni-2B-Q4_K_M.gguf?download=true) |

**Bundle:** `lfm3-omni-2b-q4_k_m` (1,39 GB, ~1,95 GB RAM, Tier 2). **SHA-256:**
`9f8d30e9…893e2` + `0a746c07…7a39a`.

## 7. d1-2B — decisor tipado, sem gerar texto

### O que é
Modelo **System One** de 2 B, vocabulário 128 000, hidden 2 048. Recebe uma sequência ChatML com
`question_ids` e `slot_positions` e devolve `logits [slots,128000]` + `hidden_states [1,seq,2048]`.
A resposta é lida dos slots — **0 tokens gerados**. Um forward pass pode empacotar até 16 perguntas.

### As 10 primitivas
| Primitiva | Resposta |
|---|---|
| `noul` | P(true) calibrada |
| `choice` | opção escolhida |
| `multiple` | P(yes) por opção (flag de `choice`) |
| `score` | nível esperado |
| `textSpan` | excerto de texto (pointer parameter-free) |
| `numberSpan` | número + unidade |
| `dateSpan` | data ISO |
| `numberRange` | mediana + p10/p90 em 128 bins (flag de `number`) |
| `box` | presença + caixa normalizada |
| `boxes` | até N caixas |

### Como usar
- **Decisões d1**: escolhe o template CT-07/CT-11, preenche o `state` (texto/JSON), adiciona perguntas,
  anexa **uma** imagem se usares `box`/`boxes`, e executa.
- O d1-2B ONNX aceita imagem/vídeo; áudio só no d1-Omni.
- Para `range`, o `number` devolve a mediana e os percentis; para `multiple`, há uma probabilidade por
  opção.
- **Nunca** uses d1 para conversa: ele não gera texto.

### GGUF vs ONNX
| Via | Primitivas | Estado |
|---|---|---|
| `d1-2b-q4_k_m` (GGUF) + mmproj Q8 | `noul`, `choice`, `score` via `/v1/systemone` | **não executável** nesta build: a API C do llama.cpp b12088 não expõe `systemone`; o motor devolve erro explícito |
| `d1-2b-onnx-q4` (q4 + vision q8) | **todas as 10** | **suportado e validado** |

### Bundle ONNX e downloads
`d1-2b-onnx-q4` = 1,96 GB, ~2,4 GB RAM, Tier 3. Ficheiros do HF
[`LiquidAI/d1-2B-ONNX`](https://huggingface.co/LiquidAI/d1-2B-ONNX/tree/main/onnx):

| Ficheiro | Tamanho | Download |
|---|---:|---|
| `onnx/decoder_q4.onnx` | 359 KB | [HF](https://huggingface.co/LiquidAI/d1-2B-ONNX/resolve/main/onnx/decoder_q4.onnx?download=true) |
| `onnx/decoder_q4.onnx_data` | 1,74 GB | [HF](https://huggingface.co/LiquidAI/d1-2B-ONNX/resolve/main/onnx/decoder_q4.onnx_data?download=true) |
| `onnx/vision_encoder_q8.onnx` | 126 KB | [HF](https://huggingface.co/LiquidAI/d1-2B-ONNX/resolve/main/onnx/vision_encoder_q8.onnx?download=true) |
| `onnx/vision_encoder_q8.onnx_data` | 196 MB | [HF](https://huggingface.co/LiquidAI/d1-2B-ONNX/resolve/main/onnx/vision_encoder_q8.onnx_data?download=true) |
| `tokenizer.json` | 17,9 MB | [HF](https://huggingface.co/LiquidAI/d1-2B-ONNX/resolve/main/tokenizer.json?download=true) |
| `processor_config.json` | 1,3 KB | [HF](https://huggingface.co/LiquidAI/d1-2B-ONNX/resolve/main/processor_config.json?download=true) |
| `chat_template.jinja` | 12,8 KB | [HF](https://huggingface.co/LiquidAI/d1-2B-ONNX/resolve/main/chat_template.jinja?download=true) |
| `config.json` | 2,9 KB | [HF](https://huggingface.co/LiquidAI/d1-2B-ONNX/resolve/main/config.json?download=true) |

**SHA-256:** decoder `00b77894…4065f`, dados `e72031f1…5b14b`, vision q8 `ea9421f2…1caac`,
sidecar `baff3c8c…2d1d`.

### GGUF (fallback documentado)
- `d1-2B-Q4_K_M.gguf` 1,10 GB + `mmproj-d1-2B-Q8_0.gguf` 203 MB
- [espelho pesos](https://github.com/frederico-kluser/lfm3-mobile-models/releases/download/models-lfm3-suite-v1/d1-2B-Q4_K_M.gguf) ·
  [espelho mmproj](https://github.com/frederico-kluser/lfm3-mobile-models/releases/download/models-lfm3-suite-v1/mmproj-d1-2B-Q8_0.gguf)
- HF: [`LiquidAI/d1-2B-GGUF`](https://huggingface.co/LiquidAI/d1-2B-GGUF)

## 8. d1-Omni-2B — d1 com áudio e voz

### O que é
d1 de 2 B com **audio encoder** e um decoder de 8 inputs. Aceita as 10 primitivas e, além disso,
perguntas faladas e áudio no `state`. O áudio é 16 kHz mono; o log-mel é `[1,128,frames]`
(FFT 400, hop 160, 128 mel Slaney, `(log10 + 4) / 4`).

### Para que serve
- triagem de chamadas/voz com decisões tipadas;
- extrair dados de uma conversa falada (números, datas, spans, escolhas);
- anexar áudio a uma pergunta d1 sem passar por um LLM gerador.

### Como usar
- **Decisões d1**: escolhe `d1-omni-2b-onnx-q4`, anexa um WAV 16 kHz e faz perguntas `noul`/`choice`/
  spans. O template CT-10 é o exemplo de triagem de voz.
- Áudio de vídeo? O d1 usa os **frames** para `video_features`; a banda sonora não entra no d1 (essa
  via é do LFM3-Omni).
- Validado: pergunta falada `noul` com 70 tokens de prompt, 1 668 ms.

### Bundle ONNX e downloads
`d1-omni-2b-onnx-q4` = 2,21 GB, ~2,65 GB RAM, Tier 3. HF
[`LiquidAI/d1-Omni-2B-ONNX`](https://huggingface.co/LiquidAI/d1-Omni-2B-ONNX/tree/main/onnx):

| Ficheiro | Tamanho | Download |
|---|---:|---|
| `onnx/decoder_q4.onnx` | 361 KB | [HF](https://huggingface.co/LiquidAI/d1-Omni-2B-ONNX/resolve/main/onnx/decoder_q4.onnx?download=true) |
| `onnx/decoder_q4.onnx_data` | 1,74 GB | [HF](https://huggingface.co/LiquidAI/d1-Omni-2B-ONNX/resolve/main/onnx/decoder_q4.onnx_data?download=true) |
| `onnx/vision_encoder_q8.onnx` | 126 KB | [HF](https://huggingface.co/LiquidAI/d1-Omni-2B-ONNX/resolve/main/onnx/vision_encoder_q8.onnx?download=true) |
| `onnx/vision_encoder_q8.onnx_data` | 196 MB | [HF](https://huggingface.co/LiquidAI/d1-Omni-2B-ONNX/resolve/main/onnx/vision_encoder_q8.onnx_data?download=true) |
| `onnx/audio_encoder_fp16.onnx` | 163 KB | [HF](https://huggingface.co/LiquidAI/d1-Omni-2B-ONNX/resolve/main/onnx/audio_encoder_fp16.onnx?download=true) |
| `onnx/audio_encoder_fp16.onnx_data` | 255 MB | [HF](https://huggingface.co/LiquidAI/d1-Omni-2B-ONNX/resolve/main/onnx/audio_encoder_fp16.onnx_data?download=true) |
| `tokenizer.json` | 17,9 MB | [HF](https://huggingface.co/LiquidAI/d1-Omni-2B-ONNX/resolve/main/tokenizer.json?download=true) |
| `processor_config.json` | 1,9 KB | [HF](https://huggingface.co/LiquidAI/d1-Omni-2B-ONNX/resolve/main/processor_config.json?download=true) |
| `chat_template.jinja` | 13,4 KB | [HF](https://huggingface.co/LiquidAI/d1-Omni-2B-ONNX/resolve/main/chat_template.jinja?download=true) |
| `config.json` | 5,8 KB | [HF](https://huggingface.co/LiquidAI/d1-Omni-2B-ONNX/resolve/main/config.json?download=true) |

### GGUF (fallback documentado)
- `d1-Omni-2B-Q8_0.gguf` 1,85 GB + `mmproj-d1-Omni-2B-Q8_0.gguf` 326 MB
- [espelho pesos](https://github.com/frederico-kluser/lfm3-mobile-models/releases/download/models-lfm3-suite-v1/d1-Omni-2B-Q8_0.gguf) ·
  [espelho mmproj](https://github.com/frederico-kluser/lfm3-mobile-models/releases/download/models-lfm3-suite-v1/mmproj-d1-Omni-2B-Q8_0.gguf)
- HF: [`LiquidAI/d1-Omni-2B-GGUF`](https://huggingface.co/LiquidAI/d1-Omni-2B-GGUF)

## 9. d1-omni-600M — fallback LFM2 legado

- **Não é LFM3**: o GGUF declara `architecture=lfm2`; foi lançado com a família d1-3B.
- 600 M, Q8_0 407 MB + mmproj 263 MB; ~1,1 GB RAM; Tier 1.
- Serve apenas de **fallback de baixa RAM**; não emparelha com a suíte LFM3.
- [espelho pesos](https://github.com/frederico-kluser/lfm3-mobile-models/releases/download/models-lfm3-suite-v1/d1-omni-600M-Q8_0.gguf) ·
  [espelho mmproj](https://github.com/frederico-kluser/lfm3-mobile-models/releases/download/models-lfm3-suite-v1/mmproj-d1-omni-600M-Q8_0.gguf)
- HF: [`LiquidAI/d1-omni-600M-GGUF`](https://huggingface.co/LiquidAI/d1-omni-600M-GGUF)

## 10. Descarregar fora da app

### GGUF/mmproj (espelho)
```bash
base=https://github.com/frederico-kluser/lfm3-mobile-models/releases/download/models-lfm3-suite-v1
curl -L --fail -o LFM3-1.7B-QAD-Q4_0.gguf "$base/LFM3-1.7B-QAD-Q4_0.gguf"
shasum -a 256 LFM3-1.7B-QAD-Q4_0.gguf
# 43a7d09a0e9cba91b63eb7052488b9564569bddfd65754d2e426465e572a7452
```
### ONNX (Hugging Face)
```bash
base=https://huggingface.co/LiquidAI/d1-2B-ONNX/resolve/main
curl -L --fail -o decoder_q4.onnx "$base/onnx/decoder_q4.onnx"
curl -L --fail -o decoder_q4.onnx_data "$base/onnx/decoder_q4.onnx_data"
# o sidecar tem de ficar ao lado do .onnx com o nome exato
```
O `SHA256SUMS.txt` do release tem as somas de todos os ficheiros conhecidos; o `manifest.json` tem
tamanho, SHA, origem e papel de cada ficheiro.

## 11. Escolher por hardware

| RAM livre | Tier | Modelos recomendados |
|---:|---|---|
| 4 GB | 1 | LFM3-1.7B QAD-Q4_0 (texto); d1-omni-600M legado |
| 6 GB | 2 | + LFM3-VL-2B, LFM3-Audio-2B, LFM3-Omni-2B, d1-2B GGUF |
| 8 GB+ | 3 | + LFM3-1.7B Q8_0, d1-2B-ONNX q4, d1-Omni-2B-ONNX q4 |

O perfilador mede RAM/disco, `asimddp`/`i8mm`, GPU e núcleos de performance; o micro-benchmark mede
prefill/decode e ajusta o contexto. Em iOS Simulator e em x86_64 os números não representam um telefone
arm64.

## 12. Licença

Código da app: **MIT**. Pesos: **LFM Open License v1.0** (Apache-2.0-like, com patentes). O §5 limita o
uso comercial a organizações cujo grupo tenha receita anual **< 10 000 000 USD**; acima disso é
necessária licença comercial da Liquid AI. Texto integral:
[LICENSE no HF](https://huggingface.co/LiquidAI/LFM3-1.7B/blob/main/LICENSE) ·
[LICENSE no espelho](https://github.com/frederico-kluser/lfm3-mobile-models/blob/main/LICENSE).
