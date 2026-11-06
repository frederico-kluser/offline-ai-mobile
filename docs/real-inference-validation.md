# Validação de inferência real (iOS Simulator)

Executada em 2026-11-06 num Mac mini M1 (16 GB), **iPhone 18 Pro Simulator**
(iOS 27.0, arm64), com os pesos oficiais descarregados do release
`models-lfm3-suite-v1` e do Hugging Face. O simulador corre em **CPU**
(`gpuLayers=0`); o Metal do simulador não é usado.

## Comandos

```bash
flutter test integration_test/real_lfm3_test.dart \
  --dart-define=REAL_LFM3=true -d <sim-udid>

flutter test integration_test/real_d1_test.dart \
  --dart-define=REAL_D1=true -d <sim-udid>
```

Os testes são **opt-in**: sem o `--dart-define` ficam `SKIP`, para a suite
normal não descarregar vários GB. No Android, o download do emulador é lento;
o modelo pode ser pré-carregado com `adb push` para
`app_flutter/models-real/` (foi o que se fez para o gate Android).

## Resultados

| Motor | Artefacto | Resultado | pt/ot | Latência |
|---|---|---|---|---|
| LFM3-1.7B | `LFM3-1.7B-QAD-Q4_0.gguf` | `"Olá! Como posso ajudar você hoje?"` | 37/10 | 380 ms |
| LFM3-VL-2B | `LFM3-VL-2B-Q4_K_M` + `mmproj-Q8_0` | imagem vermelha → `"Vermelho"` | 91/4 | 956 ms |
| LFM3-Audio-2B | `LFM3-Audio-2B-Q4_K_M` + `mmproj-Q8_0` | transcrição exata: `"Olá, mundo! Este é um teste de áudio."` | 60/14 | 1087 ms |
| d1-2B ONNX | `decoder_q4.onnx` + `vision_encoder_q8` | `noul` texto, `D1NoulAnswer`, 0 tokens gerados | 38/0 | 769 ms |
| d1-2B ONNX | idem, com imagem | `noul` visual com `image_features` | 46/0 | 1093 ms |
| d1-Omni ONNX | `decoder_q4` + `audio_encoder_fp16` | `noul` falado com `audio_features` | 70/0 | 1668 ms |
| d1-2B ONNX | `decoder_q4` + `vision_q8`, clipe 2 s | `noul` visual com `video_features` (frames 2 fps) | 50/0 | 1557 ms |
| LFM3-VL-2B | VL + mmproj, clipe 2 s | vídeo vermelho → `"Laranja"` (frames 2 fps via `libmtmd`) | 51/4 | 744 ms |
| LFM3-1.7B | idem, **Android x86_64** | `"Olá! Como posso ajudar você hoje?"` | 37/10 | 137 s* |

\* Emulador Android x86_64 sem dotprod/i8mm (CPU emulada): o tempo não é
representativo de um telefone arm64. O objetivo foi validar o caminho
`libllama.so`/`libmtmd.so` Android, que passou. O modelo foi pré-carregado
via `adb push` para evitar o download lento do emulador.

Os três modelos LFM3 usam o mesmo caminho `llama.cpp b12088` + `libmtmd`:
carregamento, ChatML, template de mídia, amostragem e EOS. O d1 usa o
`onnxruntime_v2` e o contrato de slots/spans.

## Nota sobre o d1 q4f16

O `decoder_q4f16.onnx` oficial (o mais pequeno) **crasha no iOS Simulator**
dentro do kernel `MlasQ8Int8GemmKernelNeon` do ONNX Runtime (SIGSEGV). O
`decoder_q4.onnx` (1,74 GB) corre sem crash e é o bundle por omissão da app
(`d1-2b-onnx-q4`). Em device físico o q4f16 pode funcionar; o fallback q4 é o
caminho validado.

## O que ainda não foi validado com pesos reais

- **Banda sonora de vídeo**: o canal nativo extrai frames a 2 fps (usados
  pelo d1 e pelo `libmtmd`), mas não o áudio do vídeo; o LFM3-Omni com
  vídeo+áudio e o d1-Omni com banda sonora não foram exercitados.
- **d1-Omni imagem/vídeo**: o gate real do d1-Omni cobriu áudio; imagem e
  vídeo foram validados no d1-2B (mesmo `vision_encoder`).
- **Android com pesos reais**: o texto LFM3-1.7B correu no emulador x86_64
  (ver tabela); VL/áudio/d1 reais ainda não correram em Android. O emulador é
  lento e não representa um telefone arm64.
- **d1-Omni imagens/vídeo** não foram exercitados com pesos reais; o gate
  real cobriu texto e áudio (`audio_features`).
- **Metal em device físico**: o simulador usa CPU; o gate Metal do llama.cpp
  continua a ser o runbook do iPhone físico.
