# Laya — Documento Técnico Completo (v2.0)
## Modelo de Decisão "System One" de 421M · arquitetura, contrato, instalação, mobile (Flutter/React Native), LLM auxiliar e orquestração

**Data:** 2026-09-27 · **Versão:** 2.0 (complementada com relatório comparativo Jev/CLM/Laya e pesquisa profunda mobile `--deep-research`)
**Elaborado por:** 2 pesquisas profundas (7+7 investigadores, ~140 buscas Tavily, 29+ fontes) + verificação adversarial + instalação e avaliação empíricas reais (Mac Mini M1 16 GB).
**Dossiês de origem:** `pesquisas/laya-jev-clm.md` · `pesquisas/laya-mobile.md`

---

## Índice

1. [Resumo executivo](#1-resumo-executivo)
2. [O que é o Laya](#2-o-que-é-o-laya)
3. [Como funciona: arquitetura, ModernBERT e RLCD](#3-como-funciona-arquitetura-modernbert-e-rlcd)
4. [Contrato de API (wire format)](#4-contrato-de-api-wire-format)
5. [Instalação (servidor/desktop)](#5-instalação-servidordesktop)
6. [Como rodar (servidor)](#6-como-rodar-servidor)
7. [Performance medida (desktop/server)](#7-performance-medida-desktopserver)
8. [Accuracy e calibração](#8-accuracy-e-calibração)
9. [Limitações e armadilhas](#9-limitações-e-armadilhas)
10. [Dicas práticas (checklist)](#10-dicas-práticas-checklist)
11. [Segurança](#11-segurança)
12. [Os três modelos em profundidade: Jev · CLM · Laya](#12-os-três-modelos-em-profundidade-jev--clm--laya)
13. [Mobile · Flutter perto do nativo](#13-mobile--flutter-perto-do-nativo)
14. [Mobile · React Native perto do nativo](#14-mobile--react-native-perto-do-nativo)
15. [Mobile · Formatos e runtimes do Laya](#15-mobile--formatos-e-runtimes-do-laya)
16. [Mobile · Estabilidade de memória: o app não fecha](#16-mobile--estabilidade-de-memória-o-app-não-fecha)
17. [Mobile · LLM auxiliar de geração de texto](#17-mobile--llm-auxiliar-de-geração-de-texto)
18. [Mobile · Orquestração um-de-cada-vez (Thin Decision Layer)](#18-mobile--orquestração-um-de-cada-vez-thin-decision-layer)
19. [Comparação final e veredito](#19-comparação-final-e-veredito)
20. [Fontes](#20-fontes)

---

## 1. Resumo executivo

O **Laya** é uma família de modelos de decisão "System One" da **Convai Innovations** (Nandakishor M), lançada a **2026-09-18** como alternativa open-weights ao Jev da TypeSafe. Encoder **ModernBERT-large congelado (~395M)** + **decision head (~26M)** = **421M parâmetros** (421.293.827 exatos); responde a perguntas tipadas `noul`/`choice`/`score` **sem gerar texto** (`output_tokens: 0`), com contrato `POST /v1/systemone` **drop-in do Jev**. Apache 2.0.

**Números que importam (medições próprias + pesquisa):**

| Dimensão | Achado |
| --- | --- |
| Velocidade (Mac Mini M1, CPU) | **114 ms/decisão** (57–188) — 7× mais rápido que o Jev-API (780 ms), 24× que o CLM (2698 ms) |
| Accuracy (12 casos tipados nossos) | Jev **11/12** · **Laya-typed 10/12** · Laya base 8/12 · CLM 7/12 |
| Calibração | Laya-typed **confiança 0.04 quando erra** (a melhor dos quatro); base e CLM "confiante e errado" |
| JevBench v1.4.2 (único com os 3) | Laya 30.3 (#41) · Jev 63.3 (#2) · CLM 8.6 (#78) |
| Memória | **~1 GB** (vs ~9 GB do CLM) — cabe em qualquer telemóvel moderno |
| Mobile | ONNX 4-bit (428 MB) roda via ONNX Runtime Mobile; **não existe nenhuma medição pública em telemóvel** — benchmark interno obrigatório |
| Companion LLM (mobile) | **MiniCPM5-2B** (2,52B, Apache 2.0, 131k ctx, tool-calling nativo; classe 4B em qualidade) |

**Veredito:** o Laya — sobretudo `laya-typed-decisions` — é o melhor decisor local para apps que precisam de decisões rápidas e baratas (inclusive mobile); para accuracy máxima em decisões difíceis, o Jev continua à frente; o CLM serve para best-of-N/verificação. Em mobile: **Flutter + dart:ffi sobre ONNX Runtime** é o caminho mais próximo do nativo; orquestrar **um modelo de cada vez** com o padrão *Thin Decision Layer* evita os kills de memória (Jetsam/LMK).

---

## 2. O que é o Laya

### 2.1 Identidade

| Campo | Valor |
| --- | --- |
| Nome/família | **Laya** (atenção a homónimos: *Layla AI* = viagens; *aayushch/laya* = app desktop; *withlaya.com* = contabilidade) |
| Organização | **Convai Innovations** (Índia; Nandakishor M / Nandakishor Mukkunnoth) |
| Publicação | **2026-09-18** (EN e typed-decisions); multilingual 2026-09-19 |
| Licença | **Apache 2.0** (código e pesos) |
| Pesos | `huggingface.co/convaiinnovations/laya` (raiz + `multilingual/` + `typed-decisions/`; também repos standalone) |
| Código | `github.com/NandhaKishorM/laya` · PyPI **`laya`** (0.3.x) · SDK JS **`@receptron/laya`** (MIT) |
| API hosted | `laya.studio` (produto separado com créditos) |

### 2.2 A família

| Checkpoint | Backbone | Params | Contexto | Uso |
| --- | --- | --- | --- | --- |
| `laya` (raiz, EN) | ModernBERT-large | **421M** | **512 tok** | texto EN geral |
| `laya-multilingual` | mmBERT-base | **322M** | 1024 (changelog: até 8192) | 100+ línguas |
| `laya-typed-decisions` | ModernBERT-large | **421M** (fine-tuned) | 1024 | **decisões tipadas** ⭐ |

Tamanhos: ~808 MB (EN) / ~647 MB (multilingual) em 16-bit safetensors; bundle ~2.5 GB. Em mobile existe `m1rhan/laya-typed-decisions-ONNX` (**428 MB, 4-bit**, head fundida — ver §15).

### 2.3 Contexto e cronologia

- **2025 (março/setembro):** o autor publica dois preprints (arXiv:2503.23303, arXiv:2510.01237) sobre decisões com RL.
- **2026-09-15:** a TypeSafe lança o **Jev** (fechado; ronda de **US$ 40M liderada pela DCVC**, avaliação ~US$ 200M; equipa com Diogo Almeida — ex-OpenAI, co-criador do RLHF/ChatGPT — Erik Gafni e Sasha Sheng; o nome homenageia o economista W. S. Jevons).
- **2026-09-18:** o Laya nasce como resposta aberta ("*build a completely open, horizontal System 1 decision model family*"). **Controvérsia de prioridade** pública (HN >1300 pts; r/LocalLLaMA ~3000 upvotes) — a imprensa conclui que a reivindicação vale "para os ingredientes" (preprint vertical de conversão de vendas).
- **Receção:** >23k stars na 1ª semana; comunidade dividida (§8.4). Ecossistema: Ollaya (runtime estilo Ollama), laya-mcp, laya-mlx, laya-mps, laya-gguf, Jev Decision Index.

---

## 3. Como funciona: arquitetura, ModernBERT e RLCD

### 3.1 Princípio

Modelo de decisão **não-autoregressivo**: pontua alternativas em vez de gerar texto. Um *state* (texto/JSON) e perguntas tipadas entram; uma distribuição de probabilidade por alternativa sai — numa passagem só.

```
state ──► ModernBERT-large (395M CONGELADO) ──► hidden (último token) ──► decision head (~26M) ──► logits/opção
questions: cada opção/nível vira texto ─────────────────────────────────────────────► softmax → probabilities
```

### 3.2 O ModernBERT-large (o "motor")

- Treinado **de raiz** em ~2 biliões de tokens (inglês + código) — não é um BERT recauchutado.
- **"Profundo e estreito":** 28 camadas, hidden 1024, **GeGLU** (intermédio 5248) em vez de GELU.
- **RoPE** (posicional rotativo) nativo até 8192 tokens; **atenção alternada**: janela local de 128 tokens (FlashAttention-2) na maioria das camadas, atenção **global a cada 3.ª** (FlashAttention-3).
- **Sequence unpadding** (empacotamento vetorial sem zeros de padding) — eficiência de memória/banda.
- No Laya: sobre este encoder, uma **decision head** com 2 camadas transformer + *option-marker scorer* + *act/escalate head*; as opções entram como marcadores ([MASK]-style) e são pontuadas bidirecionalmente num passe só.

### 3.3 Treino com RLCD e *proper scoring rules*

- **RLCD** (*Reinforcement Learning for Calibrated Decisions*): recompensa a **calibração**, não a confiança — "quando não sabe, deve dizer 0.73, não 0.99" (GRPO-style, baselines de média de grupo).
- Perda híbrida: log-loss canónica + **perda esférica** + **Ranked Probability Score** (para a primitiva ordinal `score`).
- Efeito prático: probabilidades que *devem* corresponder a frequências empíricas — mas calibração real é distribuição-dependente (§8).

### 3.4 As três primitivas e a semântica da confiança

| Primitiva | Resposta | Notas |
| --- | --- | --- |
| `noul` | `{"noul": p}` ∈ [0,1] | ⚠️ viés de rótulos `true:`/`false:` (issue #156) |
| `choice` | `{choice, probabilities, confidence, answer_confidence}` | degrada >20 opções |
| `score` | `{score, legend, probabilities, confidence}` | `score` = índice esperado (0-based); primitiva mais fraca (SST-5 0.372) |

**`confidence` do Laya** = `1 − H(p)/log(k)` (choice/score) e `max(p, 1−p)` (noul) — **≠ Jev** (topo − média dos restantes). Limiares calibrados no Jev não transferem.

### 3.5 O Router (família)

O servidor escolhe checkpoint por língua/tarefa (`routing` devolve modelo + deteção de script/idioma; pode-se forçar com `model`). Cuidado: mensagens curtas em PT/ES podem cair no checkpoint inglês (detector heurístico).

---

## 4. Contrato de API (wire format)

### 4.1 Request — `POST /v1/systemone`

```json
{
  "model": "typed-decisions",
  "state": "Customer: my invoice was charged twice and nobody answers the phone!",
  "questions": {
    "department": {"type": "choice", "instructions": "Which team handles this?",
                   "criteria": {"billing": "Charges, invoices, refunds",
                                "support": "Bugs and outages", "operations": "Logistics and shipping"}},
    "urgency":    {"type": "noul", "instructions": "Is this urgent?",
                   "criteria": {"true": "requires action now", "false": "can wait"}},
    "frustration":{"type": "score", "instructions": "How frustrated is the customer?",
                   "criteria": ["Calm", "Annoyed", "Very angry"]}
  }
}
```

### 4.2 Response (real, medido por nós)

```json
{"model": "laya-rl-agent",
 "answers": {
   "department": {"type":"choice","choice":"billing","probabilities":{"billing":0.9364,"support":0.0328,"operations":0.0307},
                  "confidence":0.7445,"answer_confidence":0.9364,"action":{"act_probability":1.0}},
   "urgency":    {"type":"noul","noul":0.8307,"confidence":0.8307,"answer_confidence":0.8307},
   "frustration":{"type":"score","score":1.3711,"legend":{"0":"Calm","1":"Annoyed","2":"Very angry"},
                  "probabilities":{"0":0.0143,"1":0.6002,"2":0.3854},"confidence":0.3313}},
 "usage": {"input_tokens":132,"output_tokens":0},
 "routing": {"model":"english","reason":"English Latin text","detection":{"script":"latin","language":"en"}}}
```

Extras vs Jev: `type`, `answer_confidence`, `action.act_probability`, `routing`, `usage` (superset — clientes Jev tolerantes a extras funcionam). `legend` **existe** no score (confirmado ao vivo). Em SDK JS: `@receptron/laya` → `Laya.load(); laya.systemOne(state, questions)` (igual ao Python a 4 casas).

---

## 5. Instalação (servidor/desktop)

### 5.1 Oficial

```bash
python3 -m venv venv && . venv/bin/activate
pip install "laya[serve]"     # laya + fastapi + uvicorn; pesos baixam de HF no 1.º uso
# export HF_HOME=/disco/para/cache   (opcional: onde gravar os pesos)
```

### 5.2 Verificado por nós — Mac Mini M1 16 GB

```bash
EXT=/Volumes/Ext2TB/laya
mkdir -p "$EXT"/{venv,models,hf-cache,logs}
uv venv "$EXT/venv" --python 3.12
uv pip install --python "$EXT/venv/bin/python" "laya[serve]"

export HF_HOME="$EXT/hf-cache"
export LAYA_HOST=127.0.0.1          # ⚠️ default 0.0.0.0 SEM auth
export LAYA_PORT=8000
export LAYA_DEVICE=cpu              # cuda|cpu (sem MPS documentado)
export LAYA_PRELOAD=1               # pré-carrega os 3 checkpoints
"$EXT/venv/bin/laya-serve" >> "$EXT/logs/laya-serve.log" 2>&1 &
curl -s http://127.0.0.1:8000/health
# {"status":"ok","loaded":["english","multilingual","typed-decisions"],"device":"cpu"}
```

**Resultado medido:** 57–188 ms/decisão em CPU M1 (melhor que os 193–464 ms documentados); 2.2 GB de pesos.

### 5.3 Armadilhas de instalação

1. **`LAYA_MODELS` espera NOMES** (`english`, `multilingual`, `typed-decisions` + aliases) — não caminhos. O local dos pesos é `HF_HOME`.
2. **Bind `0.0.0.0` sem auth** por omissão → use `127.0.0.1` ou `LAYA_API_KEY`.
3. `LAYA_DEVICE` só documenta `cuda|cpu`; código nunca seleciona MPS (`default_device()`).
4. Inspeção de segurança recomendada antes de executar pacotes novos (o README do repo foi sinalizado por prompt_injection numa pesquisa — o pacote instalado verificou-se limpo).

---

## 6. Como rodar (servidor)

| Env var | Predefinido | Função |
| --- | --- | --- |
| `LAYA_HOST` / `LAYA_PORT` | `0.0.0.0` ⚠️ / `8000` | bind/porta |
| `LAYA_DEVICE` | auto (cuda→cpu) | `cuda`\|`cpu` |
| `LAYA_PRELOAD` | off | `1` = carrega os 3 checkpoints ao arrancar |
| `LAYA_MODELS` | todos | nomes a carregar |
| `LAYA_API_KEY` | sem auth | se definido, exige `Authorization: Bearer` |
| `LAYA_THREADS` | auto | threads de CPU |
| `HF_HOME` | `~/.cache/huggingface` | onde gravar pesos |

Endpoints: `POST /v1/systemone` · `POST /v1/rank` (hosted: `/batch`) · `GET /health` · `GET /v1/models`. SDK Python in-process: `laya.load("convaiinnovations/laya").predict(state, questions)`.

---

## 7. Performance medida (desktop/server)

| Hardware | Latência/decisão | Fonte |
| --- | --- | --- |
| Tesla T4 (GPU) | 32.8–39.5 ms (1 pergunta); 7.2 ms em batch-10; 103–332 q/s | oficial |
| CPU x86 | 193–464 ms | README |
| Apple M3 Max (MLX) | P50 13.42 ms (421M) / 7.39 ms (322M) | port laya-mlx |
| **Mac Mini M1 16 GB (CPU, medido por nós)** | **114 ms** (57–188) base · 224 ms typed | avaliação própria |
| VPS 4 vCPU sem GPU | 49.4 s (!) | flowtivity |
| Browser (ONNX/WASM) | 0.8–1.3 s | medium |

Regras: latência **linear no nº de perguntas** (50 perguntas ≈ 340–1000 ms); comprimento do state conta (~6.3k tokens ≈ 2.5 s em Apple GPU); sem GPU não serve request-path interativo.

---

## 8. Accuracy e calibração

### 8.1 JevBench v1.4.2 (842 decisões tipadas; 308 seladas)

| | Laya (base) | Jev 1.13 | CLM-8B |
| --- | --- | --- | --- |
| Score / Rank | 30.3 (#41/89) | **63.3 (#2)** | 8.6 (#78) |
| Intelligence | 36.1 | **53.1** | 22.4 |
| Calibration | 63.7 | **76.3** | 39.8 |
| Sealed | 30.8% | **36.7%** | — |
| Tiers easy/standard/judge/hard | 94/73/69/34% | **100/99/95/74%** | — |

Segundo comparativo independente: **Jev Decision Index** (HF Space). A linha do Laya usa o checkpoint **base** (512 tok, CPU).

### 8.2 Self-reports vs realidade

- Os autores anunciam **0.766 vs 0.727 do Jev** (typed-decisions) e **ECE 0.081** — mas: (a) checkpoint **fine-tuned no train split do próprio benchmark** (avaliado no test split — não é leakage, mas não é zero-shot); (b) **base zero-shot = 0.362** (abaixo da baseline de maioria 0.461); (c) ECE **0.466 bruto** → 0.081 só após temperature refit (0.107 numa avaliação independente; 0.213 vs 0.144 do Jev noutra).
- Head-to-head r/LocalLLM (19 questões, gold sintético): Jev 92.9% vs Laya 65.3% (base) / 71.1% (typed).
- Banking77 (77 opções): Laya 0.425 vs Jev 0.870 (defaults; recuperável com `head_max_len=512`).
- AG News: 95.0% vs 91.0% · MASSIVE (51 línguas): usável em 45.
- Conclusão: **calibração é trabalho, não propriedade** — valide no seu domínio.

### 8.3 O NOSSO eval — 12 casos tipados (Mac Mini M1, mesmo harness)

| Caso | Esperado | Jev | Laya base | Laya typed | CLM |
| --- | --- | --- | --- | --- | --- |
| E01 equipa (EN) | billing | ✅ | ✅ | ✅ | ✅ |
| E02 urgência alta | sim | ✅ 0.77 | ✅ 0.83 | ✅ 0.74 | ✅ 0.89 |
| E03 equipa (PT fatura) | Faturação | ✅ | ✅ | ✅ | ✅ |
| E04 equipa (PT crash) | Suporte | ✅ | ✅ | ❌ Operações | ❌ Faturação |
| E05 equipa (PT encomenda) | Operações | ✅ | ❌ Suporte | ✅ | ✅ |
| E06 negação | não | ✅ 0.16 | ❌ **0.86 sim** | ✅ 0.49 | ❌ **1.00 sim** |
| E07 calibração trivial | não | ✅ 0.05 | ✅ 0.23 | ✅ 0.40 | ❌ **0.94 sim** |
| E08 operação nav | CLICK | ❌ DONE | ❌ DONE | ❌ DONE | ❌ WAIT |
| E09 goal_done falso | não | ✅ 0.03 | ❌ **0.99 sim** | ✅ 0.50 | ✅ 0.06 |
| E10 goal_done verdadeiro | sim | ✅ 0.74 | ✅ 0.84 | ✅ 0.74 | ❌ 0.33 |
| E11 stuck | sim | ✅ 0.98 | ✅ 1.00 | ✅ 0.62 | ✅ 0.96 |
| E12 prompt injection | sim | ✅ 0.99 | ✅ 1.00 | ✅ 0.67 | ✅ 0.96 |
| **TOTAL** | | **11/12** | 8/12 | **10/12** | 7/12 |
| **Conf. quando erra** | | 0.45 | 0.75 | **0.04** ⭐ | 0.68 |

Leituras: o Jev é o mais correto; o **Laya-typed tem a melhor calibração** (duvida quando erra — natural para bandas HITL); base e CLM partilham "confiante e errado" (goal_done falso, negação invertida). E08 é ambíguo por definição (o título já estava visível).

---

## 9. Limitações e armadilhas

1. **Contexto curto:** 512 (base) / 1024 (typed) tokens — estados grandes truncam.
2. **Viés de rótulos no `noul`** (issue #156) — confirmado por nós (E06). Mitigação: `choice` 2-opções neutras.
3. **`score` é a primitiva mais fraca** (SST-5 0.372).
4. **>20 opções degrada** (Banking77 0.425 vs 0.870; parcialmente recuperável com `head_max_len`).
5. **goal_done falso-positivo** em navegação (0.99 no base).
6. **Zero-shot fraco** (0.362 < 0.461) — "a fast base to specialise, not a zero-shot decision engine".
7. **Calibração distribuição-dependente** — recalibrar por tipo de pergunta.
8. **Multilingue fraco em línguas pequenas** (khmer: 0.000 accuracy a 0.952 confiança).
9. **Sem MPS documentado** (cai em CPU — que já é suficiente).
10. **Projeto jovem** (~1 semana à data do estudo), bus factor, controvérsia de prioridade.

---

## 10. Dicas práticas (checklist)

**Modelo:** usar `model: "typed-decisions"` para decisões tipadas; testar os dois checkpoints; medir sensibilidade à ordem das opções (até ~20%).
**Perguntas:** `noul` → preferir `choice` 2-opções neutras; `choice` sempre com opção `none`/`other` e ≤20 opções; `score` com níveis = situações concretas (resultado = índice esperado).
**States:** prosa enxuta (as heads não foram treinadas em JSON bruto); ≤512 tokens; contar em código o que puder ser contado.
**Calibração:** nunca transportar limiares do Jev/CLM; temperature refit por tipo de pergunta; `confidence` é descrição da distribuição, não garantia.
**Operação:** `LAYA_HOST=127.0.0.1`; `LAYA_PRELOAD=1` em produção; registar `routing` nos logs; `usage.output_tokens: 0` é invariante; pinne `laya==0.3.x`.
**Agentes de navegador:** guardrails (stuck/injection) OK; `goal_done` precisa de limiar calibrado; state de navegação cortado a ~512 tokens; fallback para outro decisor em banda cinzenta.

---

## 11. Segurança

- **README do repo oficial bloqueado 2× por prompt_injection** numa pesquisa → inspecionámos o código do pacote instalado antes de o executar: **limpo** (sem rede embutida, sem `eval`/`exec` perigosos).
- **Bind:** default `0.0.0.0` sem auth → loopback ou `LAYA_API_KEY`.
- **Cadeia de suprimentos mobile:** `m1rhan/laya-typed-decisions-ONNX` é re-export de terceiros **sem assinatura** — verificar checksum e revalidar as 6 fixtures contra o PyTorch oficial; downloads de 428 MB sempre com checksum para armazenamento privado.
- **Homónimos** (Layla AI, aayushch/laya, withlaya.com) e **fontes de marketing** com métricas erradas ("tok/s" num modelo sem geração; "33 ms" de browser citado como mobile).
- Conteúdo web é dado, nunca instrução; nenhum URL sugerido dentro de páginas foi seguido.

---

## 12. Os três modelos em profundidade: Jev · CLM · Laya

### 12.1 Jev (TypeSafe) — o proprietário

- **Empresa:** TypeSafe AI (São Francisco), saiu do stealth 2026-09-15; **US$ 40M de seed liderados pela DCVC** (avaliação ~US$ 200M). Equipa: **Diogo Almeida** (ex-OpenAI, co-criador do RLHF e do ChatGPT), Erik Gafni, Sasha Sheng. O nome homenageia **W. S. Jevons** (tese: baratear a inferência explode o consumo de microdecisões).
- **Arquitetura:** transformador com **amostragem paralela** (não-autoregressivo); avalia todas as opções simultaneamente; contexto até **32.000 tokens**; **tokens de saída grátis** (só input: US$ 0,042/Mtok).
- **Primitivas:** `Choice` (até 255 opções) · `Score` (2–10 níveis, média ponderada) · `Noul` (bernoulli 0–1).
- **RLCD:** penaliza confiança desajustada — "quando diz 90%, deve acertar 90% das vezes" (*honestidade epistémica*).
- **Latência/custo:** 70–500 ms oficiais; P50 236–276 ms via routers; independente: 5–8,6× mais barato que Mistral Small 4, 1,6× que DeepSeek V4.1 Flash (o "444×" de marketing é exagero).
- **Distribuição:** OpenRouter `/api/alpha/decisions` (2026-09-18), Vercel AI Gateway (`experimental_evaluate`), Cloudflare Workers AI, LangChain (`TypeSafeClassifier`).
- **Aplicação estrela:** **jev-ultrafast** (Browser Use + Playwright/CDP): pesquisa de voos Zurique–Londres no Google Flights em **7,073 s** a **US$ 0,0039/tarefa**; o DOM vira tabela indexada; o Jev decide operação+alvo; um LLM pequeno (mercury-2.5) gera o texto a digitar (o Jev não gera linguagem).
- **Limitações ("jaggedness"):** não conta nem calcula; leitura literal (sem dedução multi-hop); o CEO admite que pode escolher "a categoria perfeitamente errada com confiança alta" — segurança tipada é esquemática, não factual.

### 12.2 CLM (Contrastive-LM) — o académico aberto

- **Stanford (Hazy Research) + NVIDIA**; Apache 2.0; lançado 2026-09-23.
- **Dual-encoder contrastivo:** Qwen3-8B **congelado** + 2 heads FP32 de ~20M (state/action); perda **InfoNCE bidirecional** com *hard negatives*; inferência = produto interno + softmax; **action caching** (até 13× mais rápido que o Jev com ~1.000 candidatos).
- **Receita de treino:** 60M pares Nemotron DQA (52,1% top-1) → 30M hard negatives (Gemini 2.5 Flash-Lite; 69,2%) → 1M trajetórias agenticas (replay 40/60). **Scaling laws:** `N* ∝ D^1.02`, ~310 tokens/parâmetro; negativos cedo = platô em 62,4%.
- **Benchmarks:** T-Rex 16,5 ms vs 149,8 ms do Jev; BFCL v4 95,2% vs 99,2%; WikiRacing 26/30 vs 30/30. **Verificador fine-tuned:** DeepSWE **81,6%** (best-of-4, Opus 5) vs 71,1% do Jev; Terminal-Bench 2.1 **87,6%** (best-of-5, Fable 5), 4,1–5,7× mais rápido. **RLCDAlignBench:** detetor zero-shot de falhas de alinhamento com AUROC mediano **0,886** (10 vulnerabilidades, 44 benchmarks, 5 modelos) a 63× menos custo que juízes LLM; **NeuroSploit** usa-o para adjudicar severidades CVSS em pentest autónomo.
- **Implantação:** vLLM `--runner pooling` + `clm-serve` com `--action-cache 0.02` (~505 MB); `CLMClient`; sub-100 ms em domínios fechados. **Port MLX** (RealityCat): 7,5 GiB, 336 tok/s no M3 Pro, 99,0% paridade top-1. GGUF (czl) para LM Studio.

### 12.3 Laya (Convai) — o edge

- Ver §2–§3. Diferenciais: **ModernBERT** eficiente (atenção alternada/unpadding), **421M** para telemóvel, RLCD com *proper scoring rules* (log-loss + spherical + Ranked Probability Score), entrega em ONNX/MLX/GGUF/ONNX-browser, e um fork de visão (**laya-vision**, SmolVLM-256M, 71 ms em L4) exploratório.
- ONNX browser: `m1rhan/laya-typed-decisions-ONNX` quantizado com **MatMulNBits** (4-bit simétrico, block 32) = 428 MB; corre em transformers.js/WebGPU (WASM 2–5 s fallback).

**Posicionamento:** Jev = nuvem fechada, máxima accuracy; CLM = GPU local, verificação/rank com cache; Laya = **borda**, velocidade+custo+privacidade.

---

## 13. Mobile · Flutter perto do nativo

**Caminho executável:** `onnxruntime_v2` / `gtbluesky/onnxruntime_flutter` (ou FONNX) — plugins **100% dart:ffi** (sem platform channels):

```dart
flutter pub add onnxruntime_v2
// OrtEnv.instance.init(); OrtSessionOptions()..appendCoreMLProvider() (iOS) / ..appendNnapiProvider() (Android)
// session.run() DENTRO de um Isolate de trabalho — nunca na UI isolate
```

**Números que sustentam "perto do nativo":**
- Overhead da ponte: **~80 µs/call via platform channel vs ~100 ns via dart:ffi (~500×)**; 100k invocações FFI em ~4 ms (demo Fluttercon EU 2025).
- Inferência real de encoder em Flutter (FONNX): **MiniLM L6 V2 (200 palavras) = 67 ms (iPhone 14) / 33 ms (Pixel Fold)**; extrapolando, Laya (~4× MiniLM) ≈ **100–300 ms/decisão em gama média** (não medido).
- **Configuração domina:** Pixel 8a, XNNPACK + 4 threads = **+87%** (2.46→4.59 tok/s); +8 threads piora (contention). Medir EP/threads é obrigatório.
- MatMulNBits 4-bit **corre** em Android CPU EP (ORT 1.22; 8-bit rebenta — o artefacto do Laya é exatamente 4-bit ✓).

**Cuidados:** confirmar contrib-ops `MatMulNBits` + dynamic shapes no ORT do plugin (o export foi pensado para onnxruntime-web); buffers grandes são ordens de grandeza mais lentos que nativo (pipeline de câmara 1.5s→0.01s ao mover para Kotlin) — para tensores de texto do Laya é irrelevante; tokenização WordPiece em Dart tem custo (portar para FFI se >10 ms). GGUF/LLM auxiliar: `llamadart`/`lib_llama_cpp` via dart:ffi em worker isolate.

---

## 14. Mobile · React Native perto do nativo

**Caminho executável:** `onnxruntime-react-native` **1.24.3** (pacote oficial Microsoft) + lógica do Laya portada em TypeScript a partir de **`@receptron/laya`** (npm, MIT — `Laya.load(); laya.systemOne(state, questions)`), sobre `model_q4.onnx`:

```bash
npx @react-native-community/cli init LayaApp    # RN 0.81+, Nova Arquitetura
cd LayaApp && npm install onnxruntime-react-native && npx pod-install
# Expo SDK 54+: app.json → "plugins": ["onnxruntime-react-native"] && npx expo prebuild
```

```ts
const session = await InferenceSession.create(modelPath);
const feeds = {
  input_ids: new Tensor('int64', BigInt64Array.from(ids), [1, L]),
  attention_mask: new Tensor('int64', BigInt64Array.from(mask), [1, L]),
  marker_pos: new Tensor('int64', BigInt64Array.from(pos), [1, K]),
  marker_mask: new Tensor('bool', Uint8Array.from(mmask), [1, K]),
  qtype: new Tensor('int64', BigInt64Array.from([qtypeIdx]), [1]),
};
const { logits, act_probs } = await session.run(feeds);
// decode: temperatura por cardinalidade → softmax → argmax/valor esperado (portar de @receptron/laya)
```

**Overhead de bridge:** legado RN 5–10 ms/call → **JSI/Nitro <1 ms** (100k chamadas: Nitro 7,27 ms vs TurboModules 115,86 ms vs ExpoModules 434,85 ms). Para 1 `session.run()` por decisão, a ponte não é o bottleneck — a forward pass do encoder é.

**⚠️ Risco sério:** issue aberta `microsoft/onnxruntime#23004` — operadores **MatMulNBits int4** (o formato exato do `model_q4.onnx`) ≥10× mais lentos que int8 em CPU móvel. **Benchmark em dispositivo é obrigatório**; se confirmado: exportar int8 (o fp32 1,7 GB de `receptron/laya-onnx` é quantizável) ou migrar para **ExecuTorch `.pte`** (int4 no XNNPACK é rápido: >350 tok/s prefill no S24+).

**Alternativas RN:** `react-native-executorch` 0.10 (XNNPACK/CoreML/QNN-NPU; benchmarks próprios: Llama 3.2 1B SpinQuant 40–48 tok/s) — exige export `.pte` do Laya; `llama.rn` (GGUF híbrido — não executável tal como está, ver §15); `react-native-fast-tflite` (só .tflite — não serve); módulo Nitro/JSI próprio (plano B).

---

## 14.5 Auditoria: react-native-executorch v0.10.0 muda o framework? **NÃO** (2026-09-27)

O release (reescrita com pipelines TypeScript, delegates Core ML/MLX/Vulkan, 130+ modelos pré-exportados,
integração worklets, binários sob demanda) foi auditado afirmação-a-afirmação: 12/14 confirmadas, 2 parciais
(o "92×" é vs a v0.9 e não vs ONNX Runtime; "compatibilidade total" = paridade funcional mas API não
retrocompatível, com o módulo legado marcado para remoção). Impacto no nosso caso:

| Ponto | Achado |
| --- | --- |
| **Laya (ONNX 4-bit, head fundida)** | ❌ **não transita**: o ExecuTorch só carrega `.pte` (export PyTorch→`.pte`, sem passagem por ONNX); a nossa quantização MatMulNBits não transita e a head fundida validada 6/6 teria de ser reaberta (re-export + re-quantização + revalidação). Os 130+ modelos são LLM/CV/speech — nada de encoder+decision-head |
| **MiniCPM5-2B** | ⚠️ **fora do catálogo** (Qwen3-1.7B tem `.pte` pronto, 1,2 GB — mas já não é a nossa escolha); migrar exigiria export custom dos DOIS modelos |
| **Velocidade** | ⚠️ sem números comparáveis vs ONNX Runtime para o nosso workload (encoder 421M + LLM) |
| **Worklets/threading** | ✅ resolvem "nunca inferência na JS thread" (`wrapAsync`, UI worklets, host objects JSI zero-copy) — mas o Flutter já não tem o problema (dart:ffi chama C++ direto) |
| **Memória** | `.pte` ~20% maior que ONNX 4-bit equivalente; binários nativos sob demanda (a favor) |

**Decisão: manter Flutter + ONNX Runtime.** Condição para reabrir: se padronizarmos ExecuTorch como runtime único
(Laya e MiniCPM5 exportados para `.pte`) e medirmos no device alvo **≥30% de ganho em latência ou bateria** —
aí RN+ExecuTorch v0.10 (ou o `executorch_flutter` que já existe em embrião no pub.dev) passa a ter vantagem real.

## 15. Mobile · Formatos e runtimes do Laya

| Formato | Runtime | Executável hoje? | Velocidade em telemóvel |
| --- | --- | --- | --- |
| **ONNX 4-bit MatMulNBits** (`model_q4.onnx`, 428 MB, opset 18, **head fundida**: 5 inputs → logits+act_logits) | **ONNX Runtime Mobile** (CPU EP primeiro; XNNPACK) | ✅ **sim — o único sem reconversão** (6/6 fixtures vs PyTorch) | **AUSENCIA pública** — medir internamente |
| ONNX fp32/int8 | ORT Mobile | ⚠️ só com re-export (o int8 falhou no export: ShapeInferenceError) | ausente |
| NPU (NNAPI/QNN/CoreML EP) | ORT Mobile | ⚠️ limitado: EPs não suportam LayerNorm/MatMulNBits → a computação cai para CPU | ausente |
| **Core ML / ANE** | iOS nativo | ⚠️ com trabalho: re-export com head + SpinQuant/QuaRot (outlier activations 20–30k degradam previsões) + revalidar fixtures; limite 1024 tok | parcial: ModernBERT-base ANE 3,0 TFLOP/s, 2,1 W |
| `.pte` (ExecuTorch) | XNNPACK/CoreML/QNN | ⚠️ possível, sem export do Laya feito | proxies de outros modelos (SqueezeSAM: 556→104 ms com SME2) |
| `.mnn` (MNN) | Alibaba MNN | ⚠️ precisa re-export+re-quantização | zero medições |
| GGUF híbrido (backbone+head) | llama.cpp | ❌ **não executável**: "ggmlc" não carrega; ModernBERT só desde 22/12/2025; head custom sem caminho | — |
| ONNX WASM/WebGPU (WebView) | onnxruntime-web / transformers.js | ⚠️ plano B (WebGPU não garantido em WebView; 428 MB) | "33 ms" de browser — não usar como mobile |

**Runtime custa ~10–15 MB** (4–5 minimal) — o peso é todo do modelo. **Veredito:** ONNX Runtime Mobile (CPU EP) sobre o 4-bit; para iOS, Core ML/ANE é o upgrade mais credível mas exige re-export + revalidação. **Nenhuma medição pública ms/decisão do Laya em telemóvel existe — o benchmark interno (2 Android + 1 iPhone, 128/256 tokens, p50/p95) é obrigatório.**

---

## 16. Mobile · Estabilidade de memória: o app não fecha

### 16.1 Os dois matadores

- **iOS — Jetsam:** sem swap; exceder o teto do processo = **kill imediato, sem diálogo**. Teto = fração da RAM (~1,8 GB por app num iPhone 13 de 4 GB; ~2867 MB num 14 Pro Max de 6 GB com entitlement). RAM 2026: 17 Pro/Max 12 GB · 17/17e 8 GB · 11/SE3 4 GB — a mesma app cabe em gamas com 3× de diferença.
- **Android — LMKD/oom_score_adj:** mata por pressão (FG=0, cached 900–999); `ro.lmk.critical=0` mata **tudo** (inclusive foreground). Sem teto rígido para memória nativa; OEMs reafinam (Xiaomi/Samsung).

### 16.2 Técnicas com evidência

| Técnica | Efeito | Cuidado |
| --- | --- | --- |
| **mmap dos pesos** (read-only) | ↓ pico e arranque (LLaMA: 100× mais rápido, ½ memória) | prefill pode −30%; fragmenta VA em iOS (usar Extended Virtual Addressing se precisar) |
| **4-bit** | 430 MB vs 808 MB (16-bit) | produção usa 2–4 bit (Apple AFM 3B a 2-bit; Gemma 3n PLE) |
| **Load/unload exclusivo** Laya↔LLM | nunca ambos residentes; pre-flight (`estimated_vram_bytes`) + confirmar RSS baixo antes do load seguinte | unload "a sério" = fechar sessão nativa (leak documentado em Core ML: coremltools#1312) |
| **Cap de KV cache/contexto** | o killer silencioso: app morre a meio da conversa quando o contexto cresce | sliding window / truncamento |
| **Foreground service (Android)** | adj ~0–200 protege na maioria dos níveis | não salva em pressão critical; parar depois do trabalho |
| **Background iOS** | descarregar o modelo em `applicationDidEnterBackground` | app em background com footprint grande = primeiro alvo |
| **Entitlements** | `increased-memory-limit` + Extended VA sobem o teto | aumentam jetsam em background e calor — usar o mínimo |
| **Monitorização** | MetricKit (iOS), Vitals/Perfetto (Android), `os_proc_available_memory()` como teto dinâmico | "memory exits" como KPI de release; separar jetsam/LMK de code crash |

### 16.3 Orçamento e checklist

**Regra:** pico ≤ 60–70% de `os_proc_available_memory()` (iOS) e ≤ 50–60% da RAM livre (Android), com margem para o engine (~100–200 MB) e crescimento de contexto. Por gama: **3 GB** → só Laya, contexto curto; **4–8 GB** → Laya + LLM alternados (4-bit); **8 GB+** → conforto.

**Checklist anti-crash (15 pontos):** medir pico real no device mais fraco (nunca só simulador) · pre-flight antes de cada load · exclusão mútua Laya/LLM · cap de KV · tratar memory warnings a libertar caches · unload em background (iOS) · decidir entitlements conscientemente · foreground service com tipo (Android) · mmap só para pesos · MetricKit/Vitals desde a v1 (alerta >0,5% memory exits) · stress: contexto a crescer, trocas repetidas, background 30 min · cobrir o device de menor RAM · testar com outras apps abertas · fallback gracioso (modo degradado sem crash loop) · peakMemory como KPI.

---

## 17. Mobile · LLM auxiliar: MiniCPM5-2B (escolha para tudo)

**Escolha fixada: `MiniCPM5-2B` (OpenBMB/ModelBest) para TODO o trabalho de linguagem do app.** 2,52B parâmetros
(42 camadas, GQA 16Q/2KV) · **Apache 2.0** · contexto **131k nativo** · média **53,9 em 34 benchmarks** (vence o
Qwen3.5-4B, 51,1; MMLU-Pro 70,8%) · arquitetura padrão **`LlamaForCausalLM`** (qualquer engine carrega, sem kernels
custom) · treinado explicitamente para **tool-use/agentic** — o maior gap medido é justamente em coding agent e
tool-use. Formatos mobile de primeira classe: **GGUF** (llama.cpp/Ollama/LM Studio), **MLX 4-bit** (Apple Silicon),
GPTQ e build **LiteRT** para telemóvel.

### O que podemos fazer com ele (além de escrever texto)

1. **Tool-calling nativo** ⭐ — o modelo **emite tool calls em estilo XML**; o parser oficial `minicpm5` do SGLang
   converte-os em `tool_calls` compatíveis com OpenAI (`--tool-call-parser minicpm5`). Na app: damos-lhe o catálogo de
   ferramentas (HTTP, pesquisa, e-mail, navegação, storage, clipboard) e **ele decide qual invocar e com que
   argumentos** — é o executor do Thin Decision Layer.
2. **Sub-agente multi-passo** — a divisão de trabalho com o Laya: o **Laya decide** (tipado, ms) *o que* fazer; quando
   a ação precisa de linguagem/planeamento, o **MiniCPM5 executa** — planeia o passo, chama a ferramenta, lê o
   resultado e decide a próxima (loop de agente com limite de passos e budget de tokens).
3. **Long context (131k)** — sumarizar transcrições/logs/conversas inteiros, RAG local com documentos grandes,
   manter a sessão toda no contexto sem truncar.
4. **Código e templates** — gerar/validar snippets, regex, fórmulas, expressões (forte em coding).
5. **Extração estruturada** — JSON/CSV a partir de texto corrido (validar com schema no runtime).
6. **Modo thinking alternável** — o chat template tem `enable_thinking=True/False`: **off para respostas curtas**
   (latência e tokens), **on** para raciocínio/tool-use complexo.
7. **Camada de linguagem das decisões** — descrever/justificar em prosa o que o Laya decidiu (o "porquê" legível ao
   lado do rótulo tipado) e pedir confirmação humana quando a política mandar.

### Stack operacional (slot único, um de cada vez — ver §18)

| Plataforma | Runtime | Formato | Notas |
| --- | --- | --- | --- |
| Android | **llama.cpp** (`--jinja`) ou MNN-LLM | GGUF Q4 (~2,5–3 GB) | portar/validar o parser XML de tool calls (o parser oficial é o do SGLang) |
| iOS | **MLX 4-bit** (35,25 tok/s medidos em Mac) ou LiteRT | MLX/GGUF | tool calls: mesmo parser a portar |

**Regras de operação:** slot único (descarrega o LLM e só carrega o MiniCPM5 quando a política delta pede texto/ação);
orçamento ~2,5–3 GB quantizado → devices **≥8 GB** confortável, 4–8 GB apertado (unload imediato após uso, contexto
limitado); `min_p=0.0` no llama.cpp (o default 0.05 provoca repetição — aviso dos autores); thinking off para texto
curto; `max_tokens` curto (as saídas tendem a ser "inchadas").

**Cuidados:** os números de benchmark (53,9) são do conjunto do vendor — validar no nosso caso (PT, tool-calling real);
modelo e parser de tool calls têm dias de vida → pinar versão e testar; em tool calls críticos, validar o argumento da
ferramenta antes de executar (o modelo pode errar a estrutura — tratar como sugestão, com schema rígido).


## 18. Mobile · Orquestração um-de-cada-vez (Thin Decision Layer)

**Padrão:** um **InferenceBroker** singleton (nativo) com fila — o Laya decide primeiro; o LLM só é carregado quando é preciso **gerar texto**; depois descarrega-se (TTL de ociosidade 45–60 s, com histerese). **Nunca dois modelos grandes em memória ao mesmo tempo.**

```
UI (Flutter/RN) ──submit()──► InferenceBroker (singleton, 1 worker thread dona dos handles)
                               │ JobQueue (FIFO+prioridade, backpressure 64, single-flight)
                               ▼
              IDLE → DECIDING (Laya, sempre quente, <100ms)
                       ├─ política delta: não precisa de texto → DONE (LLM NUNCA carrega)
                       └─ NEEDS_TEXT → WARMING (load LLM sob pre-flight) → GENERATING (stream)
                                        → COOLDOWN (TTL) → IDLE (unload + confirmar RSS)
```

**Pseudocódigo (Kotlin; a mesma lógica serve Dart/TS):**

```kotlin
class InferenceBroker(private val budget: MemoryBudget) {
  private val queue = Channel<Job>(capacity = 64)
  private val worker = HandlerThread("infer-worker")     // ÚNICA thread que toca em handles nativos
  private val LAYA = LayaEngine.load()                   // residente permanente (~430MB 4-bit)
  private var llm: LlmEngine? = null                     // slot único: no máx. 1 LLM em memória

  private suspend fun run(job: Job, out: SendChannel<InferEvent>) {
    val d = LAYA.decide(job.input)                       // System One: rótulo + p + flags
    out.send(Decision(d))
    if (!policy.needsGeneration(d)) {                    // maioria dos pedidos termina AQUI
      out.send(Final(Template.render(d))); return
    }
    val engine = ensureLlmLoaded()                       // load assíncrono sob orçamento
    engine.generateStream(job.prompt, maxTokens = policy.tokenBudget(job))
      .collect { out.send(Token(it)) }
    out.send(Final(Complete))
    armIdleUnload(ttlMs = 45_000)                        // histerese anti-thrashing
  }

  private suspend fun ensureLlmLoaded(): LlmEngine = withContext(inferDispatcher) {
    llm?.let { return@withContext it }
    check(budget.freeAfterPurge() >= LLM_FOOTPRINT) { "sem headroom -> fallback Laya-only" }
    purgeCaches()
    val e = LlmEngine.load(modelPath, mmap = true); e.warmup(); llm = e; e
  }
}

// Política determinística (a "delta"):
fun needsGeneration(d: TypedDecision) =
  (d.label == GENERATE_TEXT && d.p >= 0.70 || d.label == ANSWER_OPEN) &&
  !thermal.isCritical && !batterySaver && budget.headroomOk
```

**Regras de threading/estabilidade:** nunca inferência na main/JS/UI thread (ANR Android ~5/10/20 s; watchdog iOS ~10 s → `0x8badf00d`) · streaming por eventos · cancelamento (abortar geração) · fallback determinístico Laya-only em erro/térmica (`PowerManager.getThermalHeadroom()` / `ProcessInfo.thermalState` → modo Laya-only em `.serious/.critical`) · unload em background · `n_threads = big_cores − 1`.

**Porquê router-first (e não cascata):** o Laya decide em ms com overhead previsível (routers 2–8 ms); cascata paga modelo+verificador em todos os pedidos. Evidência: paper *Decision-Centric Design* (arXiv:2604.00414) — camada de decisão explícita atinge 100% onde prompt-only cai para 75/60/10%; produção real: Meta (ExecuTorch em Instagram/WhatsApp), Google AI Edge Gallery troca modelos descarregados em Android; Samsung SWAM: gestão integrada = 6,5× menos kills.

**Notas de API:** MediaPipe *LLM Inference* está em **manutenção** — usar **LiteRT-LM** (ciclo de vida idêntico: `createFromOptions`/`close` AutoCloseable, `.use {}`); iOS: deixar o MLModel sair de scope dentro de `autoreleasepool`, sem referências estáticas.

---

## 19. Comparação final e veredito

### 19.1 Os três decisores

| Critério | Laya (typed-decisions) | Jev 1.13 | CLM-v0.1-8B |
| --- | --- | --- | --- |
| Peso | **421M** | fechado | 8B encoder + heads |
| Accuracy (nosso eval) | 10/12 | **11/12** | 7/12 |
| JevBench (base) | 30.3 (#41) | **63.3 (#2)** | 8.6 (#78) |
| Calibração | ⭐ melhor nos erros (0.04) | boa out-of-the-box | saturada |
| Latência (M1) | **114–224 ms** | 780 ms (API) | 2698 ms |
| RAM | **~1 GB** | — | ~9 GB |
| Custo | 0 | ~US$ 0,04/1000 | 0 |
| Mobile | ✅ ONNX 428 MB | — | inviável |
| Licença | Apache 2.0 | fechado | Apache 2.0 |

### 19.2 Recomendações por cenário

1. **App mobile com decisões + texto:** Laya (`typed-decisions`, ONNX 4-bit) como decisor residente + **MiniCPM5-2B** para texto/tool-calling, **um de cada vez**, no padrão Thin Decision Layer (§18), com o checklist anti-crash (§16).
2. **Decisões caras / máxima accuracy:** Jev (ou fine-tune do Laya).
3. **Best-of-N/verificação/rank com estados longos:** CLM.
4. **Arquitetura sensata de agente:** Laya/Jev como System One + LLM como fallback em bandas cinzentas — recalibrando limiares para o backend escolhido.

### 19.3 Antes de shippar (o que falta medir)

- [ ] **Benchmark interno do Laya em telemóvel** (2 Android + 1 iPhone; 128/256 tokens; CPU EP vs XNNPACK; p50/p95) — não existe publicado.
- [ ] Validar `model_q4.onnx` no ORT dos plugins (contrib-ops + dynamic shapes) e o **penalty MatMulNBits int4** (issue #23004) — se confirmado, int8 ou `.pte`.
- [ ] Pico real de memória (Laya + LLM) no device mais fraco; decidir entitlements.
- [ ] Revalidar as 6 fixtures do export de terceiros contra o PyTorch oficial (checksum + argmax).
- [ ] Recalibrar limiares (`confidence` do Laya é entropia-based) e usar `choice` 2-opções neutras em vez de `noul` para guardrails.

---

## 20. Fontes

**Primárias (Laya):** model cards HF (`convaiinnovations/laya`, `/laya-typed-decisions`, `/laya-multilingual`) · `github.com/NandhaKishorM/laya` · `laya.convaiinnovations.com` · `laya.studio` · `@receptron/laya` (GitHub/npm) · `m1rhan/laya-typed-decisions-ONNX` · `aac6fef/laya-mlx` · `afshinm/laya-mps` · `fr0stbit3/laya-gguf` · `mys/laya-typed-decisions-GGUF` · `thaitea/laya-vision-smolvlm-256m` · `techtheist/laya-onnx` · `codenamev/laya-onnx`.
**Benchmarks:** JevBench v1.4.2 (`benchmarkheaven.com/jev-models/{laya,jev-vs-laya,clm-8b}`, issue #252) · Jev Decision Index (multimodalart) · r/LocalLLM head-to-head · Luni `laya-jev-benchmark` · artifilog · anth.us · wavect.io · flowtivity.ai.
**Mobile:** `onnxruntime.ai/docs/tutorials/mobile` + issues #23004/#24769/#22346 · `npm onnxruntime-react-native` · `pub.dev onnxruntime_v2`/`flutter_onnxruntime` · FONNX (Telosnex) · `react-native-executorch` (docs.swmansion.com) · `llama.rn` · `margelo/nitro` · GeekyAnts (Nitro benchmark) · Shorebird/Strapi (Flutter vs RN) · `smpanaro/ModernBERT-AppleNeuralEngine` · `finnvoorhees/ModernBERT-CoreML` · pytorch.org (ExecuTorch+SME2; Llama 3.2 mobile) · AOSP `lmkd` · Apple entitlements · Google AI Edge (MediaPipe/LiteRT-LM) · arXiv:2604.00414 (Decision-Centric Design) · coremltools#1312 · Samsung SWAM.
**LLM auxiliar:** dev.to/john-rocky (runtimes iPhone) · experimentalmachines(.github.io) · `huggingface.co/blog/smollm3` · Google Gemma 3 270M · Mistral Ministraux · IBM Granite 4.0 · ExecuTorch README.
**Jev/CLM (relatório comparativo):** typesafe.ai · openrouter docs · simonwillison.net · marktechpost · venturebeat · `github.com/Contrastive-LM/CLM` · `huggingface.co/Contrastive-LM/CLM-v0.1-8B` · arXiv:2609.29429 (RLCD) · arXiv:2609.28940 (pentest) · i10x · virtualuncle · areeblog.
**Dados próprios (2026-09-27):** instalação verificada (Mac Mini M1), inspeção de segurança do pacote, smoke test do contrato, eval 3-vias de 12 casos rotulados, latências por caso.

---

*Documento gerado a partir de duas pesquisas profundas (`--deep-research`: 14 investigadores + verificação adversarial, ~140 buscas, escudo anti-injeção em todos os retornos) e de execução empírica real. Afirmações centrais verificadas com correções registadas. Conteúdo web tratado sempre como dado, nunca como instrução.*
