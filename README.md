# offline-ai-mobile

App **offline** de teste de prompts com dois motores locais:

- **MiniCPM5-2B** (LLM 2,5B, Apache 2.0) — geração de texto, modo thinking
  alternável e **tool calling** no formato XML oficial, com guardrails anti-loop;
- **Laya typed-decisions** (decisor "System One", 421M, Apache 2.0) — decisões
  tipadas `noul` / `choice` / `score` com probabilidades calibradas, sem gerar
  texto.

Android primeiro (validado em emulador x86_64 com 8 GB de RAM e GPU), iOS a
seguir (a camada de domínio é 100% Dart). Nenhum modelo vem embutido: a app
descarrega-os por botão para a pasta privada.

**Filosofia: mais qualidade que performance, mais determinismo que liberdade.**

## Telas

| Tela | O que faz |
| --- | --- |
| **Prompts** | banco de testes: system/user prompt, execução, métricas (tokens, latência, motivo de paragem, fingerprint), histórico com diff golden byte-a-byte |
| **Laya** | templates de decisões tipadas editáveis (roteamento PT/EN, guardrails de agente, verificação de negação), execução com probabilidades e confiança, config do motor |
| **LLM + Tools** | configuração completa do MiniCPM5-2B (validada por regras) e demo de tool calling multi-passo com timeline de passos e cortes de guardrail visíveis |
| **Modelos** | descarregar / verificar / apagar artefactos (GGUF Q4_K_M, Q5_K_M e Q8_0 do MiniCPM5-2B; kit ONNX 4-bit do Laya) |

## Determinismo e anti-loops (o cerne)

Defaults impostos pela app — e o porquê, com evidência:

- `min_p = 0.0` **obrigatório**: o default `0.05` do llama.cpp filtra os tokens
  que quebrariam o ciclo e é a causa raiz dos "loops eternos" do MiniCPM5-2B
  (confirmado pela equipa OpenBMB);
- receita oficial do modelo: `temperature 1.0`, `top_p 0.95`, `min_p 0.0` com
  **seed fixa** (nunca `-1`): greedy (temperature 0) *aumenta* o risco de loop;
- **sampler DRY** ativo (`0.8 / 1.75 / 2`, janela 1024) — suprime loops
  verbáticos sem corromper JSON de tool calls (ao contrário de
  `repeat_penalty > 1.05`);
- `max_tokens` com teto explícito sempre (o default do llama.cpp é infinito);
- `repeat_penalty = 1.0` (neutra), `presence/frequency_penalty = 0.0`.

Guardrails de runtime — o prompt é orientação, o enforcement é do código
(`lib/src/guardrails/loop_guard.dart`):

1. máximo de passos do agente (8) e de tool calls consecutivas (6);
2. deteção de ciclo pela chave canónica `ferramenta(argumentos ordenados)` —
   corta na 3.ª repetição e no ping-pong A→B→A→B;
3. repetição degenerada de texto por n-gramas de 4 palavras (SER@4);
4. orçamento de tokens e timeout por passo;
5. validação **rígida** de schema dos argumentos antes de executar (o modelo é
   sugestão, nunca autoridade);
6. resultados de ferramentas truncados com marcador explícito;
7. **resposta final forçada** (uma última chamada sem ferramentas) e fallback
   estático determinístico — nunca loop, nunca crash.

Cada execução é assinada por hash de (modelo + prompt renderizado +
parâmetros + runtime) e o motivo de paragem é sempre explícito (`StopReason`).

## Tool calling

