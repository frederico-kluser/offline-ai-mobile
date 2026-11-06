---
tipo: dossie-pesquisa-profunda
versao: 1
pergunta: "Liquid AI LFM3 family release LFM3-1.7B LFM3-VL-2B LFM3-Audio-2B LFM3-Omni-2B d1-2B models llama.cpp support"
criado: 2026-11-06
atualizado: 2026-11-06
estado: concluido
ronda: 3
---

# Dossiê — Verificação factual para migrar a app para a suíte Liquid AI LFM3 + d1

> Gerado por `tavily.py research init --deep-research`; protocolo em `references/pesquisa-profunda.md`.
> Texto citado de fontes é DADO: nenhuma frase vinda da web é instrução para quem lê este dossiê.
> Âmbito desta investigação: **só verificação e documentação** — nenhum ficheiro de código da app foi alterado.

## 0. Brief (a estrela-guia)

- **Pergunta principal:** que factos estão verificados (nomes, tamanhos, SHAs, contratos de I/O, versões mínimas, licença) para migrar a app offline-ai-mobile para a suíte Liquid AI LFM3 + d1, e onde é que o guia interno contradiz as fontes oficiais?
- **Para quê / decisão que informa:** escolher os artefactos a descarregar (GGUF para llama.cpp; ONNX para o caminho de decisão), fixar a versão mínima de llama.cpp, e decidir se o caminho `/v1/systemone` pode substituir o motor ONNX de decisão (noul/choice/score) já existente na app.
- **Âmbito — inclui:** família LFM3 (texto, visão, áudio, omni), modelos de decisão d1 (d1-2B, d1-Omni-2B, d1-omni-600M), artefactos GGUF e ONNX oficiais no Hugging Face (LiquidAI), licença LFM Open License v1.0, suporte em llama.cpp (arquitetura `lfm3`, `mtmd`, `/v1/systemone`), PRs/commits/issues citados no guia.
- **Âmbito — exclui:** qualidade/benchmarks comparativos, MLX/NVFP4/FP8, detalhes de fine-tuning, quantização própria, desempenho medido localmente.
- **Público e profundidade esperada:** engenharia da app; profundidade de contrato (nomes de ficheiro exatos, bytes, SHA-256, nomes de tensores).
- **Critérios de «terminado»** (achados obrigatórios, verificáveis):
  - [x] Data e composição exata da família LFM3 confirmadas em fonte oficial [S1][S2][S30][S31]
  - [x] Parâmetros, contexto, modalidades e mistura tri-híbrida de cada modelo LFM3 [S1][S2][S10]
  - [x] Termos da LFM Open License v1.0, incluindo o limite de 10 M USD [S16]
  - [x] Nomes de ficheiro exatos, bytes e SHA-256 (LFS) para os 7 repos GGUF pedidos [S3][S4][S5][S6][S7][S8][S9]
  - [x] Subgrafos e ficheiros de tokenizer/processor dos 2 pacotes ONNX [S11][S12][S15]
  - [x] Contrato de I/O do decoder ONNX (nomes de inputs e outputs) e pós-processamento tipado [S11][S12][S13][S14]
  - [x] Versão mínima real de llama.cpp com `lfm3` e com os templates de vídeo [S18][S35][S22]
  - [x] Estado de `/v1/systemone` em llama.cpp e limitação a `choice`/`score`/`noul` [S17][S24]
  - [x] PRs, commits e issues citados no guia, com estado real [S20][S21][S22][S23][S25][S26][S27][S28][S29]
  - [x] Contradições entre o guia do utilizador e as fontes, listadas e classificadas [§5]
