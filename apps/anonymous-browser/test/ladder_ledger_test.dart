/// Testes da escada de repetição e do ledger anti-repetição de perguntas.
import 'package:anonymous_browser_mobile/src/autopilot/ladder.dart';
import 'package:anonymous_browser_mobile/src/autopilot/question_ledger.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('escada de repetição', () {
    test('dentro do orçamento segue', () {
      expect(ladderCheck(repeats: 0, isWait: false), LadderAction.proceed);
      expect(ladderCheck(repeats: 2, isWait: false), LadderAction.proceed);
      expect(ladderCheck(repeats: 4, isWait: true), LadderAction.proceed);
    });

    test('3 repetições forçam o modelo de texto; 5 mandam o humano', () {
      expect(ladderCheck(repeats: 3, isWait: false), LadderAction.forceTextModel);
      expect(ladderCheck(repeats: 4, isWait: false), LadderAction.forceTextModel);
      expect(ladderCheck(repeats: 5, isWait: false), LadderAction.askHuman);
    });

    test('WAIT tem mais paciência (5/8)', () {
      expect(ladderCheck(repeats: 5, isWait: true), LadderAction.forceTextModel);
      expect(ladderCheck(repeats: 7, isWait: true), LadderAction.forceTextModel);
      expect(ladderCheck(repeats: 8, isWait: true), LadderAction.askHuman);
    });

    test('orçamento de correções por run esgota', () {
      expect(
          ladderCheck(
              repeats: 0, isWait: false, correctionsUsed: 5),
          LadderAction.askHuman);
      expect(
          ladderCheck(
              repeats: 0, isWait: false, correctionsUsed: 4),
          LadderAction.proceed);
    });

    test('assinatura = op + alvo', () {
      expect(actionSignature(op: 'CLICK', target: 'e1'), 'CLICK|e1');
    });
  });

  group('ledger de perguntas', () {
    test('mesma pergunta nunca volta a sair (replay)', () {
      final l = QuestionLedger();
      l.record('ask', 'ctx', 'Qual é a próxima ação?', 'usar o menu');
      expect(l.recall('ask', 'ctx', 'Qual é a próxima ação?'), 'usar o menu');
    });

    test('pergunta equivalente (Jaccard ≥ 0.8) também faz replay', () {
      final l = QuestionLedger();
      l.record('ask', 'ctx', 'o que fazer agora nesta página?', 'continuar');
      expect(l.recall('ask', 'ctx', 'o que fazer agora nesta pagina'),
          'continuar');
    });

    test('outro tipo de pergunta não herda a resposta', () {
      final l = QuestionLedger();
      l.record('gate', 'ctx', 'autoriza enviar?', 'sim');
      expect(l.recall('ask', 'ctx', 'autoriza enviar?'), isNull);
    });

    test('round-trip JSON', () {
      final l = QuestionLedger()
        ..record('ask', 'x', 'pergunta?', 'resposta');
      final l2 = QuestionLedger()..loadJson(l.toJson());
      expect(l2.recall('ask', 'x', 'pergunta?'), 'resposta');
    });
  });
}
