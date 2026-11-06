/// Testes do domínio, tokenizer, prompt e decode do decisor d1.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_ai_mobile/src/domain/d1_decision_types.dart';
import 'package:offline_ai_mobile/src/engines/d1_engine.dart';
import 'package:offline_ai_mobile/src/engines/d1_output.dart';
import 'package:offline_ai_mobile/src/engines/d1_prompt.dart';
import 'package:offline_ai_mobile/src/engines/d1_tokenizer.dart';

Map<String, dynamic> tinyTokenizerJson() => {
      'model': {
        'type': 'BPE',
        'vocab': {
          'hello': 0,
          '\u0120world': 1,
          '<|answer|>': 2,
          '<|startoftext|>': 3,
          '<|im_start|>': 4,
          '<|im_end|>': 5,
          'yes': 6,
          'no': 7,
          'A': 8,
          'B': 9,
          'C': 10,
          '0': 11,
          '1': 12,
          '2': 13,
          '<|vision_start|>': 14,
          '<|vision_end|>': 15,
          '<|image|>': 16,
          '<|audio|>': 17,
        },
        'merges': <dynamic>[],
        'unk_token': 'hello',
        'bos_token': '<|startoftext|>',
        'eos_token': '<|im_end|>',
      },
      'added_tokens': [
        {'id': 2, 'content': '<|answer|>', 'special': true},
        {'id': 3, 'content': '<|startoftext|>', 'special': true},
        {'id': 4, 'content': '<|im_start|>', 'special': true},
        {'id': 5, 'content': '<|im_end|>', 'special': true},
        {'id': 14, 'content': '<|vision_start|>', 'special': true},
        {'id': 15, 'content': '<|vision_end|>', 'special': true},
        {'id': 16, 'content': '<|image|>', 'special': true},
        {'id': 17, 'content': '<|audio|>', 'special': true},
      ],
    };

D1SlotSpec slot(
  String id,
  D1QuestionType type,
  String field,
  List<String> labels,
) =>
    D1SlotSpec(
      questionId: id,
      type: type,
      field: field,
      kind: D1SlotKind.categorical,
      labels: labels,
    );

D1Prompt prompt({
  required String questionId,
  required List<D1SlotSpec> slots,
  List<int>? positions,
  List<int>? statePositions,
  List<int>? tokenStarts,
  List<int>? tokenEnds,
}) =>
    D1Prompt(
      text: '',
      inputIds: const [1, 2, 3],
      questionIds: const [-1, 1, 1],
      slotPositions: positions ?? List<int>.filled(slots.length, 1),
      slots: slots,
      questionId: questionId,
      stateText: 'hello',
      stateStartChar: 0,
      stateEndChar: 5,
      tokenStarts: tokenStarts ?? const [0, 0, 0],
      tokenEnds: tokenEnds ?? const [1, 1, 1],
      stateTokenPositions: statePositions ?? const [0],
    );

