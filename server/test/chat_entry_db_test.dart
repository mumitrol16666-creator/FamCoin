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

  Map<String, Object?> last(String method) => calls.lastWhere((c) => c.$1 == method).$2;

  /// `callback_data` кнопки с подписью, содержащей [label], в последнем сообщении.
  String button(String label) {
    final sent = calls.lastWhere((c) => (c.$1 == 'sendMessage' || c.$1 == 'editMessageText') && c.$2['reply_markup'] != null).$2;
    final rows = (sent['reply_markup'] as Map)['inline_keyboard'] as List;
    return rows.expand((r) => r as List).cast<Map>().firstWhere((b) => '${b['text']}'.contains(label))['callback_data'] as String;
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
  final base = 9300000000 + (DateTime.now().microsecondsSinceEpoch % 1000000) * 1000;
  var n = 0;

  setUpAll(() async {
    pool = await _connect();
    if (pool == null) return;
    auth = AuthService(pool!);
    ledger = LedgerService(pool!);
    bot = _FakeTelegram(pool!);
    chat = ChatEntry(pool!, ledger, bot)..attach();
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

  test('команды и непонятные сообщения', () async {
    if (skip()) return;
    final (chatId, _) = await owner();
    await say(chatId, '/today');
    expect(bot.last('sendMessage')['text'], contains('Сегодня'));
    await say(chatId, '/month@Famcoin01_bot');
    expect(bot.last('sendMessage')['text'], contains('Итог месяца'));
    await say(chatId, 'привет');
    expect(bot.last('sendMessage')['text'], contains('Не нашёл сумму'));
    expect(await chat.onMessage(chatId, {'voice': {'file_id': 'x'}}), isTrue);
    expect(bot.last('sendMessage')['text'], contains('Голосовые'));
  });
}
