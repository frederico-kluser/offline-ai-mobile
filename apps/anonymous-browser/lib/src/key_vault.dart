/// Cofre da chave OpenRouter — guardada **criptografada** e **validada**.
///
/// - Criptografia: `flutter_secure_storage` — Keychain (iOS) e
///   RSA OAEP + AES-GCM / Keystore (Android). A chave NUNCA vai para
///   `shared_preferences`, logs, tape nem argv (regra do desktop: segredos só
///   por caminho, nunca em claro).
/// - Validação: `GET /api/v1/key` (o mesmo endpoint que o desktop usa em
///   `llm.py:KEY_URL`) com a chave como Bearer — sem gastar créditos. A chave
///   só fica guardada se a API a aceitar (200); 401 = inválida.
library;

import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

/// Armazenamento de segredos (abstração para testes).
abstract class SecretStore {
  Future<String?> read();
  Future<void> write(String value);
  Future<void> delete();
}

/// Implementação real: cofre seguro do SO (Keychain/Keystore criptografado).
class SecureKeyStore implements SecretStore {
  static const String slot = 'openrouter_api_key';
  final FlutterSecureStorage _storage;

  SecureKeyStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  @override
  Future<String?> read() => _storage.read(key: slot);

  @override
  Future<void> write(String value) =>
      _storage.write(key: slot, value: value);

  @override
  Future<void> delete() => _storage.delete(key: slot);
}

/// Implementação em memória (SÓ para testes — nunca em produção).
class InMemorySecretStore implements SecretStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String v) async => value = v;
  @override
  Future<void> delete() async => value = null;
}

/// Resultado da validação de uma chave.
class KeyValidation {
  final bool valid;
  final String? label;
  final double? usage;
  final double? limit;
  final bool? isFreeTier;
  final String? error;

  const KeyValidation({
    required this.valid,
    this.label,
    this.usage,
    this.limit,
    this.isFreeTier,
    this.error,
  });

  /// Resumo humano para a UI (nunca mostra a chave).
  String get summary => !valid
      ? (error ?? 'chave inválida')
      : 'chave válida${label == null ? "" : " · $label"}'
          '${usage == null ? "" : " · uso ${usage!.toStringAsFixed(4)}"}'
          '${limit == null ? "" : " · limite ${limit!.toStringAsFixed(2)}"}';
}

/// Cofre + validação da chave OpenRouter.
class KeyVault {
  final SecretStore store;
  final http.Client client;
  final String baseUrl;

  KeyVault({
    required this.store,
    http.Client? client,
    this.baseUrl = 'https://openrouter.ai',
  }) : client = client ?? http.Client();

  /// Valida a chave contra `GET /api/v1/key` (sem gastar créditos).
  Future<KeyValidation> validate(String key) async {
    final k = key.trim();
    if (k.isEmpty) {
      return const KeyValidation(valid: false, error: 'chave vazia');
    }
    http.Response resp;
    try {
      resp = await client.get(
        Uri.parse('$baseUrl/api/v1/key'),
        headers: {'Authorization': 'Bearer $k'},
      ).timeout(const Duration(seconds: 15));
    } catch (e) {
      return KeyValidation(
          valid: false, error: 'sem resposta da API ($e) — tenta de novo');
    }
    if (resp.statusCode == 401) {
      return const KeyValidation(
          valid: false, error: 'chave inválida (401) — confirma no openrouter.ai');
    }
    if (resp.statusCode != 200) {
      return KeyValidation(
          valid: false, error: 'HTTP ${resp.statusCode} — tenta de novo');
    }
    try {
      final json = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      final data = (json['data'] as Map?)?.cast<String, dynamic>() ?? json;
      return KeyValidation(
        valid: true,
        label: data['label'] as String?,
        usage: (data['usage'] as num?)?.toDouble(),
        limit: (data['limit'] as num?)?.toDouble(),
        isFreeTier: data['is_free_tier'] as bool?,
      );
    } catch (_) {
      // Resposta 200 mas corpo inesperado: a chave foi ACEITE pela API.
      return const KeyValidation(valid: true);
    }
  }

  /// Valida e SÓ guarda se for válida. Devolve o veredito.
  Future<KeyValidation> validateAndSave(String key) async {
    final v = await validate(key);
    if (v.valid) {
      await store.write(key.trim());
    }
    return v;
  }

  Future<String?> readKey() => store.read();

  Future<void> deleteKey() => store.delete();

  /// Apresentação mascarada: `sk-or-…1234` (a chave nunca aparece inteira).
  static String mask(String key) {
    if (key.length <= 8) return key.isEmpty ? '' : '••••';
    return '${key.substring(0, 3)}••••${key.substring(key.length - 4)}';
  }
}
