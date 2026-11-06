# Cenários de teste CT-01..CT-12

Cada cenário tem um gate E2E objetivo. A suite
[`integration_test/lfm3_e2e_test.dart`](../integration_test/lfm3_e2e_test.dart)
imprime `SKIP` quando o bundle necessário não está instalado; com os pesos em
`<documents>/models/`, exercita os motores reais.

## Parte A — tecnologias individuais

| ID | Tecnologia | Ecrã | Entrada | Gate |
|---|---|---|---|---|
| CT-01 | LFM3-1.7B `<think>` vs direto + determinismo | Prompts | pergunta de KV cache, duas execuções (thinking on/off, JSON) | modo A emite `<think>`; modo B devolve JSON válido; seed 42 dá o mesmo texto |
| CT-02 | Deferred Tool Search | LLM + Tools | 50+ tools deferidas, só `search_tools` ativa | passo 1 chama `search_tools`; passo 2 recebe `<additional_tools>`; termina em ≤5 passos sem corte |
| CT-03 | VL-2B OCR/pointing/grounding | Prompts | imagem com tabela e botão | JSON da tabela; `point_2d`/`bbox_2d` em [0,1000] |
| CT-04 | VL-2B vídeo 2 fps | Prompts | clipe de 6 s (12 frames, 6 pares) | descreve a ordem e o segundo da transição |
| CT-05 | Audio-2B ASR/LiveASR/TTS/spoken tools | LLM + Tools | microfone 100 ms / WAV 16 kHz | transcrição; tool call a partir de voz; fala 24 kHz entrelaçada |
| CT-06 | Omni-2B vídeo com som | Prompts | vídeo com 3 beeps fora de câmara | identifica objeto visual + eventos sonoros no mesmo passo |
| CT-07 | d1-2B/Omni todas as primitivas | Decisões d1 | fatura, imagem, áudio, pergunta falada | `output_tokens == 0`; spans/ISO/None; caixas; áudio dentro de 0,5 pts |

## Parte B — cenários combinados

| ID | Cascata | Gate |
|---|---|---|
| CT-08 | d1 gatekeeper (`prompt_injection`, `domain_route`, `complexity`) → LFM3 | injeção >0,85 bloqueia sem gerar; trivial usa `enable_thinking=false`; tools usa `<think>` + search restrito |
| CT-09 | d1 grounding visual → LFM3/VL agente no browser | `next_action.confidence >= 0,8` e `target_box.found >= 0,5` clica sem tokens; senão escala |
| CT-10 | d1-Omni triagem de voz → Audio-2B entrelaçado | `has_speech < 0,5` descarta ruído; `device_tool` executa e confirma em fala |
| CT-11 | câmara + voz → JSON validado | d1 valida `is_blurry` e `target_region`; Omni/d1-Omni preenche schema |
| CT-12 | LFM3 + d1 judge de abstenção | `is_grounded_in_state < 0,5` força abstenção ou `note_read`/Browser |

## Como executar

```bash
# Tudo o que não precisa de pesos
flutter test

# E2E no dispositivo (SKIP sem modelos)
flutter test integration_test -d <device>
```

Para instalar os modelos, usar o ecrã **Modelos LFM3** (download verificado)
ou copiar os bundles do release para `<documents>/models/<bundle-id>/`.
