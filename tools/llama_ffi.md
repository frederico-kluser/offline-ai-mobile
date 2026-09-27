# tools/llama_ffi.md — como o build do llama.cpp foi feito

Nota curta e reproduzível. O script canónico é **`tools/llama_build.sh`**
(este ficheiro documenta o "porquê" e o que foi verificado).

## Versão pinada

| Item | Valor |
|---|---|
| llama.cpp | **tag `b11217`** (release mais recente à data do build; exige-se ≥ b10883 porque o MiniCPM5 é arquitetura/tokenizer novos) |
| Commit | `c9064dded732d81f90b34e6b33d4fbd77cbfa058` |
| Clone | `git clone --depth 1 --branch b11217 https://github.com/ggml-org/llama.cpp tools/llama.cpp` |
| Android NDK | `27.2.12479018` (`/home/ondokai/Android/Sdk/ndk/27.2.12479018`) |
| CMake | `3.22.1` (kit do Android SDK, `bin/cmake` + `bin/ninja`) |
| Toolchain | `build/cmake/android.toolchain.cmake` do NDK |
| ABIs | `x86_64` (emulador) e `arm64-v8a` (device) |
| Plataforma | `-DANDROID_PLATFORM=android-26` (API mínima para `dlopen` por nome de ficheiro) |

Confirmação do suporte MiniCPM5 nesta tag: tokenizer `minicpm5`
(`src/llama-vocab.cpp`, `LLAMA_VOCAB_PRE_TYPE_MINICPM5`) e parser de chat
`common/parsers/minicpm5.cpp`.

## Flags de build (todas no script)

```
-DCMAKE_TOOLCHAIN_FILE=$NDK/build/cmake/android.toolchain.cmake
-DANDROID_ABI=x86_64 | arm64-v8a
-DANDROID_PLATFORM=android-26
-DCMAKE_BUILD_TYPE=Release
-DBUILD_SHARED_LIBS=ON        # libllama.so + libggml*.so
-DGGML_NATIVE=OFF             # sem -march do host (build reproduzível)
-DGGML_OPENMP=OFF             # sem libomp no Android; usa o threadpool do ggml
-DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_TOOLS=OFF
-DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=OFF
-DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_MTMD=OFF
```

Alvo compilado: `cmake --build . --target llama`. As `.so` partilhadas saem
em `<build>/bin/` e são copiadas para
`android/app/src/main/jniLibs/<abi>/{libllama.so,libggml.so,libggml-base.so,libggml-cpu.so}`
(empacotadas pela APK; `android/app/build.gradle(.kts)` declara
`sourceSets { main { jniLibs.srcDirs ... } }`).

## FFI (lib/src/engines/llm_engine_llama.dart)

- `DynamicLibrary.open('libllama.so')` por NOME de ficheiro — obrigatório no
  Android (as libs entram pelo linker da app; `DynamicLibrary.process()` não
  as enxerga).
- **Sem `package:ffi`**: o `pubspec.yaml` não o inclui e não foi alterado; o
  `calloc`/`free` vêm do libc ligados por `dart:ffi`. Se algum dia se quiser
  `package:ffi`, basta adicioná-lo ao pubspec — o motor não o usa.
- Structs por valor (`llama_model_params`, `llama_context_params`,
  `llama_batch`, `llama_sampler_chain_params`) passam-se diretamente — o
  `dart:ffi` atual (Dart 3.13) implementa o ABI C completo (verificado em
  runtime com structs de 56 B por argumento e 104 B de retorno `sret`).
- API da tag `b11217` (não depreciada): `llama_model_load_from_file`,
  `llama_init_from_model`, `llama_model_free`, `llama_memory_clear`,
  `llama_memory_seq_rm`, `llama_vocab_*`, `llama_batch_init/free`,
  `llama_decode`, `llama_sampler_*`. Subconjunto ligado: backend_init,
  model/context default params + init/free, get_vocab, model_n_embd, n_ctx,
  set_n_threads, get_memory, memory_clear, memory_seq_rm, tokenize,
  token_to_piece, vocab_n_tokens, vocab_eos, vocab_is_eog, batch_init,
  batch_free, decode, get_logits_ith, sampler_chain_init/add,
  init_penalties, **init_dry**, init_top_k, init_top_p, init_min_p,
  init_temp, init_dist, init_greedy, sampler_sample, sampler_accept,
  sampler_free.
- **DRY**: `llama_sampler_init_dry` EXISTE nesta tag (com a assinatura da
  b11217: sem `n_ctx_train`; seq breakers por defeito `"\n" ":" "\"" "*"`).
  É ligado defensivamente: se o símbolo faltar, o DRY é ignorado com aviso no
  `GenEnd.error` (sem falha da geração).
- `llama_sampler_sample` já faz `llama_sampler_accept` internamente — o
  `accept` explícito é usado apenas para alimentar a cadeia com os tokens do
  prompt (penalties/DRY corretos).
- Ordem dos samplers: `LlmConfig.samplersOrder`
  (`penalties;dry;top_k;top_p;min_p;temperature`) + terminal
  `llama_sampler_init_dist(seed)`; com `temperature <= 0` o terminal é
  `llama_sampler_init_greedy()` (`temp(0)` + `dist` não é definido).
- Geração corre num **isolate** dedicado; abort por mensagem entre tokens →
  `stopReason: 'aborted'`. 1 `GenDelta` por token + `GenEnd` final.

## Verificação do build

- `file android/app/src/main/jniLibs/*/*.so` → `ELF 64-bit ... x86-64` e
  `ELF 64-bit ... aarch64` (4 libs por ABI).
- `flutter analyze lib/src/engines/llm_engine_llama.dart` → *No issues found*.
- Reexecutar tudo: `./tools/llama_build.sh` (idempotente; `--force` re-clona).