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

typedef MessageHandler = Future<bool> Function(int chatId, Map<String, dynamic> message);
typedef CallbackHandler = Future<void> Function(Map<String, dynamic> query);

/// Ряды кнопок под сообщением: у каждой `text` и `callback_data` (до 64 байт).
typedef Buttons = List<List<Map<String, String>>>;

/// Служебный email аккаунта, созданного через Telegram. По нему аккаунт
/// узнаётся, даже если чат отвязали от уведомлений.
String telegramEmail(int chatId) => 'tg$chatId@telegram.local';

/// Чем закончилась привязка чата к аккаунту для уведомлений.
enum LinkOutcome { linked, notFound, loginChat }

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

  /// Обычное сообщение в личном чате (не код привязки и не платёж): ввод
  /// операции и запросы (D79). `false` — не обработано, бот ответит как раньше.
  MessageHandler? onMessage;

  /// Нажатие кнопки под сообщением бота.
  CallbackHandler? onCallback;

  bool get enabled => token != null && token!.isNotEmpty;

  Future<Map<String, dynamic>?> call(String method, Map<String, Object?> body) async {
    if (!enabled) return null;
    try {
      // Без общего таймаута оборванное соединение подвешивало бы опрос бота
      // навсегда — без ошибки в журнале. Длинный опрос сам ждёт до 25 секунд.
      final limit = Duration(seconds: method == 'getUpdates' ? 45 : 20);
      return await _post(method, body).timeout(limit);
    } catch (e) {
      stderr.writeln('telegram $method: ${e.runtimeType}');
      return null;
    }
  }

  Future<Map<String, dynamic>?> _post(String method, Map<String, Object?> body) async {
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
  }

  /// [buttons] — ряды кнопок под сообщением; нажатие приходит в [onCallback].
  Future<bool> send(int chatId, String text, {Buttons? buttons}) async =>
      (await call('sendMessage', {
        'chat_id': chatId,
        'text': text,
        'parse_mode': 'HTML',
        if (buttons != null) 'reply_markup': {'inline_keyboard': buttons},
      })) !=
      null;

  /// Заменяет текст и кнопки уже отправленного сообщения; без [buttons] кнопки убираются.
  Future<bool> edit(int chatId, int messageId, String text, {Buttons? buttons}) async =>
      (await call('editMessageText', {
        'chat_id': chatId,
        'message_id': messageId,
        'text': text,
        'parse_mode': 'HTML',
        'reply_markup': {'inline_keyboard': buttons ?? const []},
      })) !=
      null;

  /// Скачивает файл из сообщения (голосовое); `null` — не вышло или файл
  /// больше [maxBytes].
  Future<List<int>?> download(String fileId, {int maxBytes = 1024 * 1024}) async {
    final info = await call('getFile', {'file_id': fileId});
    final path = (info?['result'] as Map?)?['file_path'] as String?;
    if (path == null) return null;
    try {
      final req = await _client.getUrl(Uri.parse('https://api.telegram.org/file/bot$token/$path'));
      final res = await req.close().timeout(const Duration(seconds: 20));
      if (res.statusCode != 200 || res.contentLength > maxBytes) {
        await res.drain<void>();
        return null;
      }
      final bytes = <int>[];
      await for (final chunk in res.timeout(const Duration(seconds: 20))) {
        bytes.addAll(chunk);
        if (bytes.length > maxBytes) return null;
      }
      return bytes;
    } catch (e) {
      stderr.writeln('telegram download: ${e.runtimeType}');
      return null;
    }
  }

  /// Ответ на нажатие кнопки: без него Telegram крутит на кнопке «часики».
  Future<bool> answerCallback(String queryId, {String? text}) async =>
      (await call('answerCallbackQuery', {'callback_query_id': queryId, if (text != null) 'text': text})) != null;

  /// Список команд в меню бота (кнопка «/» в чате).
  Future<bool> setCommands(Map<String, String> commands, {String? language}) async =>
      (await call('setMyCommands', {
        'commands': [
          for (final e in commands.entries) {'command': e.key, 'description': e.value},
        ],
        if (language != null) 'language_code': language,
      })) !=
      null;

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

  /// Длинный опрос: «/start <код>», сообщения и кнопки, предоплата и успешные платежи.
  Future<void> pollForever() async {
    if (!enabled) return;
    while (true) {
      final data = await call('getUpdates', {
        'offset': _offset,
        'timeout': 25,
        'allowed_updates': ['message', 'pre_checkout_query', 'callback_query'],
      });
      if (data == null) {
        await Future<void>.delayed(const Duration(seconds: 10));
        continue;
      }
      final updates = data['result'];
      if (updates is! List) {
        await Future<void>.delayed(const Duration(seconds: 10));
        continue;
      }
      for (final u in updates.cast<Map<String, dynamic>>()) {
        _offset = (u['update_id'] as int) + 1;
        try {
          final pre = u['pre_checkout_query'] as Map<String, dynamic>?;
          if (pre != null) {
            await _preCheckout(pre);
            continue;
          }
          final cb = u['callback_query'] as Map<String, dynamic>?;
          if (cb != null) {
            final handler = onCallback;
            if (handler != null) await handler(cb);
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
      final ok = await confirmLogin(login[1]!, chatId, name.isEmpty ? null : name);
      await send(chatId, ok ? 'Готово — вернитесь в FamCoin, вход выполнится сам.' : 'Код устарел. Нажмите кнопку в приложении ещё раз.');
      return;
    }
    final m = RegExp(r'^/start\s+([A-Za-z0-9]{6,12})$').firstMatch(text);
    if (m == null) {
      final handler = onMessage;
      if (handler != null && (msg['chat'] as Map)['type'] == 'private' && await handler(chatId, msg)) return;
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
    await send(
      chatId,
      switch (await linkChat(m[1]!, chatId)) {
        LinkOutcome.linked => 'Готово: аккаунт привязан. Утром — сводка на день, вечером — отчёт о тратах.',
        LinkOutcome.notFound => 'Код не найден или устарел. Получите новый в приложении.',
        LinkOutcome.loginChat =>
          'Этот Telegram уже служит входом в другой аккаунт FamCoin (он создан через Telegram). Привязать его к ещё одному аккаунту нельзя — иначе вход в тот аккаунт был бы потерян.',
      },
    );
  }

  /// «/start login_<код>»: код входа достаётся первому чату, который его
  /// прислал; второй чат тот же код забрать не может.
  Future<bool> confirmLogin(String code, int chatId, String? name) async {
    final rows = await db.execute(
      Sql.named('UPDATE telegram_logins SET chat_id = @c, name = @n WHERE code = @code AND chat_id IS NULL AND expires_at > now() RETURNING code'),
      parameters: {'c': chatId, 'n': name, 'code': code},
    );
    return rows.isNotEmpty;
  }

  /// «/start <код>» из «Настройки → Telegram»: чат привязывается к аккаунту
  /// для уведомлений — одной транзакцией, у прежнего владельца чат снимается.
  ///
  /// Чат, который служит входом в аккаунт, созданный через Telegram, к
  /// другому аккаунту не привязывается (D78): у такого аккаунта нет своего
  /// пароля, и перенос чата оставил бы человека без входа в него.
  Future<LinkOutcome> linkChat(String code, int chatId) => db.runTx((tx) async {
        final link = await tx.execute(
          Sql.named('SELECT user_id FROM telegram_links WHERE code = @code AND expires_at > now() FOR UPDATE'),
          parameters: {'code': code},
        );
        if (link.isEmpty) return LinkOutcome.notFound;
        final userId = link.first[0].toString();
        final login = await tx.execute(
          Sql.named('SELECT 1 FROM users WHERE lower(email) = @e AND id <> @u'),
          parameters: {'e': telegramEmail(chatId), 'u': userId},
        );
        if (login.isNotEmpty) return LinkOutcome.loginChat;
        await tx.execute(Sql.named('DELETE FROM telegram_links WHERE code = @code'), parameters: {'code': code});
        await tx.execute(Sql.named('UPDATE users SET telegram_chat_id = NULL WHERE telegram_chat_id = @c AND id <> @u'), parameters: {'c': chatId, 'u': userId});
        await tx.execute(Sql.named('UPDATE users SET telegram_chat_id = @c WHERE id = @u'), parameters: {'c': chatId, 'u': userId});
        return LinkOutcome.linked;
      });
}
