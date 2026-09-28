/// Хранилище секретов устройства: сессия и PIN-код.
///
/// На телефоне — системное защищённое хранилище (Keychain на iOS, Keystore
/// на Android), в вебе — обычное хранилище браузера: у сайта иного нет.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

abstract class SecretStore {
  Future<String?> read(String key);

  /// `null` удаляет значение.
  Future<void> write(String key, String? value);
}

class PrefsSecretStore implements SecretStore {
  PrefsSecretStore(this._prefs);
  final SharedPreferences _prefs;

  @override
  Future<String?> read(String key) async => _prefs.getString(key);

  @override
  Future<void> write(String key, String? value) => value == null ? _prefs.remove(key) : _prefs.setString(key, value);
}

class SecureSecretStore implements SecretStore {
  const SecureSecretStore();
  static const _storage = FlutterSecureStorage();

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String? value) => value == null ? _storage.delete(key: key) : _storage.write(key: key, value: value);
}

/// Для тестов: ничего не пишет на диск.
class MemorySecretStore implements SecretStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String? value) async => value == null ? values.remove(key) : values[key] = value;
}
