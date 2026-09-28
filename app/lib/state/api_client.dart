/// HTTP-клиент API FamCoin.
///
/// Адрес задаётся при сборке: `--dart-define=API_URL=...`.
/// По умолчанию — локальный сервер из docker-compose.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

const apiUrl = String.fromEnvironment('API_URL', defaultValue: 'http://localhost:8080');

class ApiException implements Exception {
  ApiException(this.code, {this.status, this.retryAfterSeconds, this.attemptsLeft, this.message});

  /// Машинный код ответа сервера или `network` при отсутствии связи.
  final String code;
  final int? status;
  final int? retryAfterSeconds;
  final int? attemptsLeft;

  /// Пояснение сервера для ошибок учёта (`code == 'ledger'`).
  final String? message;

  bool get isNetwork => code == 'network';

  @override
  String toString() => 'ApiException($code${message == null ? '' : ': $message'})';
}

class AuthResult {
  AuthResult(this.token, this.email, this.locale, {this.name});
  final String token;
  final String email;
  final String locale;

  /// Имя из Telegram; у обычных аккаунтов отсутствует.
  final String? name;
}

class ApiClient {
  ApiClient({http.Client? client, this.baseUrl = apiUrl}) : _http = client ?? http.Client();

  final http.Client _http;
  final String baseUrl;

  Future<Map<String, dynamic>> _send(String method, String path, {Map<String, Object?>? body, String? token}) async {
    http.Response res;
    try {
      final uri = Uri.parse('$baseUrl$path');
      final headers = {
        'content-type': 'application/json',
        if (token != null) 'authorization': 'Bearer $token',
      };
      final future = method == 'GET'
          ? _http.get(uri, headers: headers)
          : _http.post(uri, headers: headers, body: jsonEncode(body ?? const {}));
      res = await future.timeout(const Duration(seconds: 20));
    } catch (_) {
      throw ApiException('network');
    }
    Map<String, dynamic> data;
    try {
      data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      throw ApiException('unknown', status: res.statusCode);
    }
    if (res.statusCode >= 400) {
      throw ApiException(
        data['error'] as String? ?? 'unknown',
        status: res.statusCode,
        retryAfterSeconds: data['retryAfterSeconds'] as int?,
        attemptsLeft: data['attemptsLeft'] as int?,
        message: data['message'] as String?,
      );
    }
    return data;
  }

  AuthResult _auth(Map<String, dynamic> d) {
    final user = d['user'] as Map<String, dynamic>;
    return AuthResult(d['token'] as String, user['email'] as String, user['locale'] as String, name: user['name'] as String?);
  }

  /// Вход через Telegram (D49): код и ссылка на бота…
  Future<(String, String)> telegramStart() async {
    final d = await _send('POST', '/auth/telegram/start');
    return (d['code'] as String, d['url'] as String);
  }

  /// …и опрос: `null`, пока бот не подтвердил чат.
  Future<AuthResult?> telegramCheck(String code, String locale) async {
    final d = await _send('POST', '/auth/telegram/check', body: {'code': code, 'locale': locale});
    return d['status'] == 'ok' ? _auth(d) : null;
  }

  Future<AuthResult> register(String email, String password, String locale) async =>
      _auth(await _send('POST', '/auth/register', body: {'email': email, 'password': password, 'locale': locale}));

  Future<AuthResult> login(String email, String password) async =>
      _auth(await _send('POST', '/auth/login', body: {'email': email, 'password': password}));

  Future<void> logout(String token) async {
    try {
      await _send('POST', '/auth/logout', token: token);
    } on ApiException {
      // Локальная сессия закрывается в любом случае.
    }
  }

  Future<Map<String, dynamic>> state(String token) => _send('GET', '/state', token: token);

  /// Отправляет команду; возвращает ревизию данных владельца и признак, что
  /// команда с таким `commandId` уже была принята раньше (повтор после
  /// обрыва связи — сервер её не применял второй раз).
  Future<({int revision, bool repeated})> command(String token, Map<String, Object?> command) async {
    final r = await _send('POST', '/command', body: command, token: token);
    return (revision: r['revision'] as int, repeated: r['repeated'] == true);
  }

  /// Язык интерфейса — на сервер, чтобы сводки в Telegram приходили на нём же.
  Future<void> setLocale(String token, String locale) => _send('POST', '/auth/locale', body: {'locale': locale}, token: token);

  /// Удаление аккаунта со всеми записями; сессия перестаёт действовать.
  Future<void> deleteAccount(String token) => _send('POST', '/auth/delete', token: token);

  Future<void> changePassword(String token, String current, String next) =>
      _send('POST', '/auth/password', body: {'current': current, 'next': next}, token: token);

  Future<int> logoutOthers(String token) async =>
      (await _send('POST', '/auth/logout-others', token: token))['closed'] as int;

  Future<int> sessionCount(String token) async =>
      (await _send('GET', '/auth/sessions', token: token))['count'] as int;

  Future<List<Map<String, dynamic>>> notifications(String token) async =>
      ((await _send('GET', '/notifications', token: token))['items'] as List).cast<Map<String, dynamic>>();

  Future<void> markNotificationsRead(String token) => _send('POST', '/notifications/read', token: token);

  Future<Map<String, dynamic>> notificationSettings(String token) => _send('GET', '/notifications/settings', token: token);

  Future<Map<String, dynamic>> updateNotificationSettings(String token, Map<String, Object?> patch) =>
      _send('POST', '/notifications/settings', body: patch, token: token);

  Future<void> sendTestNotification(String token, String kind) => _send('POST', '/notifications/test', body: {'kind': kind}, token: token);

  Future<String> telegramLinkCode(String token) async => (await _send('POST', '/telegram/link', token: token))['code'] as String;

  Future<void> telegramUnlink(String token) => _send('POST', '/telegram/unlink', token: token);

  /// Тариф: цена в звёздах, срок, история платежей.
  Future<Map<String, dynamic>> billing(String token) => _send('GET', '/billing', token: token);

  /// Ссылка на счёт в Telegram; открывается сразу с кнопкой «Оплатить».
  Future<String> billingInvoice(String token) async => (await _send('POST', '/billing/invoice', token: token))['url'] as String;
}
