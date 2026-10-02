/// Ввод операций из чата Telegram (D79) от сообщения до журнала — на
/// настоящей базе, с подставным Telegram. Нужна база из docker-compose
/// (`docker compose up -d db api`, порт 5433) — порт задаётся `TEST_DB_PORT`;
/// без базы тесты пропускаются.
library;

import 'dart:io';

import 'package:famcoin_core/famcoin_core.dart';
import 'package:famcoin_server/auth_service.dart';
import 'package:famcoin_server/chat_entry.dart';
import 'package:famcoin_server/ledger_service.dart';
import 'package:famcoin_server/speech.dart';
import 'package:famcoin_server/telegram.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

/// Записывает обращения к Telegram вместо отправки.
class _FakeTelegram extends Telegram {
  _FakeTelegram(super.db) : super(token: 'test');

  final calls = <(String, Map<String, Object?>)>[];

  @override
  Future<Map<String, dynamic>?> call(String method, Map<String, Object?> body) async {
    calls.add((method, body));
    return {'ok': true};
  }

  @override
  Future<List<int>?> download(String fileId, {int maxBytes = 1024 * 1024}) async => [1, 2, 3];

  Map<String, Object?> last(String method) => calls.lastWhere((c) => c.$1 == method).$2;

  /// `callback_data` кнопки с подписью, содержащей [label], в последнем сообщении.
  String button(String label) {
    final sent = calls.lastWhere((c) => (c.$1 == 'sendMessage' || c.$1 == 'editMessageText') && c.$2['reply_markup'] != null).$2;
    final rows = (sent['reply_markup'] as Map)['inline_keyboard'] as List;
    return rows.expand((r) => r as List).cast<Map>().firstWhere((b) => '${b['text']}'.contains(label))['callback_data'] as String;
  }
}

/// «Распознаёт» заранее заданную фразу и считает обращения.
class _FakeSpeech extends Speech {
  _FakeSpeech() : super(apiKey: 'test');

  String heard = '';
  int requests = 0;

  @override
  Future<Transcript?> transcribe(List<int> audio) async {
    requests++;
    return heard.isEmpty ? null : Transcript(heard, tokensIn: 60, tokensOut: 9);
  }
}

Future<Pool?> _connect() async {
  final db = Pool.withEndpoints(
    [
      Endpoint(
        host: 'localhost',
        port: int.parse(Platform.environment['TEST_DB_PORT'] ?? '5433'),
        database: 'famcoin',
        username: 'famcoin',
        password: 'famcoin',
      ),
    ],
    settings: const PoolSettings(maxConnectionCount: 8, sslMode: SslMode.disable),
  );
  try {
    await db.execute('SELECT 1 FROM telegram_drafts LIMIT 1').timeout(const Duration(seconds: 3));
    return db;
  } catch (_) {
    return null;
  }
}

