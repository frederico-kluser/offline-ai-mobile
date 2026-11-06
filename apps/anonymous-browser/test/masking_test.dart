/// Testes de higiene de dados: mascaramento de segredos e placeholders.
import 'package:anonymous_browser_mobile/src/autopilot/masking.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SecretScrubber', () {
    test('mascara o valor em claro', () {
      final s = SecretScrubber()..register('hunter2secret', 'password');
      expect(s.scrubText('pw is hunter2secret!'), 'pw is {{password}}!');
    });

    test('mascara formas URL-encoded e HTML-escaped', () {
      final s = SecretScrubber()..register('a b&c', 'code');
      expect(s.scrubText('x=a%20b%26c'), 'x={{code}}');
      expect(s.scrubText('y=a b&amp;c'), 'y={{code}}');
    });

    test('mascara recursivamente em mapas e listas', () {
      final s = SecretScrubber()..register('topsecret', 'token');
      final out = s.scrub({
        'a': ['topsecret', 'ok'],
        'b': {'c': 'topsecret'}
      }) as Map;
      expect(out['a'], ['{{token}}', 'ok']);
      expect((out['b'] as Map)['c'], '{{token}}');
    });

    test('valores curtos (<4) não são registados', () {
      final s = SecretScrubber()..register('ab', 'password');
      expect(s.isEmpty, isTrue);
    });

    test('maskForDisplay nunca mostra o valor', () {
      expect(maskForDisplay('hunter2secret'), isNot(contains('hunter2secret')));
    });
  });

  group('placeholders', () {
    test('resolveParams resolve só o que existe', () {
      expect(resolveParams('{{email}} e {{code}}', {'email': 'x@y.invalid'}),
          'x@y.invalid e {{code}}');
    });

    test('pendingParams lista o que falta', () {
      expect(pendingParams('{{email}} {{password}}', {'email': 'x'}),
          ['password']);
    });
  });
}