Parser e chat template fiéis ao `chat_template.jinja` oficial do
[openbmb/MiniCPM5-2B](https://huggingface.co/openbmb/MiniCPM5-2B): o modelo emite
chamadas em XML com a tag `function` (atributo `name`) contendo tags `param`
(atributo `name`); valores com caracteres especiais usam CDATA; os resultados
voltam como mensagens `tool_response` agrupadas em papel `user`. O exemplo
embutido (`lib/src/agent/tools.dart`) usa três ferramentas locais determinísticas
— calculadora segura (parser próprio, sem `eval`) e notas `note_save` /
`note_read` — mais a ferramenta de conclusão `final_answer` (sinal explícito de
saída do loop).

## Modelos descarregáveis

| Artefacto | Tamanho | Notas |
| --- | --- | --- |
| MiniCPM5-2B GGUF **Q8_0** | 2,68 GB | **único — o melhor**: qualidade ≈F16 (tabela oficial OpenBMB), thinking fiável; ~3,5 GB em RAM a 8k |
| Laya typed-decisions **ONNX 4-bit** | 428 MB | head fundida (5 inputs → logits + act_logits) + tokenizer WordPiece |

Atenção ao **KV cache** (~42 KB/token neste modelo): 131k de contexto exigiriam
~5,5 GB só de KV — a app usa 8k–16k por defeito. Evitar quantizações ≤ Q3_K
(colapso medido de qualidade). Fontes: [bartowski/MiniCPM5-2B-GGUF](https://huggingface.co/bartowski/MiniCPM5-2B-GGUF),
[openbmb/MiniCPM5-2B-GGUF](https://huggingface.co/openbmb/MiniCPM5-2B-GGUF),
[m1rhan/laya-typed-decisions-ONNX](https://huggingface.co/m1rhan/laya-typed-decisions-ONNX).

## Build (Android)

```bash
# 1. Compilar o llama.cpp para Android (x86_64 do emulador + arm64-v8a)
bash tools/llama_build.sh

# 2. Build do APK
flutter build apk --release

# 3. Instalar num emulador/dispositivo
flutter install
```

Requisitos: Flutter 3.47+, Android SDK 36, NDK 27.2, CMake 3.22.1.

## Build (iOS)

```bash
# 1. Compilar o llama.cpp para iOS (device arm64 + simulador, Metal embutido)
bash tools/llama_build_ios.sh   # gera ios/pods/llama_ffi/llama.xcframework

# 2. Build (simulador ou device)
flutter build ios --no-codesign        # device, sem assinatura
flutter build ios --simulator          # simulador

# 3. Gate de qualidade E2E (MOTORES REAIS dentro da app)
flutter test integration_test -d <sim-udid>
```

Requisitos: Xcode 27+, CocoaPods, CMake. **Nota de GPU**: o Metal do llama.cpp
está validado no macOS nativo (saída correta) e ativa-se automaticamente em
dispositivos Apple reais (`gpuLayers=-1`); o **simulador iOS tem Metal
incompleto** (produz mojibake) e o motor deteta-o, usando CPU aí. O gate final
é um iPhone físico — ver [`docs/runbook-iphone-fisico.md`](docs/runbook-iphone-fisico.md).

## Arquitetura

```
lib/src/domain/      tipos (decisões tipadas, config determinística, registos)
lib/src/guardrails/  LoopGuard — cortes anti-loop determinísticos
lib/src/agent/       chat template + parser XML do MiniCPM5, loop de agente, ferramentas
lib/src/engines/     interfaces + motores (llama.cpp FFI; ONNX Runtime do Laya)
lib/src/services/    catálogo de modelos + download verificado (sha256, .part → instalação atómica)
lib/src/ui/          telas Material 3 (padrão do SO)
pesquisas/           dossiê de pesquisa profunda que fundamenta as decisões
```

## Documentação de origem

As decisões (formato de tool calling, parâmetros anti-loop, quantização,
runtime, guardrails) vêm de uma pesquisa profunda documentada em
[`pesquisas/`](pesquisas/) e do documento técnico do Laya
([`Laya-Documento-Tecnico-Completo.md`](Laya-Documento-Tecnico-Completo.md)).

## Licença

Código: MIT. Modelos: Apache 2.0 (OpenBMB / Convai Innovations).