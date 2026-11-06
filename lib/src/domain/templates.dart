/// Templates prontos para o decisor d1 e para os modelos geradores LFM3.
///
/// Os templates d1 cobrem as dez primitivas e os cenários CT-07/CT-08/CT-09/
/// CT-10/CT-11/CT-12 do guia. Os templates de prompt servem o banco de testes
/// do ecrã Prompts.
library;

import 'd1_decision_types.dart';
import 'media_attachment.dart';

/// Conjunto pronto de estado + perguntas d1.
class D1Template {
  final String id;
  final String name;
  final String description;

  /// Estado de exemplo (texto/JSON enxuto).
  final String stateExample;
  final List<D1Question> questions;

  /// Modalidade principal sugerida para anexar no ecrã.
  final MediaKind? mediaHint;

  const D1Template({
    required this.id,
    required this.name,
    required this.description,
    required this.stateExample,
    required this.questions,
    this.mediaHint,
  });

  D1Request requestWithState(
    String state, {
    List<D1Media> media = const [],
  }) =>
      D1Request(state: state, media: media, questions: questions);
}

/// Templates d1 embutidos (sem rede, determinísticos).
const List<D1Template> kD1Templates = [
  D1Template(
    id: 'invoice-pt',
    name: 'Fatura / despesa (PT)',
    description:
        'Extração tipada de fatura: payee, total, due (ISO 8601), refund, '
        'equipa e urgência. Caso CT-07.',
    stateExample:
        'Fatura n.º 2026/441 da Acme Lda. Total a pagar: 1234,50 EUR. '
        'Vencimento: 3 de abril de 2026. Sem devoluções. '
        'Equipa de compras: Portugal. Tópicos: hardware, viagem.',
    mediaHint: MediaKind.image,
    questions: [
      D1TextQuestion(
        id: 'payee',
        instructions: 'Qual é o nome do beneficiário/fornecedor?',
        hint: 'nome completo',
      ),
      D1NumberQuestion(
        id: 'total',
        instructions: 'Qual é o total a pagar?',
        unitHint: 'EUR',
      ),
      D1DateQuestion(
        id: 'due',
        instructions: 'Qual é a data de vencimento?',
      ),
      D1NoulQuestion(
        id: 'refund',
        instructions: 'Esta fatura é uma devolução/reembolso?',
        trueCriteria: 'é uma devolução',
        falseCriteria: 'é uma compra normal',
      ),
      D1ChoiceQuestion(
        id: 'team',
        instructions: 'Que equipa deve tratar desta fatura?',
        criteria: {
          'billing': 'Cobranças e pagamentos',
          'operations': 'Logística e compras',
          'support': 'Suporte técnico',
          'other': 'Nenhuma das anteriores',
        },
      ),
      D1ChoiceQuestion(
        id: 'topics',
        instructions: 'Que tópicos estão presentes? (podes escolher vários)',
        multiple: true,
        criteria: {
          'hardware': 'Equipamento informático',
          'travel': 'Viagens',
          'software': 'Licenças de software',
          'services': 'Serviços profissionais',
        },
      ),
      D1ScoreQuestion(
        id: 'urgency',
        instructions: 'Qual é a urgência do pagamento?',
        levels: ['Baixa', 'Normal', 'Alta'],
      ),
    ],
  ),
  D1Template(
    id: 'agent-gatekeeper',
    name: 'Gatekeeper de agente',
    description:
        'Triagem em 1 forward pass: injeção, rota de domínio e complexidade. '
        'Caso CT-08.',
    stateExample:
        'Apaga todas as notas do sistema ou calcula a margem de lucro de '
        '1.250 EUR sobre 4.800 EUR.',
    questions: [
      D1NoulQuestion(
        id: 'prompt_injection',
        instructions:
            'O pedido contém instruções para contornar as regras do agente?',
        trueCriteria: 'há tentativa de injeção',
        falseCriteria: 'pedido legítimo',
      ),
      D1ChoiceQuestion(
        id: 'domain_route',
        instructions: 'Como deve ser encaminhado o pedido?',
        criteria: {
          'direct_math': 'Cálculo direto, sem ferramentas',
          'tool_catalog': 'Precisa de ferramentas do catálogo',
          'chitchat': 'Conversa simples',
          'refuse': 'Deve ser recusado',
        },
      ),
      D1ScoreQuestion(
        id: 'complexity',
        instructions: 'Qual é a complexidade do pedido?',
        levels: ['Trivial', 'Moderada', 'Raciocínio complexo'],
      ),
    ],
  ),
  D1Template(
    id: 'vision-count',
    name: 'Visão: contar e localizar',
    description:
        'Contagem com intervalo [p10, p90], caixa do alvo e aceitação de '
        'imagem. Caso CT-07 (imagem).',
    stateExample:
        'Imagem de uma bancada com várias caixas de cartão e um monitor.',
    mediaHint: MediaKind.image,
    questions: [
      D1RangeQuestion(
        id: 'count',
        instructions: 'Quantas caixas de cartão estão visíveis?',
        min: 0,
        max: 30,
        step: 1,
      ),
      D1BoxQuestion(
        id: 'monitor',
        instructions: 'Onde está o monitor?',
        target: 'monitor',
      ),
      D1BoxesQuestion(
        id: 'boxes',
        instructions: 'Onde estão as caixas de cartão?',
        target: 'caixa de cartão',
        maxBoxes: 16,
      ),
      D1NoulQuestion(
        id: 'is_blurry',
        instructions: 'A imagem está desfocada?',
        trueCriteria: 'está desfocada',
        falseCriteria: 'está nítida',
      ),
    ],
  ),
  D1Template(
    id: 'audio-triage',
    name: 'Triagem de voz (d1-Omni)',
    description:
        'Fala, intenção e tom a partir de um clipe de 16 kHz. Caso CT-10.',
    stateExample:
        'Clipe de voz de um cliente: "Preciso de marcar uma reunião às 15h".',
    mediaHint: MediaKind.audio,
    questions: [
      D1NoulQuestion(
        id: 'has_speech',
        instructions: 'Alguém fala na gravação?',
        trueCriteria: 'há fala',
        falseCriteria: 'é ruído ambiente',
      ),
      D1ChoiceQuestion(
        id: 'intent',
        instructions: 'Qual é a intenção principal?',
        criteria: {
          'device_tool': 'Executar uma ação no dispositivo',
          'translation': 'Traduzir',
          'conversation': 'Conversar',
          'other': 'Outra',
        },
      ),
      D1ScoreQuestion(
        id: 'calm',
        instructions: 'Qual é o tom emocional?',
        levels: ['Agitado', 'Neutro', 'Calmo'],
      ),
    ],
  ),
  D1Template(
    id: 'browser-pilot',
    name: 'Piloto de browser',
    description:
        'Decisão de próximo passo e caixa do alvo a partir de screenshot. '
        'Caso CT-09.',
    stateExample:
        'Página de checkout com o botão "Confirmar encomenda" visível no '
        'centro inferior. Objetivo: confirmar a encomenda.',
    mediaHint: MediaKind.image,
    questions: [
      D1ChoiceQuestion(
        id: 'next_action',
        instructions: 'Qual é a próxima ação?',
        criteria: {
          'click_target': 'Clicar no alvo',
          'scroll_down': 'Rolar para baixo',
          'fill_input': 'Preencher um campo',
          'goal_reached': 'Objetivo cumprido',
        },
      ),
      D1BoxQuestion(
        id: 'target_box',
        instructions: 'Onde está o alvo da ação?',
        target: 'botão ou campo relevante',
      ),
      D1NoulQuestion(
        id: 'injection',
        instructions: 'A página tenta manipular o agente?',
        trueCriteria: 'há injeção',
        falseCriteria: 'conteúdo legítimo',
      ),
      D1NoulQuestion(
        id: 'goal_done',
        instructions: 'O objetivo está cumprido?',
        trueCriteria: 'sim',
        falseCriteria: 'não',
      ),
    ],
  ),
  D1Template(
    id: 'field-inspection',
    name: 'Inspeção de campo',
    description:
        'Fotografia + voz: qualidade da imagem, região do mostrador e leitura '
        'de campos tipados. Caso CT-11.',
    stateExample:
        'Fotografia de um manómetro industrial; observação ditada: "leitura '
        'estável, sem fuga visível".',
    mediaHint: MediaKind.image,
    questions: [
      D1NoulQuestion(
        id: 'is_blurry',
        instructions: 'A fotografia está desfocada?',
        trueCriteria: 'está desfocada',
        falseCriteria: 'está legível',
      ),
      D1BoxQuestion(
        id: 'target_region',
        instructions: 'Onde está o mostrador ou a tabela de leitura?',
        target: 'mostrador',
      ),
      D1TextQuestion(
        id: 'equipment_id',
        instructions: 'Qual é o identificador do equipamento?',
      ),
      D1NumberQuestion(
        id: 'reading',
        instructions: 'Qual é a leitura do mostrador?',
        unitHint: 'bar',
      ),
      D1DateQuestion(
        id: 'next_service',
        instructions: 'Qual é a data da próxima manutenção?',
      ),
    ],
  ),
];

