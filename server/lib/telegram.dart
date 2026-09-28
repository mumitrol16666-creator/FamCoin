/// Бот Telegram: доставка уведомлений, привязка аккаунта по коду, вход
/// по ссылке и приём оплаты звёздами (Telegram Stars).
///
/// Работает только при заданном TELEGRAM_BOT_TOKEN. Без токена методы
/// молча ничего не делают — приложение и сервер от него не зависят.
library;

import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart';

/// Предоплата: бот обязан ответить за 10 секунд, иначе Telegram отменит покупку.
typedef PreCheckoutHandler = Future<String?> Function(Map<String, dynamic> query);

/// Успешная оплата: сообщение с полем `successful_payment`.
typedef PaymentHandler = Future<void> Function(int chatId, Map<String, dynamic> from, Map<String, dynamic> payment);

class Telegram {
  Telegram(this.db, {required this.token});

  final Pool db;
  final String? token;
  final _client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  int _offset = 0;

  /// Проверка перед списанием: вернуть `null`, если можно платить, иначе текст ошибки.
  PreCheckoutHandler? onPreCheckout;

  /// Что делать после успешной оплаты.
  PaymentHandler? onPayment;

  bool get enabled => token != null && token!.isNotEmpty;

  Future<Map<String, dynamic>?> call(String method, Map<String, Object?> body) async {
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
      (await call('sendMessage', {'chat_id': chatId, 'text': text, 'parse_mode': 'HTML'})) != null;

  String? _username;

  /// Имя бота для ссылки t.me/<бот>?start=… — узнаём один раз.
  Future<String?> username() async {
    if (_username != null) return _username;
    final me = await call('getMe', const {});
    return _username = (me?['result'] as Map?)?['username'] as String?;
  }

  /// Ссылка на счёт в звёздах: открывается в Telegram сразу с кнопкой «Оплатить».
  /// Для валюты XTR токен платёжного провайдера не нужен.
  Future<String?> createStarsInvoice({
    required String title,
    required String description,
    required String payload,
    required int stars,
    required String label,
  }) async {
    final r = await call('createInvoiceLink', {
      'title': title,
      'description': description,
      'payload': payload,
      'currency': 'XTR',
      'prices': [
        {'label': label, 'amount': stars},
      ],
    });
    return r?['result'] as String?;
  }

  Future<bool> answerPreCheckout(String queryId, {String? error}) async =>
      (await call('answerPreCheckoutQuery', {
        'pre_checkout_query_id': queryId,
        'ok': error == null,
        if (error != null) 'error_message': error,
      })) !=
      null;

  /// Возврат звёзд покупателю; нужен id пользователя Telegram и id платежа.
  Future<bool> refundStars({required int telegramUserId, required String chargeId}) async =>
      (await call('refundStarPayment', {'user_id': telegramUserId, 'telegram_payment_charge_id': chargeId})) != null;

  /// Длинный опрос: «/start <код>», предоплата и успешные платежи.
  Future<void> pollForever() async {
    if (!enabled) return;
    while (true) {
      final data = await call('getUpdates', {
        'offset': _offset,
        'timeout': 25,
        'allowed_updates': ['message', 'pre_checkout_query'],
      });
      if (data == null) {
        await Future<void>.delayed(const Duration(seconds: 10));
        continue;
      }
      for (final u in (data['result'] as List).cast<Map<String, dynamic>>()) {
        _offset = (u['update_id'] as int) + 1;
        try {
          final pre = u['pre_checkout_query'] as Map<String, dynamic>?;
          if (pre != null) {
            await _preCheckout(pre);
            continue;
          }
          final msg = u['message'] as Map<String, dynamic>?;
          if (msg == null) continue;
          await _handle(msg);
        } catch (e, st) {
          stderr.writeln('telegram update: ${e.runtimeType}\n$st');
        }
      }
    }
  }

  Future<void> _preCheckout(Map<String, dynamic> q) async {
    final id = q['id'] as String;
    final handler = onPreCheckout;
    final error = handler == null ? 'Оплата временно недоступна.' : await handler(q);
    await answerPreCheckout(id, error: error);
  }

  Future<void> _handle(Map<String, dynamic> msg) async {
    final chatId = (msg['chat'] as Map)['id'] as int;
    final payment = msg['successful_payment'] as Map<String, dynamic>?;
    if (payment != null) {
      final handler = onPayment;
      if (handler != null) await handler(chatId, (msg['from'] as Map<String, dynamic>? ?? const {}), payment);
      return;
    }
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
