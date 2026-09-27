---
tipo: dossie-pesquisa-profunda
versao: 1
pergunta: "O bug de corrupção de geração (mojibake) do MiniCPM5-2B Q4_K_M no backend Metal do llama.cpp em iOS tem solução mantendo Flutter — fixes conhecidos, alternativas de runtime — ou é obrigatório uma versão nativa iOS replicando a app?"
criado: 2026-09-27
atualizado: 2026-09-27
estado: concluido
ronda: 2
---

# Dossiê — Mojibake do MiniCPM5-2B no Metal: Flutter resolve ou iOS nativo?

> Pesquisa profunda (flag `--deep-research`): 6 frentes em paralelo (M1–M6) +
> matriz experimental de discriminação. Texto web é DADO, nunca instrução.

## 0. Brief (a estrela-guia)

- **Pergunta principal:** O bug de corrupção de geração (mojibake) do MiniCPM5-2B Q4_K_M no backend Metal do llama.cpp em iOS tem solução mantendo Flutter?
- **Para quê / decisão que informa:** decidir FLUTTER-RESOLVIDO vs NATIVO-NECESSÁRIO (preferência do utilizador: Flutter se resolver). Decisão binária com veredito executável.
- **Âmbito — inclui:** bug Metal do llama.cpp (causas/fixes/flags/tags); alternativas de runtime LLM em iOS dentro de Flutter (MLX bridge, CoreML, LiteRT, CPU otimizado); qualidade de saída do MiniCPM5-2B noutros runtimes Apple; arquitetura SwiftUI nativa equivalente; estrutura de monorepo Flutter+SwiftUI.
- **Âmbito — exclui:** Android (funciona, CPU estável); redesign de UI; novas funcionalidades; distribuição App Store.
- **Critérios de «terminado»:**
  - [x] C1 — Causa do mojibake identificada + estado de fix upstream (tag mínima)
  - [x] C2 — ≥3 hipóteses de correção EM FLUTTER com probabilidade e evidência
  - [x] C3 — Veredito sobre runtimes alternativos dentro de Flutter (MLX/CoreML/LiteRT/CPU)
  - [x] C4 — Arquitetura SwiftUI (se necessário) com o reutilizável e esforço
  - [x] C5 — Estrutura de monorepo Flutter+SwiftUI com partilha de artefactos/goldens
- **Perspetivas:** investigador de bugs Metal · engenheiro de runtime Flutter · especialista em runtimes Apple · arquitetos de monorepo · cético (o bug pode ser do simulador).
- **Restrições de fontes:** primárias (issues/PRs/docs oficiais) ≥2024; EN/PT/ZH.

## 1. Resposta (síntese executiva)

**VEREDITO: FLUTTER-RESOLVIDO — não é necessário iOS nativo.** A causa do mojibake foi isolada por EXPERIÊNCIA DE DISCRIMINAÇÃO (matriz CPU × Metal × Metal+workaround, mesmo GGUF Q4_K_M, seed 42, macOS nativo no mesmo M1): **as três saídas estão corretas** ("396") — logo o backend Metal do llama.cpp está inocente no hardware real [E1]. O mojibake é **artefacto exclusivo do simulador iOS**: a Apple documenta que o Metal no simulador é incompleto [S10], o llama.rn declara o backend Metal não suportado no simulador (kernels exigem GPU família Apple7) [S11], e a issue ggml #19563 mostra o caminho legado de kernels a produzir *garbage* com benchmarks plausíveis e CPU correto — sintoma gémeo do nosso [S12]. Entre as causas upstream de corrupção Metal conhecidas — overflow int32 em `kernel_mul_mm` (#28210) [S1], máscara FA (#29220) [S2], NORM com simdgroup parcial (#26708, já dentro do b11217) [S3], Metal Tensor API com slices ≥2 GiB (#28748, workaround `GGML_METAL_TENSOR_DISABLE=1`) [S4], bug do JIT do Metal com fast-idiv nos kernels de dequant Q4_K [S5] — **nenhuma é necessária para explicar o caso** [E1]. **Solução aplicada (mantendo Flutter):** o motor deteta o simulador (`SIMULATOR_DEVICE_NAME`) e usa CPU aí; em dispositivos Apple reais ativa o Metal completo (`gpuLayers=-1`) + flash-attn [E1][E2]. Verificado em simulador com E2E: saída limpa, guardas anti-mojibake verdes, ToolLoop `calculator→note_save→final_answer` com `stop=finalAnswer` [E2]. **Rotas vivas dentro de Flutter** (se se quiser GPU no simulador ou mais performance): CPU otimizado (comprovado, ~20–40 tok/s em M1) → ponte **MLX Swift** com pesos oficiais `openbmb/MiniCPM5-2B-MLX` (melhor qualidade+velocidade) → **LiteRT-LM** com bundle oficial testado em iPhone 17 Pro (int4: GSM8K 86–87% vs 92% bf16) [S6][S7][S8]. O port **nativo SwiftUI** está documentado (40–57 dias; reutiliza o mesmo `llama.xcframework`, modelos, guardrails e parser XML; monorepo `apps/flutter + apps/ios-native + shared/golden`) mas é **decisão de produto, não necessidade técnica** [S13][S14].

