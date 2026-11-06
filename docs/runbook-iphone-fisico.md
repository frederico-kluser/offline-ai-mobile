# Runbook — gate final no iPhone físico

O simulador iOS tem Metal incompleto; o gate de GPU tem de ser num iPhone
físico. O build já liga `llama.xcframework` (llama + mtmd) por `force_load`.

## Pré-requisitos

1. Mac com Xcode 27+ e o projeto em `/Volumes/Ext2TB/Projects/offline-ai-mobile`.
2. iPhone com Developer Mode e confiança no Mac.
3. `bash tools/llama_build_ios.sh` (gera `ios/pods/llama_ffi/llama.xcframework`).

## Execução

```bash
xcrun devicectl list devices
cd /Volumes/Ext2TB/Projects/offline-ai-mobile
flutter run -d <UDID>
flutter test integration_test -d <UDID>
```

## Critérios de aprovação

- [ ] LFM3-1.7B QAD-Q4_0 gera texto coerente em Metal (`gpuLayers=-1`), sem
      mojibake (detetor de blocos CJK/Cirílico/Kana).
- [ ] ToolLoop: `search_tools` → `<additional_tools>` → `calc_expression` →
      `note_save` → `final_answer`, sem cortes do LoopGuard.
- [ ] d1-2B ONNX decide com `output_tokens == 0`; invoice devolve payee/total/
      due e `found` correto.
- [ ] Perfilador: Tier 2/3, RAM/disco corretos, `performanceCores` ==
      `hw.perflevel0.logicalcpu`.
- [ ] Benchmark: tok/s de prefill/decode medidos e registados; sem Jetsam.
- [ ] Anexo de imagem no Prompts: LFM3-VL-2B descreve/OCR (se instalado).
- [ ] d1-Omni: pergunta falada (WAV 16 kHz) mantém precisão.

## Se o Metal falhar

Aplicar, por esta ordem: `GGML_METAL_TENSOR_DISABLE=1` → KV Q8_0 → flash-attn
off → tag b12088+ (já usada). O simulador deve continuar em CPU.
