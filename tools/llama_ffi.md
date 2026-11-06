# tools/llama_ffi.md — build e FFI do llama.cpp b12088

O script canónico é **`tools/llama_build.sh`** (Android) e
**`tools/llama_build_ios.sh`** (iOS). Este ficheiro regista o "porquê" e o
layout ABI que o `dart:ffi` espelha.

## Versão pinada

| Item | Valor |
|---|---|
| llama.cpp | **tag `b12088`** (2026-11-04) |
| Mínimo LFM3 | `b11938` (primeira tag com `LLM_ARCH_LFM3`) |
| Mínimo vídeo LFM3 | `b11960` (`MTMD_VIDEO_TEMPLATE_LFM3` / `_LFM3_OMNI`) |
| Fix JSON + thinking | `b12005` / PR #31374 (commit `3c809f44`) |
| Vídeo libmtmd | PR #31283 / commit `d4f1b18` |
| NVFP4 | PR #31608 |
| Android NDK | `27.2.12479018` |
| CMake | `3.22.1` (kit do SDK) |
| ABIs | `arm64-v8a` + `x86_64` |
| Plataforma | `android-28` |
| iOS | `iphoneos` + `iphonesimulator`, arm64, mínimo 16.0 |

Porque b12088 e não o mínimo: inclui o fix da gramática JSON com
`enable_thinking=false` (#31374), o vídeo LFM3 (#31283) e NVFP4 (#31608).
A issue #31150 (router + concorrência do `/v1/systemone`) continua aberta —
não usar `-np >= 2` com o decisor.

## Flags de build

```
-DBUILD_SHARED_LIBS=ON
-DGGML_NATIVE=OFF
-DGGML_OPENMP=OFF
-DLLAMA_CURL=OFF
-DLLAMA_BUILD_COMMON=ON
-DLLAMA_BUILD_MTMD=ON
-DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_TOOLS=OFF
-DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=OFF
```

Alvos: `llama` + `mtmd`. As `.so` saem em `<build>/bin/`:
`libllama.so`, `libmtmd.so`, `libggml*.so`; são copiadas para
`android/app/src/main/jniLibs/<abi>/`.

## Structs (ABI b12088)

O layout é copiado de `include/llama.h`. O ponto crítico é o
`llama_context_params`: entre `type_v` e `abort_callback` existe

```c
size_t moe_cache_size; // device cache para experts (0 = desligado)
```

Sem este campo (ausente nas builds antigas) todos os campos seguintes ficam
desalinhados e o `llama_init_from_model` rebenta. O `_ContextParams` do Dart
inclui `@Uint64() moeCacheSize` na posição correta. O resto dos campos
(`n_ctx`, `n_batch`, `n_ubatch`, `n_seq_max`, `n_threads`, `type_k`,
`type_v`, `flash_attn_type`, `samplers`, `ctx_other`) segue o header.

## libmtmd (mtmd.h b12088)

O módulo `libmtmd` é obrigatório para LFM3-VL/Audio/Omni:

- `mtmd_context_params_default` → `mtmd_init_from_file(mmproj, llama_model, params)`;
- `mtmd_support_vision` / `mtmd_support_audio` / `mtmd_get_audio_sample_rate`;
- `mtmd_bitmap_init(nx, ny, RGBRGB…)` e `mtmd_bitmap_init_from_audio(n, F32)`;
- `mtmd_bitmap_set_id` (cache por SHA-256), `set_mergeable`/`set_is_video`
  para frames de vídeo;
- `mtmd_tokenize` com o marcador `<__media__>`;
- `mtmd_helper_eval_chunks(mtmd, llama_ctx, chunks, n_past, seq, n_batch,
  logits_last, &new_n_past)`.

O `_Worker` do motor guarda `mtmd_context*` e liberta-o antes do modelo. Os
frames de vídeo são extraídos a 2 fps pelo canal nativo
`offline_ai_mobile/media` e enviados como RGB; o áudio é WAV PCM16/F32
convertido para 16 kHz.

## FFI

- `DynamicLibrary.open('libllama.so')` / `libmtmd.so` no Android;
  `DynamicLibrary.process()` no iOS/macOS.
- Sem `package:ffi` no motor llama (calloc/free do libc); o módulo mtmd usa
  `package:ffi` para `toNativeUtf8`.
- Structs por valor (`llama_model_params`, `llama_context_params`,
  `llama_batch`, `llama_sampler_chain_params`, `mtmd_context_params`) passam
  diretamente; o `dart:ffi` do Dart 3.13 implementa o ABI C.
- Geração num **isolate** dedicado; abort por mensagem entre tokens.
- Raciocínio `<think>` separado em `GenDelta.thinking`; teto
  `maxThinkingTokens`.

## Verificação

```bash
bash tools/llama_build.sh --force
file android/app/src/main/jniLibs/*/*.so   # ELF 64-bit x86-64/aarch64
flutter analyze lib/src/engines
```

Sem `libmtmd.so` o script falha de propósito: a app não deve arrancar com uma
build que diz suportar VL/Audio/Omni mas não tem o projetor.