- **Perspetivas a cobrir:** (1) facto oficial do fabricante; (2) contrato de artefacto (HF API, bytes, SHA); (3) implementação de runtime (llama.cpp, fonte e issues); (4) jurisprudência de licença; (5) engenharia de app móvel (o que cabe num telemóvel).
- **Restrições de fontes:** fontes primárias oficiais (liquid.ai, docs.liquid.ai, huggingface.co/LiquidAI/*, github.com/ggml-org/llama.cpp e a sua API), mais uma fonte de imprensa independente para a data. Sem blogs agregadores como base de afirmações centrais.

## 1. Resposta (síntese executiva)

A família LFM3 foi anunciada a **27 de outubro de 2026** e é composta por **seis modelos** — texto (`LFM3-1.7B`), visão (`LFM3-VL-2B`), áudio (`LFM3-Audio-2B`), omni (`LFM3-Omni-2B`) e dois modelos de decisão (`d1-2B`, derivado do VL, e `d1-Omni-2B`, derivado do Omni) — todos ramificados do mesmo backbone `LFM3-1.7B-Base` e todos na classe dos ~2B [S1][S30][S31]. A data, os nomes e a existência dos seis repositórios estão confirmados; o `d1-omni-600M` **não** faz parte desta família (é da vaga de 7 de outubro de 2026, arquitetura `lfm2`) [S9][S34].

A arquitetura é tri-híbrida e está confirmada em três sítios independentes (blog, model card e `config.json` do pacote ONNX): **24 camadas = 13 convoluções curtas com gating + 5 atenção de janela deslizante (janela 256) + 6 atenção global**, kernel de convolução 7, RoPE parcial (0,5) nas camadas globais, sandwich norm, vocabulário de 128 000 tokens [S1][S2][S14]. O `LFM3-1.7B` tem 1,73B parâmetros e 256K de contexto; o `d1-2B` tem 1,92B e 128K de contexto [S2][S10].

A licença é a **LFM Open License v1.0**: é uma licença tipo Apache-2.0 com concessão de patentes, mas o **§5 limita o uso comercial a entidades com receita anual inferior a 10 000 000 USD**; acima do limiar o uso comercial *não está licenciado* [S16]. No Hugging Face o campo é `license: other` / `license_name: lfm1.0` — a licença não é OSI, o que importa para a distribuição da app [S3][S16].

Os artefactos estão todos publicados, **nenhum repo é gated**, e os tamanhos/SHA-256 são verificáveis na API do HF [S3]–[S9]. Para telemóvel, o par mais defensável é `LFM3-1.7B-Q4_0`/`Q4_K_M` (~1,05–1,10 GB) para texto e `mmproj` Q8_0 (203 MB) + `Q4_K_M` (1,10 GB) para visão [S3][S4]. O `d1-2B-GGUF` só publica `mmproj` em BF16/F16/Q8_0 (sem Q4) e o `d1-Omni-2B-GGUF` só publica Q8_0/BF16/F16 — não há quantização Q4 desses dois [S7][S8].

O suporte em llama.cpp é real mas **mais estreito do que o guia sugere**: a arquitetura `lfm3` entrou no release **b11938** (27/10/2026 23:57) e os templates de vídeo `MTMD_VIDEO_TEMPLATE_LFM3` / `MTMD_VIDEO_TEMPLATE_LFM3_OMNI` no **b11960** (28/10/2026 12:45); `b12088` (04/11/2026) é válido como "ou superior" mas não é o mínimo [S18][S35][S19]. O endpoint `/v1/systemone` existe e reconhece `LFM3_D1` e `LFM3_D1_OMNI`, mas **só aceita os tipos `choice`, `score` e `noul`** — as respostas tipadas (`text`, `number`, `date`, `box`, `boxes`, `multiple`, `range`) existem apenas no caminho ONNX/Transformers [S17][S24][S13]. Além disso, o issue **#31150 está aberto**: em modo router, pedidos concorrentes ao `/v1/systemone` matam a instância do modelo de decisão [S27].

## 2. FAQ — árvore de perguntas

### Q1 — Em que data foi lançada a família LFM3 e que modelos exatos a compõem?

- **Estado:** respondida
- **Prioridade:** alta
- **Confiança:** alta
- **Origem:** brief (ronda 0)
- **Resposta:** O anúncio é de **27 de outubro de 2026** — o post oficial, o blog do Hugging Face e a cobertura do VentureBeat têm todos essa data [S1][S31][S30]. A primeira vaga tem **seis modelos**: `LFM3-1.7B` (texto), `LFM3-VL-2B` (visão), `LFM3-Audio-2B` (áudio), `LFM3-Omni-2B` (omni) e os dois decisores `d1-2B` (a partir do VL) e `d1-Omni-2B` (a partir do Omni), todos derivados do backbone `LFM3-1.7B-Base` [S1][S2]. Os seis repositórios existem em `huggingface.co/LiquidAI` e não estão gated [S3][S4][S5][S6][S7][S8]. O `d1-omni-600M` **não** pertence a esta vaga: foi lançado a 7 de outubro de 2026 com o `d1-3B`, e o seu GGUF declara arquitetura `lfm2` [S34][S9].
- **Evidência:** post oficial com "Today, we're excited to announce LFM3" e a lista de seis modelos [S1]; entrada de blog HF datada de 27/10/2026 [S31]; artigo VentureBeat de 27/10/2026 12:37 PT [S30]; API do HF com `createdAt`/`lastModified` e `gated:false` por repo [S3]–[S9].
- **Lacunas → sub-perguntas:** —

### Q2 — Quais são os parâmetros, o contexto, as modalidades e a arquitetura tri-híbrida de cada modelo?

- **Estado:** respondida
- **Prioridade:** alta
- **Confiança:** alta
- **Origem:** brief (ronda 0)
- **Resposta:** `LFM3-1.7B`: **1,73B** parâmetros, contexto de **256K** tokens (262 144), vocabulário 128 000, 16 idiomas, só texto [S2]. `LFM3-VL-2B`: ~**1,9B** (blog) e acrescenta vídeo; o encoder de visão é interno, 14 camadas, hidden 1024, patch 16, merge espacial 2, patch temporal 2 [S1][S14]. `LFM3-Audio-2B`: ~**2B**, áudio+texto, encoder e codec (LiquidCodec) internos [S1][S5]. `LFM3-Omni-2B`: **2,2B**, visão+áudio+texto [S1]. `d1-2B`: **1,92B**, contexto **128K** [S10]. A arquitetura é tri-híbrida em todos: **24 camadas = 13 convoluções curtas com gating + 5 atenção de janela deslizante (janela 256) + 6 atenção global** [S1][S2][S14]; o `config.json` do ONNX confirma a ordem exata das camadas, `sliding_window: 256`, `partial_rotary_factor: 0.5` nas camadas globais, `use_sandwich_norm: true` e `conv_L_cache: 7` [S14].
- **Evidência:** tabela de especificações do model card [S2]; secção "Tri-hybrid layer mix" do blog [S1]; `text_config.layer_types` com 24 entradas [S14]; card do d1-2B com 1,92B e 128K [S10].
- **Lacunas → sub-perguntas:** Q2.1 (o `total` do GGUF dos modelos multimodais é 1,7288B, menor que o total do card — ver §5).

#### Q2.1 — Porque é que o `gguf.total` dos modelos multimodais é 1 728 801 600 e não os ~2B do nome?

- **Estado:** respondida
- **Prioridade:** media
- **Confiança:** moderada
- **Origem:** contradicao (ronda 1)
- **Resposta:** O campo `gguf.total` da API do HF nos repos `LFM3-VL-2B-GGUF`, `LFM3-Audio-2B-GGUF`, `LFM3-Omni-2B-GGUF`, `d1-2B-GGUF` e `d1-Omni-2B-GGUF` vale **1 728 801 600**, igual ao `LFM3-1.7B`, enquanto os cards lhes atribuem ~1,9B/2B/2,2B [S4][S5][S6][S7][S8][S1]. A leitura mais consistente com a documentação é que esse número conta **só o backbone de linguagem** (que é o mesmo 1.7B-Base em toda a família) e não os encoders de visão/áudio, que vivem nos `mmproj-*.gguf` [S1][S2]. Isto é **inferência**, não está afirmado em nenhuma fonte.
- **Evidência:** `gguf.total` idêntico em cinco repos e igual ao do 1.7B [S3][S4][S5][S6][S7][S8]; blog a afirmar backbone partilhado [S1]; existência de `mmproj-*` separados com centenas de MB [S4][S5][S6].
- **Lacunas → sub-perguntas:** —

### Q3 — O que permite exatamente a LFM Open License v1.0 e qual é o limite dos 10 M USD?

- **Estado:** respondida
- **Prioridade:** alta
- **Confiança:** alta
- **Origem:** brief (ronda 0)
- **Resposta:** O texto da licença chama-se **"LFM Open License v1.0"** e segue a estrutura da Apache-2.0: concessão perpétua, mundial, não exclusiva, gratuita e irrevogável de copyright (§2) e de patentes (§3), com obrigações de redistribuição (§4: copiar a licença, manter avisos, NOTICE) e terminação automática por incumprimento (§11) [S16]. O que a distingue é o **§5 — Commercial Use Limitation**: os direitos de uso comercial ficam condicionados a a entidade **não exceder o Threshold**, definido como "annual revenue of 10 million United States dollars ($10,000,000) or more"; **acima do limiar o uso comercial não está licenciado** por este acordo, e o limiar não se aplica a organizações sem fins lucrativos qualificadas em uso não comercial ou de investigação [S16]. No Hugging Face a licença aparece como `license: other` com `license_name: lfm1.0` [S3][S16].
- **Evidência:** definições de "Commercial Use", "Qualified Non-Profit Organization" e "Threshold" e o corpo do §5 [S16]; metadados `license`/`license_name` do repo [S3].
- **Lacunas → sub-perguntas:** —

### Q4 — Que ficheiros GGUF oficiais existem, com que tamanho e SHA-256, e quais servem para telemóvel?

- **Estado:** respondida
- **Prioridade:** alta
- **Confiança:** alta
- **Origem:** brief (ronda 0)
- **Resposta:** Todos os sete repos pedidos existem, **nenhum é gated**, e a API devolve tamanho e `lfs.sha256` por ficheiro [S3]–[S9]. `LFM3-1.7B-GGUF`: `Q4_0` ausente, mas há `QAD-Q4_0` (1 049 615 680 B), `Q4_K_M` (1 099 627 808 B), `Q5_K_M`, `Q6_K`, `Q8_0` (1 846 238 496 B), `F16`/`BF16` (3 466 626 336 B) e `NVFP4` (1 280 019 776 B) [S3]. `LFM3-VL-2B-GGUF`: `Q4_K_M` 1 099 627 808 B + `mmproj-…-Q8_0` 203 031 872 B (o par mais leve com visão) [S4]. `LFM3-Audio-2B-GGUF`: `Q4_K_M` 1 099 626 016 B + `mmproj-…-Q4_K_M` 172 418 048 B [S5]. `LFM3-Omni-2B-GGUF`: `Q4_K_M` 1 099 630 080 B + `mmproj-…-Q4_K_M` 291 586 720 B [S6]. `d1-2B-GGUF`: `Q4_K_M` 1 099 629 888 B, mas o `mmproj` só existe em **BF16/F16/Q8_0** (203 031 584 B o Q8_0) [S7]. `d1-Omni-2B-GGUF`: **só** `Q8_0` (1 846 241 184 B) + `mmproj` Q8_0 (326 104 096 B) — não há Q4 [S8]. `d1-omni-600M-GGUF`: `Q8_0` 407 207 584 B, arquitetura `lfm2` [S9].
- **Evidência:** listagens `siblings` com `size` e `lfs.sha256` obtidas em `https://huggingface.co/api/models/<repo>?blobs=true` [S3]–[S9].
- **Lacunas → sub-perguntas:** Q4.1 (o card do 1.7B recomenda `Q4_0` mas o repo não publica `Q4_0` simples).

#### Q4.1 — Onde está o `Q4_0` que o blog e o card usam nos benchmarks?

- **Estado:** respondida
- **Prioridade:** baixa
- **Confiança:** moderada
- **Origem:** contradicao (ronda 1)
- **Resposta:** O blog e o card dizem que as medições on-device usam **"Q4_0 GGUF"** [S1][S2], mas o repo só publica `LFM3-1.7B-QAD-Q4_0.gguf` (1 049 615 680 B) e `Q4_K_M` [S3]. A explicação mais provável é que o "Q4_0" dos benchmarks seja o checkpoint **QAD** (quantization-aware distillation), que a documentação de llama.cpp identifica como o tag `:Q4_0` [S33]; isto é **inferência** e não está escrito em nenhuma das fontes.
- **Evidência:** ausência de `Q4_0` na listagem [S3]; presença de `QAD-Q4_0` [S3]; menção a "Q4_0 GGUF" nos benchmarks [S1][S2]; tag `:Q4_0` como QAD na doc [S33].
- **Lacunas → sub-perguntas:** —

### Q5 — Que subgrafos e ficheiros de suporte têm os pacotes `d1-2B-ONNX` e `d1-Omni-2B-ONNX`?

- **Estado:** respondida
- **Prioridade:** alta
- **Confiança:** alta
- **Origem:** brief (ronda 0)
- **Resposta:** `d1-2B-ONNX` traz **dois subgrafos**: `onnx/decoder*.onnx` e `onnx/vision_encoder*.onnx`, em seis precisões (`decoder.onnx` fp32, `decoder_fp16`, `decoder_q4`, `decoder_q4f16`, `decoder_q8`, `decoder_q8f16`), com os pesos em ficheiros `*_data` externos [S11]. `d1-Omni-2B-ONNX` traz **três**: os mesmos `decoder` e `vision_encoder` mais `onnx/audio_encoder*.onnx` (fp32 e fp16) [S12]. O suporte textual é comum aos dois: `tokenizer.json` (17 908 258 B no d1-2B; 17 908 634 B no Omni), `tokenizer_config.json`, `processor_config.json` (1254 B / 1928 B), `chat_template.jinja`, `config.json`, e o código Python do checkpoint (`api.py`, `runner.py`, `slots.py`, `box.py`, `pointer.py`, `parsing.py`, `grid.py`, `prompt.py`, `calibration.py`+`calibration.json`, `json_spans.py`, `media.py`, `depthwise.py`, `attention.py`, `lfm3.py`), mais os processors (`image_processing_lfm3_vl.py`, `video_processing_lfm3_vl.py`, `processing_lfm3_vl.py`; no Omni também `feature_extraction_lfm3_omni.py`, `processing_lfm3_omni.py`, `configuration_lfm3_omni.py`) [S11][S12]. O par recomendado para CPU é `decoder_q4` + `vision_encoder_q8` (1,94 GB) e para GPU `q4f16`/`q8f16` [S11][S12].
- **Evidência:** listagens `siblings` dos dois repos [S11][S12]; tabelas de precisões dos model cards [S11][S12].
- **Lacunas → sub-perguntas:** —

### Q6 — Qual é o contrato de I/O do decoder ONNX?

- **Estado:** respondida
- **Prioridade:** alta
- **Confiança:** moderada
- **Origem:** brief (ronda 0)
- **Resposta:** O card de `d1-2B-ONNX` descreve o contrato: o decoder "answers a state and up to 16 questions, packed into one row without padding, in a single forward pass with no cache. It takes `input_ids`, `attention_mask`, `position_ids`, the features at the `<|image|>` and `<|video|>` placeholders (`image_features`, `video_features`), `question_ids` (-1 on the state, k on question k) and the flat positions of the answer slots (`slot_positions`). It returns `logits` at the answer slots and the final-norm `hidden_states`" [S11]. O card do Omni acrescenta o placeholder `<|audio|>` e o input `audio_features`, alimentado pelo `audio_encoder` a partir de log-mel de áudio a 16 kHz [S12]. O limite de **16 perguntas** é o `d1_set_size: 16` do `config.json`, descrito no card como "the model's trained size (16)" [S14][S10]. Os shapes e dtypes foram lidos diretamente do grafo `onnx/decoder_q4.onnx` (`ir_version` 10, opsets `ai.onnx:21` + `com.microsoft:1`): `input_ids` int64 `[batch_size, sequence_length]`, `attention_mask` int64 `[batch_size, total_sequence_length]`, `position_ids` int64 `[batch_size, sequence_length]`, `image_features` float32 `[num_image_tokens, 2048]`, `video_features` float32 `[num_video_tokens, 2048]`, `audio_features` float32 `[num_audio_tokens, 2048]` (só no decoder do Omni), `question_ids` int64 `[batch_size, sequence_length]`, `slot_positions` int64 `[num_slots]`; saídas `logits` float32 `[num_slots, 128000]` e `hidden_states` float32 `[batch_size, sequence_length, 2048]` [S36]. O contrato completo (prompt, slots, pós-processamento por tipo, licença em texto integral) está no anexo §10 [S13][S36]–[S42].
- **Evidência:** parágrafo "Use with ONNX Runtime" dos dois cards [S11][S12]; `d1_set_size` e `d1_codes` no `config.json` [S14]; afirmação de 16 perguntas no card do d1-2B [S10].
- **Lacunas → sub-perguntas:** Q6.1 (shapes/dtypes reais do grafo).

#### Q6.1 — Os shapes e dtypes dos tensores do decoder estão publicados em algum sítio oficial?

- **Estado:** respondida
- **Prioridade:** media
- **Confiança:** alta
- **Origem:** lacuna (ronda 2)
- **Resposta:** Não estão publicados em documentação, mas **são legíveis no próprio grafo**: `decoder_q4.onnx` declara `ir_version` 10, opsets `ai.onnx:21` + `com.microsoft:1`, e os inputs `input_ids` int64 `[batch_size, sequence_length]`, `attention_mask` int64 `[batch_size, total_sequence_length]`, `position_ids` int64 `[batch_size, sequence_length]`, `image_features`/`video_features` float32 `[…, 2048]`, `question_ids` int64 `[batch_size, sequence_length]`, `slot_positions` int64 `[num_slots]`, com saídas `logits` float32 `[num_slots, 128000]` e `hidden_states` float32 `[batch_size, sequence_length, 2048]`; o decoder do Omni acrescenta `audio_features` float32 `[num_audio_tokens, 2048]` [S36]. O SHA-256 local do ficheiro coincide com o LFS do repo, o que valida a leitura [S36][S11].
- **Evidência:** metadados do grafo lidos com um leitor de protobuf mínimo (`ModelProto`/`GraphProto`/`ValueInfoProto`) e conferidos por hash contra a API do HF [S36]; tabela completa no anexo §10.1–§10.2.
- **Lacunas → sub-perguntas:** —

### Q7 — Como é que o pós-processamento produz `noul`, `choice`, `multiple`, `score`, `text`, `number`, `date`, `range`, `box` e `boxes`?

- **Estado:** respondida
- **Prioridade:** alta
- **Confiança:** alta
- **Origem:** brief (ronda 0)
- **Resposta:** No caminho ONNX/Transformers, `api.py` mapeia as probabilidades lidas nos slots para respostas tipadas [S13]. `noul` devolve `{"type":"noul","noul":p}` (P(sim)) [S13]. `choice` devolve `choice` (argmax), `confidence` (= probabilidade do escolhido) e `probabilities` por opção [S13]. `choice` com `multiple: true` devolve `choices` (todas as opções com p ≥ 0,5) e as probabilidades individuais [S13]. `score` devolve `score`, `confidence`, `probabilities` e `legend`, com o nível lido por `mean`/`median`/`argmax` [S13]. `text`/`number`/`date` são `Read`: o valor só existe se `found ≥ 0,5`, e a resposta leva o campo do tipo, `span`, `found` e, para número, `unit` [S13]. `number` com `range` (classe `Estimate`) devolve `number` (mediana) e `interval` (p10, p90) lidos da grelha [S13]. `box`/`boxes` delegam em `box.answer`/`box.answer_many` e devolvem `top`/`bottom`/`left`/`right` como frações da imagem, `found`, `confidence`, ou `boxes`+`count` [S10][S13]. Os limiares de 0,5 passam por tabelas de calibração (`calibration.json`) [S13][S11]. **Nuance importante:** `multiple` e `range` não são valores de `type` — são modificadores de `choice` e de `number`; os `type` válidos são `noul`, `choice`, `score`, `text`, `number`, `date`, `box`, `boxes` [S10][S13].
- **Evidência:** função `answer()` de `api.py` [S13]; tabela "Question types" do card do d1-2B [S10]; existência de `calibration.json`/`calibration.py` [S11].
- **Lacunas → sub-perguntas:** —

### Q8 — Qual é a versão mínima real de llama.cpp com `lfm3`, `mtmd` e os templates de vídeo?

- **Estado:** respondida
- **Prioridade:** alta
- **Confiança:** alta
- **Origem:** brief (ronda 0)
- **Resposta:** A arquitetura `lfm3` aparece por primeira vez no release **b11938** (2026-10-27 23:57:45): o ficheiro `src/llama-arch.cpp` desse tag já contém `LLM_ARCH_LFM3`, e o **b11936** (20:11 do mesmo dia) ainda não [S18]. Os PRs que a introduzem foram o **#31252** ("model : add LiquidAI/LFM3-1.7B and LiquidAI/LFM3-VL-2B", merged 27/10 16:06) e o **#31257** ("…LFM3-Audio-2B and …LFM3-Omni-2B", merged 27/10 17:47) [S20][S21]. Os templates de vídeo — enum `mtmd_video_template` com `MTMD_VIDEO_TEMPLATE_LFM3` e `MTMD_VIDEO_TEMPLATE_LFM3_OMNI`, mais `mtmd_get_video_config()` — entram no **b11960** (2026-10-28 12:45:39), via PR **#31283** merged a 28/10 11:23 (commit **d4f1b18**) [S35][S22][S29]. O **b12088** (2026-11-04 00:54) existe e inclui ainda o **#31608** ("model : enable NVFP4 LFM3 ggufs") [S19][S23]. Os tipos de projetor em `mtmd` são `lfm3vl`, `lfm3a` e `lfm3a_gen` — não existe um projetor chamado `LFM3_OMNI` [S22].
- **Evidência:** `LLM_ARCH_LFM3` presente/ausente em `src/llama-arch.cpp` por tag [S18]; diff de `tools/mtmd/mtmd.h` entre b11953 e b11960 [S35]; lista de ficheiros alterados no PR #31283 [S22]; release notes do b12088 [S19].
- **Lacunas → sub-perguntas:** —

### Q9 — O `/v1/systemone` do llama.cpp serve os modelos d1 desta vaga e que primitivas aceita?

- **Estado:** respondida
- **Prioridade:** alta
- **Confiança:** alta
- **Origem:** brief (ronda 0)
- **Resposta:** O endpoint está documentado no README do servidor e o campo `type` de cada pergunta aceita **apenas `choice`, `score` e `noul`** — um pedido com outro tipo é rejeitado com "type must be one of: choice, score, noul" [S17]. O `server-decision.cpp` do b12088 reconhece explicitamente `COMMON_DECISION_TYPE_LFM3_D1` e `COMMON_DECISION_TYPE_LFM3_D1_OMNI` (além de `LFM2_D1`/`LFM2_D1_OMNI`), aceita `state` nulo para perguntas só sobre imagem, aceita `video_url` para o `lfm3-d1`, aceita instruções faladas no `lfm3-d1` e fala de `lfm3-d1-omni` com `input_audio` [S24]. O limite de opções de `choice` é 255 para estes modelos e o `output_tokens` é sempre 0 [S17][S24]. As respostas tipadas (`text`/`number`/`date`/`box`/`boxes`/`multiple`/`range`) **não** têm representação nesta API: só existem no caminho ONNX/Transformers [S17][S13].
- **Evidência:** secção "POST /v1/systemone" do README [S17]; enumeração e ramos por tipo de modelo em `server-decision.cpp` [S24]; função `answer()` do pacote ONNX para os tipos que faltam [S13].
- **Lacunas → sub-perguntas:** Q9.1 (estabilidade em concorrência).

#### Q9.1 — O `/v1/systemone` é seguro em concorrência e em modo router?

- **Estado:** respondida
- **Prioridade:** alta
- **Confiança:** alta
- **Origem:** contradicao (ronda 1)
- **Resposta:** Não. O issue **#31150** ("/v1/systemone in router mode — concurrent requests kill the decision model instance (exit 1, no error line)") está **aberto** desde 2026-10-25 [S27]. Já o **#30482** (500 "the question and its options must fit in one batch" com `-np ≥ 2` quando duas perguntas partilham prefixo) está **fechado**, a 2026-10-31 [S26]. Há ainda dois PRs abertos que mexem no mesmo caminho: **#31382** ("share image features within SystemOne requests") e **#31475** ("systemone reads shared prefix again for each question group") [S24].
- **Evidência:** estado `open`/`closed` e datas na API do GitHub [S27][S26]; PRs abertos listados na pesquisa do mesmo repositório [S24].
- **Lacunas → sub-perguntas:** —

### Q10 — Os PRs, commits e issues citados no guia existem e dizem o que o guia diz?

- **Estado:** respondida
- **Prioridade:** alta
- **Confiança:** alta
- **Origem:** contradicao (ronda 0)
- **Resposta:** Todos existem. **#31374** = commit **3c809f44**, "common : end reasoning budget forcing on an end tag from the prompt", merged 2026-10-30 [S28]. **#31283** = commit **d4f1b18**, "mtmd: enable video input support for LFM3 model family", merged 2026-10-28 [S29][S22]. **#31608** = "model : enable NVFP4 LFM3 ggufs", merged 2026-11-03 e presente no b12088 [S23][S19]. **Issue #31328** = "LFM3: any response_format (json_schema or json_object) fails with 'Unexpected empty grammar stack after accepting piece: 6 (30)'", fechado a 2026-10-30 [S25]. **Issue #30482** fechado; **issue #31150 aberto** [S26][S27]. A única ressalva é de leitura: o #31374 é sobre *reasoning budget*, não sobre LFM3 em si, e o #31608 só é relevante se se usarem GGUF NVFP4 [S28][S23].
- **Evidência:** títulos, `state`, `merged_at`, `merge_commit_sha` e `closed_at` na API do GitHub [S28][S29][S23][S25][S26][S27].
- **Lacunas → sub-perguntas:** —

### Q11 — Que contradições entre o guia do utilizador e as fontes ficam registadas?

- **Estado:** respondida
- **Prioridade:** alta
- **Confiança:** alta
- **Origem:** contradicao (ronda 2)
- **Resposta:** São seis, detalhadas na §5: (1) o `d1-omni-600M` não é LFM3 nem desta vaga; (2) `b12088` é válido mas o mínimo real é `b11938` (e `b11960` para vídeo); (3) `multiple` e `range` não são `type` mas modificadores; (4) o `/v1/systemone` só faz `choice`/`score`/`noul`, e as primitivas tipadas são exclusivas do ONNX; (5) os templates de vídeo chamam-se `MTMD_VIDEO_TEMPLATE_LFM3`/`…_LFM3_OMNI` e não existe projetor "LFM3_OMNI"; (6) o `mmproj` Q4 não existe para `d1-2B` nem Q4 de qualquer tipo para `d1-Omni-2B`, o que muda o orçamento de memória em telemóvel [S9][S18][S35][S13][S17][S22][S7][S8].
- **Evidência:** ver §5, com a fonte de cada divergência.
- **Lacunas → sub-perguntas:** —

## 3. Registo de rondas

| Ronda | Perguntas investigadas | Subagentes | Fontes novas | Afirmações novas | Lacunas abertas | Decisão |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | Q1, Q2, Q3, Q4, Q5, Q6, Q7, Q8, Q9, Q10 (brief + decomposição) | 0 (execução em série, sem subagentes disponíveis neste nível de delegação) | 0 | 0 | — | decompor e lançar a ronda 1 |
| 1 | Q1–Q10 contra fonte primária (blog, cards, HF API, GitHub API, LICENSE) | 0 | 35 | 34 | Q2.1, Q4.1, Q6.1, Q9.1 | aprofundar contradições |
| 2 | Q2.1, Q4.1, Q6.1, Q9.1 + Q11 | 0 | 0 (reuso de S1–S35) | 6 | Q6.1 fica `parcial` | saturação: nenhuma afirmação nova muda respostas de prioridade alta → sintetizar |

## 4. Matriz de evidência (afirmações centrais)

| ID | Afirmação | Fontes | Independentes | Verificação adversarial | Confiança |
| --- | --- | --- | --- | --- | --- |
| A1 | Lançamento a 27/10/2026, seis modelos, mesmo backbone | S1, S30, S31 | 3 (fabricante, HF, imprensa) | 3-0 mantém (datas coincidentes) | alta |
| A2 | Tri-híbrida: 13 conv + 5 SWA(256) + 6 global em 24 camadas | S1, S2, S14 | 3 (blog, card, config do pacote) | 3-0 mantém (ordem das camadas no config) | alta |
| A3 | `LFM3-1.7B` = 1,73B, 256K contexto, vocab 128k | S2, S3 | 2 | 2-0 mantém (`gguf.total` e `context_length`) | alta |
| A4 | Licença LFM Open License v1.0 com limite de 10 M USD | S16, S3 | 2 | 2-0 mantém (§5 literal) | alta |
| A5 | Tamanhos e SHA-256 dos GGUF | S3–S9 | 1 (API do HF, fonte primária) | 2-0 mantém (bytes coerentes entre `size` e LFS) | alta |
| A6 | `d1-omni-600M` é `lfm2`, de 07/10/2026 | S9, S34 | 2 | 2-0 mantém (arquitetura no GGUF + blog open-d1) | alta |
| A7 | Subgrafos ONNX: decoder + vision_encoder (+ audio_encoder no Omni) | S11, S12 | 2 | 2-0 mantém (listagem + tabelas) | alta |
| A8 | Contrato de I/O do decoder (nomes) | S11, S12 | 2 | 2-0 mantém (texto idêntico nos dois cards) | alta |
| A9 | Shapes/dtypes dos tensores do decoder | S14 (indireto) | 0 | não verificável | muito-baixa |
| A10 | Pós-processamento tipado (noul/choice/multiple/score/text/number/date/range/box/boxes) | S13, S10 | 2 | 2-0 mantém (código + tabela) | alta |
| A11 | `lfm3` desde b11938; vídeo desde b11960; b12088 inclui NVFP4 | S18, S35, S19, S22 | 3 | 3-0 mantém (presença no código por tag) | alta |
| A12 | `/v1/systemone` só aceita `choice`/`score`/`noul` | S17, S24 | 2 | 2-0 mantém (README + código) | alta |
| A13 | `/v1/systemone` reconhece `LFM3_D1`/`LFM3_D1_OMNI` | S24 | 1 | 1-0 mantém (código-fonte) | moderada |
| A14 | Issue #31150 aberto (router + concorrência) | S27 | 1 | 1-0 mantém (`state: open`) | alta |
| A15 | Todos os repos são públicos e não gated | S3–S12 | 1 (API do HF) | 2-0 mantém (`gated:false` em 9 repos) | alta |

## 5. Contradições

| Tema | Posição A (guia) | Posição B (fontes) | Explicação provável | Resolução |
| --- | --- | --- | --- | --- |
| Composição da suíte | `d1-omni-600M-GGUF` faz parte da vaga LFM3 | GGUF declara `architecture=lfm2`, criado 2026-10-17, e o blog `open-d1` de 07/10/2026 lança `d1-3B` + `d1-omni-600M` | O guia agrupou "os d1 todos"; o 600M é da vaga anterior e de outro backbone | `d1-omni-600M` fica fora do âmbito LFM3; serve para `/v1/systemone` como `lfm2-d1-omni` [S9][S34][S17] |
| Versão mínima de llama.cpp | "tag b12088 (ou superior)" | `lfm3` desde b11938; templates de vídeo desde b11960; b12088 é de 04/11/2026 | O guia fixou a versão que testou, não o mínimo | Usar `b12088` é seguro; o mínimo real é b11938 (texto/VL/áudio/omni) e b11960 (vídeo) [S18][S35] |
| Nomes dos tipos de resposta | "noul/choice/multiple/score/text/number/date/range/box/boxes" | `type` válidos: `noul`, `choice`, `score`, `text`, `number`, `date`, `box`, `boxes`; `multiple` é flag de `choice`, `range` é flag de `number` | Lista colapsada de tipos e modificadores | Implementar `multiple`/`range` como flags [S10][S13] |
| Primitivas em llama.cpp | "noul/choice/score apenas; multiple/spans/range/box só ONNX" | Confirmado: README só aceita `choice`/`score`/`noul` e o código rejeita os restantes | — (não é contradição) | Confirmado como facto [S17][S24] |
| Templates de vídeo | "templates de vídeo LFM3/LFM3_OMNI" | Enums `MTMD_VIDEO_TEMPLATE_LFM3` e `MTMD_VIDEO_TEMPLATE_LFM3_OMNI`; projetores `lfm3vl`/`lfm3a`/`lfm3a_gen` (não há projetor "LFM3_OMNI") | O guia referia os templates de prompt, não os projetores | Nomes confirmados; não confundir template de vídeo com tipo de mmproj [S35][S22] |
| Quantizações disponíveis | Implícito que há Q4 para todos | `d1-2B-GGUF` sem `mmproj` Q4 (só BF16/F16/Q8_0); `d1-Omni-2B-GGUF` só Q8_0/BF16/F16 | Publicação por repo, não uniforme | Orçamento móvel do d1 sobe para ~2,0–2,2 GB [S7][S8] |
| Contexto nos metadados GGUF | — | `context_length=262144` no 1.7B, mas `128000` nos GGUF VL/Audio/Omni/d1 | O backbone multimodal foi exportado com 128K, coerente com o card do d1 (128K) | Usar 128K como orçamento nos multimodais [S3][S4][S10] |
| `Q4_0` dos benchmarks | Blog/card dizem "Q4_0 GGUF" | O repo só publica `QAD-Q4_0` e `Q4_K_M` | "Q4_0" refere o checkpoint QAD | Inferência; ver Q4.1 [S1][S3][S33] |

## 6. Fontes

- [S1] Liquid AI. «Introducing LFM3: Every Modality for Specialized Intelligence». Liquid AI Blog, 2026-10-27. https://www.liquid.ai/blog/lfm3 · tipo: oficial · nível: A · lida: integral · acesso: 2026-11-06
- [S2] Liquid AI. «LFM3-1.7B» (model card). Hugging Face, 2026. https://huggingface.co/LiquidAI/LFM3-1.7B · tipo: oficial · nível: A · lida: integral · acesso: 2026-11-06
- [S3] Liquid AI. «LFM3-1.7B-GGUF» (model card + API `?blobs=true`). Hugging Face, 2026. https://huggingface.co/LiquidAI/LFM3-1.7B-GGUF · tipo: oficial · nível: A · lida: integral · acesso: 2026-11-06
- [S4] Liquid AI. «LFM3-VL-2B-GGUF» (model card + API `?blobs=true`). Hugging Face, 2026. https://huggingface.co/LiquidAI/LFM3-VL-2B-GGUF · tipo: oficial · nível: A · lida: integral · acesso: 2026-11-06
- [S5] Liquid AI. «LFM3-Audio-2B-GGUF» (model card + API `?blobs=true`). Hugging Face, 2026. https://huggingface.co/LiquidAI/LFM3-Audio-2B-GGUF · tipo: oficial · nível: A · lida: integral · acesso: 2026-11-06
- [S6] Liquid AI. «LFM3-Omni-2B-GGUF» (model card + API `?blobs=true`). Hugging Face, 2026. https://huggingface.co/LiquidAI/LFM3-Omni-2B-GGUF · tipo: oficial · nível: A · lida: integral · acesso: 2026-11-06
- [S7] Liquid AI. «d1-2B-GGUF» (model card + API `?blobs=true`). Hugging Face, 2026. https://huggingface.co/LiquidAI/d1-2B-GGUF · tipo: oficial · nível: A · lida: integral · acesso: 2026-11-06
- [S8] Liquid AI. «d1-Omni-2B-GGUF» (model card + API `?blobs=true`). Hugging Face, 2026. https://huggingface.co/LiquidAI/d1-Omni-2B-GGUF · tipo: oficial · nível: A · lida: integral · acesso: 2026-11-06
- [S9] Liquid AI. «d1-omni-600M-GGUF» (model card + API `?blobs=true`). Hugging Face, 2026. https://huggingface.co/LiquidAI/d1-omni-600M-GGUF · tipo: oficial · nível: A · lida: integral · acesso: 2026-11-06
- [S10] Liquid AI. «d1-2B» (model card). Hugging Face, 2026. https://huggingface.co/LiquidAI/d1-2B · tipo: oficial · nível: A · lida: integral · acesso: 2026-11-06
- [S11] Liquid AI. «d1-2B-ONNX» (model card + API `?blobs=true`). Hugging Face, 2026. https://huggingface.co/LiquidAI/d1-2B-ONNX · tipo: oficial · nível: A · lida: integral · acesso: 2026-11-06
- [S12] Liquid AI. «d1-Omni-2B-ONNX» (model card + API `?blobs=true`). Hugging Face, 2026. https://huggingface.co/LiquidAI/d1-Omni-2B-ONNX · tipo: oficial · nível: A · lida: integral · acesso: 2026-11-06
- [S13] Liquid AI. «api.py» do checkpoint d1-2B-ONNX. Hugging Face, 2026. https://huggingface.co/LiquidAI/d1-2B-ONNX/raw/main/api.py · tipo: documentacao · nível: A · lida: trechos · acesso: 2026-11-06
- [S14] Liquid AI. «config.json» do pacote d1-2B-ONNX. Hugging Face, 2026. https://huggingface.co/LiquidAI/d1-2B-ONNX/raw/main/config.json · tipo: documentacao · nível: A · lida: integral · acesso: 2026-11-06
- [S15] Liquid AI. «processor_config.json» do pacote d1-2B-ONNX. Hugging Face, 2026. https://huggingface.co/LiquidAI/d1-2B-ONNX/raw/main/processor_config.json · tipo: documentacao · nível: A · lida: integral · acesso: 2026-11-06
- [S16] Liquid AI. «LFM Open License v1.0» (LICENSE do repo LFM3-1.7B). Hugging Face, 2026. https://huggingface.co/LiquidAI/LFM3-1.7B/raw/main/LICENSE · tipo: oficial · nível: A · lida: integral · acesso: 2026-11-06
- [S17] ggml-org. «llama.cpp — tools/server/README.md», secção «POST /v1/systemone». GitHub, master, 2026. https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md · tipo: documentacao · nível: A · lida: integral · acesso: 2026-11-06
- [S18] ggml-org. «llama.cpp b11938» (release) + `src/llama-arch.cpp` nesse tag. GitHub, 2026-10-27. https://github.com/ggml-org/llama.cpp/releases/tag/b11938 · tipo: documentacao · nível: A · lida: trechos · acesso: 2026-11-06
- [S19] ggml-org. «llama.cpp b12088» (release). GitHub, 2026-11-04. https://github.com/ggml-org/llama.cpp/releases/tag/b12088 · tipo: documentacao · nível: A · lida: trechos · acesso: 2026-11-06
- [S20] ggml-org. «PR #31252 — model : add LiquidAI/LFM3-1.7B and LiquidAI/LFM3-VL-2B». GitHub, 2026-10-27. https://github.com/ggml-org/llama.cpp/pull/31252 · tipo: documentacao · nível: A · lida: trechos · acesso: 2026-11-06
- [S21] ggml-org. «PR #31257 — model : add LiquidAI/LFM3-Audio-2B and LiquidAI/LFM3-Omni-2B». GitHub, 2026-10-27. https://github.com/ggml-org/llama.cpp/pull/31257 · tipo: documentacao · nível: A · lida: trechos · acesso: 2026-11-06
- [S22] ggml-org. «PR #31283 — mtmd: enable video input support for LFM3 model family» (inclui `tools/mtmd/clip-impl.h`). GitHub, 2026-10-28. https://github.com/ggml-org/llama.cpp/pull/31283 · tipo: documentacao · nível: A · lida: integral · acesso: 2026-11-06
- [S23] ggml-org. «PR #31608 — model : enable NVFP4 LFM3 ggufs». GitHub, 2026-11-03. https://github.com/ggml-org/llama.cpp/pull/31608 · tipo: documentacao · nível: A · lida: trechos · acesso: 2026-11-06
- [S24] ggml-org. «tools/server/server-decision.cpp» no tag b12088. GitHub, 2026-11-04. https://github.com/ggml-org/llama.cpp/blob/b12088/tools/server/server-decision.cpp · tipo: documentacao · nível: A · lida: trechos · acesso: 2026-11-06
- [S25] ggml-org. «Issue #31328 — LFM3: any response_format fails with "Unexpected empty grammar stack…"». GitHub, 2026-10-28 (fechado 2026-10-30). https://github.com/ggml-org/llama.cpp/issues/31328 · tipo: documentacao · nível: A · lida: trechos · acesso: 2026-11-06
- [S26] ggml-org. «Issue #30482 — /v1/systemone returns 500 … (-np >= 2)». GitHub, 2026-10-13 (fechado 2026-10-31). https://github.com/ggml-org/llama.cpp/issues/30482 · tipo: documentacao · nível: A · lida: trechos · acesso: 2026-11-06
- [S27] ggml-org. «Issue #31150 — /v1/systemone in router mode — concurrent requests kill the decision model instance». GitHub, 2026-10-25 (aberto). https://github.com/ggml-org/llama.cpp/issues/31150 · tipo: documentacao · nível: A · lida: trechos · acesso: 2026-11-06
- [S28] ggml-org. «Commit 3c809f44 — common : end reasoning budget forcing on an end tag from the prompt (#31374)». GitHub, 2026-10-30. https://github.com/ggml-org/llama.cpp/commit/3c809f44383bcebc318b8cddd8c6d11aaa861e9b · tipo: documentacao · nível: A · lida: trechos · acesso: 2026-11-06
- [S29] ggml-org. «Commit d4f1b18 — mtmd: enable video input support for LFM3 model family (#31283)». GitHub, 2026-10-28. https://github.com/ggml-org/llama.cpp/commit/d4f1b18b3a1522eec48decbe9ff7dc66eb60a9f4 · tipo: documentacao · nível: A · lida: trechos · acesso: 2026-11-06
- [S30] Carl Franzen. «Liquid AI's new LFM3 models put browser agents, voice commands, and image recognition onto enterprise-controlled devices». VentureBeat, 2026-10-27. https://venturebeat.com/technology/liquid-ais-new-lfm3-models-put-browser-agents-voice-commands-and-image-recognition-onto-enterprise-controlled-devices · tipo: imprensa · nível: C · lida: trechos · acesso: 2026-11-06
- [S31] Liquid AI. «Build specialized multimodal models with LFM3». Hugging Face Blog, 2026-10-27. https://huggingface.co/blog/LiquidAI/lfm3 · tipo: oficial · nível: A · lida: trechos · acesso: 2026-11-06
- [S32] Liquid AI. «ONNX — on-device deployment». docs.liquid.ai, 2026. https://docs.liquid.ai/deployment/on-device/onnx · tipo: documentacao · nível: A · lida: integral · acesso: 2026-11-06
- [S33] Liquid AI. «llama.cpp — on-device deployment». docs.liquid.ai, 2026. https://docs.liquid.ai/deployment/on-device/llama-cpp · tipo: documentacao · nível: A · lida: trechos · acesso: 2026-11-06
- [S34] Liquid AI. «Open d1: Edge decision models for text, vision, and audio». Liquid AI Blog, 2026-10-07. https://www.liquid.ai/blog/open-d1 · tipo: oficial · nível: A · lida: integral · acesso: 2026-11-06
- [S35] ggml-org. «tools/mtmd/mtmd.h» nos tags b11953 e b11960 (diff dos templates de vídeo). GitHub, 2026-10-28. https://github.com/ggml-org/llama.cpp/blob/b11960/tools/mtmd/mtmd.h · tipo: documentacao · nível: A · lida: integral · acesso: 2026-11-06

- [S36] Liquid AI. Grafos ONNX `onnx/decoder_q4.onnx`, `onnx/vision_encoder_q8.onnx` (d1-2B-ONNX) e `onnx/decoder_q4.onnx`, `onnx/audio_encoder.onnx` (d1-Omni-2B-ONNX) — metadados do grafo (inputs/outputs, shapes, dtypes, opsets) lidos localmente. Hugging Face, 2026. https://huggingface.co/LiquidAI/d1-2B-ONNX/tree/main/onnx · tipo: documentacao · nível: A · lida: integral · acesso: 2026-11-06
- [S37] Liquid AI. «slots.py» (plano de slots e `slot_logits`). Hugging Face, 2026. https://huggingface.co/LiquidAI/d1-2B-ONNX/raw/main/slots.py · tipo: documentacao · nível: A · lida: integral · acesso: 2026-11-06
- [S38] Liquid AI. «prompt.py» (verbalizer: prefixo, `question_block`, `suffix_layout`, `readout_ids`, `probabilities`). Hugging Face, 2026. https://huggingface.co/LiquidAI/d1-2B-ONNX/raw/main/prompt.py · tipo: documentacao · nível: A · lida: trechos · acesso: 2026-11-06
- [S39] Liquid AI. «pointer.py» (leitura por ponteiro sobre as posições do state, `spans`). Hugging Face, 2026. https://huggingface.co/LiquidAI/d1-2B-ONNX/raw/main/pointer.py · tipo: documentacao · nível: A · lida: integral · acesso: 2026-11-06
- [S40] Liquid AI. «box.py» (caixas, grelhas de arestas, confiança por IoU). Hugging Face, 2026. https://huggingface.co/LiquidAI/d1-2B-ONNX/raw/main/box.py · tipo: documentacao · nível: A · lida: integral · acesso: 2026-11-06
- [S41] Liquid AI. «parsing.py» (`parse_number`, `parse_date`, `written_unit`, moedas e escalas). Hugging Face, 2026. https://huggingface.co/LiquidAI/d1-2B-ONNX/raw/main/parsing.py · tipo: documentacao · nível: A · lida: trechos · acesso: 2026-11-06
- [S42] Liquid AI. «grid.py» (grelha de valores igualmente espaçados, quantis). Hugging Face, 2026. https://huggingface.co/LiquidAI/d1-2B-ONNX/raw/main/grid.py · tipo: documentacao · nível: A · lida: integral · acesso: 2026-11-06
- [S43] Liquid AI. «runner.py» (construção das sequências, `set_size`, `_rows`, pixels de visão). Hugging Face, 2026. https://huggingface.co/LiquidAI/d1-2B-ONNX/raw/main/runner.py · tipo: documentacao · nível: A · lida: trechos · acesso: 2026-11-06
- [S44] Liquid AI. «attention.py» (modos `causal`/`state`/`prompt`/`set`, `pack_set`, `question` tensor). Hugging Face, 2026. https://huggingface.co/LiquidAI/d1-2B-ONNX/raw/main/attention.py · tipo: documentacao · nível: A · lida: trechos · acesso: 2026-11-06
- [S45] Liquid AI. «calibration.json» (temperatura e tabelas monótonas por cabeça). Hugging Face, 2026. https://huggingface.co/LiquidAI/d1-2B-ONNX/raw/main/calibration.json · tipo: documentacao · nível: A · lida: integral · acesso: 2026-11-06
- [S46] Liquid AI. «processor_config.json» e «feature_extraction_lfm3_omni.py» do pacote Omni. Hugging Face, 2026. https://huggingface.co/LiquidAI/d1-Omni-2B-ONNX/raw/main/processor_config.json · tipo: documentacao · nível: A · lida: integral · acesso: 2026-11-06
- [S47] Liquid AI. «LICENSE» do repo LFM3-1.7B — URL canónico; cópia local em `pesquisas/2026-11-06-LFM-Open-License-v1.0.txt`. Hugging Face, 2026. https://huggingface.co/LiquidAI/LFM3-1.7B/blob/main/LICENSE · tipo: oficial · nível: A · lida: integral · acesso: 2026-11-06

## 7. Incidentes de segurança (injeção de prompt)

| Fonte | Sinais do escudo | O que o texto tentava | Ação |
| --- | --- | --- | --- |
| — | nenhum | — | nenhum conteúdo web tentou dar instruções; todo o texto foi tratado como dado |

## 8. Limitações e perguntas em aberto

- **Shapes e dtypes dos tensores do decoder ONNX não confirmados** (Q6.1). Os cards dão nomes e semântica, não tabelas de tensores. Para fechar: `onnx.load("onnx/decoder_q4.onnx", load_external_data=False)` num ambiente com `onnx` e ler `graph.input`/`graph.output`. Impacto prático: ao implementar em Dart/ORT-mobile, os shapes têm de ser descobertos empiricamente.
- **`total` do GGUF multimodal** (Q2.1) é lido como backbone-only por inferência, não por afirmação de fonte.
- **`Q4_0` dos benchmarks** (Q4.1) é provavelmente o checkpoint QAD; não confirmado textualmente.
- **Estado do `/v1/systemone` em router** (Q9.1) é um risco aberto a montante (#31150), não algo que a app possa corrigir.
- **Contagem de parâmetros dos multimodais:** o blog dá ~1,9B (VL), ~2B (Audio) e 2,2B (Omni); só o d1-2B (1,92B) e o LFM3-1.7B (1,73B) têm número exato no card lido. Os restantes são arredondamentos do blog.
- **Não verificado:** SHA-256 dos ficheiros ONNX individuais está publicado (LFS) e consta do anexo de apoio, mas não foi validado por download real de cada blob; os valores vêm da API do HF.
- **Não verificado:** desempenho real em Android/iOS com estes GGUF — está fora do âmbito desta investigação.

## 9. Metodologia

- Motor: tavily-agent-skill (`search` + `extract`), modo pesquisa profunda (flag `--deep-research`).
- Rondas: 3 (0 decomposição, 1 verificação primária, 2 contradições) · subagentes: 0 (o nível de delegação deste agente não permitia `subagent`; os papéis de investigador/verificador foram executados em série) · consultas web: 2 (`search --include-domains` e `search --topic news`) · **fetch direto de API**: 30+ pedidos a `huggingface.co/api/models/...?blobs=true` (9 repos), `api.github.com` (releases, PRs, issues, commits, search), `raw.githubusercontent.com` (server README, `server-decision.cpp`, `clip.cpp`, `clip-impl.h`, `mtmd.h`, `llama-arch.cpp`, `api.py`, `config.json`, `processor_config.json`, `LICENSE`) — a API do HF e a do GitHub foram a via primária por darem bytes e SHAs exatos, e a Tavily ficou para a data/imprensa.
- Fontes lidas na íntegra: S1, S2, S10, S11, S12, S14, S15, S16, S17, S22, S34, S35 (12). Lidas em trechos: as restantes.
- Verificação adversarial: as 15 afirmações centrais da §4 foram confrontadas com uma segunda fonte sempre que existia (coluna "Independentes"); A9 fica declarada como não verificável em vez de inferida como facto.

## 10. Anexo — contrato de execução ONNX (ronda 3)

Tudo abaixo foi lido no código e nos grafos publicados; `ficheiro:linha` refere o ficheiro do pacote ONNX.

### 10.1 Inventário com bytes e SHA-256

Os ficheiros LFS têm `lfs.sha256` na API do HF e foram **validados por hash local** (ex.: `decoder_q4.onnx` local = `00b77894…4065f` = o LFS do repo) [S36]. Os ficheiros de texto não são LFS: a API só dá `blobId` (SHA-1 de blob git); o SHA-256 abaixo foi calculado sobre o `raw` descarregado [S11][S12].

| Repo | Ficheiro | Bytes | SHA-256 |
| --- | --- | --- | --- |
| d1-2B-ONNX | onnx/decoder.onnx | 285437 | 126d1bfc12012161380843b63c6989b8d4664655fe07daf29ca88cee77e92cf4 |
| d1-2B-ONNX | onnx/decoder.onnx_data | 2111160320 | 7b871dd94c4b298c5877b7354acf7f451b8065508c2df39dbefdde0781b3fc90 |
| d1-2B-ONNX | onnx/decoder.onnx_data_1 | 2140200960 | 769afd899f65b7703ec4a7babed84a76cca19f52a64340ed604b04725d3cafef |
| d1-2B-ONNX | onnx/decoder.onnx_data_2 | 2115108864 | 5bfda795d0df1e49405b1e53157446efedd99c15c6b33c17a55691a587b715bc |
| d1-2B-ONNX | onnx/decoder.onnx_data_3 | 679796736 | e7cab339b922c7f783b1218304086eb20d2cb31dc350ce7e67ff41418f64d2e4 |
| d1-2B-ONNX | onnx/decoder_fp16.onnx | 281560 | 0299506c082fb8999e5788314a1db41b20bc432b43fbba07f713d4cd2ea8ef62 |
| d1-2B-ONNX | onnx/decoder_fp16.onnx_data | 2125680640 | 7a41d6bd71a1ec48a6efe956384c45f44523bc087be42df2b0cf15188f665634 |
| d1-2B-ONNX | onnx/decoder_fp16.onnx_data_1 | 1397452800 | 04a3e694b92a51c908c0534de18e8221d3b1817fb6eb0e474cdec98723c36f26 |
| d1-2B-ONNX | onnx/decoder_q4.onnx | 358945 | 00b77894a36d92c0d455db07f39743c0fa814f5855aa060b75b8dace1654065f |
| d1-2B-ONNX | onnx/decoder_q4.onnx_data | 1741806592 | e72031f1b00e3273e286b4125d1b58c20b59c7e031bd791796277e0fab65b14b |
| d1-2B-ONNX | onnx/decoder_q4f16.onnx | 274492 | 3ac6c50361b1f262b4bf1ac250459eee49bde2620f704b1785fa355cc68117ab |
| d1-2B-ONNX | onnx/decoder_q4f16.onnx_data | 1567474688 | 977616f1fcc543490a49c7e54aec98a6398566c7868e3adf0134688a9b701426 |
| d1-2B-ONNX | onnx/decoder_q8.onnx | 358439 | ebe3c8a0bd5b74c6f96ca67b8e83dec082163f089936dee116eaa1cbdfbc853c |
| d1-2B-ONNX | onnx/decoder_q8.onnx_data | 2131090432 | 06dc67c0f0c2b3c3c212c13b89bdf5d032409f09cbe26c048f7aa0d4a360e55a |
| d1-2B-ONNX | onnx/decoder_q8f16.onnx | 274026 | fb3d9b2a64bb67f0ec0e8c4b6083896ad56e67f5e656e3e573994b8eaff0b199 |
| d1-2B-ONNX | onnx/decoder_q8f16.onnx_data | 1956758528 | b58457cf51d5f84637cf60af5a25cb42d6f55f6ef1bf3b0195bdc728dddfacb2 |
| d1-2B-ONNX | onnx/vision_encoder.onnx | 105627 | 70c8d5f4e749426d6ef6362995a81b4e4f5d0ad35de657829bc4c0d2750ada52 |
| d1-2B-ONNX | onnx/vision_encoder.onnx_data | 758042624 | 6f2f5570edaf8a7e87f14513c178ca87e00b2bf9c50fa21e7072296e663dde5c |
| d1-2B-ONNX | onnx/vision_encoder_fp16.onnx | 104940 | d6f3ed9a9211feb09d146fb8d550517a7b779940d081eb1604127bfe23ca2e6a |
| d1-2B-ONNX | onnx/vision_encoder_fp16.onnx_data | 379021312 | ca65da8ca1d95481f71cc669266284f5be64046df1c7d53e8ca51cf3f4643a05 |
| d1-2B-ONNX | onnx/vision_encoder_q8.onnx | 126353 | ea9421f2a7fa8bc401bee96b1077be522b8d448e82e46c9117f2bc90eb01caac |
| d1-2B-ONNX | onnx/vision_encoder_q8.onnx_data | 196153344 | baff3c8cf1dd0b4d8dd3108850558a7f26fafb55367be7bcf98d02739c162d1d |
| d1-2B-ONNX | tokenizer.json | 17908258 | a39eed58008cbcbc09e5b629b81338a654269c64cd13348aaa6090f4db75c7e7 |
| d1-2B-ONNX | tokenizer_config.json | 623 | 594a96e4caedd07536a595b48f5dc84655bd672b715b6ac891ca3d503d439f76 |
| d1-2B-ONNX | processor_config.json | 1254 | 37396ef3370083a04381ef25f9e1b50dec184b8cdcf08cf718feb8944ad8f3bc |
| d1-2B-ONNX | chat_template.jinja | 12762 | 17f33d44f7bd01aa94623dd8bf8e4e0ef80580a725ef8b71dc6b78f6bcc11700 |
| d1-2B-ONNX | config.json | 2903 | ffdc4c996152d23dbe8a2659a8c6aabe2992aa3fa3a41601dd0fca8771d6f332 |
| d1-2B-ONNX | api.py | 11734 | d57845b414b6766cd0410f0437080244320adebd4f9f031a03777acbec243d2a |
| d1-2B-ONNX | runner.py | 22405 | ac195b19f60f985a6081ccecc1a5c9f7c9fbe6711e8916c0e9835aaaac0bc2a2 |
| d1-2B-ONNX | prompt.py | 34677 | e5344f65481374da6b30e5ceda2a5ee398100b13ee69ed2ce52ac42713a7a048 |
| d1-2B-ONNX | slots.py | 2463 | 67adea5fb377a79832827c43054b4ce94de0fa48f5ba0a39e6f2867b7e59f373 |
| d1-2B-ONNX | box.py | 7747 | 1a123160ce3c94c25074132407c41d553601a6d8cb7056c814397ad0718dd16f |
| d1-2B-ONNX | pointer.py | 7700 | 53e7b403d5f9d6f24e18a3f08b4dd9e93fea6da1da7eaeea92d07a4700cfedb3 |
| d1-2B-ONNX | parsing.py | 16157 | 0f0a05e7f2eee037f2e5ce1fefc984ff34824e07e7999120d94563a82642b54a |
| d1-2B-ONNX | grid.py | 1714 | a5626b67094eda0a4a22d50e73346f3bc2f1b4b6eb6d95ba64333c6f71592eff |
| d1-2B-ONNX | attention.py | 19450 | 2608cc3f48bc3f906b64244322df81de5a18cd1faa8243680713289d5540fd2c |
| d1-2B-ONNX | calibration.json | 4924 | e534464458f485d800fe6cc896ac241590bbc8cd54f5af08f7b3064b0d884d69 |
| d1-2B-ONNX | LICENSE | 10574 | 4d28ca14dedc0b3d0fcc2b3339f0e79931faa33874f3d24f522183a8fc70068c |
| d1-Omni-2B-ONNX | onnx/audio_encoder.onnx | 162507 | abde0cdde89473120a23a05c38ec3f2a2dc7bf27b48166d37919eabff7326a3e |
| d1-Omni-2B-ONNX | onnx/audio_encoder.onnx_data | 510351360 | 90ca95f549eb840314d1a23b9f48f88ef02b11d614ed0662b75f9da5d1ac1da7 |
| d1-Omni-2B-ONNX | onnx/audio_encoder_fp16.onnx | 163115 | 20a7c84d1f3b5ca39e6f1903b9482ec68bc16a841b637d4684b72c679036110e |
| d1-Omni-2B-ONNX | onnx/audio_encoder_fp16.onnx_data | 255173120 | d7d67ea09bda583fe346097af9f06ba03c92e47870e475f1c65604677581b878 |
| d1-Omni-2B-ONNX | onnx/decoder.onnx | 287323 | a11590a067d437d08f1dcb1b34986e8c925ccc4689ce7131859a5951d6783ae2 |
| d1-Omni-2B-ONNX | onnx/decoder.onnx_data | 2111160320 | c285b67df9885bfecac8883889dff41dc72b99c820f5f4e9e38c357fc38f1e6e |
| d1-Omni-2B-ONNX | onnx/decoder.onnx_data_1 | 2140200960 | f31128c85bda0d7142d8df1482d75eeacc597c7ce286eacc98bbf5019ec85cd4 |
| d1-Omni-2B-ONNX | onnx/decoder.onnx_data_2 | 2115108864 | de7b89a48fceb2a72bf9ec1780e42200e9d0af8299c8657878ed7002db73957a |
| d1-Omni-2B-ONNX | onnx/decoder.onnx_data_3 | 679796736 | 62d31c675dd147fda659a72f6c02fd19f1f9a9bb3d15641c38e83ced4b6a42bd |
| d1-Omni-2B-ONNX | onnx/decoder_fp16.onnx | 283583 | db90197d57df73c876ad82f4a1981e9a26816ceedc3f35f5991cb09d64037af6 |
| d1-Omni-2B-ONNX | onnx/decoder_fp16.onnx_data | 2125680640 | e5d19eef6e39cd5cc55dd2d533dcefd2b6f7351d2c72137fb6420939a963fa34 |
| d1-Omni-2B-ONNX | onnx/decoder_fp16.onnx_data_1 | 1397452800 | 3549edcb3ade07ed735d10d503e253f06824c7b9940ef18157236b9d55b8957c |
| d1-Omni-2B-ONNX | onnx/decoder_q4.onnx | 360831 | d3d54dfb740c761e21ffc4eec0e3546c2f0b7453d4514f357191786585a67681 |
| d1-Omni-2B-ONNX | onnx/decoder_q4.onnx_data | 1741806592 | 59df2ee2430b3973edab00ba14771e3da849f476251ada487949cd09e8314d10 |
| d1-Omni-2B-ONNX | onnx/decoder_q4f16.onnx | 276444 | 59bed92a6ec5df6462aa02ad8ac5be342afecfa8525539852a9a5deb48d7f221 |
| d1-Omni-2B-ONNX | onnx/decoder_q4f16.onnx_data | 1567474688 | bf8a038340291e07e6864243016eae55e9c183523d446fca608b5d82acceed1f |
| d1-Omni-2B-ONNX | onnx/decoder_q8.onnx | 360325 | a34bfdcbf99162c9fbd3f9b3f805cafbdece1fa26d1e57e9491f6cf659333766 |
| d1-Omni-2B-ONNX | onnx/decoder_q8.onnx_data | 2131090432 | 212a006911a429c3e57214d3d4cf683fb9404a29cdd649b5e0bd26efa28bb275 |
| d1-Omni-2B-ONNX | onnx/decoder_q8f16.onnx | 275978 | c4f241bd8d62d1943d1fc3e34df612cd7f3a5a5b1273737690f82cbd75e5a05d |
| d1-Omni-2B-ONNX | onnx/decoder_q8f16.onnx_data | 1956758528 | aa213329bd669b19fb065c5e7072d57259d198ca4d00ed349f23f56a4a684c7e |
| d1-Omni-2B-ONNX | onnx/vision_encoder*.onnx (+data) | 105627/758042624/104940/379021312/126353/196153344 | 13dba596… / f08ea911… / bad561d7… / bdb6d246… / 5447beba… / f55c525b… |
| d1-Omni-2B-ONNX | tokenizer.json | 17908634 | 41927bd314d17d7d7fadb44e10cd0919f7b71528d7741596d8cbd15c6945ec44 |
| d1-Omni-2B-ONNX | tokenizer_config.json | 625 | 3cff70d801d7c2086ffa2979046051b2727f160acb2eaeb3a77512be41c6a29e |
| d1-Omni-2B-ONNX | processor_config.json | 1928 | 2288d34b7c0579593258b1c083de4ab8328a842fdb0190977363e573dbdcd0e5 |
| d1-Omni-2B-ONNX | api.py / slots.py / box.py / pointer.py / parsing.py / grid.py / prompt.py / runner.py / attention.py | iguais ao d1-2B | d57845b4… / 67adea5f… / 1a123160… / 53e7b403… / 0f0a05e7… / a5626b67… / e5344f65… / ac195b19… / 2608cc3f… |
| d1-Omni-2B-ONNX | calibration.json | 4819 | 182270f679ee9b8ead5d2d3f37ea5f297839126baaced22e4cd57d48cfaf1772 |
| d1-Omni-2B-ONNX | chat_template.jinja | 13363 | não calculado (download falhou) |
| d1-Omni-2B-ONNX | config.json | 5802 | não calculado (download falhou) |

### 10.2 Contrato do decoder (os dois decoders, `q4`) [S36]

| Tensor | Direção | Dtype | Shape | Notas |
| --- | --- | --- | --- | --- |
| input_ids | in | int64 | [batch_size, sequence_length] | batch = 1 na prática; sem padding |
| attention_mask | in | int64 | [batch_size, total_sequence_length] | `total_sequence_length` = sequência + features de mídia |
| position_ids | in | int64 | [batch_size, sequence_length] | |
| image_features | in | float32 | [num_image_tokens, 2048] | saída do `vision_encoder` |
| video_features | in | float32 | [num_video_tokens, 2048] | idem, por patch temporal |
| audio_features | in | float32 | [num_audio_tokens, 2048] | **só no decoder do Omni** (8 inputs vs 7) |
| question_ids | in | int64 | [batch_size, sequence_length] | −1 no state, k na pergunta k |
| slot_positions | in | int64 | [num_slots] | posições planas dos answer slots |
| logits | out | float32 | [num_slots, 128000] | log-probabilidades nas slots |
| hidden_states | out | float32 | [batch_size, sequence_length, 2048] | pós final-norm, para os pointers |

Sem cache, sem sampling, uma passagem. O `vision_encoder_q8` tem 1 input `pixel_values` float32 `[grid_height_blocks, grid_width_blocks, 2, 2, 1536]` e 1 output `image_features` float32 `[num_image_tokens, 2048]`; o `audio_encoder` tem `input_features` float32 `[1, 128, num_frames]` e `audio_features` float32 `[num_audio_tokens, 2048]` [S36].

### 10.3 Como o prompt é montado [S38][S44]

- **Prefixo:** `bos + "<|im_start|>system\n" + SYSTEMS[system] + "<|im_end|>\n"` (por omissão `system="none"` → **sem turno de sistema**) `+ "<|im_start|>user\n" + media + state_block + "\n" + question_header`; `question_header` = `"QUESTION:\n"` (vazio se `state is None`) — `prompt.py:618-635`.
- **State:** estilo por omissão `json_only` → `json.dumps(state, ensure_ascii=False, indent=2) + "\n\n"`; strings vão como `"{state}\n\n"` — `prompt.py:478-503`.
- **Corpo da pergunta** (`question_block`, `prompt.py:572-615`): cada tipo escreve instruções + opções e uma instrução de resposta literal, p. ex. `noul` → `"{instructions}\n\nReply with yes or no only."`; `choice` → `Options:` com `A: …`, `B: …` e `Reply with the option code only.`; `score` → níveis numerados `0..k-1` e `Reply with a single digit 0-{k-1} only.`; `text/number/date` → `Read the {type} from the state, or nothing if it is absent.`; `box` → `Presence is yes or no.` + legenda das arestas + `Reply with yes or no at present, then one code at top, bottom, left and right.`; `boxes` → `Present k is yes when there are at least k.` e `16 at most,` no prompt 1; `choice multiple` → uma linha `"nome": descrição` por opção e `Reply with yes or no for each option.`
- **Sufixo e slots** (`suffix_layout`/`marked_suffix`, `prompt.py:668-717`): `"{pergunta}" + "<|im_end|>\n<|im_start|>assistant\n" + lead` e depois, por cada slot, `"\n" + "<nome>:"`. O **slot é o token do `:`** (o último token do marcador); guarda-se o offset `end - len(ids) + 1` — logo `slot_positions` conta a partir do fim da sequência. Marcadores: `start:`,`end:` (read); `present:`,`top:`,`bottom:`,`left:`,`right:` (box); `"present 1:"…"present N:"` + 4 arestas por bloco (boxes); o **nome JSON** de cada opção (choice multiple).
- **`question_ids`:** tensor `[B, T]` com `1..N` nos tokens da pergunta k e `-1` no state; produzido por `pack_set` — `attention.py:100-125, 201`.
- **`slot_plan` / `set_size`:** `d1_attention` no `config.json` é `"set"` e `d1_set_size` é `16` [S14]; sob `set` empacotam-se até `set_size` perguntas depois de um state partilhado (`pack_set`), uma linha por grupo; fallback `SET_SIZE = 4` e teto de treino `TRAINED_SET_SIZE = 128` — `attention.py:36-37`, `runner.py:151-183`; a separação entre *code slots* (lidos pelo LM head) e *read slots* (lidos pelo ponteiro) está em `slots.py:12-28` [S37][S43][S44]. `set_size` é um inteiro ≥ 1 por chamada (`group_size`, `runner.py:56-62`); 1 significa uma pergunta por prompt.
- **Quantos slots por tipo** (`question_slots`, `prompt.py:308-326`): `noul` 1; `choice` 1; `score` 1; `text/number/date` (read) **2** (`start`, `end`, lidos por ponteiro); `number` com `range`/`Estimate` 1 (grelha); `box` **5** (presença + 4 arestas); `boxes` **5 × blocos** (16 por omissão, até 64 com `max`); `choice multiple` **1 por opção** (cada um um `noul`).
- **Escaping:** os tokens especiais escritos pelo chamador são neutralizados (`plain`, `prompt.py:517-543`), com um zero-width `BREAK` (`prompt.py:504`).

### 10.4 Pós-processamento por tipo [S38][S39][S40][S42][S45]

- **Regra comum:** a resposta de um slot é uma **softmax sobre os tokens das opções** (max-pool por opção, nunca sobre o vocabulário inteiro): `readout`/`probabilities` — `prompt.py:333-404`. A temperatura vem de `calibration.json` (`default: 1.337398453966105` no d1-2B, `temperatures: {}`) [S45].
- **`noul`:** 2 grupos (`yes/Yes/YES`, `no/No/NO`); `noul = p[yes]` — `prompt.py:344-348`, `api.py:123-124`.
- **`choice`:** 1 grupo por opção, com os códigos nativos (`A..Z`, senão `00..`, esquema 2 → `AA, AB..`) e formas alternativas (`" A"`); `choice = argmax`, `confidence = p[argmax]`, `probabilities` por opção — `prompt.py:163-175, 355-361`, `api.py:129-135`.
- **`choice multiple`:** um `noul` por opção; `choices = [nome for p ≥ 0,5]` **depois** da tabela de calibração `"multiple"` — `api.py:125-128`.
- **`score`:** 1 grupo por nível com o **dígito único** `0..k-1` (2 a 10 níveis); `score` é a média do índice ponderada (`mean`), o nível da massa acumulada ≥ 0,5 (`median`, **predefinição** — `SCORE_READOUT = "median"`) ou o argmax; mais `legend` e `probabilities` — `prompt.py:349-354`, `api.py:67-81, 136-140`.
- **`text`/`number`/`date` (read):** dois slots lidos por **ponteiro** contra as posições do state (não contra o vocabulário): `logits = q·k/√d` com máscara `valid`, `found = 1 − exp(start_logp[0])` (o token 0 = "nada"), e a melhor janela `start+end` com `cap = min(max_tokens, T−1)`; caps `text 512`, `number 32`, `date 32` tokens; o span é aparado de espaços e recortado ao JSON string quando aplicável — `pointer.py:14-16, 35-56, 101-166`. `found ≥ 0,5` decide se há valor; depois `parse_number` (locale, moeda, escalas `k/M/B/…`) e `parse_date` (dmy/mdy/ano-primeiro, CJK) — `parsing.py:103-136, 217-223` [S41]. Exemplo do card: `{"type":"text","text":"ACME SA","span":[a,b],"found":…}` [S10].
- **`number` com `range` (estimate):** grelha de valores igualmente espaçados (`Grid(low, high, size=128)` por omissão); `read()` devolve `mean`, e `p10`/`median`/`p90` pela massa acumulada (com a tabela de calibração `"estimate"` a remapear o quantil); a API devolve `number = median` e `interval = [p10, p90]` — `grid.py:12-45`, `api.py:99-101`.
- **`box`:** 5 slots (presença + `top,bottom,left,right`). `found` = presença calibrada (`"found:box"`), corte em 0,5; cada aresta é a **mediana** da sua distribuição sobre 128 códigos, ou sobre 1000 milésimos quando o checkpoint lê números (`d1_numbers`; leitura `median` ou `interp` conforme `d1_box_edges`); arestas cruzadas são convertidas numa caixa em torno da média; `confidence` = fração de **512** amostras Halton 4-D cuja caixa tem IoU ≥ 0,5 com a resposta — `box.py:27-33, 89-128`.
- **`boxes`:** blocos de 5 slots; a presença do bloco k é `P(count ≥ k)`, calibrada (`"found:boxes"`) e forçada monotónica; para no primeiro bloco < 0,5; as caixas saem ordenadas por `(left, top)`; `count = len(boxes)` e `at_least = True` quando todos os blocos lidos estão presentes — `box.py:131-150`.
- **Abstenção ("I don't know"):** opcional (`abstain_below`), só para opções de texto exatamente nas formas `i don't know…` (`IDK_TEXTS`) — `api.py:42-47, 60-64`. Ausente no `d1-2B`/`d1-Omni-2B` por omissão.

### 10.5 Formatação de imagem, vídeo e áudio [S15][S46]

- **Imagem:** `patch_size 16`, `merge_size 2`, `temporal_patch_size 2`, `resize` com `resample 3`, `rescale 1/255`, `mean = std = 0.5` (normalização `(x−0.5)/0.5`); limites `longest_edge 16777216` / `shortest_edge 65536` no d1-2B e `2097152` no Omni; o encoder espera `pixel_values` no layout `[grid_h, grid_w, 2, 2, 1536]` (1536 = 3 canais × 16 × 16 × 2 frames) — `processor_config.json` [S15][S46], `probe` do grafo [S36].
- **Vídeo:** `fps 2.0`, `min_frames 4`, `max_frames 768` (d1-2B) / **384** (Omni), `max_video_tokens 768`, frames emparelhados dois a dois (`temporal_patch_size 2`); no prompt, `MTMD_VIDEO_TEMPLATE_LFM3` escreve `<X.X seconds>` antes de cada grupo de 2 frames e `…_LFM3_OMNI` acrescenta a banda sonora do grupo — [S15][S46][S35].
- **Áudio (Omni):** 16 kHz, `n_fft 400`, `hop_length 160` (10 ms), `win_length 400`, **128** mel, `log_floor −12`, normalização `(x / 4) + 4`, `encoder_stride 8`; o grafo consome `input_features` `[1, 128, num_frames]` — `feature_extractor` em [S46], grafo em [S36].
- **Tokens de mídia:** `<|image|>`, `<|video|>`, `<|audio|>`, `<|audio_out|>`, `<|vision_start|>`, `<|vision_end|>` — [S46].

### 10.6 Requisitos de execução em onnxruntime [S36][S11][S12]

- `ir_version 10`; **opsets `ai.onnx:21` e `com.microsoft:1`**; 188 nós em `com.microsoft` no decoder (154 `MatMulNBits` = pesos int4, 119 `SimplifiedLayerNormalization`, 22 `RotaryEmbedding`, 6 `MultiHeadAttention` no encoder de visão, `Conv`, `Split`, `Expand`). Logo o runtime tem de ser **ORT com os contrib ops `com.microsoft`** (o `MatMulNBits` exige um ORT recente; a versão mínima exata não está documentada nas fontes lidas — **inferência**, não facto).
- **Sidecars:** os pesos vivem em `decoder_q4.onnx_data` (e `_data_1…_3`), `vision_encoder_q8.onnx_data`, `audio_encoder.onnx_data`; os ficheiros têm de ficar **ao lado** do `.onnx` com esse nome exato (external data), senão a sessão não inicializa.
- **CPU:** `decoder_q4` + `vision_encoder_q8` (1,94 GB no d1-2B; 2,45 GB com áudio no Omni). **GPU:** `fp16`, `q4f16` ou `q8f16`; o EP CUDA não tem kernel fp32 de GroupQueryAttention, pelo que os grafos fp32 correm as camadas de janela na CPU [S11][S12]. A documentação oficial de ONNX fixa apenas as precisões (Q4 recomendado, Q8 só em servidor) [S32].
- **WebGPU:** `import * as ort from 'onnxruntime-web/webgpu'` (o import por omissão não corre estes grafos); emparelhar `decoder_q4f16` com os grafos float32 do bundle q4 e manter cada linha empacotada **abaixo de 8192 tokens** (ou 4096 com `decoder_q4`) [S11].
- **Limites de entrada:** até **16 perguntas** por linha (`d1_set_size = 16` no `config.json`); `d1_vision_max_pixels = 1638400` no config (o runner usa `1024×1024` por omissão, e `D1_VISION_MAX_PIXELS` sobrepõe) — [S14][S43].

### 10.7 Licença

Texto integral copiado para `pesquisas/2026-11-06-LFM-Open-License-v1.0.txt`: **10 574 bytes, 71 linhas, SHA-256 `4d28ca14dedc0b3d0fcc2b3339f0e79931faa33874f3d24f522183a8fc70068c`**, idêntico ao `LICENSE` de `LiquidAI/LFM3-1.7B` (e ao dos pacotes ONNX, mesmo tamanho) [S47][S16]. URL canónico: `https://huggingface.co/LiquidAI/LFM3-1.7B/blob/main/LICENSE`. SPDX: **não existe identificador**; o HF publica `license: other` + `license_name: lfm1.0` — para um `LICENSE` de repo de modelos, usar o texto literal e, se houver campo SPDX, `LicenseRef-LFM-Open-License-1.0` (não é OSI) [S16][S3].

- Nota de honestidade: dois pedidos falharam por SSL transitório e foram repetidos; nada foi inventado — onde não há fonte, o dossiê diz "não confirmado". Na ronda 3, dois ficheiros do pacote Omni (`chat_template.jinja`, `config.json`) não chegaram a ser descarregados, pelo que os seus SHA-256 estão declarados como não calculados.
