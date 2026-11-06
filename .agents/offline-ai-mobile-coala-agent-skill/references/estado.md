# Estado definitivo — referência rápida da skill

Retrato completo em [`docs/estado-do-projeto.md`](../../../docs/estado-do-projeto.md).

## Identidade

- App Flutter offline para **Liquid AI LFM3 + d1**; Android primeiro, iOS pela mesma camada Dart.
- Migração MiniCPM5-2B + Laya concluída; PR **#1** mergeado em `main` no commit
  **`9ce4da799a24acf95c78f2f93b43e76477f6b845`**.
- Release de modelos **`models-lfm3-suite-v1`** com 15 GGUF/mmproj + manifesto/SHA/licença.
- Repo: <https://github.com/frederico-kluser/offline-ai-mobile>.
- Modelos: <https://github.com/frederico-kluser/lfm3-mobile-models>.

## Camadas

- `domain` — LlmConfig LFM3, D1 types, templates, media, tool spec.
- `agent` — ChatML LFM3, parser XML, Deferred Tool Search, ToolLoop.
- `guardrails` — LoopGuard: passos, ciclos, SER@4, teto `<think>`, mesma query.
- `engines` — llama.cpp b12088 + libmtmd; d1 ONNX; tokenizer BPE.
- `services` — catálogo, downloader, hardware, mídia.
- `ui` — Prompts, Decisões d1, LLM + Tools, Modelos LFM3, Browser.

## Modelos

Ver [`modelos.md`](modelos.md). Resumo: LFM3-1.7B (texto/agente), VL-2B (imagem/vídeo),
Audio-2B (ASR/TTS), Omni-2B (tudo+vídeo+som), d1-2B (10 primitivas), d1-Omni-2B (d1+áudio),
d1-omni-600M (LFM2 legado).

## Mídia

- Imagem: lados múltiplos de 32, ≤1024 px.
- Áudio: WAV PCM16/F32 mono 16 kHz.
- Vídeo: 2 fps + banda sonora WAV 16 kHz (`AVAssetReader`/`MediaCodec`).
- LFM3: `libmtmd` com bitmaps mergeable/is_video e áudio PCM.
- d1: `image_features`/`audio_features`/`video_features`; log-mel 128×frames; `pixel_values`
  `[grid_h,grid_w,2,2,1536]`.

## Qualidade

- `flutter analyze` 0 issues; **79 testes**; APK release 125,3 MB; build nativo b12088 nos dois ABIs.
- Suite `integration_test` verde em iOS e Android; CT-01..CT-12 com SKIP sem pesos.
- Gates reais: texto, VL imagem/vídeo, Audio ASR, Omni vídeo+som, d1 texto/imagem/vídeo/áudio e
  as 10 primitivas. Números em `docs/real-inference-validation.md`.

## Limitações

1. d1 GGUF não executa (sem `/v1/systemone` na API C); usa ONNX.
2. iPhone físico/Metal não validado; simulador em CPU/Skia.
3. Android real: texto e Omni vídeo+som; VL/áudio/d1 reais no iOS.
4. TTS gera PCM 24 kHz e `audioSamples`, mas a UI não reproduz o áudio.
5. d1-Omni imagem/vídeo reais não correram; d1-2B cobre o mesmo vision encoder.
6. d1 `date`/`range`/`box` mostraram limites de precisão no gate real.