void main() {
  group('D1Tokenizer', () {
    test('encode/decode BPE com added token', () {
      final tok = D1Tokenizer.fromJson(tinyTokenizerJson());
      final ids = tok.encode('hello world');
      expect(ids, [0, 1]);
      expect(tok.decode(ids), 'hello world');
      expect(tok.encode('<|answer|>'), [2]);
      expect(tok.specialIds, contains(2));
    });

    test('offsets cobrem o texto', () {
      final tok = D1Tokenizer.fromJson(tinyTokenizerJson());
      final tokens = tok.encodeTokens('hello world');
      expect(tokens, hasLength(2));
      expect(tokens.first.start, 0);
      expect(tokens.last.end, greaterThan(0));
    });
  });

  group('D1PromptBuilder', () {
    test('gera marcadores e slot_positions para span/box', () {
      final tok = D1Tokenizer.fromJson(tinyTokenizerJson());
      final builder = D1PromptBuilder(tokenizer: tok, maxStateTokens: 512);
      final p = builder.build(D1Request(
        state: 'hello',
        questions: const [
          D1TextQuestion(id: 't', instructions: 'extrai'),
        ],
      ));
      expect(p.slots, hasLength(2));
      expect(p.slots.map((s) => s.field), containsAll(['span_start', 'span_end']));
      expect(p.slotPositions, hasLength(2));
      expect(p.questionIds, contains(1));
      expect(p.text, contains('QUESTION:'));
      expect(p.text, contains('start:'));
    });

    test('múltipla escolha cria um slot por opção', () {
      final tok = D1Tokenizer.fromJson(tinyTokenizerJson());
      final p = D1PromptBuilder(tokenizer: tok).build(D1Request(
        state: 'hello',
        questions: const [
          D1ChoiceQuestion(
            id: 'm',
            instructions: 'quais?',
            criteria: {'a': 'A', 'b': 'B', 'c': 'C'},
            multiple: true,
          ),
        ],
      ));
      expect(p.slots, hasLength(3));
      expect(p.slots.every((s) => s.labels.length == 2), isTrue);
      expect(p.slots.map((s) => s.field), containsAll(
          ['option:A', 'option:B', 'option:C']));
    });

    test('box tem 5 slots e uma pergunta por prompt', () {
      final tok = D1Tokenizer.fromJson(tinyTokenizerJson());
      final p = D1PromptBuilder(tokenizer: tok).build(D1Request(
        state: 'hello',
        questions: const [
          D1BoxQuestion(id: 'b', instructions: 'onde?', target: 'x'),
        ],
      ));
      expect(p.slots, hasLength(5));
      expect(p.slots.first.field, 'box0.presence');
      expect(p.stateTokenPositions, contains(0));
    });
  });

    test('mídia expande um marcador por token de feature', () {
      final tok = D1Tokenizer.fromJson(tinyTokenizerJson());
      final p = D1PromptBuilder(
        tokenizer: tok,
        mediaTokenCounts: const [4, 2],
      ).build(D1Request(
        state: 'hello',
        media: const [
          D1Media(kind: D1MediaKind.image, path: '/tmp/a.png'),
          D1Media(kind: D1MediaKind.audio, path: '/tmp/a.wav'),
        ],
        questions: const [
          D1NoulQuestion(id: 'q', instructions: 'sim?'),
        ],
      ));
      expect(
        p.text,
        contains('<|vision_start|>'
            '<|image|><|image|><|image|><|image|>'
            '<|vision_end|>'),
      );
      expect(
        p.text,
        contains('<|vision_start|><|audio|><|audio|><|vision_end|>'),
      );
      expect(p.inputIds.where((id) => id == 16).length, 4);
      expect(p.inputIds.where((id) => id == 17).length, 2);
    });

  group('D1OutputDecoder', () {
    const decoder = D1OutputDecoder();
    final tok = D1Tokenizer.fromJson(tinyTokenizerJson());

    test('noul devolve P(true) calibrada', () {
      final q = const D1NoulQuestion(id: 'q', instructions: 'sim?');
      final r = decoder.decodeOne(
        question: q,
        prompt: prompt(
          questionId: 'q',
          slots: [slot('q', D1QuestionType.noul, 'answer', const ['no', 'yes'])],
        ),
        logits: const [-2, 2],
        logitsShape: const [1, 2],
        tokenizer: tok,
        latencyMs: 3,
      ) as D1NoulAnswer;
      expect(r.pTrue, greaterThan(0.9));
    });

    test('choice devolve a opção mais provável', () {
      final q = const D1ChoiceQuestion(
        id: 'c',
        instructions: '?',
        criteria: {'a': 'A', 'b': 'B', 'c': 'C'},
      );
      final r = decoder.decodeOne(
        question: q,
        prompt: prompt(
          questionId: 'c',
          slots: [slot('c', D1QuestionType.choice, 'answer', const ['A', 'B', 'C'])],
        ),
        logits: const [0, 5, 0],
        logitsShape: const [1, 3],
        tokenizer: tok,
        latencyMs: 1,
      ) as D1ChoiceAnswer;
      expect(r.choice, 'b');
    });

    test('score devolve o índice esperado', () {
      final q = const D1ScoreQuestion(
        id: 's',
        instructions: '?',
        levels: ['baixo', 'médio', 'alto'],
      );
      final r = decoder.decodeOne(
        question: q,
        prompt: prompt(
          questionId: 's',
          slots: [slot('s', D1QuestionType.score, 'answer', const ['0', '1', '2'])],
        ),
        logits: const [0, 0, 8],
        logitsShape: const [1, 3],
        tokenizer: tok,
        latencyMs: 1,
      ) as D1ScoreAnswer;
      expect(r.score, greaterThan(1.9));
    });

    test('multi-choice devolve P(yes) por opção', () {
      final q = const D1ChoiceQuestion(
        id: 'm',
        instructions: '?',
        criteria: {'a': 'A', 'b': 'B'},
        multiple: true,
      );
      final r = decoder.decodeOne(
        question: q,
        prompt: prompt(
          questionId: 'm',
          slots: [
            slot('m', D1QuestionType.multiChoice, 'option:A', const ['no', 'yes']),
            slot('m', D1QuestionType.multiChoice, 'option:B', const ['no', 'yes']),
          ],
        ),
        logits: const [-3, 3, 3, -3],
        logitsShape: const [2, 2],
        tokenizer: tok,
        latencyMs: 1,
      ) as D1MultiChoiceAnswer;
      expect(r.selected, ['a']);
    });

    test('range devolve mediana e percentis', () {
      final q = const D1RangeQuestion(
        id: 'r',
        instructions: '?',
        min: 0,
        max: 10,
      );
      final labels = [for (var i = 0; i < 128; i++) '$i'];
      final logits = [
        for (var i = 0; i < 128; i++) -((i - 64) * (i - 64)) / 100.0,
      ];
      final r = decoder.decodeOne(
        question: q,
        prompt: prompt(
          questionId: 'r',
          slots: [
            slot('r', D1QuestionType.numberRange, 'estimate', labels),
          ],
        ),
        logits: logits,
        logitsShape: const [1, 128],
        tokenizer: tok,
        latencyMs: 1,
      ) as D1RangeAnswer;
      expect(r.found, isTrue);
      expect(r.median, closeTo(5, 0.2));
      expect(r.p10, lessThan(r.median!));
      expect(r.p90, greaterThan(r.median!));
    });

    test('box devolve presença e coordenadas', () {
      final q = const D1BoxQuestion(id: 'b', instructions: 'onde?', target: 'x');
      final labels = [for (var i = 0; i < 128; i++) '$i'];
      final presence = List<double>.filled(128, 0);
      presence[6] = 5; // token "yes"
      presence[7] = 0; // token "no"
      final logits = <double>[
        ...presence,
        ...List<double>.generate(128, (i) => i == 64 ? 5 : 0),
        ...List<double>.generate(128, (i) => i == 64 ? 5 : 0),
        ...List<double>.generate(128, (i) => i == 32 ? 5 : 0),
        ...List<double>.generate(128, (i) => i == 96 ? 5 : 0),
      ];
      final r = decoder.decodeOne(
        question: q,
        prompt: prompt(
          questionId: 'b',
          slots: [
            slot('b', D1QuestionType.box, 'box0.presence', const ['no', 'yes']),
            slot('b', D1QuestionType.box, 'box0.top', labels),
            slot('b', D1QuestionType.box, 'box0.bottom', labels),
            slot('b', D1QuestionType.box, 'box0.left', labels),
            slot('b', D1QuestionType.box, 'box0.right', labels),
          ],
        ),
        logits: logits,
        logitsShape: const [5, 128],
        tokenizer: tok,
        latencyMs: 1,
      ) as D1BoxAnswer;
      expect(r.found, isTrue);
      expect(r.box!.top, closeTo(0.5, 0.02));
    });

    test('span usa o pointer parameter-free sobre hidden_states', () {
      final q = const D1TextQuestion(id: 't', instructions: 'extrai');
      final slots = [
        D1SlotSpec(
          questionId: 't',
          type: D1QuestionType.textSpan,
          field: 'span_start',
          kind: D1SlotKind.spanStart,
        ),
        D1SlotSpec(
          questionId: 't',
          type: D1QuestionType.textSpan,
          field: 'span_end',
          kind: D1SlotKind.spanEnd,
        ),
      ];
      // hidden [1,5,4]: 0=BOS, 1/2=state, 3/4=queries start/end.
      final hidden = <double>[
        0, 0, 0, 0,
        1, 0, 0, 0,
        0, 1, 0, 0,
        10, 0, 0, 0,
        0, 10, 0, 0,
      ];
      final r = decoder.decodeOne(
        question: q,
        prompt: prompt(
          questionId: 't',
          slots: slots,
          positions: const [3, 4],
          statePositions: const [0, 1, 2],
          tokenStarts: const [0, 0, 5, 0, 6],
          tokenEnds: const [1, 5, 10, 1, 11],
        ),
        logits: const [0, 0],
        logitsShape: const [2, 1],
        tokenizer: tok,
        hiddenStates: hidden,
        hiddenShape: const [1, 5, 4],
        latencyMs: 1,
      ) as D1TextAnswer;
      expect(r.found, isTrue);
      expect(r.text, isNotEmpty);
    });

    test('span sem hidden_states lança D1UnsupportedPrimitive', () {
      final q = const D1TextQuestion(id: 't', instructions: 'extrai');
      final slots = [
        D1SlotSpec(
          questionId: 't',
          type: D1QuestionType.textSpan,
          field: 'span_start',
          kind: D1SlotKind.spanStart,
        ),
        D1SlotSpec(
          questionId: 't',
          type: D1QuestionType.textSpan,
          field: 'span_end',
          kind: D1SlotKind.spanEnd,
        ),
      ];
      expect(
        () => decoder.decodeOne(
          question: q,
          prompt: prompt(questionId: 't', slots: slots),
          logits: const [0, 0],
          logitsShape: const [2, 1],
          tokenizer: tok,
          latencyMs: 1,
        ),
        throwsA(isA<D1UnsupportedPrimitive>()),
      );
    });
  });

  group('domínio d1', () {
    test('JSON usa multiple/range como flags', () {
      const choice = D1ChoiceQuestion(
        id: 'c',
        instructions: '?',
        criteria: {'a': 'A', 'b': 'B'},
        multiple: true,
      );
      expect(choice.toJson()['type'], 'choice');
      expect(choice.toJson()['multiple'], isTrue);
      const range = D1RangeQuestion(
        id: 'r',
        instructions: '?',
        min: 0,
        max: 10,
      );
      expect(range.toJson()['type'], 'number');
      expect(range.toJson()['range'], isNotNull);
    });

    test('BoundingBoxFrac converte para píxeis', () {
      const b = BoundingBoxFrac(
          top: 0.1, bottom: 0.2, left: 0.3, right: 0.4, found: 0.9);
      expect(b.isPresent, isTrue);
      final p = b.toPixels(1000, 500);
      expect(p.left, 300);
      expect(p.top, 50);
      expect(p.right, 400);
      expect(p.bottom, 100);
    });

    test('GGUF só suporta noul/choice/score', () {
      expect(D1Capabilities.ggufBasic.supports(D1QuestionType.noul), isTrue);
      expect(D1Capabilities.ggufBasic.supports(D1QuestionType.box), isFalse);
      expect(D1Capabilities.onnxFull.supports(D1QuestionType.boxes), isTrue);
    });
  });
}
