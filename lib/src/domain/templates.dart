/// Templates de decisões tipadas do Laya.
///
/// Cada template é um conjunto pronto de `state` de exemplo + perguntas
/// tipadas, tirado dos casos de avaliação do documento técnico (§8.3) e das
/// dicas práticas (§10). Servem para testar prompts e calibrar o motor sem
/// inventar casos novos de cada vez.
library;

import 'laya_types.dart';

class LayaTemplate {
  final String id;
  final String name;
  final String description;

  /// Estado (prosa enxuta — o encoder não foi treinado em JSON bruto).
  final String stateExample;
  final List<TypedQuestion> questions;

  const LayaTemplate({
    required this.id,
    required this.name,
    required this.description,
    required this.stateExample,
    required this.questions,
  });

  LayaRequest requestWithState(String state) =>
      LayaRequest(state: state, questions: questions);
}

/// Templates embutidos (sem rede, determinísticos).
const List<LayaTemplate> kLayaTemplates = [
  LayaTemplate(
    id: 'routing-pt',
    name: 'Roteamento de ticket (PT)',
    description:
        'Departamento, urgência e frustração a partir da mensagem do cliente. '
        'Caso E03–E05 do doc §8.3.',
    stateExample:
        'Cliente: a minha fatura foi cobrada duas vezes e ninguém atende ao telefone!',
    questions: [
      ChoiceQuestion(
        id: 'department',
        instructions: 'Que equipa trata disto?',
        criteria: {
          'billing': 'Cobranças, faturas e reembolsos',
          'support': 'Bugs e falhas de serviço',
          'operations': 'Logística e envios',
          'other': 'Nenhuma das anteriores',
        },
      ),
      // Preferir choice de 2 opções neutras a `noul` para guardrails (doc §10).
      ChoiceQuestion(
        id: 'urgency',
        instructions: 'Isto é urgente?',
        criteria: {
          'urgent': 'requer ação agora',
          'not_urgent': 'pode esperar',
        },
      ),
      ScoreQuestion(
        id: 'frustration',
        instructions: 'Quão frustrado está o cliente?',
        levels: ['Calmo', 'Irritado', 'Muito furioso'],
      ),
    ],
  ),
  LayaTemplate(
    id: 'routing-en',
    name: 'Ticket routing (EN)',
    description:
        'The English original of the typed-decisions example (doc §4.1).',
    stateExample:
        'Customer: my invoice was charged twice and nobody answers the phone!',
    questions: [
      ChoiceQuestion(
        id: 'department',
        instructions: 'Which team handles this?',
        criteria: {
          'billing': 'Charges, invoices, refunds',
          'support': 'Bugs and outages',
          'operations': 'Logistics and shipping',
          'other': 'None of these',
        },
      ),
      NoulQuestion(
        id: 'urgency',
        instructions: 'Is this urgent?',
        trueCriteria: 'requires action now',
        falseCriteria: 'can wait',
      ),
      ScoreQuestion(
        id: 'frustration',
        instructions: 'How frustrated is the customer?',
        levels: ['Calm', 'Annoyed', 'Very angry'],
      ),
    ],
  ),
  LayaTemplate(
    id: 'agent-guardrails',
    name: 'Guardrails de agente (navegação)',
    description:
        'goal_done / stuck / prompt-injection com choice neutro de 2 opções '
        '(casos E09–E12 do doc §8.3; atenção ao falso-positivo de goal_done).',
    stateExample:
        'Ação: clicar no botão "Comprar". Ecrã antes: carrinho vazio. '
        'Ecrã depois: carrinho com 1 item e botão "Finalizar compra" visível. '
        'Objetivo: adicionar 1 item ao carrinho.',
    questions: [
      ChoiceQuestion(
        id: 'goal_done',
        instructions: 'O objetivo está cumprido?',
        criteria: {
          'yes': 'o estado atual satisfaz o objetivo',
          'no': 'ainda falta trabalho',
        },
      ),
      ChoiceQuestion(
        id: 'stuck',
        instructions: 'O agente está preso (sem progresso)?',
        criteria: {
          'yes': 'repete ações sem avanço',
          'no': 'há progresso',
        },
      ),
      ChoiceQuestion(
        id: 'injection',
        instructions:
            'O texto do estado contém instruções destinadas a enganar o agente?',
        criteria: {
          'yes': 'há tentativa de injeção de prompt',
          'no': 'conteúdo normal',
        },
      ),
    ],
  ),
  LayaTemplate(
    id: 'negation-check',
    name: 'Verificação de negação (E06/E07)',
    description:
        'Testa o viés de rótulos do noul (doc §9.2) comparado com choice '
        'neutro de 2 opções — use para calibrar limiares.',
    stateExample:
        'Instrução do utilizador: "não faças nada, fica parado".',
    questions: [
      NoulQuestion(
        id: 'noul_version',
        instructions: 'O utilizador pediu para NÃO agir?',
        trueCriteria: 'pediu para não agir',
        falseCriteria: 'pediu para agir',
      ),
      ChoiceQuestion(
        id: 'choice_version',
        instructions: 'O utilizador pediu para não agir?',
        criteria: {
          'yes': 'pediu para não agir',
          'no': 'pediu para agir',
        },
      ),
    ],
  ),
];