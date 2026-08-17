import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class StoredCredential {
  const StoredCredential({
    required this.username,
    required this.password,
    this.serverUrl,
  });

  final String username;
  final String password;
  final String? serverUrl;
}

abstract interface class CredentialStore {
  Future<void> write({
    required String key,
    required String username,
    required String password,
    String? serverUrl,
  });
  Future<StoredCredential?> read(String key);
  Future<void> delete(String key);
}

class SecureCredentialStore implements CredentialStore {
  SecureCredentialStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<void> write({
    required String key,
    required String username,
    required String password,
    String? serverUrl,
  }) => _storage.write(
    key: key,
    value: jsonEncode({
      'username': username,
      'password': password,
      'serverUrl': ?serverUrl,
    }),
  );

  @override
  Future<StoredCredential?> read(String key) async {
    final value = await _storage.read(key: key);
    if (value == null) return null;
    try {
      final decoded = jsonDecode(value);
      if (decoded is! Map) return null;
      final username = decoded['username'];
      final password = decoded['password'];
      if (username is! String || password is! String) return null;
      return StoredCredential(
        username: username,
        password: password,
        serverUrl: decoded['serverUrl'] as String?,
      );
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}
