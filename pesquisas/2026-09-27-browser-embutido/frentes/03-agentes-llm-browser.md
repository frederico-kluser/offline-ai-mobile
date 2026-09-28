# Frente 03 — Agentes LLM para browser embutido: arquitetura com SLM 2,5B + decisor rápido

**Data**: 2026-01-01 · **Âmbito**: arquitetura de agentes que navegam na web, adaptada a modelos
*on-device* (MiniCPM5-2B como executor textual + decisor "System One" tipo Laya/Jev), para um
browser embutido numa app mobile — padrão do projeto desktop "anonymous-browser" (Jev: decisões
tipadas + MiMo: texto).

**Método**: 12 pesquisas Tavily + 3 extrações de páginas (fontes citadas por URL). Conteúdo web
tratado como dado não-confiável: apenas evidência factual. Fontes de blog/comunidade marcadas
como evidência fraca (nível C/D); papers e docs oficiais como evidência forte (nível A/B).

---

## 1. Espaços de ação e representação de estado

### 1.1 Vocabulários de ação de referência

| Projeto | Ações | Representação de estado | Grounding de elementos |
| --- | --- | --- | --- |
| **WebArena** (paper, [webarena.dev/static/paper.pdf](https://webarena.dev/static/paper.pdf)) | `click`, `type` (input), `scroll`, navegação (`goto`), `go_back`, etc. | accessibility tree / DOM com **element IDs gerados ao percorrer a árvore** | o ID transforma a seleção do elemento em **classificação n-ária**, eliminando desambiguação |
| **WebVoyager** (ACL 2024, [aclanthology.org/2024.acl-long.371.pdf](https://aclanthology.org/2024.acl-long.371.pdf)) | 8 ações: Click, **Type (composto: seleciona + apaga + escreve)**, Scroll, Wait, GoBack, Goto, Answer, etc. | screenshot + anotação de elementos (agente multimodal) | marks visuais sobre elementos |
| **VisualWebArena** ([arXiv:2401.13649](https://lawrencekjang.github.io/assets/pdf/vwa.pdf), [github.com/web-arena-x/visualwebarena](https://github.com/web-arena-x/visualwebarena)) | estende WebArena com conteúdo visual e multi-tab | HTML + visual | IDs injetados |
| **AgentOccam** (ICLR 2025, [arXiv:2410.13825](https://arxiv.org/html/2410.13825v1)) | **voluntariamente minimalista**: subtrai ações redundantes e simplifica observação | observação alinhada com o espaço de ação | — |
| **Set-of-Marks / SoM** (Microsoft, [arXiv:2310.11441](https://arxiv.org/html/2310.11441v2), [github.com/microsoft/SoM](https://github.com/microsoft/SoM)) | n/a (técnica de *prompting* visual) | screenshot segmentado (ex. SAM) com marcas alfanuméricas sobre regiões | marca ⇒ índice de região na resposta |

**Lições que importam para nós:**

1. **Refs numéricos estáveis fazem do grounding uma classificação**, não geração de texto
   (WebArena). Para um SLM de 2,5B isto é a decisão de design mais importante: o modelo escolhe
   `[17]`, não escreve um XPath/CSS selector.
2. **AgentOccam ganha performance por SUBTRAÇÃO**: um espaço de ação alinhado com a observação e
   sem ações redundantes bate agentes com mais engenharia (+4,6% em tarefas determinísticas sobre
   o melhor agente anterior, sem exemplos em contexto nem papéis de agente). Contraria a tentação
   de acrescentar ações "convenientes" (macros, `search_google`, `extract_all`, …).
3. **Ações compostas reduzem passos**: o `Type` do WebVoyager (selecionar + limpar + escrever)
   num só passo corta decisões intermédias — cada decisão é uma oportunidade de erro num SLM.
4. **SoM só se houver visão**. O MiniCPM5-2B é textual: SoM fica reservado a uma futura camada
   multimodal (ex. Ferret-UI Lite) ou a pré-visualização para humano.

### 1.2 Representação de página: DOM vs accessibility tree vs screenshot

- **Accessibility tree (AX tree) é o formato dominante para agentes texto**: 1 exemplo medido
  mostra 47 nós DOM → 5 nós AX para preencher um formulário ("93% mais eficiente em tokens"),
  e a árvore diz explicitamente o que é clicável
  ([isagentready.com](https://isagentready.com/en/blog/how-ai-agents-see-your-website-the-accessibility-tree-explained),
  [searchenginejournal.com](https://www.searchenginejournal.com/the-accessibility-tree-is-how-ai-agents-read-your-site-its-breaking/578171)).
- **Contraponto importante**: noutro benchmark, agentes com **HTML cru superaram a AX tree:
  67,0% vs 52,4%** num dos modelos — a AX tree perde texto/semântica que o HTML tem
  ([digitalstrategyforce.com](https://digitalstrategyforce.com/journal/the-accessibility-tree-what-ai-agents-read-instead-of-pixels)).
  Conclusão: **não escolher um dos dois — AX tree para estrutura interativa + texto visível
  podado para conteúdo**.
- O survey [arXiv:2511.19477](https://arxiv.org/html/2511.19477v1) ("Building Browser Agents")
  confirma a hierarquia: screenshot (caro, exige VLM) vs DOM direto (funciona em páginas simples,
  explode em páginas reais) vs representação textual estruturada podada (o compromisso usado na
  prática).
- Um snapshot de browser agents em 2026 descreve o padrão de mercado: **"structured snapshot:
  cada elemento interativo, o seu *role*, *accessible name* e estado — texto, poucos KB"**
  ([theagentecosystem.com](https://www.theagentecosystem.com/blog/browser-agents-explained)).

---

## 2. Agentes web/GUI com SLMs (1–4B) on-device: o que funciona e o que não

| Evidência | Resultado | Leitura para nós |
| --- | --- | --- |
| **TinyAgent** (BAIR, [bair.berkeley.edu/blog/2024/05/29/tiny-agent](https://bair.berkeley.edu/blog/2024/05/29/tiny-agent)) | Llama-3.2-1B/3B fazem *function calling* ao nível de modelos muito maiores **depois de poda + destilação sobre dados de alta qualidade**; Tool RAG com classificador **DeBERTa-v3-small** (16-way multi-label, threshold 50%) escolhe 3,97 tools/query em média, recall 0,998, prompt ~2× menor | Tool calling em SLM é **treinável**, não emergente da escala. E um classificador pequeno a escolher tools é exatamente o padrão "System One" |
| **Ferret-UI Lite** (Apple, 3B, [arXiv:2509.26539](https://arxiv.org/html/2509.26539v1); números via [emergentmind.com](https://www.emergentmind.com/topics/ferret-ui-lite)) | Grounding forte: ScreenSpot-V2 **91,6%**, OSWorld-G 61,2%, ScreenSpot-Pro 53,3%. **Navegação fraca: AndroidWorld 28,0%, OSWorld 19,8%** | SLM de 3B **sabe apontar** para o elemento certo; **não sabe planejar sequências longas**. Separe grounding/escolha (rápido) de planeamento (escalado) |
| **Mobile-Agent** (família, [github.com/x-plug/mobileagent](https://github.com/x-plug/mobileagent)) | família de agentes GUI para telemóvel (multi-agent, perceção visual + texto) | ecossistema Android/GUI com ideias de perceção a reutilizar |
| **Go-Browse** ([arXiv:2506.03533](https://arxiv.org/html/2506.03533v2)) | 10K trajetórias / 40K passos coligidos por exploração estruturada → fine-tune de um 7B resolve tarefas WebArena | a rota "dados próprios → fine-tune" funciona, mas exige escala de dados que um protótipo mobile não tem |
| **NVIDIA, SLMs for agentic AI** ([research.nvidia.com](https://research.nvidia.com/labs/lpr/slm-agents)) | posição: SLMs (≈3–10B) para agentes quando latência/energia/privacidade mandam | alinhado com o nosso caso de uso |

**Calibração de expectativas** (WebArena, [alphaxiv.org/abs/2307.13854](https://www.alphaxiv.org/abs/2307.13854)):
humano 78,24%, melhor GPT-4 da época **14,41%**, GPT-3.5 8,75%; tarefas multi-passo longas
(relatos de dezenas de passos). Um SLM 2,5B **zero-shot não resolve WebArena**: o âmbito realista
é **fluxos guiados, sites únicos, tarefas de 3–10 passos**, com HITL nos pontos de risco.

**O que NÃO funciona com SLMs** (síntese das fontes acima + BFCL v4, secção 3): manter estado em
multi-turno longo, recuperar de erros de ferramenta de forma adaptativa, e "desistir/continuar"
com juízo. Logo: **estado, memória e políticas de retry vivem em código determinístico, não no
modelo**.

---

## 3. Tool calling em modelos pequenos

- **MiniCPM5-2B** ([github.com/openbmb/minicpm](https://github.com/openbmb/minicpm)):
  tool calls em **formato XML**; o parser `minicpm5` existe no **SGLang** (recomendado pelo
  fabricante) e no **vLLM** (PR #43175, merged 2026-05-27, ainda fora de v0.21/v0.22 —
  [recipes.vllm.ai](https://recipes.vllm.ai/openbmb/MiniCPM5-1B)); em **llama.cpp o suporte está
  num PR não merged** ([discussão HF openbmb/MiniCPM5-1B](https://huggingface.co/openbmb/MiniCPM5-1B/discussions/7))
  ⇒ **na app temos de fazer o parse XML nós mesmos** (o projeto já assume tool calling XML).
  Contexto nativo 131K, modos Think/No-Think no mesmo checkpoint
  ([daily.dev](https://daily.dev/posts/minicpm5-2b-a-2-6b-model-with-tool-calling-deep-search-and-131k-context-tbrvu4jp8)).
- **Testes de robustez do MiniCPM5-2B** ([mindstudio.ai](https://www.mindstudio.ai/blog/minicpm-5-2b-sub-agent-model),
  evidência C — blog de terceiros, ~10 execuções/teste): planeamento multi-tool em sequência OK,
  resistência a prompt injection em saídas de ferramentas OK, retry após falhas de ferramenta OK
  (ponto historicamente fraco de modelos pequenos), distratores OK; **~80% de pass rate nos casos
  mais difíceis**. Ou seja: bom para 2,5B, mas 1 falha em 5 ⇒ guarda determinística obrigatória.
- **BFCL v4 — o estado da arte do tool calling pequeno**
  ([ai.plainenglish.io](https://ai.plainenglish.io/5-tiny-language-models-for-tool-calling-part-3-ebcda32c2518),
  evidência C com números de benchmark):
  - *Tool calling é uma skill treinável, não um subproduto da escala*: um 1B construído para o
    efeito (xLAM-2-1b-fc-r, BFCL v4 **30,44**) faz **~3×** um 1B generalista
    (Llama-3.2-1B-Instruct, 10,82).
  - O melhor pequeno atinge **~2/3 do desempenho frontier** — gap real.
  - **"Suporta tool calling" esconde 3 coisas: emitir, parsear, escolher bem. Só a terceira é
    difícil.** Falhas típicas: alucinar chamadas quando **nenhuma** tool serve; colapsar em
    multi-turno (manter plano por 6 chamadas); **recuperação** — repetir a mesma chamada falhada
    ou desistir.
  - BFCL v4 é materialmente mais difícil que v3 (multi-turno, agente); claims antigas (v1/v2) não
    são comparáveis.
- Benchmarks comunitários ([reddit r/LocalLLaMA](https://www.reddit.com/r/LocalLLaMA/comments/1r4ie8z/i_tested_21_small_llms_on_toolcalling_judgment),
  [github.com/MikeVeerman/tool-calling-benchmark](https://github.com/MikeVeerman/tool-calling-benchmark),
  evidência D): phi4-mini, qwen3-4b/0.6b, lfm2.5-1.2b atingem bons "Agent Score" em cenários
  simples; formatos *raw-schema* vs *native-tools* variam por runtime — a escolha do **formato**
  do prompt de tools afeta tanto quanto o modelo.

---

## 4. Loop de agência: observação compacta, memória, custos

- **Custo de tokens é a restrição dominante em observações**: screenshot gasta muitos tokens para
  o modelo depois "adivinhar" o que é clicável; a AX tree é texto compacto e diz-o
  ([searchenginejournal.com](https://www.searchenginejournal.com/the-accessibility-tree-is-how-ai-agents-read-your-site-its-breaking/578171)).
  Com um SLM de contexto generoso (131K) mas *throughput* limitado (~20–40 tok/s estimados para
  Q4 em CPU — ver memória do projeto), **poupar tokens de entrada poupa latência por passo**.
- **Compactação de contexto**: técnicas maduras — *anchored iterative summarization*,
  reconstrução por resumo rolante quando o contexto ultrapassa limiar, memória com *working
  memory* orçada
  ([github.com/YerbaPage/Awesome-Agent-Context-Compression](https://github.com/YerbaPage/Awesome-Agent-Context-Compression),
  [zylos.ai](https://zylos.ai/research/2026-02-28-ai-agent-context-compression-strategies)).
  Um relatório de produção (Datadog, via [towardsai.pub](https://pub.towardsai.net/the-7-design-patterns-every-ai-agent-developer-should-know-in-2026-c77f28b51565),
  evidência C) mede **69% dos tokens de entrada em system prompts** — orçar o prompt do sistema
  conta.
- **Histórico ≠ transcrição**: guardar o *trace* como eventos compactos `(ação, alvo, resultado)`
  e fatos extraídos; nunca reenviar observações antigas completas ([dev.to anatomia de um
  agente](https://dev.to/tyler007/the-anatomy-of-an-ai-agent-model-loop-tools-memory-207g)).
- **Domínio determinístico do loop**: *scroll*, *wait*, retry, detecção de "página não mudou",
  timeouts — tudo código. O modelo decide **o quê**; o host decide **como e quantas vezes**.
- **Cascata elemento→ação** (Mind2Web/MindAct, [arXiv:2306.06070](https://arxiv.org/html/2306.06070v3)):
  primeiro um **encoder pequeno faz *rank* de elementos candidatos**, depois o LLM escolhe a
  ação sobre o conjunto podado — melhora eficácia e eficiência. É o mesmo padrão do nosso
  decisor rápido a podar candidatos antes do executor.

---

## 5. Decisão rápida ("System One") vs geração

- **RouteLLM** ([arXiv:2406.18665](https://arxiv.org/html/2406.18665v4)): router treinado com
  dados de preferência encaminha cada *query* para o modelo adequado; mantém qualidade perto do
  forte com uma fração do custo. Variantes: classificador BERT, *matrix factorization*, heurísticas.
- **FrugalGPT / cascata** ([neuraltrust.ai](https://neuraltrust.ai/blog/llm-model-routing)):
  tenta o modelo barato primeiro e **só escala se a confiança não passar o limiar** — o custo de
  latência extra só existe nos casos escalados.
- **Jev da TypeSafe** ([openrouter.ai/docs/guides/community/jev](https://openrouter.ai/docs/guides/community/jev),
  [openrouter.ai/blog/insights/what-is-jev](https://openrouter.ai/blog/insights/what-is-jev)):
  modelo *System One* que devolve **decisão tipada** (`noul`/`choice`/`score`) + **probabilidade
  calibrada** em vez de texto; latência citada 70–500 ms; ~68% de exatidão no benchmark interno
  de 4 workflows (perto de LLMs de gama média, evidência C); **não pode sair do tipo nem
  "alucinar" formato** — o valor é a calibração que sustenta bandas auto/HITL/abstain.
- **Análogo local**: o projeto usa **Laya typed-decisions 421M** (Apache 2.0) com o mesmo contrato
  (`noul`/`choice`/`score`, probabilidades calibradas) — decisões discretas em milissegundos, sem
  geração de texto (memória do projeto).
- **TinyAgent Tool RAG** (ver secção 2) é o precedente concreto de **classificador pequeno à
  frente do LLM**: DeBERTa-v3-small a escolher que tools entram no prompt. Pode ser replicado com
  Laya/Jev para escolher *tools* ou *próxima classe de ação*.

---

## 6. Arquitetura recomendada (SLM 2,5B + decisor rápido, browser embutido mobile)

```
                    ┌────────────────────────────────────────────────┐
 Objetivo do        │  1. PERCEÇÃO (Dart, determinístico)            │
 utilizador ──────► │  WebView → AX tree + texto visível podado      │
                    │  → OBS compacta com refs numéricos [1..N]      │
                    └───────────────┬────────────────────────────────┘
                                    ▼
                    ┌────────────────────────────────────────────────┐
                    │  2. SYSTEM ONE — Laya/Jev (rápido, tipado)     │
                    │  entrada: objetivo + sub-objetivo + OBS +      │
                    │           últimos K eventos                    │
                    │  saída: {classe_acao, ref, confiança}          │
                    │  bandas: ≥0.8 AUTO · 0.5–0.8 ESCALAR ·         │
                    │          <0.5 ABSTAIN/PERGUNTAR                │
                    └──────┬───────────────────────┬─────────────────┘
                AUTO ◄─────┘                       └────► ESCALAR
                 │                                          ▼
                 │                     ┌────────────────────────────────────┐
                 │                     │  3. SYSTEM TWO — MiniCPM5-2B       │
                 │                     │  tool calling XML, 1 tool por      │
                 │                     │  passo; thinking OFF por defeito;  │
                 │                     │  DRY sampler, repeat_penalty=1.0   │
                 │                     └───────────────┬────────────────────┘
                 ▼                                      ▼
                    ┌────────────────────────────────────────────────┐
                    │  4. EXECUTOR (Dart, determinístico)            │
                    │  valida ação contra schema tipado + guardas    │
                    │  (ref existe? domínio permitido? ação segura?) │
                    │  executa no WebView · ações irreversíveis →    │
                    │  confirmação humana (HITL)                     │
                    └───────────────┬────────────────────────────────┘
                                    ▼
                    ┌────────────────────────────────────────────────┐
                    │  5. MEMÓRIA (orçada)                           │
                    │  objetivo · sub-objetivo · fatos extraídos ·   │
                    │  log compacto (ação,ref,resultado) · erros     │
                    │  resumo rolante quando > limiar                │
                    └────────────────────────────────────────────────┘
```

**Decisões-chave:**

1. **Divisão de trabalho por tipo de operação, não por "inteligência"**: escolhas discretas de
   alto volume (que ação? que elemento? continuar ou escalar?) → decisor tipado; preenchimento de
   argumentos, extração estruturada, recuperação de erros e passos de baixa confiança → MiniCPM5.
2. **Uma tool por chamada** (o formato XML do MiniCPM5 e a fragilidade multi-turno do BFCL v4
   justificam-no); o *loop* de várias ações é do host, não do modelo.
3. **Guardas determinísticas** obrigatórias: schema tipado com validação, retry limitado e
   adaptativo (nunca repetir idêntico mais de 1×), timeout, deteção de "página não mudou",
   allowlist de domínios, HITL para submeter/apagar/comprar/logar.
4. **Escopo realista**: fluxos guiados de 3–10 passos num site por vez (ver calibração WebArena).
5. **Anti-loop**: sampler DRY (memória do projeto: `dry_multiplier=0.8`, `dry_base=1.75`) e
   `repeat_penalty=1.0` — o repeat_penalty corrompe JSON/tool calls.

## 7. Vocabulário de ações proposto (ferramentas tipadas)

Mínimo deliberado (lição AgentOccam); uma ação por passo; argumentos tipados.

| Ferramenta | Argumentos | Notas |
| --- | --- | --- |
| `goto` | `url: str` | só URLs já visitadas/digitadas ou allowlist |
| `back` | — | histórico do WebView |
| `click` | `ref: int` | o `ref` vem da OBS; classificação n-ária |
| `type` | `ref: int, text: str, submit: bool=false` | composto (limpa+escreve), WebVoyager |
| `select` | `ref: int, option: str` | dropdowns nativos |
| `scroll` | `direction: up\|down, ref?: int` | `ref` = trazer elemento à vista |
| `hover` | `ref: int` | só se necessário (menus desktop) |
| `wait` | `until: visible(ref)\|load, max_ms: int` | limitado, com timeout duro |
| `extract` | `field: str, ref?: int` | leitura estruturada para memória; **read-only** |
| `answer` | `text: str` | terminal para tarefas-pergunta |
| `ask_user` | `question: str, options?: list` | HITL / abstain |
| `done` | `status: ok\|failed, evidence: str` | fim de tarefa com evidência |

Sem ações-macro, sem `search`, sem `extract_all` (não acrescentar conveniência: AgentOccam mostra
que subtrair ajuda). Se o conjunto crescer, selecionar tools por classificador (padrão TinyAgent
Tool RAG) em vez de pôr todas no prompt.

## 8. Formato de observação recomendado

AX tree **filtrada a elementos interativos** + **texto visível podado** (contra o regresso do
benchmark 67% HTML vs 52% AX), com refs numéricos estáveis por versão da página e teto de tokens
duro (≈600–900 tokens; ~2× mais compacto que DOM):

```
TASK: adicionar 2 almofadas queen-size ao carrinho
SUBGOAL: escolher tamanho
URL: https://loja.exemplo/prod/almofada · TITLE: Almofada Classic
[1] heading "Almofada Classic — 45€"
[2] radio "Queen" checked=false
[3] radio "King" checked=false
[4] spinbutton "Quantidade" value=1
[5] button "Adicionar ao carrinho"
[6] link "Avaliações (128)"
TEXT: Almofada em penas 100% algodão… (400 chars, truncado)
LAST: click(3) → ok (estado: King selecionado)
DIFF: 2 nós alterados desde a OBS anterior
```

Regras: `role` + *accessible name* + valor/estado; ordem de leitura = ordem visual; só nós
visíveis e interativos (mais cabeçalhos/texto principal); nunca HTML cru; **sem screenshots**
para o MiniCPM5 (canal de imagem reservado a VLM futuro/preview humano — aí usar SoM).

## 9. Riscos e decisões abertas

- **Parser XML de tool calls em llama.cpp não existe upstream** (PR não merged) → parser próprio
  na app + testes de regressão; considerar SGLang/vLLM só em dev.
- **~80% de pass nos casos difíceis** (MindStudio) ⇒ 1 falha em 5 passos derruba tarefas de 8+
  passos sem guardas determinísticas e *checkpointing* de sub-objetivos.
- **Grounding forte vs planeamento fraco** (Ferret-UI Lite: 91,6% grounding, 19,8–28% navegação)
  ⇒ investir no decisor/memória, não em mais capacidade de "apontar".
- **Testar os nossos schemas com o nosso modelo** — BFCL não substitui um teste de 2h com as
  nossas tools reais (conselho explícito da fonte da secção 3).
- **Formato da observação a validar empiricamente** no WebView embarcado (sites reais com AX tree
  incompleta: botões sem *accessible name* são invisíveis para o agente —
  [searchenginejournal.com](https://www.searchenginejournal.com/the-accessibility-tree-is-how-ai-agents-read-your-site-its-breaking/578171));
  fallback para heurísticas DOM (onclick, cursor pointer, <a>/<button>) quando a AX tree é pobre.

## 10. Fontes

**Nível A/B (papers, docs oficiais):**
- WebArena paper — https://webarena.dev/static/paper.pdf
- WebVoyager (ACL 2024) — https://aclanthology.org/2024.acl-long.371.pdf
- VisualWebArena — https://arxiv.org/abs/2401.13649 · https://github.com/web-arena-x/visualwebarena
- AgentOccam (ICLR 2025) — https://arxiv.org/abs/2410.13825
- Set-of-Mark Prompting — https://arxiv.org/abs/2310.11441 · https://github.com/microsoft/SoM
- Ferret-UI Lite — https://arxiv.org/abs/2509.26539
- Mind2Web / MindAct — https://arxiv.org/abs/2306.06070 · https://github.com/OSU-NLP-Group/Mind2Web
- RouteLLM — https://arxiv.org/abs/2406.18665
- Building Browser Agents (survey) — https://arxiv.org/abs/2511.19477
- Go-Browse — https://arxiv.org/abs/2506.03533
- OpenBMB/MiniCPM (tool calling XML) — https://github.com/openbmb/minicpm
- vLLM recipes MiniCPM5 — https://recipes.vllm.ai/openbmb/MiniCPM5-1B
- OpenRouter docs Jev — https://openrouter.ai/docs/guides/community/jev · https://openrouter.ai/typesafe/jev-1.13

**Nível C/D (blogs, comunidade — corroborar antes de decisões):**
- TinyAgent, BAIR — https://bair.berkeley.edu/blog/2024/05/29/tiny-agent
- MindStudio, MiniCPM5-2B sub-agent tests — https://www.mindstudio.ai/blog/minicpm-5-2b-sub-agent-model
- BFCL v4 small models — https://ai.plainenglish.io/5-tiny-language-models-for-tool-calling-part-3-ebcda32c2518
- Ferret-UI Lite números — https://www.emergentmind.com/topics/ferret-ui-lite
- WebArena calibração — https://www.alphaxiv.org/abs/2307.13854
- AX tree vs DOM/token cost — https://isagentready.com/en/blog/how-ai-agents-see-your-website-the-accessibility-tree-explained · https://www.searchenginejournal.com/the-accessibility-tree-is-how-ai-agents-read-your-site-its-breaking/578171 · https://digitalstrategyforce.com/journal/the-accessibility-tree-what-ai-agents-read-instead-of-pixels
- Browser agents DOM vs pixels — https://www.theagentecosystem.com/blog/browser-agents-explained
- Context compression — https://github.com/YerbaPage/Awesome-Agent-Context-Compression · https://zylos.ai/research/2026-02-28-ai-agent-context-compression-strategies
- Jev explicado — https://openrouter.ai/blog/insights/what-is-jev · https://www.datacamp.com/blog/system-one-models-jev
- NVIDIA SLM agents — https://research.nvidia.com/labs/lpr/slm-agents
- Mobile-Agent — https://github.com/x-plug/mobileagent
- Tool calling comunitário — https://www.reddit.com/r/LocalLLaMA/comments/1r4ie8z/i_tested_21_small_llms_on_toolcalling_judgment · https://github.com/MikeVeerman/tool-calling-benchmark
- FrugalGPT/cascata — https://neuraltrust.ai/blog/llm-model-routing

---

## Síntese (≤400 palavras)

**Arquitetura**: perceção determinística (WebView → accessibility tree filtrada + texto visível
podado, com refs numéricos) → decisor rápido tipado (Laya/Jev: `classe_acao + ref + confiança`)
→ executor SLM (MiniCPM5-2B, tool calling XML, 1 tool por passo) só nos passos escalados →
executor determinístico com guardas + HITL para ações irreversíveis → memória orçada (objetivo,
sub-objetivo, fatos, log compacto de eventos). Cascata com bandas de confiança (auto ≥0.8 ·
escalar 0.5–0.8 · abstain/perguntar <0.5), padrão RouteLLM/FrugalGPT.

**Vocabulário de ações** (12 ferramentas tipadas, mínimo deliberado — lição AgentOccam, que ganha
performance por subtração): `goto`, `back`, `click(ref)`, `type(ref,text,submit)`,
`select(ref,option)`, `scroll`, `hover`, `wait`, `extract`, `answer`, `ask_user`, `done`. Os refs
numéricos transformam o grounding em classificação n-ária (WebArena) — crítico para um SLM de
2,5B. Uma ação composta por passo (o `Type` do WebVoyager) e uma tool por chamada: o BFCL v4
mostra que modelos pequenos colapsam em multi-turno e recuperação de erros, e que "suporta tool
calling" = emitir + parsear + escolher — só a terceira é difícil. O MiniCPM5-2B emite XML e o
parser não existe upstream em llama.cpp ⇒ parser próprio na app.

**Observação**: AX tree de elementos interativos (role + accessible name + estado + valor) +
400 chars de texto visível + `LAST`/`DIFF`, com teto de 600–900 tokens. AX tree é ~2× mais
compacta que DOM, mas há um benchmark em que HTML cru ganhou (67% vs 52%) — daí incluir texto de
conteúdo. Sem screenshots: o MiniCPM5 é textual (SoM só num futuro VLM).

**Evidência**: TinyAgent prova que SLMs fazem tool calling ao nível de modelos grandes após
poda/destilação e que um classificador pequeno (DeBERTa) a escolher tools dá recall 0.998 com
metade dos tokens. Ferret-UI Lite (3B) mostra o padrão decisivo: grounding forte (91,6%
ScreenSpot-V2) mas navegação fraca (19,8–28%) — separar escolha rápida de planeamento. Jev/Laya
dão decisões tipadas calibradas em 70–500 ms. Calibração: WebArena humano 78% vs GPT-4 14% ⇒
âmbito realista são fluxos guiados de 3–10 passos, com guardas determinísticas e memória em
código, não no modelo.
