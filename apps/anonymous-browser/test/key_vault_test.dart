// Testes do cofre da chave OpenRouter: validação (GET /api/v1/key) e guarda
// criptografada — a chave só persiste se a API a aceitar.
import 'dart:convert';

import 'package:anonymous_browser_mobile/src/key_vault.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('KeyVault.validate', () {
    test('chave válida (200 + data) — parse de label/uso/limite', () async {
      final client = MockClient((req) async {
        expect(req.url.toString(), 'https://openrouter.ai/api/v1/key');
        expect(req.headers['Authorization'], 'Bearer sk-or-teste');
        return http.Response(
            jsonEncode({
              'data': {
                'label': 'principal',
                'usage': 0.5,
                'limit': 10.0,
                'is_free_tier': false,
              }
            }),
            200);
      });
      final vault =
          KeyVault(store: InMemorySecretStore(), client: client);
      final v = await vault.validate('sk-or-teste');
      expect(v.valid, isTrue);
      expect(v.label, 'principal');
      expect(v.usage, 0.5);
      expect(v.limit, 10.0);
      expect(v.summary, contains('principal'));
    });

    test('401 = inválida', () async {
      final client =
          MockClient((req) async => http.Response('{"error":"unauthorized"}', 401));
      final vault =
          KeyVault(store: InMemorySecretStore(), client: client);
      final v = await vault.validate('sk-or-mau');
      expect(v.valid, isFalse);
      expect(v.error, contains('401'));
    });

    test('chave vazia nem vai à rede', () async {
      var called = false;
      final client = MockClient((req) async {
        called = true;
        return http.Response('{}', 200);
      });
      final vault =
          KeyVault(store: InMemorySecretStore(), client: client);
      final v = await vault.validate('   ');
      expect(v.valid, isFalse);
      expect(called, isFalse);
    });

    test('falha de rede = inválida (nunca trava a UI)', () async {
      final client = MockClient((req) async {
        throw http.ClientException('sem rede');
      });
      final vault =
          KeyVault(store: InMemorySecretStore(), client: client);
      final v = await vault.validate('sk-or-teste');
      expect(v.valid, isFalse);
      expect(v.error, contains('sem resposta'));
    });

    test('corpo inesperado em 200 = válida (a API aceitou)', () async {
      final client = MockClient((req) async => http.Response('o quê', 200));
      final vault =
          KeyVault(store: InMemorySecretStore(), client: client);
      final v = await vault.validate('sk-or-teste');
      expect(v.valid, isTrue);
    });
  });

  group('KeyVault.validateAndSave', () {
    test('guarda só quando válida', () async {
      final store = InMemorySecretStore();
      final bad = KeyVault(
        store: store,
        client: MockClient((req) async => http.Response('{}', 401)),
      );
      final v1 = await bad.validateAndSave('sk-or-mau');
      expect(v1.valid, isFalse);
      expect(await store.read(), isNull, reason: 'inválida nunca persiste');

      final good = KeyVault(
        store: store,
        client: MockClient((req) async => http.Response('{}', 200)),
      );
      final v2 = await good.validateAndSave('sk-or-boa');
      expect(v2.valid, isTrue);
      expect(await store.read(), 'sk-or-boa');
    });

    test('remover apaga do cofre', () async {
      final store = InMemorySecretStore();
      final vault = KeyVault(
        store: store,
        client: MockClient((req) async => http.Response('{}', 200)),
      );
      await vault.validateAndSave('sk-or-boa');
      await vault.deleteKey();
      expect(await store.read(), isNull);
    });
  });

  group('mascaramento', () {
    test('mask nunca mostra a chave inteira', () {
      expect(KeyVault.mask('sk-or-abcdefghijklmnop'),
          isNot(contains('abcdefghijklmnop')));
      expect(KeyVault.mask(''), '');
      expect(KeyVault.mask('curta'), '••••');
    });
  });
}
