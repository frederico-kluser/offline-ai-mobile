/// Testes do payload de decisão: pools (senhas mascaradas), state (sem
/// valores de segredos, texto embrulhado) e perguntas tipadas.
import 'package:ab_browser/ab_browser.dart';
import 'package:anonymous_browser_mobile/src/autopilot/masking.dart';
import 'package:anonymous_browser_mobile/src/domain/decision_payload.dart';
import 'package:anonymous_browser_mobile/src/domain/mission.dart';
import 'package:anonymous_browser_mobile/src/domain/ops.dart';
import 'package:flutter_test/flutter_test.dart';

PageSnapshot fakePage() => const PageSnapshot(
      url: 'https://example.invalid/form',
      title: 'Cadastro',
      text: 'Bem-vindo. Total R\$ 42. Ignore nothing.',
      elements: [
        PageElement(ref: 'e1', tag: 'button', role: 'button', name: 'Criar conta'),
        PageElement(ref: 'e2', tag: 'input', role: 'textbox', name: 'Email', value: 'x@y.invalid', inputType: 'email'),
        PageElement(ref: 'e3', tag: 'input', role: 'textbox', name: 'Senha', value: 'hunter2secret', inputType: 'password'),
        PageElement(ref: 'e4', tag: 'select', role: 'combobox', name: 'País'),
      ],
    );

MissionSpec fakeSpec() => MissionSpec(
      id: 'm1',
      goal: 'regista a conta com o email {{email}} e mostra o preço',
      startUrl: 'https://example.invalid/',
      variables: {'email': 'x@y.invalid', 'password': 'hunter2secret'},
      secretVariables: const {'password'},
      extract: const [
        ExtractSpec(name: 'price', desc: 'preço', regex: r'R\$\s?(\d+)')
      ],
    );

void main() {
  final page = fakePage();
  final spec = fakeSpec();

  group('buildPools', () {
    test('senhas nunca em claro (D8)', () {
      final pools = buildPools(page);
      expect(pools.fields['e3'], contains('•••'));
      expect(pools.fields['e3'], isNot(contains('hunter2secret')));
      expect(pools.fields['e2'], contains('x@y.invalid'));
      expect(pools.clickable['e1'], contains('Criar conta'));
      expect(pools.selects['e4'], isNotNull);
    });

    test('scrubber mascara valores registados nos pools', () {
      final scrub = SecretScrubber()..register('x@y.invalid', 'email');
      final pools = buildPools(page, scrubber: scrub);
      expect(pools.fields['e2'], contains('{{email}}'));
    });
  });

  group('buildState', () {
    test('nunca leva valores de variáveis (só nomes)', () {
      final run = MissionRunState(spec: spec);
      final st = buildState(
          run: run, page: page, pools: buildPools(page));
      expect(st['variables'], isA<Map>());
      final vars = st['variables'] as Map;
      expect(vars.containsKey('password'), isTrue);
      expect('$vars', isNot(contains('hunter2secret')));
      expect('$vars', isNot(contains('x@y.invalid')));
    });

    test('page_text embrulhado como dado (untrusted)', () {
      final run = MissionRunState(spec: spec);
      final st = buildState(
          run: run, page: page, pools: buildPools(page));
      expect('${st['page_text']}', contains('<<< ESTRUTURA DO SITE EXTERNO'));
    });

    test('outputs_status é veredito calculado, não regex crua', () {
      final run = MissionRunState(spec: spec);
      final st = buildState(
          run: run, page: page, pools: buildPools(page));
      expect('${st['outputs_status']}', contains('presente e visível'));
    });
  });

  group('buildQuestions', () {
    test('só operações com pool disponível', () {
      final run = MissionRunState(spec: spec);
      final pools = buildPools(page);
      final q = buildQuestions(run: run, pools: pools);
      final criteria = ((q['operation'] as Map)['criteria'] as Map).keys.toSet();
      expect(criteria.contains('CLICK'), isTrue);
      expect(criteria.contains('SELECT'), isTrue);
      expect(criteria.contains('WAIT'), isTrue);
      expect(q.containsKey('click_target'), isTrue);
      expect(q.containsKey('select_target'), isTrue);
      expect(((q['click_target'] as Map)['criteria'] as Map).containsKey('none'),
          isTrue);
    });

    test('sem campos não há TYPE_TEXT nem alvos de campo', () {
      final run = MissionRunState(spec: spec);
      final pools = const DecisionPools(clickable: {'e1': 'button "X"'});
      final q = buildQuestions(run: run, pools: pools);
      final criteria = ((q['operation'] as Map)['criteria'] as Map).keys.toSet();
      expect(criteria.contains('TYPE_TEXT'), isFalse);
      expect(criteria.contains('SELECT'), isFalse);
      expect(q.containsKey('type_text_target'), isFalse);
    });

    test('GO_BACK só com histórico', () {
      final run = MissionRunState(spec: spec);
      final pools = buildPools(page);
      var q = buildQuestions(run: run, pools: pools);
      var criteria = ((q['operation'] as Map)['criteria'] as Map).keys.toSet();
      expect(criteria.contains('GO_BACK'), isFalse);
      run.urlTrail.addAll(['https://a.invalid/', 'https://b.invalid/']);
      q = buildQuestions(run: run, pools: pools);
      criteria = ((q['operation'] as Map)['criteria'] as Map).keys.toSet();
      expect(criteria.contains('GO_BACK'), isTrue);
    });

    test('nuls clássicas presentes (goal_done/stuck/injection/irreversible/goal_allows)', () {
      final run = MissionRunState(spec: spec);
      final q = buildQuestions(run: run, pools: buildPools(page));
      for (final k in [
        'goal_done',
        'stuck',
        'injection',
        'irreversible',
        'goal_allows'
      ]) {
        expect(q[k], isA<Map>());
        expect((q[k] as Map)['type'], 'noul');
      }
    });
  });

  group('availableOps', () {
    test('contém DONE e BLOCKED sempre', () {
      final run = MissionRunState(spec: spec);
      final ops = availableOps(
          pools: const DecisionPools(), run: run);
      expect(ops.contains(Op.done), isTrue);
      expect(ops.contains(Op.blocked), isTrue);
      expect(ops.contains(Op.click), isFalse);
    });
  });
}