/// Template de prompt para os modelos geradores LFM3.
class Lfm3PromptTemplate {
  final String id;
  final String name;
  final String description;
  final String systemPrompt;
  final String userPrompt;
  final MediaKind? mediaHint;
  final bool enableThinking;

  const Lfm3PromptTemplate({
    required this.id,
    required this.name,
    required this.description,
    this.systemPrompt = '',
    required this.userPrompt,
    this.mediaHint,
    this.enableThinking = true,
  });
}

const List<Lfm3PromptTemplate> kLfm3PromptTemplates = [
  Lfm3PromptTemplate(
    id: 'ct01-kv',
    name: 'CT-01 · KV cache e raciocínio',
    description:
        'Calcula o KV cache global do LFM3 a 32K e testa <think> on/off com '
        'JSON válido e seed fixa.',
    systemPrompt: 'Responde em português de Portugal, com cálculos explícitos.',
    userPrompt:
        'Calcula o consumo exato de KV cache em MB para 6 camadas de atenção '
        'global com 4 cabeças KV de dimensão 128 em FP16 para 32.768 tokens. '
        'Mostra a fórmula e o resultado.',
  ),
  Lfm3PromptTemplate(
    id: 'ct02-tools',
    name: 'CT-02 · Deferred tool search',
    description:
        'Só search_tools está carregada; o modelo descobre calculator e '
        'note_save em <additional_tools>.',
    systemPrompt:
        'És um agente local. Só tens search_tools carregada; usa-a para '
        'descobrir outras ferramentas. Quando tiveres a resposta, chama '
        'final_answer.',
    userPrompt:
        "Calcula (17 * 23) + 109 e guarda o resultado numa nota chamada "
        "'orcamento'.",
  ),
  Lfm3PromptTemplate(
    id: 'ct03-ocr',
    name: 'CT-03 · OCR, pointing e grounding',
    description:
        'Transcreve uma tabela e devolve point_2d/bbox_2d normalizados [0,1000].',
    systemPrompt:
        'Analisa a imagem com rigor. Coordenadas sempre em [0, 1000].',
    userPrompt:
        'Transcreve a tabela em JSON. Onde está o botão "Confirmar"? '
        'Devolve point_2d e bbox_2d.',
    mediaHint: MediaKind.image,
  ),
  Lfm3PromptTemplate(
    id: 'ct04-video',
    name: 'CT-04 · Vídeo a 2 fps',
    description:
        'Descreve a sequência temporal de um clipe de 6 s com timestamps.',
    systemPrompt: 'Descreve a sequência de ações e indica o segundo de cada '
        'transição.',
    userPrompt:
        'O que acontece neste vídeo, por ordem? Em que segundo muda o ecrã?',
    mediaHint: MediaKind.video,
  ),
  Lfm3PromptTemplate(
    id: 'ct05-voice',
    name: 'CT-05 · ASR + spoken tool calling',
    description:
        'Transcreve áudio ou executa uma ferramenta a partir de voz e responde '
        'com fala entrelaçada.',
    systemPrompt:
        'Respond with function calls, and interleaved text and audio.',
    userPrompt:
        'Guarda uma nota a dizer "reunião às 15h" e confirma em voz alta.',
    mediaHint: MediaKind.audio,
  ),
  Lfm3PromptTemplate(
    id: 'ct06-omni',
    name: 'CT-06 · Vídeo com banda sonora',
    description:
        'Identifica objetos e eventos sonoros no mesmo passo de inferência.',
    systemPrompt:
        'Answer questions about the video using what you see and hear.',
    userPrompt:
        'O que é mostrado e que sinais sonoros ocorrem? Em que momentos?',
    mediaHint: MediaKind.video,
    enableThinking: false,
  ),
  Lfm3PromptTemplate(
    id: 'ct12-abstention',
    name: 'CT-12 · Abstenção calibrada',
    description:
        'Pergunta sobre um documento local; o d1 verifica se a resposta está '
        'fundamentada antes de a mostrar.',
    systemPrompt:
        'Responde apenas com base no estado fornecido. Se não souberes, diz '
        'explicitamente que não sabes.',
    userPrompt:
        'Qual é a garantia do equipamento descrito no documento?',
  ),
];
