# Migração MiniCPM5-2B + Laya → Liquid AI LFM3 + d1

Este documento regista as decisões de engenharia da migração e as correções ao
guia original, verificadas no dossiê
[`pesquisas/2026-11-06-liquid-ai-lfm3-family-release-lfm3-1-7b-lfm3-vl-2b-lfm3-audi.md`](../pesquisas/2026-11-06-liquid-ai-lfm3-family-release-lfm3-1-7b-lfm3-vl-2b-lfm3-audi.md).

## 1. Mapeamento

| Antes | Depois | Motor |
|---|---|---|
| MiniCPM5-2B GGUF | LFM3-1.7B / VL-2B / Audio-2B / Omni-2B | llama.cpp b12088 + libmtmd |
| Laya 421M ONNX (noul/choice/score) | d1-2B / d1-Omni-2B ONNX + GGUF fallback | onnxruntime_v2 |
| — | d1-omni-600M (LFM2 legado) | llama.cpp, fallback 4 GB |
| parser XML `<function name=…>` | parser XML qwen3_coder superset | Dart |
| prompt MiniCPM5 | ChatML LFM3 + `<think>` + mídia | Dart |
| catálogo de 2 ficheiros | 11 bundles multi-ficheiro | downloader |

## 2. Arquitetura tri-híbrida e orçamento de memória

O LFM3-1.7B tem 24 camadas = **13 convoluções curtas** (kernel 7) + **5 SWA**
(janela 256) + **6 atenção global**. Só as globais fazem crescer o KV:

```
6 camadas × 4 KV heads × 128 dim × 2 (K/V) = 6 144 elementos/token
FP16: 6 144 × 2 B = 12 288 B = 12,29 KB/token
Q8_0: 6 144 × 1 B = 6 144 B = 6,53 KB/token
```

A 32 768 tokens: ~384 MB em FP16 (mais ~2,8 MB fixos de conv/SWA) e ~192 MB
em Q8_0. A app mede e mostra esta estimativa no ecrã Modelos/Definições.

## 3. Motores

### llama.cpp FFI

- Structs sincronizadas com o header b12088; `llama_context_params` inclui
  `moe_cache_size` (size_t) — sem isto o ABI fica desalinhado.
- `n_gpu_layers = 99` (ou -1) em Apple físico com Metal; 0 no simulador iOS e
  por omissão em Android.
- KV cache configurável F16/Q8_0; contexto 8K–32K em mobile.
- `libmtmd` carrega o `mmproj` e avalia chunks de imagem/áudio/vídeo.
- O raciocínio é separado em `GenDelta.thinking` e limitado por
  `maxThinkingTokens`.

### d1 ONNX

- Um ficheiro por pergunta (`D1PromptBuilder.build(index)`), sem padding; a
  resposta é sempre 0 tokens gerados.
- O contrato completo (prompt ChatML, `question_ids`, `slot_positions`,
  `logits [slots,128000]`, `hidden_states [1,seq,2048]`, pointer
  parameter-free e pós-processamento) está em
  [`d1-onnx-contract.md`](d1-onnx-contract.md).
- A via GGUF (`/v1/systemone`) faz `noul/choice/score`; as restantes
  primitivas exigem ONNX.

## 4. Correções ao guia original

1. **`d1-omni-600M` não é LFM3**: o GGUF declara `architecture=lfm2` e foi
   lançado a 07/10/2026 com a família d1-3B. Fica como fallback legado.
2. **b12088 não é o mínimo**: `LLM_ARCH_LFM3` entra em b11938; os templates de
   vídeo LFM3/LFM3_OMNI só em b11960. b12088 é usado por incluir o fix de
   gramática JSON (#31374), vídeo (#31283) e NVFP4 (#31608).
3. **`multiple` e `range` não são `type`**: são flags de `choice` e `number`.
4. **Não existe projetor mtmd “LFM3_OMNI”**: os projetores são `lfm3vl`,
   `lfm3a`, `lfm3a_gen`; os templates de vídeo é que se chamam
   `MTMD_VIDEO_TEMPLATE_LFM3` / `_LFM3_OMNI`.
5. **`/v1/systemone` só aceita `choice`/`score`/`noul`**; o issue #31150
   (router + concorrência) continua aberto.
6. **Quantizações não uniformes**: d1-2B não publica mmproj Q4 e d1-Omni-2B
   não publica pesos Q4; o orçamento sobe para ~2,0–2,2 GB no d1.
7. **Metadados de contexto divergem**: 262 144 no LFM3-1.7B e 128 000 nos
   GGUF VL/Audio/Omni/d1.
8. **“Q4_0” dos benchmarks** é o checkpoint QAD; o repo publica QAD-Q4_0 e
   Q4_K_M.

## 5. Licença

Código MIT. Pesos sob **LFM Open License v1.0** (não é OSI; HF publica
`license: other` / `license_name: lfm1.0`). O §5 limita o uso comercial a
grupos com receita anual < 10 000 000 USD; acima disso é necessária licença
comercial. O texto integral está em
[`pesquisas/2026-11-06-LFM-Open-License-v1.0.txt`](../pesquisas/2026-11-06-LFM-Open-License-v1.0.txt)
e no repo de modelos.

## 6. Limitações conhecidas

- O pipeline ONNX de mídia do d1 exige o processor oficial; o d1 de texto
  (incluindo spans com pointer) está implementado.
- A banda sonora de vídeo ainda não é extraída no dispositivo; os frames a
  2 fps são extraídos por canal nativo.
- O espelho GitHub não tem os pesos completos (limite de tempo/banda); o
  downloader usa o Hugging Face como fallback.
