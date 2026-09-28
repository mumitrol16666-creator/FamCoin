/// Бот Telegram: доставка уведомлений и привязка аккаунта по коду.
///
/// Работает только при заданном TELEGRAM_BOT_TOKEN. Без токена методы
/// молча ничего не делают — приложение и сервер от него не зависят.
library;

import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart';

class Telegram {
  Telegram(this.db, {required this.token});

  final Pool db;
  final String? token;
  final _client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  int _offset = 0;

  bool get enabled => token != null && token!.isNotEmpty;

  Future<Map<String, dynamic>?> _call(String method, Map<String, Object?> body) async {
    if (!enabled) return null;
    try {
      final req = await _client.postUrl(Uri.parse('https://api.telegram.org/bot$token/$method'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      final data = jsonDecode(text) as Map<String, dynamic>;
      if (data['ok'] != true) {
        stderr.writeln('telegram $method: ${data['description']}');
        return null;
      }
      return data;
    } catch (e) {
      stderr.writeln('telegram $method: ${e.runtimeType}');
      return null;
    }
  }

  Future<bool> send(int chatId, String text) async =>
      (await _call('sendMessage', {'chat_id': chatId, 'text': text, 'parse_mode': 'HTML'})) != null;

  String? _username;

  /// Имя бота для ссылки t.me/<бот>?start=… — узнаём один раз.
  Future<String?> username() async {
    if (_username != null) return _username;
    final me = await _call('getMe', const {});
    return _username = (me?['result'] as Map?)?['username'] as String?;
  }

  /// Длинный опрос: ловим «/start <код>» и привязываем чат к пользователю.
  Future<void> pollForever() async {
    if (!enabled) return;
    while (true) {
      final data = await _call('getUpdates', {'offset': _offset, 'timeout': 25, 'allowed_updates': ['message']});
      if (data == null) {
        await Future<void>.delayed(const Duration(seconds: 10));
        continue;
      }
      for (final u in (data['result'] as List).cast<Map<String, dynamic>>()) {
        _offset = (u['update_id'] as int) + 1;
        final msg = u['message'] as Map<String, dynamic>?;
        if (msg == null) continue;
        await _handle(msg);
      }
    }
  }

  Future<void> _handle(Map<String, dynamic> msg) async {
    final chatId = (msg['chat'] as Map)['id'] as int;
    final text = (msg['text'] as String? ?? '').trim();
    // Вход/регистрация: «/start login_<код>» — код из приложения ждёт этот чат.
    final login = RegExp(r'^/start\s+login_([A-Za-z0-9]{8,16})$').firstMatch(text);
    if (login != null) {
      final from = msg['from'] as Map<String, dynamic>? ?? const {};
      final name = [from['first_name'], from['last_name']].whereType<String>().join(' ').trim();
      final rows = await db.execute(
        Sql.named('UPDATE telegram_logins SET chat_id = @c, name = @n WHERE code = @code AND chat_id IS NULL AND expires_at > now() RETURNING code'),
        parameters: {'c': chatId, 'n': name.isEmpty ? null : name, 'code': login[1]},
      );
      await send(chatId, rows.isEmpty ? 'Код устарел. Нажмите кнопку в приложении ещё раз.' : 'Готово — вернитесь в FamCoin, вход выполнится сам.');
      return;
    }
    final m = RegExp(r'^/start\s+([A-Za-z0-9]{6,12})$').firstMatch(text);
    if (m == null) {
      final linked = await db.execute(
        Sql.named('SELECT email FROM users WHERE telegram_chat_id = @c'),
        parameters: {'c': chatId},
      );
      await send(
        chatId,
        linked.isEmpty
            ? 'Это бот FamCoin. Чтобы привязать аккаунт, откройте в приложении «Настройки → Telegram» и отправьте код командой /start.'
            : 'Аккаунт ${linked.first[0]} привязан. Сюда будут приходить утренняя сводка и вечерний отчёт.',
      );
      return;
    }
    final rows = await db.execute(
      Sql.named('DELETE FROM telegram_links WHERE code = @code AND expires_at > now() RETURNING user_id'),
      parameters: {'code': m[1]},
    );
    if (rows.isEmpty) {
      await send(chatId, 'Код не найден или устарел. Получите новый в приложении.');
      return;
    }
    final userId = rows.first[0].toString();
    await db.execute(Sql.named('UPDATE users SET telegram_chat_id = NULL WHERE telegram_chat_id = @c'), parameters: {'c': chatId});
    await db.execute(Sql.named('UPDATE users SET telegram_chat_id = @c WHERE id = @u'), parameters: {'c': chatId, 'u': userId});
    await send(chatId, 'Готово: аккаунт привязан. Утром — сводка на день, вечером — отчёт о тратах.');
  }
}
