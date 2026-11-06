# Modelos — referência rápida da skill

O guia completo, com todos os links, SHA e passos, está em
[`docs/modelos.md`](../../../docs/modelos.md). Esta página é o resumo que a memória usa.

## Tabela

| Modelo | Para que serve | Bundle principal | Download |
|---|---|---|---|
| LFM3-1.7B | texto, `<think>`, agente/tools, JSON | `lfm3-1.7b-q4_0` (1,05 GB) | [release](https://github.com/frederico-kluser/lfm3-mobile-models/releases/download/models-lfm3-suite-v1/LFM3-1.7B-QAD-Q4_0.gguf) · [HF](https://huggingface.co/LiquidAI/LFM3-1.7B-GGUF) |
| LFM3-VL-2B | imagem, OCR, grounding, vídeo 2 fps | `lfm3-vl-2b-q4_k_m` (1,30 GB) | [HF](https://huggingface.co/LiquidAI/LFM3-VL-2B-GGUF) |
| LFM3-Audio-2B | ASR, LiveASR, TTS 24 kHz, voz | `lfm3-audio-2b-q4_k_m` (1,40 GB) | [HF](https://huggingface.co/LiquidAI/LFM3-Audio-2B-GGUF) |
| LFM3-Omni-2B | texto+imagem+vídeo+som+áudio | `lfm3-omni-2b-q4_k_m` (1,39 GB) | [HF](https://huggingface.co/LiquidAI/LFM3-Omni-2B-GGUF) |
| d1-2B | 10 primitivas sem gerar texto | `d1-2b-onnx-q4` (1,96 GB) | [HF ONNX](https://huggingface.co/LiquidAI/d1-2B-ONNX) |
| d1-Omni-2B | d1 + áudio/perguntas faladas | `d1-omni-2b-onnx-q4` (2,21 GB) | [HF ONNX](https://huggingface.co/LiquidAI/d1-Omni-2B-ONNX) |
| d1-omni-600M | fallback LFM2 legado, 4 GB | `d1-omni-600m-legacy-q8_0` (0,67 GB) | [HF](https://huggingface.co/LiquidAI/d1-omni-600M-GGUF) |

## Regras de uso

- **Gerar** texto → LFM3. **Decidir** sem gerar → d1.
- Texto/agente → 1.7B; imagem/vídeo → VL; áudio → Audio; tudo/vídeo com som → Omni.
- d1 completo → ONNX `d1-2b-onnx-q4`; d1 com áudio → `d1-omni-2b-onnx-q4`.
- d1 GGUF (`d1-2b-q4_k_m`, `d1-omni-2b-q8_0`) está catalogado mas **não executa** nesta build:
  `/v1/systemone` não está na API C do llama.cpp b12088. Usa ONNX.
- `box`/`boxes` no d1 exigem **exatamente uma** imagem.
- d1 não usa a banda sonora do vídeo; usa frames a 2 fps. A banda sonora é do LFM3-Omni.
- O `decoder_q4f16` oficial crasha no iOS Simulator (MLAS int8); a app usa q4 + vision q8/audio fp16.

## Onde estão os ficheiros

- Catálogo: `lib/src/services/model_registry.dart`.
- Download/instalação: `lib/src/services/download_manager.dart`.
- Manifesto/hashes: repositório `lfm3-mobile-models`, release `models-lfm3-suite-v1`.
- Pasta local: `Documentos-da-app/models/<localDirName>/` + `.bundle.json`.
- ONNX: `LiquidAI/d1-2B-ONNX/onnx/` e `LiquidAI/d1-Omni-2B-ONNX/onnx/`; sidecar `.onnx_data`
  ao lado do `.onnx`.

## Licença

Código MIT; pesos sob **LFM Open License v1.0**. §5: uso comercial apenas com receita anual do grupo
< 10 000 000 USD; acima disso, licença comercial da Liquid AI.