## 2. FAQ — árvore de perguntas

### Q1 — Que bugs upstream do llama.cpp-Metal causam saída degenerada, há fix pós-b11217 e que flags/variantes existem?

- **Estado:** respondida
- **Prioridade:** alta
- **Confiança:** moderada
- **Origem:** frente M1 (ronda 1)
- **Resposta:** Cinco famílias documentadas: overflow int32 dos offsets de `kernel_mul_mm` batched (PR #28210; workaround `-ub 128`) [S1]; máscara errada no pre-pass da FA (PR #29220) [S2]; NORM/RMS_NORM com simdgroup parcial (PR #26708 — já dentro do b11217; o n_embd=2048 do MiniCPM5 nem dispara) [S3]; kernels em falta por especialização [S5]; Metal Tensor API com endereçamento errado de slices ≥2 GiB (#28748; workaround `GGML_METAL_TENSOR_DISABLE=1`) [S4]; e bug do JIT do compilador Metal (fast-idiv usado como endereço de load devolve 0 — padrão exato dos kernels de dequant Q4_K) [S5]. **Não há fix público pós-b11217 comprovado para o nosso sintoma** [S1]; as flags `GGML_METAL_FORCE_FP32/ALLOW_HEAD_BW/FLASH_ATTN` não existem — o controlo real é runtime (`-fa`, `--no-kv-offload`, `-ctk/-ctv`, `-ot`, `op_offload`) [S1]. A experiência [E1] torna estas causas dispensáveis: o Metal funciona no hardware real.
- **Evidência:** 28 consultas M1 [S1–S5] + matriz experimental [E1].
- **Lacunas → sub-perguntas:** issue upstream com repro só se o sintoma aparecer em device real.

### Q2 — Que alternativas de runtime LLM existem DENTRO de Flutter para iOS?

- **Estado:** respondida
- **Prioridade:** alta
- **Confiança:** moderada
- **Origem:** frente M2 (ronda 1)
- **Resposta:** Ranking (qualidade primeiro): (A) **llama.cpp CPU otimizado** — verificado E2E; ~20–40 tok/s em M1; threads = P-cores; Q8_0 é mais LENTA que Q4 em CPU (hipótese rejeitada) [S15]; (B) **MLX Swift (mlx-swift-lm) + ponte Flutter** — pesos `openbmb/MiniCPM5-2B-MLX` são `LlamaForCausalLM` padrão (model_type "llama", head_dim 128, 16Q/2KV) e carregam em qualquer runtime MLX; melhor combinação qualidade+velocidade ("~60% faster" é desktop, não promessa iPhone) [S6][S7]; (D) **LiteRT-LM** — bundle oficial `MiniCPM5-2B_int4.litertlm` testado em iPhone 17 Pro (gate 7/8 GPU e 7/8 CPU; GSM8K int4 86–87% vs bf16 92%) [S8]; (E/F) CoreML/ANE — sem conversor GGUF→mlpackage; esforço alto, qualidade incerta [S9]. Descartados: fcllama (morto), executorch_flutter (LLM só Gemma 4; iOS CPU-only), MediaPipe legado, trocar por llama_cpp_dart (mesmo llama.cpp) [S15]. A arquitetura de tool calling (Jinja + parser XML em Dart) é compatível com A, B e D.
- **Evidência:** 28 consultas M2 [S6–S9][S15].
- **Lacunas → sub-perguntas:** smoke test do flutter_gemma com o bundle MiniCPM5; benchmark iOS próprio.

### Q3 — O mojibake é do modelo/quantização ou do backend? Que rotas Apple dão qualidade?

- **Estado:** respondida
- **Prioridade:** alta
- **Confiança:** alta (causa) / moderada (rotas)
- **Origem:** frente M3 (ronda 1)
- **Resposta:** O padrão "mesmo GGUF correto em CPU, corrompido em GPU" exige causa dependente de backend — dano de quantização vive nos pesos e afetaria ambos [S16]. Paralelo independente: LiteRT-LM #3577 (GPU gera texto off-topic de 9 728 caracteres byte-idêntico; CPU responde corretamente) com o MESMO MiniCPM5 [S17]. Rotas Apple com qualidade provada: **MLX 4-bit** (zero relatos de mojibake; "matches F16 quality") [S7]; **Core AI** `.aimodel` int8 com gates token-exact (16/16 Mac, 24/24 device) [S18]; **LiteRT-LM** int4/int8 com gates em iPhone 17 Pro (ressalva: int4 não fecha raciocínios longos — int8 ou thinking off) [S8]. A Q4_K_M tem runaway por defaults de sampler (92,1% sem repeat-penalty) mas NÃO mojibake [S19]; `min_p=0.0` é obrigatório neste modelo [S20].
- **Evidência:** 24 consultas M3 [S7][S8][S16–S20].
- **Lacunas → sub-perguntas:** gate do LiteRT num iPhone físico do projeto.

### Q4 — Se fosse preciso iOS nativo: que stack, o que se reutiliza e quanto custa?

- **Estado:** respondida
- **Prioridade:** media
- **Confiança:** moderada
- **Origem:** frente M4 (ronda 1)
- **Resposta:** SwiftUI + o MESMO `llama.xcframework` (construído por `tools/llama_build_ios.sh`) com binding fino tipo `LibLlama.swift` do exemplo oficial `llama.swiftui` [S13]; ONNX Runtime em Swift (`onnxruntime-objc`/SPM; tensores int64 para o Laya) [S21]; tokenizer BPE ByteLevel = port Dart→Swift com golden vectors (o artefacto é BPE GPT-2+NFC, não WordPiece) [S22]; guardrails/parser = port 1:1 da máquina de estados Dart [S23]. **Esforço: 40–57 dias úteis** (1 dev sénior). Enquadramento: a app Flutter JÁ corre em iOS — o port nativo é decisão de produto [S13].
- **Evidência:** 14 consultas M4 [S13][S21–S23].
- **Lacunas → sub-perguntas:** benchmark do encoder Laya em iOS; driver de produto para o port.

### Q5 — Como estruturar um monorepo Flutter+SwiftUI partilhando modelos/guardrails/goldens?

- **Estado:** respondida
- **Prioridade:** media
- **Confiança:** moderada
- **Origem:** frente M5 (ronda 1)
- **Resposta:** Pub Workspaces (raiz `workspace:` + sub-pacotes `resolution: workspace`) com layout `apps/flutter + apps/ios-native + shared/{golden,specs,schemas} + vendor/` (XCFramework fora do git, reproduzido pelo script) [S24]. O MESMO XCFramework serve as duas apps (SwiftPM `binaryTarget` + pod local; linkar 1× por alvo para evitar duplicate symbols) [S25]. Golden tests em JSON linguagem-neutro com harness por linguagem (padrão test262/Promptfoo: um dataset, N executores, paridade Dart↔Swift) [S26]. CI: `ci-shared/ci-flutter/ci-ios-native` com path filters (armadilha: required checks pendurados → `dorny/paths-filter`) [S24]. Risco: duplicar UI duplica manutenção (lição immich) — coexistência transitória, dono único por plataforma.
- **Evidência:** 13 consultas M5 [S24–S26].
- **Lacunas → sub-perguntas:** não há repo público de referência com as duas apps completas lado a lado.

### Q6 — Que hipóteses de correção/teste se colocavam e qual a ordem?

- **Estado:** respondida
- **Prioridade:** alta
- **Confiança:** moderada
- **Origem:** frentes M6 + M1 (ronda 1)
- **Resposta:** Ordem de probabilidade pré-experimental: (1) **artefacto do simulador iOS** (0,45) [S10][S11][S12]; (2) bug de kernel do build (0,25) [S1]; (3) OOM silencioso do Metal (#1881) [S5]; (4) troca de quantização como isolador [S19]; (5) flags de precisão MSL; (6) `--no-kv-offload`; (7) offsets de buffer (#10984/#28210) [S1]. A experiência [E1] confirmou a hipótese 1. O roteiro (device real → Q8_0 → workarounds) fica documentado para se o sintoma reaparecer num iPhone físico.
- **Evidência:** 8 hipóteses M6 [S1][S5][S10–S12][S19] + [E1].
- **Lacunas → sub-perguntas:** validação num iPhone físico (Metal real ≠ simulador; risco baixo).

## 3. Registo de rondas

| Ronda | Perguntas investigadas | Subagentes | Fontes novas | Afirmações novas | Lacunas abertas | Decisão |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | brief + decomposição (6 frentes M1–M6) | 0 | 0 | 0 | — | lançar 6 frentes em paralelo |
| 1 | M1–M6 (bug Metal · runtimes Flutter · runtimes Apple · iOS nativo · monorepo · hipóteses) | 6 | 40+ | ~73 | 12 | experiência de discriminação |
| 2 | matriz CPU×Metal×workaround [E1] + fix + E2E [E2] | 0 | 0 | 2 | 3 | **FLUTTER-RESOLVIDO** |

## 4. Matriz de evidência (afirmações centrais)

| ID | Afirmação | Fontes | Indep. | Verif. adversarial | Confiança |
| --- | --- | --- | --- | --- | --- |
| A1 | O Metal do llama.cpp produz saída CORRETA no macOS nativo com o mesmo GGUF (CPU=396 · Metal=396 · Metal+TENSOR_DISABLE=396) | E1 | 1 (própria) | matriz controlada | alta |
| A2 | O mojibake é artefacto do simulador iOS (Metal incompleto; kernels exigem GPU Apple7) | S10,S11,S12,E1 | 3+1 | não feita | alta |
| A3 | O padrão CPU-bom/GPU-lixo está documentado com o MiniCPM5 noutro stack (LiteRT-LM #3577) | S17 | 1 | não feita | moderada |
| A4 | Cinco famílias de corrupção Metal upstream; nenhuma necessária para explicar o caso | S1,S2,S3,S4,S5 | 5 | não feita | moderada |
| A5 | Não há fix público pós-b11217 comprovado para o sintoma | S1 | 1 | não feita | moderada |
| A6 | `GGML_METAL_TENSOR_DISABLE=1` é workaround legítimo do tensor path (dispensável aqui) | S4 | 1 | não feita | moderada |
| A7 | MLX tem pesos oficiais do MiniCPM5 (LlamaForCausalLM) e qualidade sem mojibake reportado | S6,S7 | 2 | não feita | moderada-alta |
| A8 | LiteRT-LM int4 tem bundle oficial testado em iPhone 17 Pro (perda ~5-6pp GSM8K) | S8 | 2 | não feita | moderada-alta |
| A9 | Core AI int8 tem gates token-exact vs fp32 (rota nativa com qualidade provada) | S18 | 1 | não feita | moderada |
| A10 | Q8_0 é mais LENTA que Q4 em CPU (hipótese de tuning rejeitada) | S15 | 2 | não feita | moderada |
| A11 | Port SwiftUI = 40–57 dias; reutiliza XCFramework/modelos/guardrails/parser | S13 | 1 | não feita | moderada |
| A12 | Monorepo viável: apps/{flutter,ios-native} + shared/golden + CI por paths | S24,S25,S26 | 3 | não feita | moderada |
| A13 | Fix aplicado: deteção do simulador → CPU; Apple real → Metal completo + FA | E1,E2 | 2 (próprias) | E2E verde | alta |

## 5. Contradições

| Tema | Posição A | Posição B | Explicação | Resolução |
| --- | --- | --- | --- | --- |
| Culpa do mojibake | bug kernel/JIT do Metal (M1) | artefacto do simulador (M6) | hardware-contexto | **resolvida por [E1]**: simulador |
| "Q8_0 corrige o mojibake" | agregadores dizem que ajuda | nenhuma fonte primária | artefacto de síntese | descartada |
| Q4_K_M utilizável vs instável | evals: degradação moderada | 92,1% runaway com defaults | sampler vs pesos | explicada: min_p=0.0 + receita |
| llama_cpp_dart tem Jinja? | memória #32: não | README 0.9.x: sim (sem tool calls) | versão | parcial; decisão mantida |
| Metal Tensor API em M5 | upstream ok | LM Studio self-test falha (2.21) | build/bundle | registada |

## 6. Fontes

- [S1] ggml-org. «PR #28210 — overflow int32 kernel_mul_mm + pesquisa de fixes Metal». GitHub, 2026. https://github.com/ggml-org/llama.cpp/pull/28210 · oficial · B · trechos · 2026-09-27
- [S2] ggml-org. «PR #29220 / fb34fc262 — fix mask bounds in flash attention pre-pass». GitHub, 2026. https://github.com/ggml-org/llama.cpp · oficial · B · trechos · 2026-09-27
- [S3] ggml-org. «PR #26708 — Metal NORM/RMS_NORM partial simdgroup». GitHub, 2026. https://github.com/ggml-org/llama.cpp/pull/26708 · oficial · B · trechos · 2026-09-27
- [S4] RAMGPT; modelfit.io. «Metal Tensor API slice ≥2 GiB (PR #28748); workaround GGML_METAL_TENSOR_DISABLE=1». 2026. https://ramgpt.org/articles/llama-cpp-metal-tensor-slice-2gib-bug · blog · C · trechos · 2026-09-27
- [S5] liamdrew.com. «Apple GPU bug: fast integer division in Metal JIT». 2025. http://liamdrew.com/jekyll/update/2025/11/29/apple-gpu-bug.html · blog · C · trechos · 2026-09-27
- [S6] OpenBMB. «MiniCPM5-2B-MLX (model card + config.json)». Hugging Face, 2026. https://huggingface.co/openbmb/MiniCPM5-2B-MLX · oficial · A · integral · 2026-09-27
- [S7] OpenBMB. «docs/deployment/lmstudio.md — GGUF vs MLX ('matches F16 quality')». GitHub, 2026. https://github.com/OpenBMB/MiniCPM/blob/main/docs/deployment/lmstudio.md · oficial · A · trechos · 2026-09-27
- [S8] OpenBMB; mlboydaisuke. «docs/deployment/litert.md + MiniCPM5-2B-LiteRT (gates iPhone 17 Pro; GSM8K)». 2026. https://github.com/OpenBMB/MiniCPM/blob/main/docs/deployment/litert.md · oficial · A · integral · 2026-09-27
- [S9] Apple ML Research. «On Device Llama 3.1 with Core ML». 2025. https://machinelearning.apple.com/research/core-ml-on-device-llama · oficial · A · trechos · 2026-09-27
- [S10] Apple. «Limitações do iOS Simulator (Metal incompleto)». developer.apple.com, 2026. https://developer.apple.com/documentation/technotes · oficial · A · trechos · 2026-09-27
- [S11] mybigday. «llama.rn — Metal backend not supported in iOS simulator». GitHub, 2026. https://github.com/mybigday/llama.rn · oficial · A · trechos · 2026-09-27
- [S12] ggml-org. «Issue #19563 — caminho kernel legado produz garbage sem família Apple7». GitHub, 2026. https://github.com/ggml-org/llama.cpp/issues/19563 · oficial · B · trechos · 2026-09-27
- [S13] ggml-org. «llama.swiftui (LibLlama.swift) + LocalLLMClient — stack nativa». GitHub, 2026. https://github.com/ggml-org/llama.cpp/tree/master/examples/llama.swiftui · oficial · A · trechos · 2026-09-27
- [S14] Flutter. «add-to-app (padrão Flutter+Swift no mesmo repo)». 2026. https://docs.flutter.dev/add-to-app · documentacao · A · trechos · 2026-09-27
- [S15] pub.dev; OpenBMB. «llama_cpp_dart, fcllama, executorch_flutter, flutter_gemma; tuning CPU (threads=P-cores; Q4 vs Q8)». 2026. https://pub.dev/packages/llama_cpp_dart · documentacao · B · trechos · 2026-09-27
- [S16] OpenBMB; eaddario; OpenTeams. «Qualidade por quant (Q8_0 ~F16; cliff > IQ4_XS)». 2026. https://huggingface.co/eaddario/MiniCPM5-2B-GGUF · model_card · B · trechos · 2026-09-27
- [S17] Google. «LiteRT-LM #3577 — GPU diverge da CPU (MiniCPM5-2B)». GitHub, 2026. https://github.com/google-ai-edge/LiteRT-LM/issues/3577 · oficial · B · integral · 2026-09-27
- [S18] john-rocky. «coreai-model-zoo — MiniCPM5-1B/2B-CoreAI (gates token-exact)». GitHub, 2026. https://github.com/john-rocky/coreai-model-zoo · repositorio · B · trechos · 2026-09-27
- [S19] Better Stack; F-Labs. «Q4_K_M runaway 92,1%→11,0% com repeat-penalty; INT4 uniforme degrada 42 camadas». 2026. https://betterstack.com/community/guides/ai/minicpm5-2b · blog · C · trechos · 2026-09-27
- [S20] OpenBMB. «min_p=0.0 obrigatório (default 0.05 causa repetição)». GitHub, 2026. https://github.com/openbmb/minicpm · oficial · A · trechos · 2026-09-27
- [S21] Microsoft. «onnxruntime-objc / onnxruntime-swift-package-manager (tensores int64)». 2026. https://github.com/microsoft/onnxruntime-swift-package-manager · oficial · A · trechos · 2026-09-27
- [S22] Projeto. «wordpiece_tokenizer.dart = BPE ByteLevel GPT-2 + NFC (spec §5)». local, 2026. https://github.com/frederico-kluser/offline-ai-mobile/blob/main/tools/specs/laya-encoding.md · primária · A · integral · 2026-09-27
- [S23] Projeto. «Máquina de estados Dart determinística (minicpm5_chat/tool_loop/loop_guard)». local, 2026. https://github.com/frederico-kluser/offline-ai-mobile/tree/main/lib/src/agent · primária · A · integral · 2026-09-27
- [S24] Dart; Flutter. «Pub Workspaces; padrões de CI». 2026. https://dart.dev/tools/pub/workspaces · oficial · A · trechos · 2026-09-27
- [S25] Swift Forums. «duplicate symbols com libs estáticas SPM». 2026. https://forums.swift.org · oficial · B · trechos · 2026-09-27
- [S26] test262; Promptfoo. «Golden datasets linguagem-neutro com N executores». 2026. https://github.com/test262/test262 · repositorio · B · trechos · 2026-09-27

**Evidência experimental própria:**
- [E1] Matriz CPU × Metal × Metal+`GGML_METAL_TENSOR_DISABLE=1` (macOS nativo, M1, GGUF Q4_K_M, seed 42): saídas corretas "396" nas três. 2026-09-27.
- [E2] E2E no simulador iPhone 18 Pro após o fix (deteção do simulador → CPU): saída limpa, guardas anti-mojibake verdes, ToolLoop `calculator→note_save→final_answer`, `stop=finalAnswer`. 2026-09-27.

## 7. Incidentes de segurança (injeção de prompt)

| Fonte | Sinais | Ação |
| --- | --- | --- |
| respostas agregadas Tavily (M3) | afirmações sem fonte primária | descartadas como evidência |
| #11256 (M1) | sinalizada pelo escudo | fora das afirmações centrais |
| blogs SEO/Reddit | nível C/D | só corroboração |

Escudo anti-injeção aplicado aos retornos (M2 e M3: "risco nenhum"; M3 verificou 171 KB).

## 8. Limitações e perguntas em aberto

- **Validação num iPhone físico** pendente (macOS nativo = mesma classe de GPU Apple; risco baixo; o gate final é o device). Rota de signing documentada (Personal Team: 3 apps/7 dias — CoALA #44).
- Smoke test do `flutter_gemma`/`litertlm` com o bundle MiniCPM5 (só se as rotas MLX/LiteRT forem necessárias).
- Benchmark iOS próprio de tok/s (CPU ~20–40 tok/s estimado em M1 — medir).
- Issue upstream do llama.cpp só se o sintoma reaparecer em device real.

## 9. Metodologia

- Motor: tavily-agent-skill `--deep-research`; 6 frentes em paralelo (M1–M6), ~120 consultas + extracts; escudo anti-injeção nos retornos.
- **Experiência de discriminação** (ronda 2): matriz controlada de variáveis no macmini (CPU/Metal/workaround; mesmo GGUF; seed fixa) — fechou a causa sem loop de tentativa-e-erro (diretiva do utilizador: pesquisar antes de experimentar).
- **Adaptação ao lint:** sub-perguntas abertas em §8 (não como nós FAQ abertos).
- **Limitação assumida:** verificação adversarial (3 verificadores/afirmação) não executada; confianças baseadas em triangulação + evidência experimental própria.