void main() {
  Pool? pool;
  late AuthService auth;
  late LedgerService ledger;
  late _FakeTelegram bot;
  late ChatEntry chat;
  final speech = _FakeSpeech();
  final base = 9300000000 + (DateTime.now().microsecondsSinceEpoch % 1000000) * 1000;
  var n = 0;

  setUpAll(() async {
    pool = await _connect();
    if (pool == null) return;
    auth = AuthService(pool!);
    ledger = LedgerService(pool!);
    bot = _FakeTelegram(pool!);
    chat = ChatEntry(pool!, ledger, bot, speech: speech)..attach();
  });

  tearDownAll(() async {
    final db = pool;
    if (db == null) return;
    final ids = await db.execute(
      Sql.named(r"SELECT id FROM users WHERE substring(email from '^tg(\d+)@telegram\.local$')::bigint BETWEEN @a AND @b"),
      parameters: {'a': base, 'b': base + 999},
    );
    for (final r in ids) {
      await deleteUserData(db, r[0].toString());
    }
    await db.close();
  });

  bool skip() {
    if (pool != null) return false;
    if (Platform.environment['TEST_DB_REQUIRED'] == '1') fail('TEST_DB_REQUIRED=1, а база недоступна');
    markTestSkipped('база не запущена');
    return true;
  }

  /// Новый владелец, вошедший через Telegram: чат привязан, есть счёт с деньгами.
  Future<(int, String)> owner({int accounts = 1}) async {
    final chatId = base + n++;
    final code = await auth.telegramStart();
    expect(await bot.confirmLogin(code, chatId, 'Тест'), isTrue);
    final userId = ((await auth.telegramCheck(code, 'ru'))['user'] as Map)['id'] as String;
    await pool!.execute(Sql.named("UPDATE users SET plan = 'pro' WHERE id = @u"), parameters: {'u': userId});
    await ledger.command(userId, {
      'type': 'batch',
      'commandId': 'setup-$chatId',
      'commands': [
        for (var i = 0; i < accounts; i++) ...[
          {'type': 'addMoneyAccount', 'accountId': 'acc$i'},
          {'type': 'upsertEntity', 'kind': 'account', 'entityId': 'acc$i', 'data': {'name': 'Счёт $i', 'type': 'card'}},
          {'type': 'opening', 'id': 'open$i', 'date': '2026-09-01', 'account': 'acc$i', 'amount': '${kzt(100000)}'},
        ],
        {'type': 'updateProfile', 'profile': {'onboarded': true}},
      ],
    });
    return (chatId, userId);
  }

  Future<void> say(int chatId, String text) async => expect(await chat.onMessage(chatId, {'text': text}), isTrue);
  Future<void> press(int chatId, String data) => chat.onCallback({'id': 'q', 'data': data, 'message': {'message_id': 7, 'chat': {'id': chatId}}});
  Future<int> liquid(String userId) async => (await ledger.view(userId))!.ledger.liquid();

  test('сообщение → черновик → «Записать» → операция в журнале → «Отменить»', () async {
    if (skip()) return;
    final (chatId, userId) = await owner();
    await say(chatId, 'кофе 1500');
    expect(bot.last('sendMessage')['text'], contains('Расход · 1 500 ₸'));
    expect(await liquid(userId), kzt(100000), reason: 'до подтверждения в журнале ничего нет');

    final ok = bot.button('Записать');
    await press(chatId, ok);
    expect(await liquid(userId), kzt(98500));
    expect(bot.last('editMessageText')['text'], contains('Записано'));

    await press(chatId, ok); // двойное нажатие — операция одна
    expect(await liquid(userId), kzt(98500));

    final undo = bot.button('Отменить запись');
    await press(chatId, undo);
    expect(await liquid(userId), kzt(100000));
    expect(bot.last('editMessageText')['text'], contains('Запись отменена'));
    await press(chatId, undo);
    expect(await liquid(userId), kzt(100000));
    expect(bot.last('answerCallbackQuery')['text'], contains('не действует'));
  });

  test('категория и счёт меняются кнопками до записи', () async {
    if (skip()) return;
    final (chatId, userId) = await owner(accounts: 2);
    await say(chatId, 'что-то 2000');
    expect(bot.last('sendMessage')['text'], allOf(contains('Прочее'), contains('Счёт 0')));
    await press(chatId, bot.button('Категория'));
    await press(chatId, bot.button('Транспорт'));
    await press(chatId, bot.button('Счёт'));
    await press(chatId, bot.button('Счёт 1'));
    expect(bot.last('editMessageText')['text'], allOf(contains('Транспорт'), contains('Счёт 1')));
    await press(chatId, bot.button('Записать'));
    final l = (await ledger.view(userId))!.ledger;
    expect(l.balance('acc1'), kzt(98000));
    expect(l.balance('acc0'), kzt(100000));
    expect(l.expenseByCategory(DateTime(2000), DateTime(2100)), {'expense:transport': kzt(2000)});
  });

  test('«Это доход»: черновик расхода становится доходом и записывается как доход', () async {
    if (skip()) return;
    final (chatId, userId) = await owner();
    await say(chatId, 'премия 5000'); // слова «премия» в словаре доходов нет — бот считает расходом
    expect(bot.last('sendMessage')['text'], contains('Расход · 5 000 ₸'));
    await press(chatId, bot.button('Это доход'));
    expect(bot.last('editMessageText')['text'], allOf(contains('Доход · 5 000 ₸'), contains('Прочий доход')));
    await press(chatId, bot.button('Это расход'));
    expect(bot.last('editMessageText')['text'], allOf(contains('Расход · 5 000 ₸'), contains('Прочее')));
    await press(chatId, bot.button('Это доход'));
    await press(chatId, bot.button('Записать'));
    expect(await liquid(userId), kzt(105000));
  });

  test('быстрые операции: кнопка → черновик → запись; без быстрых — подсказка и клавиатура', () async {
    if (skip()) return;
    final (chatId, userId) = await owner();
    await say(chatId, '⚡ Быстрые');
    expect(bot.last('sendMessage')['text'], contains('Быстрых операций пока нет'));
    expect(((bot.last('sendMessage')['reply_markup'] as Map)['keyboard'] as List).first, [
      {'text': '⚡ Быстрые'},
      {'text': '📅 Сегодня'},
    ]);

    await ledger.command(userId, {'type': 'upsertEntity', 'commandId': 'quick-$chatId', 'kind': 'quick', 'entityId': 'coffee', 'data': {'name': 'Кофе', 'category': 'cafe', 'amount': '${kzt(1500)}'}});
    await say(chatId, '/quick');
    final quick = bot.button('Кофе · 1 500 ₸');
    await press(chatId, quick);
    expect(bot.last('sendMessage')['text'], allOf(contains('Расход · 1 500 ₸'), contains('Кафе'), contains('Заметка: Кофе')));
    expect(await liquid(userId), kzt(100000), reason: 'быстрая операция тоже ждёт подтверждения');
    await press(chatId, bot.button('Записать'));
    expect(await liquid(userId), kzt(98500));

    await press(chatId, 'q:нет-такой');
    expect(bot.last('answerCallbackQuery')['text'], contains('уже нет'));
    await say(chatId, '📅 Сегодня');
    expect(bot.last('sendMessage')['text'], contains('Потрачено: <b>1 500 ₸</b>'));
  });

  test('перевод: счета меняются кнопками, «куда» = «откуда» меняет их местами; запись и отмена', () async {
    if (skip()) return;
    final (chatId, userId) = await owner(accounts: 3);
    await say(chatId, 'перевёл 30000');
    expect(bot.last('sendMessage')['text'], allOf(contains('Перевод · 30 000 ₸'), contains('Со счёта: Счёт 0'), contains('На счёт: Счёт 1')));
    await press(chatId, bot.button('На счёт'));
    await press(chatId, bot.button('Счёт 2'));
    expect(bot.last('editMessageText')['text'], allOf(contains('Со счёта: Счёт 0'), contains('На счёт: Счёт 2')));
    await press(chatId, bot.button('Со счёта'));
    await press(chatId, bot.button('Счёт 2'));
    expect(bot.last('editMessageText')['text'], allOf(contains('Со счёта: Счёт 2'), contains('На счёт: Счёт 0')), reason: 'выбрали тот же счёт — поменялись местами');
    final ok = bot.button('Записать');
    await press(chatId, ok);
    var l = (await ledger.view(userId))!.ledger;
    expect((l.balance('acc0'), l.balance('acc1'), l.balance('acc2')), (kzt(130000), kzt(100000), kzt(70000)));
    expect(l.liquid(), kzt(300000), reason: 'перевод не меняет сумму денег');
    await press(chatId, bot.button('Отменить запись'));
    l = (await ledger.view(userId))!.ledger;
    expect((l.balance('acc0'), l.balance('acc2')), (kzt(100000), kzt(100000)));
  });

  test('долг: выдал и получил обратно; без имени — подсказка; минус — предупреждение до записи', () async {
    if (skip()) return;
    final (chatId, userId) = await owner();
    await say(chatId, 'взял в долг 20000');
    expect(bot.last('sendMessage')['text'], contains('Не понял, с кем долг'));

    await say(chatId, 'дал в долг марату 150000');
    expect(bot.last('sendMessage')['text'], allOf(contains('Дал в долг · 150 000 ₸'), contains('Кому: Марату'), contains('уйдёт в минус на 50 000 ₸')));
    await press(chatId, bot.button('Отмена'));

    await say(chatId, 'дал в долг марату 40000');
    expect(bot.last('sendMessage')['text'], isNot(contains('⚠')));
    await press(chatId, bot.button('Записать'));
    var l = (await ledger.view(userId))!.ledger;
    expect((l.balance('acc0'), l.balance('receivable:Марату')), (kzt(60000), kzt(40000)));
    expect(bot.last('editMessageText')['text'], contains('На счетах: 60 000 ₸.'));

    await say(chatId, 'марат вернул мне 15000');
    expect(bot.last('sendMessage')['text'], allOf(contains('Мне вернули долг · 15 000 ₸'), contains('Кто вернул: Марату')));
    await press(chatId, bot.button('Записать'));
    l = (await ledger.view(userId))!.ledger;
    expect((l.balance('acc0'), l.balance('receivable:Марату')), (kzt(75000), kzt(25000)));
    expect(l.report(DateTime(2000), DateTime(2100)).expense, 0, reason: 'долг — не расход');

    // Вернуть больше, чем должны, журнал не даст — бот покажет причину.
    await say(chatId, 'марат вернул мне 90000');
    await press(chatId, bot.button('Записать'));
    expect(bot.last('answerCallbackQuery')['text'], isNot(anyOf('Записано', isNull)));
    expect((await ledger.view(userId))!.ledger.balance('receivable:Марату'), kzt(25000));
  });

  test('после расхода бот показывает «доступно сегодня» по лимиту', () async {
    if (skip()) return;
    final (chatId, userId) = await owner();
    await ledger.command(userId, {'type': 'updateProfile', 'commandId': 'limit-$chatId', 'profile': {'dailyLimit': '${kzt(5000)}'}});
    await say(chatId, 'кофе 1500');
    await press(chatId, bot.button('Записать'));
    expect(bot.last('editMessageText')['text'], contains('Сегодня потрачено: 1 500 ₸. Доступно сегодня: <b>3 500 ₸</b>.'));
    await say(chatId, '/today');
    expect(bot.last('sendMessage')['text'], contains('Лимит на день: 5 000 ₸\nДоступно сегодня: <b>3 500 ₸</b>'));
  });

  test('«Отмена» ничего не записывает, кнопки после неё не действуют', () async {
    if (skip()) return;
    final (chatId, userId) = await owner();
    await say(chatId, 'такси 900');
    final ok = bot.button('Записать');
    await press(chatId, bot.button('Отмена'));
    expect(bot.last('editMessageText')['text'], contains('Не записано'));
    await press(chatId, ok);
    expect(await liquid(userId), kzt(100000));
  });

  test('чужой чат и отвязанный чат черновиком не управляют', () async {
    if (skip()) return;
    final (chatId, userId) = await owner();
    final (other, _) = await owner();
    await say(chatId, 'кофе 1500');
    final ok = bot.button('Записать');
    await press(other, ok);
    expect(await liquid(userId), kzt(100000));
    await pool!.execute(Sql.named('UPDATE users SET telegram_chat_id = NULL WHERE id = @u'), parameters: {'u': userId});
    await press(chatId, ok);
    expect(await liquid(userId), kzt(100000));
    expect(await chat.onMessage(chatId, {'text': 'кофе 1500'}), isFalse, reason: 'непривязанный чат — обычная подсказка бота');
  });

  /// Голосовое обрабатывается в фоне — ждём ответа бота.
  Future<void> voice(int chatId, String id, {int duration = 3}) async {
    final before = bot.calls.where((c) => c.$1 == 'sendMessage').length;
    expect(await chat.onMessage(chatId, {'voice': {'file_id': id, 'file_unique_id': id, 'duration': duration}}), isTrue);
    for (var i = 0; i < 100 && bot.calls.where((c) => c.$1 == 'sendMessage').length == before; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test('голосовое: распознанная фраза → черновик → запись; обращение учтено один раз', () async {
    if (skip()) return;
    final (chatId, userId) = await owner();
    speech.heard = 'Кофе 1500.';
    await voice(chatId, 'v1-$chatId');
    expect(bot.last('sendMessage')['text'], allOf(contains('🎤'), contains('Кофе 1500.'), contains('Расход · 1 500 ₸'), contains('Кафе')));
    await press(chatId, bot.button('Категория'));
    await press(chatId, bot.button('Назад'));
    expect(bot.last('editMessageText')['text'], contains('🎤'), reason: 'услышанное остаётся в черновике');
    await press(chatId, bot.button('Записать'));
    expect(await liquid(userId), kzt(98500));
    await voice(chatId, 'v1-$chatId');
    final rows = await pool!.execute(Sql.named("SELECT count(*), sum(tokens_in) FROM ai_usage WHERE user_id = @u AND feature = 'voice'"), parameters: {'u': userId});
    expect(rows.first[0], 1);
    expect(rows.first[1], 60);
  });

  test('голосовое: длинное не распознаётся, нераспознанное и лимит — понятный ответ', () async {
    if (skip()) return;
    final (chatId, userId) = await owner();
    final before = speech.requests;
    await voice(chatId, 'long-$chatId', duration: maxVoiceSeconds + 1);
    expect(bot.last('sendMessage')['text'], contains('Слишком длинное'));
    expect(speech.requests, before);

    speech.heard = '';
    await voice(chatId, 'mute-$chatId');
    expect(bot.last('sendMessage')['text'], contains('Не смог разобрать'));

    speech.heard = 'привет как дела';
    await voice(chatId, 'hello-$chatId');
    expect(bot.last('sendMessage')['text'], allOf(contains('привет как дела'), contains('Не нашёл сумму')));

    await pool!.execute(
      Sql.named("INSERT INTO ai_usage (user_id, feature, model, request_id) SELECT @u, 'voice', 'test', 'fill-' || g FROM generate_series(1, $maxVoicePerDay) g"),
      parameters: {'u': userId},
    );
    final spent = speech.requests;
    speech.heard = 'кофе 1500';
    await voice(chatId, 'over-$chatId');
    expect(bot.last('sendMessage')['text'], contains('лимит голосовых'));
    expect(speech.requests, spent);
  });

  test('команды и непонятные сообщения', () async {
    if (skip()) return;
    final (chatId, _) = await owner();
    await say(chatId, '/today');
    expect(bot.last('sendMessage')['text'], contains('Сегодня'));
    await say(chatId, '/month@Famcoin01_bot');
    expect(bot.last('sendMessage')['text'], contains('Итог месяца'));
    await say(chatId, 'привет');
    expect(bot.last('sendMessage')['text'], contains('Не нашёл сумму'));
    expect(await chat.onMessage(chatId, {'video_note': {'file_id': 'x'}}), isTrue);
    expect(bot.last('sendMessage')['text'], contains('Голосовые'));
  });
}
