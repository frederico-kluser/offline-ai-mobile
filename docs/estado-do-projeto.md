# offline-ai-mobile — estado definitivo do projeto

**Data de referência:** 2026-11-06 · **branch principal:** `main` · **merge da migração:**
`9ce4da799a24acf95c78f2f93b43e76477f6b845` (PR #1) · **release de modelos:**
`models-lfm3-suite-v1`.

Este é o retrato da versão **definitiva** da migração MiniCPM5-2B + Laya → **Liquid AI LFM3 + d1**.
Para o guia de cada modelo (para que serve, como usar, links de download) vê
[`modelos.md`](modelos.md).

## 1. O que é a app

App Flutter **offline** de laboratório para a suíte móvel da Liquid AI. Não há pesos no APK: o
utilizador instala bundles multi-ficheiro na pasta privada da app, com SHA-256 e download retomável.
Depois do download, a inferência é local; a rede só é usada no catálogo/download e no browser.

- **Android primeiro**, iOS pela mesma camada de domínio Dart.
- **Qualidade > performance; determinismo > liberdade.**
- Cinco ecrãs: **Prompts**, **Decisões d1**, **LLM + Tools**, **Modelos LFM3**, **Browser**.

## 2. Arquitetura

```
lib/src/domain/      LlmConfig LFM3, D1 types, templates, media, tool spec
lib/src/guardrails/  LoopGuard (passos, ciclos, SER@4, teto de <think>, search_tools)
lib/src/agent/       ChatML LFM3, parser XML qwen3_coder, Deferred Tools, ToolLoop
lib/src/engines/     llama.cpp FFI + libmtmd; d1 ONNX; tokenizer BPE
lib/src/services/    catálogo, downloader Range/SHA, hardware profiler, mídia
lib/src/ui/          Material 3, 5 ecrãs + folhas de configuração
android/ ios/        canais nativos de hardware, frames e banda sonora
tools/               build llama.cpp b12088, release de modelos, manifesto
docs/                migração, contrato d1, CT, modelos, validação real
```

### Motores

| Motor | Usado por | Como funciona |
|---|---|---|
| **llama.cpp b12088 + libmtmd** | LFM3-1.7B/VL/Audio/Omni | `libllama.so`/`.a` + `libmtmd`; mmap dos pesos; KV F16/Q8_0; chunks de imagem/áudio/vídeo; template ChatML LFM3 |
| **onnxruntime_v2** | d1-2B/d1-Omni-2B ONNX | sessões num isolate; prompt ChatML com `question_ids`/`slot_positions`; `logits [slots,128000]`; `hidden_states`; 0 tokens gerados |
| **d1 GGUF** | d1-2B/d1-Omni GGUF | catalogado, mas **não executável** nesta build: `/v1/systemone` não está na API C do llama.cpp b12088; o motor devolve erro explícito |

### Pipeline de mídia

1. **Imagem** → `MediaPreprocessor.prepareImage`: lados múltiplos de 32, lado maior ≤1024, RGB.
2. **Áudio** → WAV PCM16/F32 mono 16 kHz; resample para 16 kHz.
3. **Vídeo** → canal nativo `offline_ai_mobile/media`:
   - frames a **2 fps** (JPEG) via `MediaMetadataRetriever`/`AVAssetImageGenerator`;
   - banda sonora → WAV PCM16 mono 16 kHz via `MediaCodec`/`AVAssetReader`.
4. **LFM3** → `libmtmd` recebe bitmaps `mergeable`/`is_video` e áudio PCM.
5. **d1** → `d1_vision.dart` gera `pixel_values [grid_h,grid_w,2,2,1536]`; `d1_audio.dart` gera
   log-mel `[1,128,frames]`; vídeo emparelha frames em `buildD1VideoValues`; o decoder recebe
   `image_features`/`audio_features`/`video_features`.

### KV cache e memória

LFM3-1.7B tem 24 camadas = 13 conv curtas + 5 SWA + 6 atenção global. Só as 6 globais crescem o KV:

- F16: **12,29 KB/token**; Q8_0: **6,53 KB/token**.
- 32 768 tokens: ~384 MB F16 / ~192 MB Q8_0, mais ~2,8 MB fixos.
- Contexto por omissão 8 192; perfis de visão/omni usam 16 384; até 32 768 em mobile.

## 3. Ecrãs e fluxos

### Prompts · LFM3
Banco de testes de prompts: template, system/user prompt, anexos imagem/vídeo/áudio, perfil de
amostragem, `<think>` separado, métricas (pt/ot/tok/s), fingerprint, histórico e diff golden.
A app escolhe o modelo compatível com os anexos: texto → LFM3-1.7B; imagem/vídeo → VL/Omni; áudio →
Audio/Omni.

### Decisões d1
Templates das 10 primitivas, editor de `state`, anexos, perguntas faladas (d1-Omni), respostas com
probabilidades, spans e caixas desenhadas sobre a imagem. O d1-2B ONNX cobre as 10; o d1-Omni ONNX
acrescenta áudio; o GGUF d1 não é executável.

### LLM + Tools
Agente LFM3 com 50+ ferramentas **deferidas**: o modelo só vê `search_tools` + `final_answer`; quando
chama `search_tools`, o resultado injeta os esquemas em `<additional_tools>` na mensagem
`<tool_response>`. A timeline mostra raciocínio, chamadas, resultados e cortes do LoopGuard
(passos, ciclos, SER@4, mesma query, teto de `<think>`).

### Modelos LFM3
Perfilador de hardware (Tier 1/2/3), micro-benchmark real, catálogo de 11 bundles, download com
progresso/Range, verificação SHA-256, remoção e estado instalado.

### Browser
Browser embutido (`flutter_inappwebview`) com teclas humanas, piloto **d1** (System One) e agente
**LFM3** (tool calling). Gates de injeção/irreversibilidade antes de ações perigosas.

## 4. Catálogo de modelos

Resumo; detalhes, links e SHA em [`modelos.md`](modelos.md).

| Bundle | Tamanho | Papel |
|---|---:|---|
| `lfm3-1.7b-q4_0` | 1,05 GB | texto/agente essencial (QAD) |
| `lfm3-1.7b-q4_k_m` | 1,10 GB | variante K-quant |
| `lfm3-1.7b-q8_0` | 1,85 GB | máxima qualidade, Tier 3 |
| `lfm3-vl-2b-q4_k_m` | 1,30 GB | visão, OCR, grounding, vídeo 2 fps |
| `lfm3-audio-2b-q4_k_m` | 1,40 GB | ASR, LiveASR, TTS 24 kHz |
| `lfm3-omni-2b-q4_k_m` | 1,39 GB | texto+imagem+vídeo+som+áudio |
| `d1-2b-q4_k_m` | 1,30 GB | d1 GGUF parcial (não executável) |
| `d1-omni-2b-q8_0` | 2,17 GB | d1 Omni GGUF parcial (não executável) |
| `d1-omni-600m-legacy-q8_0` | 0,67 GB | fallback LFM2 legado |
| `d1-2b-onnx-q4` | 1,96 GB | **d1 completo** (10 primitivas) |
| `d1-omni-2b-onnx-q4` | 2,21 GB | **d1 completo + áudio/voz** |

**Origem:** espelho [`lfm3-mobile-models`](https://github.com/frederico-kluser/lfm3-mobile-models)
(release `models-lfm3-suite-v1`) para todos os GGUF/mmproj; Hugging Face oficial para os grafos ONNX
(`LiquidAI/d1-2B-ONNX`, `LiquidAI/d1-Omni-2B-ONNX`). O `manifest.json` e o `SHA256SUMS.txt` do release
são a fonte de verdade de tamanhos e hashes.

### Como o downloader funciona
- catálogo com 11 bundles e ficheiros individuais;
- espelho primeiro para GGUF (se o ativo existir), HF como fallback;
- `.part` + HTTP `Range` para retomar;
- SHA-256 por ficheiro (quando publicado);
- rename atómico e `.bundle.json` com o manifesto instalado;
- `verify`/`delete` por bundle; nada é apagado sem pedido.

## 5. Build

```bash
# Android: llama.cpp b12088 + libmtmd (NDK 27.2, CMake 3.22.1)
bash tools/llama_build.sh

# iOS: XCFramework com llama + mtmd
bash tools/llama_build_ios.sh

# uma vez por máquina, AGP 9 + flutter_inappwebview
bash tools/patch_inappwebview_agp9.sh

# app
flutter build apk --release
flutter build ios --no-codesign      # ou --simulator
```

Requisitos: Flutter 3.47+, Android SDK 36/NDK 27.2, Xcode 27+.
O script Android publica `libllama.so`, `libmtmd.so`, `libggml*.so` em
`android/app/src/main/jniLibs/{arm64-v8a,x86_64}/`; o iOS gera
`ios/pods/llama_ffi/llama.xcframework` com `ios-arm64` e `ios-arm64-simulator`.

## 6. Testes e validação

```bash
flutter analyze                       # 0 issues
flutter test                          # 79 testes
flutter test integration_test -d ...  # CT-01..CT-12 + hardware + arranque; SKIP sem pesos
```

Gates reais (opt-in, descarregam pesos):

```bash
flutter test integration_test/real_lfm3_test.dart --dart-define=REAL_LFM3=true -d <device>
flutter test integration_test/real_d1_test.dart   --dart-define=REAL_D1=true  -d <device>
```

### Resultados reais (iOS Simulator, CPU; Android x86_64 quando indicado)

| Gate | Resultado |
|---|---|
| LFM3-1.7B texto | `"Olá! Como posso ajudar você hoje?"` · 37/10 · 380 ms |
| LFM3-VL-2B imagem | `"Vermelho"` · 91/4 · 956 ms |
| LFM3-VL-2B vídeo 2 fps | `"Laranja"` · 51/4 · 744 ms |
| LFM3-Audio-2B ASR | transcrição exata `"Olá, mundo! Este é um teste de áudio."` · 60/14 · 1 087 ms |
| LFM3-Omni-2B vídeo+som | 4 frames + 31 983 amostras → `"Um som de sinto de um sino."` · 83/10 · 1 201 ms |
| LFM3-Omni-2B vídeo+som (Android) | 4 frames + 32 322 amostras · 84/9 · 293 s (emulador) |
| d1-2B texto | `noul` · 38/0 · 769 ms |
| d1-2B imagem | `noul` visual · 46/0 · 1 093 ms |
| d1-2B vídeo | `noul` com `video_features` · 50/0 · 1 557 ms |
| d1-Omni-2B áudio | `noul` falado · 70/0 · 1 668 ms |
| d1-2B 10 primitivas | 842 tokens · 13 273 ms; `noul`/`choice`/`number` certos, `text` parcial, `date`/`range`/`box` limites |
| LFM3-1.7B Android | mesma resposta · 37/10 · 137 s (emulador) |

**Builds verificados:** `flutter analyze` 0; 79 testes; APK release 125,3 MB com libs arm64/x86_64;
iOS build + suite `integration_test`; Android suite; `libllama`/`libmtmd` b12088 nos dois ABIs.

## 7. Decisões e correções ao guia

- `d1-omni-600M` é **LFM2 legado**, não LFM3.
- b12088 não é o mínimo (LFM3 entra em b11938; vídeo em b11960), mas inclui fixes de gramática,
  vídeo e NVFP4.
- `multiple` e `range` são **flags**, não tipos.
- Não existe projetor mtmd “LFM3_OMNI”; os projetores são `lfm3vl`, `lfm3a`, `lfm3a_gen`.
- `/v1/systemone` só expõe `noul`/`choice`/`score`; o caminho completo é ONNX.
- O `decoder_q4f16` oficial crasha no kernel MLAS int8 do iOS Simulator; a app usa **q4** e
  `vision_encoder_q8`/`audio_encoder_fp16`.
- O d1 não usa a banda sonora do vídeo; usa frames 2 fps. A banda sonora é do LFM3-Omni.
- O simulador iOS usa **Skia** (`FLTEnableImpeller=false`) porque o Impeller/Metal do simulador
  pintava a janela de branco; o Metal do llama.cpp é para device físico.

## 8. Limitações atuais

1. **d1 GGUF** (`d1-2b-q4_k_m`, `d1-omni-2b-q8_0`): catálogo presente, mas o motor não executa porque
   a build llama.cpp não expõe `/v1/systemone`; usa ONNX.
2. **iPhone físico/Metal**: não validado neste ambiente; o simulador corre em CPU. Runbook em
   [`runbook-iphone-fisico.md`](runbook-iphone-fisico.md).
3. **Android com pesos reais**: cobertos texto e Omni vídeo+som; VL/áudio/d1 reais ficaram no iOS.
4. **TTS**: o motor produz amostras PCM 24 kHz e `GenEnd.audioSamples`, mas a UI atual não reproduz
   esse áudio; o ASR está validado.
5. **d1-Omni imagem/vídeo**: o gate real do Omni cobriu áudio; imagem/vídeo foram validados no d1-2B
   (mesmo `vision_encoder`).
6. **d1 precisão**: no gate real das 10 primitivas, `date` não encontrou a data e `range` deu 33,1 em
   vez de 42,5; é uma limitação do modelo/prompt, não do decode (os testes sintéticos passam).

## 9. Segurança, privacidade e licença

- **Offline por omissão**: pesos locais; sem telemetria; rede só para downloads e browser.
- **Browser**: gates para injeção de prompt, ações irreversíveis e escape hatch JS só humano.
- **CoALA local**: memória SQLite na pasta `.agents`; sem segredos; proveniência `owner > agent >
  untrusted`.
- **Código:** MIT. **Pesos:** LFM Open License v1.0; §5 limita uso comercial a grupos com receita
  anual < 10 000 000 USD; acima disso é necessária licença comercial. O `d1-omni-600M` é LFM2 legado.

## 10. Mapa de ficheiros que interessam

| Quero… | Vou a… |
|---|---|
| instalar/usar modelos | [`modelos.md`](modelos.md) · `lib/src/services/model_registry.dart` |
| perceber o motor llama.cpp | `lib/src/engines/llama_lfm3_ffi_engine.dart` · `mtmd_bindings.dart` · `tools/llama_ffi.md` |
| perceber o d1 | `lib/src/engines/d1_onnx_engine.dart` · `d1_prompt.dart` · `d1_output.dart` · [`d1-onnx-contract.md`](d1-onnx-contract.md) |
| perceber o agente/tools | `lib/src/agent/` · `lib/src/guardrails/loop_guard.dart` |
| perceber as telas | `lib/src/ui/` |
| perceber downloads | `lib/src/services/download_manager.dart` |
| correr testes reais | `integration_test/real_lfm3_test.dart` · `real_d1_test.dart` · [`real-inference-validation.md`](real-inference-validation.md) |
| build nativo | `tools/llama_build.sh` · `tools/llama_build_ios.sh` · [`../tools/llama_ffi.md`](../tools/llama_ffi.md) |

## 11. Ligação ao CoALA

A skill local do projeto é
[`offline-ai-mobile-coala-agent-skill`](../.agents/offline-ai-mobile-coala-agent-skill/SKILL.md).
Começa sempre por:

```bash
COALA="python3 .agents/offline-ai-mobile-coala-agent-skill/scripts/coala.py"
$COALA map
$COALA recall "<tarefa>" --budget 1500
```

A memória é o índice; o código e estes documentos são a verdade.
