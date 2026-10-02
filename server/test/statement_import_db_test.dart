/// Импорт выписки Kaspi через бота (D94) от файла до журнала — на настоящей
/// базе, с подставным Telegram и подставным чтением PDF. Нужна база из
/// docker-compose (порт задаётся `TEST_DB_PORT`); без базы тесты пропускаются.
library;

import 'dart:io';

import 'package:famcoin_core/famcoin_core.dart';
import 'package:famcoin_server/auth_service.dart';
import 'package:famcoin_server/chat_entry.dart';
import 'package:famcoin_server/ledger_service.dart';
import 'package:famcoin_server/notifications.dart';
import 'package:famcoin_server/pdf_words.dart';
import 'package:famcoin_server/statement_import.dart';
import 'package:famcoin_server/statement_plan.dart';
import 'package:famcoin_server/telegram.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

import 'statement_layout.dart';

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
  Future<List<int>?> download(String fileId, {int maxBytes = 1024 * 1024}) async => '%PDF-1.4 test'.codeUnits;

  Map<String, Object?> last(String method) => calls.lastWhere((c) => c.$1 == method).$2;

  /// Текст последнего сообщения — отправленного или изменённого.
  String get text => '${calls.lastWhere((c) => c.$1 == 'sendMessage' || c.$1 == 'editMessageText').$2['text']}';

  List<Map> get buttons {
    final sent = calls.lastWhere((c) => c.$1 == 'sendMessage' || c.$1 == 'editMessageText').$2;
    final rows = (sent['reply_markup'] as Map?)?['inline_keyboard'] as List? ?? const [];
    return rows.expand((r) => r as List).cast<Map>().toList();
  }

  bool has(String label) => buttons.any((b) => '${b['text']}'.contains(label));
  String button(String label) => buttons.firstWhere((b) => '${b['text']}'.contains(label))['callback_data'] as String;
}

/// «Читает» заранее заданные слова вместо запуска pdftotext.
class _FakeReader extends PdfReader {
  List<PdfWord>? next;
  var on = true;

  @override
  bool get enabled => on;

  @override
  Future<List<PdfWord>?> words(List<int> pdf) async => next;
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
    await db.execute('SELECT 1 FROM telegram_imports LIMIT 1').timeout(const Duration(seconds: 3));
    return db;
  } catch (_) {
    return null;
  }
}

const _pdf = {'file_id': 'f1', 'file_name': 'gold_statement.pdf', 'mime_type': 'application/pdf', 'file_size': 120000};

void main() {
  Pool? pool;
  late AuthService auth;
  late LedgerService ledger;
  late _FakeTelegram bot;
  late StatementImport imports;
  late ChatEntry chat;
  final reader = _FakeReader();
  final base = 9400000000 + (DateTime.now().microsecondsSinceEpoch % 1000000) * 1000;
  var n = 0;

  setUpAll(() async {
    pool = await _connect();
    if (pool == null) return;
    auth = AuthService(pool!);
    ledger = LedgerService(pool!);
    bot = _FakeTelegram(pool!);
    imports = StatementImport(pool!, ledger, bot, reader, proLink: (userId) async => 'https://t.me/\$test-invoice');
    chat = ChatEntry(pool!, ledger, bot, imports: imports)..attach();
  });

  setUp(() {
    reader
      ..on = true
      ..next = sampleStatement().words;
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

  /// Новый владелец с привязанным чатом и счётом «Kaspi Gold» (`acc0`).
  /// [extra] — ещё команды: счета, операции, профиль.
  Future<(int, String)> owner({String openingDate = '2026-09-20', num openingAmount = 50000, List<Map<String, dynamic>> extra = const [], bool pro = true}) async {
    final chatId = base + n++;
    final code = await auth.telegramStart();
    expect(await bot.confirmLogin(code, chatId, 'Тест'), isTrue);
    final userId = ((await auth.telegramCheck(code, 'ru'))['user'] as Map)['id'] as String;
    if (pro) await pool!.execute(Sql.named("UPDATE users SET plan = 'pro' WHERE id = @u"), parameters: {'u': userId});
    await ledger.command(userId, {
      'type': 'batch',
      'commandId': 'setup-$chatId',
      'commands': [
        {'type': 'addMoneyAccount', 'accountId': 'acc0'},
        {'type': 'upsertEntity', 'kind': 'account', 'entityId': 'acc0', 'data': {'name': 'Kaspi Gold', 'type': 'card'}},
        {'type': 'opening', 'id': 'open0', 'date': openingDate, 'account': 'acc0', 'amount': '${kzt(openingAmount)}'},
        {'type': 'updateProfile', 'profile': {'onboarded': true}},
        ...extra,
      ],
    });
    return (chatId, userId);
  }

  Future<void> send(int chatId, String userId, [Map<String, dynamic> doc = _pdf]) => imports.onDocument(chatId, userId, doc);
  Future<void> press(int chatId, String data) => chat.onCallback({'id': 'q', 'data': data, 'message': {'message_id': 7, 'chat': {'id': chatId}}});
  Future<LedgerView> view(String userId) async => (await ledger.view(userId))!;
  Future<String> status(String userId) async =>
      (await pool!.execute(Sql.named('SELECT status FROM telegram_imports WHERE user_id = @u ORDER BY created_at DESC LIMIT 1'), parameters: {'u': userId})).first[0] as String;

  /// Действующие (не отменённые) операции по счёту, кроме начального остатка.
  List<Transaction> liveOps(Ledger l) =>
      [for (final t in l.transactions) if (t.type != EventType.reversal && t.type != EventType.opening && !l.isReversed(t.id) && t.amountOn('acc0') != 0) t];
  Transaction liveOpening(Ledger l) => l.transactions.singleWhere((t) => t.type == EventType.opening && !l.isReversed(t.id));

  test('файл → сводка → «Записать» → операции в журнале, остаток как в банке → «Отменить импорт»', () async {
    if (skip()) return;
    final (chatId, userId) = await owner();
    // Через общий вход бота: документ уходит в импорт, разбор не ждут.
    expect(await chat.onMessage(chatId, {'document': _pdf}), isTrue);
    for (var i = 0; i < 100 && !bot.calls.any((c) => c.$1 == 'sendMessage' && c.$2['chat_id'] == chatId && '${c.$2['text']}'.contains('Выписка Kaspi')); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(bot.text, allOf(contains('Выписка Kaspi · 01.09.2026 – 30.09.2026'), contains('Счёт в FamCoin: Kaspi Gold'), contains('операций: 9, итоги сошлись с банком ✓'), contains('новых — 9')));
    expect(bot.text, allOf(contains('Расходы — 5, 43 220,08 ₸'), contains('покупки 2'), contains('переводы людям 1'), contains('снятия наличных 1'), contains('прочее 1')));
    expect(bot.text, allOf(contains('Доходы — 1, 50 000 ₸'), contains('Возвраты — 1, 2 500 ₸'), contains('Уточнения остатка — 2, −15 000 ₸')));
    expect(bot.text, allOf(contains('Начальный остаток счёта заменю: 100 000 ₸ на 01.09.2026'), contains('сейчас 50 000 ₸ на 20.09.2026')));
    expect(bot.text, allOf(contains('Остаток счёта после записи: <b>94 279,92 ₸</b>'), contains('Остаток на 30.09.2026 совпадает с выпиской ✓')));
    expect((await view(userId)).ledger.balance('acc0'), kzt(50000), reason: 'до подтверждения в журнале ничего нет');

    final ok = bot.button('Записать (9)');
    await press(chatId, ok);
    var l = (await view(userId)).ledger;
    expect(l.balance('acc0'), 9427992, reason: 'как в банке');
    expect(liveOps(l).length, 9);
    expect((dateToJson(liveOpening(l).date), liveOpening(l).amountOn('acc0')), ('2026-09-01', kzt(100000)));
    expect(l.isDeleted('open0'), isFalse);
    expect(l.expenseByCategory(DateTime(2026, 9), DateTime(2026, 10)), {
      'expense:food': kzt(1500) - kzt(2500),
      'expense:subscriptions': 1147008,
      'expense:other': kzt(20000) + kzt(10000),
      'expense:fees': kzt(250),
    });
    expect(l.byId(importRowId(ok.split(':')[1], 8))!.meta, {'who': 'me', 'note': 'MAGNUM AF51', 'src': 'kaspi'});
    expect(bot.text, allOf(contains('Записано операций: 9'), contains('остаток <b>94 279,92 ₸</b>'), contains('Начальный остаток теперь 100 000 ₸ на 01.09.2026'), contains('совпадает с выпиской ✓')));
    expect(bot.has('Выровнять'), isFalse);
    expect(await status(userId), 'saved');

    await press(chatId, ok); // двойное нажатие — операции те же
    expect(liveOps((await view(userId)).ledger).length, 9);

    final undo = bot.button('Отменить импорт');
    await press(chatId, undo);
    l = (await view(userId)).ledger;
    expect(l.balance('acc0'), kzt(50000));
    expect(liveOps(l), isEmpty);
    expect((dateToJson(liveOpening(l).date), liveOpening(l).amountOn('acc0')), ('2026-09-20', kzt(50000)), reason: 'начальный остаток возвращён');
    expect(bot.text, allOf(contains('Импорт отменён'), contains('начальный остаток возвращён')));
    expect(await status(userId), 'undone');
    await press(chatId, undo);
    expect(bot.last('answerCallbackQuery')['text'], contains('не действует'));

    // Отменённый импорт не мешает прислать ту же выписку снова.
    await send(chatId, userId);
    expect(bot.text, contains('новых — 9'));
    await press(chatId, bot.button('Записать (9)'));
    expect((await view(userId)).ledger.balance('acc0'), 9427992);
  });

  test('та же выписка второй раз: новых операций нет, записывать нечего', () async {
    if (skip()) return;
    final (chatId, userId) = await owner();
    await send(chatId, userId);
    await press(chatId, bot.button('Записать'));
    await send(chatId, userId);
    expect(bot.text, allOf(contains('уже записаны — 9'), contains('Новых операций нет'), contains('совпадает с выпиской ✓')));
    expect(bot.has('Записать'), isFalse);
    expect(bot.has('Выровнять'), isFalse);
    await press(chatId, bot.button('Закрыть'));
    expect(bot.text, contains('Выписка не записана'));
    expect(liveOps((await view(userId)).ledger).length, 9);
  });

  test('записанное вручную сверяется: совпавшее не задваивается, лишнее видно и выравнивается кнопкой', () async {
    if (skip()) return;
    final (chatId, userId) = await owner(openingDate: '2026-09-01', openingAmount: 100000, extra: [
      // есть в выписке (30.09, MAGNUM) — записано руками днём раньше
      {'type': 'expense', 'id': 'm1', 'date': '2026-09-29', 'account': 'acc0', 'splits': {'food': '${kzt(1500)}'}, 'meta': {'who': 'me', 'note': 'продукты'}},
      // в выписке такого нет
      {'type': 'expense', 'id': 'm2', 'date': '2026-09-10', 'account': 'acc0', 'splits': {'cafe': '${kzt(5000)}'}, 'meta': {'who': 'me'}},
    ]);
    await send(chatId, userId);
    expect(bot.text, allOf(contains('новых — 8'), contains('уже записаны — 1'), isNot(contains('Начальный остаток'))));
    expect(bot.text, allOf(contains('По выписке на 30.09.2026 — 94 279,92 ₸'), contains('выйдет 89 279,92 ₸: на 5 000 ₸ меньше'), contains('После записи предложу выровнять')));
    await press(chatId, bot.button('Записать (8)'));
    var l = (await view(userId)).ledger;
    expect(l.balance('acc0'), 8927992);
    expect(bot.text, allOf(contains('Записано операций: 8'), contains('на 5 000 ₸ меньше'), contains('Нажмите «Выровнять»')));

    await press(chatId, bot.button('Выровнять'));
    l = (await view(userId)).ledger;
    expect(l.balance('acc0', asOf: DateTime(2026, 9, 30)), 9427992);
    final level = l.transactions.singleWhere((t) => t.type == EventType.adjustment && t.meta['reason'] == 'Сверка с выпиской Kaspi за 01.09.2026 – 30.09.2026');
    expect((level.amountOn('acc0'), dateToJson(level.date)), (kzt(5000), '2026-09-30'));
    expect(bot.text, allOf(contains('Остаток выровнен по выписке: уточнение остатка +5 000 ₸ на 30.09.2026'), isNot(contains('Нажмите «Выровнять»'))));
    expect(bot.has('Выровнять'), isFalse);

    await press(chatId, bot.button('Отменить импорт'));
    l = (await view(userId)).ledger;
    expect(l.balance('acc0'), kzt(100000 - 1500 - 5000), reason: 'осталось только записанное вручную');
    expect(liveOps(l).map((t) => t.id).toSet(), {'m1', 'm2'});
  });

  test('всё уже записано, а остаток расходится — выровнять можно и без записи', () async {
    if (skip()) return;
    final (chatId, userId) = await owner(openingDate: '2026-09-01', openingAmount: 100000);
    await send(chatId, userId);
    await press(chatId, bot.button('Записать'));
    await ledger.command(userId, {'type': 'expense', 'id': 'm9', 'date': '2026-09-15', 'account': 'acc0', 'splits': {'cafe': '${kzt(700)}'}, 'meta': {'who': 'me'}, 'commandId': 'c-m9-$chatId'});
    await send(chatId, userId);
    expect(bot.text, allOf(contains('Новых операций нет'), contains('на 700 ₸ меньше')));
    await press(chatId, bot.button('Выровнять'));
    expect((await view(userId)).ledger.balance('acc0'), 9427992);
    expect(bot.text, contains('уточнение остатка +700 ₸'));
    await press(chatId, bot.button('Отменить импорт'));
    expect((await view(userId)).ledger.balance('acc0'), 9427992 - kzt(700));
  });

  test('операцию из выписки поправили и удалили в приложении: отмена импорта это учитывает', () async {
    if (skip()) return;
    final (chatId, userId) = await owner(openingDate: '2026-09-01', openingAmount: 100000);
    await send(chatId, userId);
    final ok = bot.button('Записать');
    final id = ok.split(':')[1];
    await press(chatId, ok);
    // Правка покупки (строка 8, MAGNUM 1 500) — как в приложении: отмена и новая версия.
    await ledger.command(userId, {
      'type': 'batch',
      'commandId': 'edit-$chatId',
      'commands': [
        {'type': 'reverse', 'txId': importRowId(id, 8), 'id': 'e-rev'},
        {'type': 'expense', 'id': 'e-new', 'date': '2026-09-30', 'account': 'acc0', 'splits': {'household': '${kzt(1500)}'}, 'meta': {'who': 'me', 'note': 'MAGNUM AF51', 'edited': importRowId(id, 8)}},
        // Удаление перевода (строка 6) — в корзину.
        {'type': 'reverse', 'txId': importRowId(id, 6), 'id': 'trash-6'},
      ],
    });
    // Повторная выписка: удалённое не возвращается, правка не задваивается.
    await send(chatId, userId);
    expect(bot.text, allOf(contains('уже записаны — 8'), contains('удалены вами раньше — 1'), contains('Новых операций нет')));
    // И следующая покупка в том же магазине пойдёт в выбранную человеком категорию.
    final s = statementHead(closing: '+ 99 000,00 ₸')
      ..header()
      ..row('03.09.26', '- 1 000,00 ₸', 'Покупка', 'MAGNUM AF51');
    reader.next = s.words;
    await send(chatId, userId);
    await press(chatId, bot.button('Список'));
    expect(bot.text, contains('03.09 · −1 000 ₸ · Бытовые покупки · MAGNUM AF51'));

    bot.calls.clear();
    await press(chatId, 'i:$id:undo');
    final l = (await view(userId)).ledger;
    expect(l.isReversed('e-new'), isTrue, reason: 'отменяется действующая версия поправленной операции');
    expect(liveOps(l), isEmpty);
    expect(l.balance('acc0'), kzt(100000));
  });

  test('перенос дневного лимита начинается заново и возвращается при отмене', () async {
    if (skip()) return;
    final history = [
      {'from': '2026-09-20', 'amount': '500000'},
    ];
    final (chatId, userId) = await owner(openingDate: '2026-09-01', openingAmount: 100000, extra: [
      {'type': 'updateProfile', 'profile': {'dailyLimit': '500000', 'dailyLimitCarry': true, 'dailyLimitSince': '2026-09-20', 'dailyLimitHistory': history}},
    ]);
    final now = DateTime.now().toUtc().add(kzOffset);
    final today = dateToJson(DateTime(now.year, now.month, now.day));
    await send(chatId, userId);
    expect(bot.text, contains('Перенос дневного лимита начну заново'));
    await press(chatId, bot.button('Записать'));
    var profile = (await view(userId)).profile;
    expect(profile['dailyLimitSince'], today);
    expect(profile['dailyLimitHistory'], [
      {'from': today, 'amount': '500000'},
    ]);
    expect(dailyLimitState((await view(userId)).ledger, profile, dateFromJson(today)).planned, kzt(5000), reason: 'траты сентября из выписки не стали перерасходом');
    expect(bot.text, contains('Перенос дневного лимита начат заново'));

    await press(chatId, bot.button('Отменить импорт'));
    profile = (await view(userId)).profile;
    expect(profile['dailyLimitSince'], '2026-09-20');
    expect(profile['dailyLimitHistory'], history);
  });

  test('плановый платёж из выписки отмечается оплаченным, платёж по кредиту не пишется; отмена снимает отметку', () async {
    if (skip()) return;
    final (chatId, userId) = await owner(openingDate: '2026-09-01', openingAmount: 100000, extra: [
      {'type': 'upsertEntity', 'kind': 'planned', 'entityId': 'p1', 'data': {'name': 'Подписка ChatGPT', 'amount': '1147008', 'day': 25, 'category': 'subscriptions', 'paid': <String>[], 'start': '2026-09-01'}},
      {'type': 'openingDebt', 'id': 'd1', 'date': '2026-09-01', 'debtId': 'red', 'amount': '${kzt(300000)}'},
      {'type': 'upsertEntity', 'kind': 'debt', 'entityId': 'red', 'data': {'name': 'Kaspi Кредит', 'kind': 'loan'}},
      {'type': 'upsertEntity', 'kind': 'planned', 'entityId': 'p2', 'data': {'name': 'Kaspi Кредит', 'amount': '${kzt(20000)}', 'day': 28, 'category': 'other', 'debtId': 'red', 'paid': <String>[], 'start': '2026-09-01'}},
    ]);
    Future<List<dynamic>> paid(String id) async => ((await view(userId)).of('planned')[id]!['paid'] as List);

    await send(chatId, userId);
    expect(bot.text, allOf(contains('новых — 8'), contains('платежи по кредитам — 1, не записываю'), contains('плановые платежи 1'), contains('Плановые платежи отмечу оплаченными: Подписка ChatGPT.')));
    expect(bot.text, allOf(contains('Платежи по кредитам не записываю — 1, 20 000 ₸ (Kaspi Кредит)'), isNot(contains('совпадает с выпиской')), isNot(contains('предложу выровнять'))));
    final ok = bot.button('Записать (8)');
    await press(chatId, ok);
    var v = await view(userId);
    expect(await paid('p1'), ['2026-09']);
    expect(await paid('p2'), isEmpty);
    final payment = v.ledger.byId(importRowId(ok.split(':')[1], 4))!;
    expect(payment.meta, {'who': 'shared', 'note': 'Подписка ChatGPT', 'planned': 'p1', 'period': '2026-09', 'src': 'kaspi'});
    expect(v.ledger.balance('acc0'), 9427992 + kzt(20000), reason: 'платёж по кредиту не записан');
    expect(v.ledger.balance(liabilityAccount('red')), kzt(300000));
    expect(bot.text, allOf(contains('Записано операций: 8'), contains('Плановые платежи отмечены оплаченными: 1'), contains('Платежи по кредитам не записаны: Kaspi Кредит 20 000 ₸ (28.09.2026)')));
    expect(bot.has('Выровнять'), isFalse, reason: 'пока не записана вся выписка, остаток с банком не сравнивается');

    await press(chatId, bot.button('Отменить импорт'));
    v = await view(userId);
    expect(await paid('p1'), isEmpty);
    expect(v.ledger.balance('acc0'), kzt(100000));
  });

  test('деньги в копилке цели не считаются расхождением с банком и не выравниваются', () async {
    if (skip()) return;
    final (chatId, userId) = await owner(openingDate: '2026-09-01', openingAmount: 100000, extra: [
      {'type': 'addMoneyAccount', 'accountId': 'piggy-g1'},
      {'type': 'upsertEntity', 'kind': 'account', 'entityId': 'piggy-g1', 'data': {'name': 'На отпуск', 'type': 'piggy'}},
      {'type': 'transfer', 'id': 't1', 'date': '2026-09-10', 'from': 'acc0', 'to': 'piggy-g1', 'amount': '${kzt(20000)}'},
    ]);
    await send(chatId, userId);
    expect(bot.buttons.map((b) => b['text']), isNot(contains('На отпуск')), reason: 'копилка — не счёт для выписки');
    expect(bot.text, allOf(contains('Остаток счёта после записи: <b>74 279,92 ₸</b>'), contains('совпадает с выпиской ✓ — если считать, что 20 000 ₸ из копилок лежат на этой же карте'), isNot(contains('предложу выровнять'))));
    await press(chatId, bot.button('Записать'));
    expect(bot.text, contains('совпадает с выпиской ✓ — если считать, что 20 000 ₸ из копилок'));
    expect(bot.has('Выровнять'), isFalse);
    final l = (await view(userId)).ledger;
    expect((l.balance('acc0'), l.balance('piggy-g1')), (9427992 - kzt(20000), kzt(20000)));

    // Расхождение сверх копилки показывается, но выравнивать предлагается сверкой в приложении.
    await ledger.command(userId, {'type': 'expense', 'id': 'm7', 'date': '2026-09-12', 'account': 'acc0', 'splits': {'cafe': '${kzt(300)}'}, 'meta': {'who': 'me'}, 'commandId': 'c-m7-$chatId'});
    await send(chatId, userId);
    expect(bot.text, allOf(contains('на 20 300 ₸ меньше'), contains('С этого счёта в копилки отложено 20 000 ₸'), contains('расхождение — 300 ₸')));
    expect(bot.has('Выровнять'), isFalse);
  });

  test('история продлевается назад второй выпиской; отменять импорты можно только с последнего', () async {
    if (skip()) return;
    final (chatId, userId) = await owner();
    await send(chatId, userId);
    await press(chatId, bot.button('Записать')); // сентябрь: начальный остаток 100 000 на 01.09
    final undoSeptember = bot.button('Отменить импорт');

    // Август: кончается ровно на остатке, с которого начинается сентябрь.
    final august = Sheet()
      ..line('ВЫПИСКА по Kaspi Gold за период с 01.08.26 по 31.08.26')
      ..pair('Доступно на 01.08.26', '+ 120 000,00 ₸')
      ..pair('Доступно на 31.08.26', '+ 100 000,00 ₸')
      ..gap()
      ..header()
      ..row('20.08.26', '- 15 000,00 ₸', 'Покупка', 'TECHNODOM')
      ..row('05.08.26', '- 5 000,00 ₸', 'Покупка', 'MAGNUM');
    reader.next = august.words;
    await send(chatId, userId);
    expect(bot.text, allOf(contains('новых — 2'), contains('Начальный остаток счёта заменю: 120 000 ₸ на 01.08.2026'), contains('сейчас 100 000 ₸ на 01.09.2026')));
    await press(chatId, bot.button('Записать'));
    final undoAugust = bot.button('Отменить импорт');
    var l = (await view(userId)).ledger;
    expect(l.balance('acc0'), 9427992, reason: 'сегодняшний остаток не изменился');
    expect(l.balance('acc0', asOf: DateTime(2026, 8, 10)), kzt(115000));
    expect((dateToJson(liveOpening(l).date), liveOpening(l).amountOn('acc0')), ('2026-08-01', kzt(120000)));

    await press(chatId, undoSeptember);
    expect(bot.last('answerCallbackQuery')['text'], contains('Сначала отмените более поздний импорт'));
    expect((await view(userId)).ledger.balance('acc0'), 9427992);

    await press(chatId, undoAugust);
    l = (await view(userId)).ledger;
    expect(l.balance('acc0'), 9427992);
    expect((dateToJson(liveOpening(l).date), liveOpening(l).amountOn('acc0')), ('2026-09-01', kzt(100000)));
    expect(liveOps(l).length, 9);

    await press(chatId, undoSeptember);
    l = (await view(userId)).ledger;
    expect(l.balance('acc0'), kzt(50000));
    expect((dateToJson(liveOpening(l).date), liveOpening(l).amountOn('acc0')), ('2026-09-20', kzt(50000)));
    expect(liveOps(l), isEmpty);
    expect(l.transactions.where((t) => l.isDeleted(t.id) && t.type == EventType.opening), isEmpty, reason: 'ни одна версия начального остатка не лежит в корзине');
  });

  test('несколько счетов: бот спрашивает, к какому относится выписка; счёт можно сменить', () async {
    if (skip()) return;
    final (chatId, userId) = await owner(extra: [
      {'type': 'addMoneyAccount', 'accountId': 'acc1'},
      {'type': 'upsertEntity', 'kind': 'account', 'entityId': 'acc1', 'data': {'name': 'Kaspi Gold жены', 'type': 'card'}},
      {'type': 'addMoneyAccount', 'accountId': 'cash'},
      {'type': 'upsertEntity', 'kind': 'account', 'entityId': 'cash', 'data': {'name': 'Наличные', 'type': 'cash'}},
    ]);
    await send(chatId, userId);
    expect(bot.text, contains('К какому счёту относится эта выписка?'));
    expect(bot.buttons.map((b) => b['text']), ['Kaspi Gold', 'Kaspi Gold жены', 'Наличные', '✖ Отмена']);
    await press(chatId, bot.button('Kaspi Gold жены'));
    expect(bot.text, allOf(contains('Счёт в FamCoin: Kaspi Gold жены'), contains('Поставлю начальный остаток счёта: 100 000 ₸ на 01.09.2026')));
    // Снятие наличных — перевод на счёт «Наличные», раз он ведётся.
    expect(bot.text, allOf(contains('Переводы между своими счетами — 1, −10 000 ₸'), isNot(contains('снятия наличных'))));
    await press(chatId, bot.button('Счёт'));
    await press(chatId, bot.button('← Назад'));
    expect(bot.text, contains('Счёт в FamCoin: Kaspi Gold жены'));
    await press(chatId, bot.button('Счёт'));
    await press(chatId, bot.buttons.firstWhere((b) => b['text'] == 'Kaspi Gold')['callback_data'] as String);
    expect(bot.text, contains('Счёт в FamCoin: Kaspi Gold\n'));
    await press(chatId, bot.button('Записать'));
    final l = (await view(userId)).ledger;
    expect(l.balance('acc0'), 9427992);
    expect(l.balance('cash'), kzt(10000));
    expect(l.balance('acc1'), 0);
  });

  test('длинная выписка пишется несколькими пачками и целиком отменяется', () async {
    if (skip()) return;
    final (chatId, userId) = await owner(openingDate: '2026-09-01', openingAmount: 1000000);
    // Остаток на начало 1 000 000: 320 покупок по 1 000 ₸.
    final sheet = Sheet()
      ..line('ВЫПИСКА по Kaspi Gold за период с 01.09.26 по 30.09.26')
      ..pair('Доступно на 01.09.26', '+ 1 000 000,00 ₸')
      ..pair('Доступно на 30.09.26', '+ 680 000,00 ₸')
      ..gap()
      ..header();
    for (var i = 0; i < 320; i++) {
      if (sheet.y > 780) sheet.newPage();
      sheet.row('${(i % 30 + 1).toString().padLeft(2, '0')}.09.26', '- 1 000,00 ₸', 'Покупка', 'SMALL $i');
    }
    reader.next = sheet.words;
    await send(chatId, userId);
    expect(bot.text, contains('новых — 320'));
    await press(chatId, bot.button('Записать (320)'));
    var l = (await view(userId)).ledger;
    expect(liveOps(l).length, 320);
    expect(l.balance('acc0'), kzt(680000));
    expect(bot.text, contains('Записано операций: 320'));
    await press(chatId, bot.button('Отменить импорт'));
    l = (await view(userId)).ledger;
    expect(liveOps(l), isEmpty);
    expect(l.balance('acc0'), kzt(1000000));
  });

  test('не тот файл, выписка не сошлась, чтение PDF выключено — понятный ответ и ничего в журнале', () async {
    if (skip()) return;
    final (chatId, userId) = await owner();
    await send(chatId, userId, {'file_id': 'f2', 'file_name': 'photo.jpg', 'mime_type': 'image/jpeg', 'file_size': 1000});
    expect(bot.text, contains('только PDF-выписку Kaspi Gold'));
    await send(chatId, userId, {..._pdf, 'file_size': 6 * 1024 * 1024});
    expect(bot.text, contains('больше 5 МБ'));

    reader.next = null;
    await send(chatId, userId);
    expect(bot.text, contains('Не смог прочитать файл'));
    reader.next = (Sheet()..line('Справка о доходах')).words;
    await send(chatId, userId);
    expect(bot.text, contains('не похоже на выписку Kaspi Gold'));
    reader.next = sampleStatement(closing: '+ 94 000,00 ₸').words;
    await send(chatId, userId);
    expect(bot.text, allOf(contains('не сошлись с её итогами'), contains('Ничего не записываю')));
    reader.on = false;
    await send(chatId, userId);
    expect(bot.text, contains('Импорт выписок сейчас недоступен'));

    expect((await view(userId)).ledger.balance('acc0'), kzt(50000));
    final rows = await pool!.execute(Sql.named('SELECT count(*) FROM telegram_imports WHERE user_id = @u'), parameters: {'u': userId});
    expect(rows.first[0], 0, reason: 'неразобранные файлы не хранятся');
  });

  test('чужой чат не может нажать кнопку импорта; «начать заново» стирает импорты', () async {
    if (skip()) return;
    final (chatId, userId) = await owner();
    final (otherChat, _) = await owner();
    await send(chatId, userId);
    final ok = bot.button('Записать');
    await press(otherChat, ok);
    expect(bot.last('answerCallbackQuery')['text'], contains('устарела'));
    expect((await view(userId)).ledger.balance('acc0'), kzt(50000));
    await resetUserData(pool!, userId);
    final rows = await pool!.execute(Sql.named('SELECT count(*) FROM telegram_imports WHERE user_id = @u'), parameters: {'u': userId});
    expect(rows.first[0], 0);
  });

  test('обычный тариф: сводка и список доступны, запись — в Pro; после оформления та же кнопка записывает', () async {
    if (skip()) return;
    final (chatId, userId) = await owner(pro: false);
    await send(chatId, userId);
    expect(bot.text, allOf(contains('новых — 9'), contains('🔒 Записать операции из выписки можно в Pro')));
    final ok = bot.button('Записать');
    await press(chatId, bot.button('Список'));
    expect(bot.text, contains('Новые операции из выписки'));

    await press(chatId, ok);
    expect(bot.text, allOf(contains('входит в <b>Pro</b>'), contains('нажмите «Записать» ещё раз')));
    expect(bot.buttons.single, {'text': 'Оформить Pro', 'url': 'https://t.me/\$test-invoice'});
    expect(bot.last('answerCallbackQuery')['text'], 'Нужен Pro');
    expect((await view(userId)).ledger.balance('acc0'), kzt(50000));
    expect(await status(userId), 'pending');

    await pool!.execute(Sql.named("UPDATE users SET plan = 'pro' WHERE id = @u"), parameters: {'u': userId});
    await press(chatId, ok);
    expect((await view(userId)).ledger.balance('acc0'), 9427992);
    expect(bot.text, contains('Записано операций: 9'));
  });

  test('не больше двадцати файлов в сутки от одного человека — считая неразобранные', () async {
    if (skip()) return;
    final (chatId, userId) = await owner();
    reader.next = null;
    for (var i = 0; i < StatementImport.maxPerDay; i++) {
      await send(chatId, userId);
      expect(bot.text, contains('Не смог прочитать файл'));
    }
    reader.next = sampleStatement().words;
    await send(chatId, userId);
    expect(bot.text, contains('На сегодня выписок достаточно'));
    // Предел личный: у другого человека всё работает.
    final (otherChat, otherUser) = await owner();
    await send(otherChat, otherUser);
    expect(bot.text, contains('новых — 9'));
  });

  test('подсказка бота упоминает выписку, только когда импорт включён', () {
    expect(helpText(false, statements: true), contains('PDF-выписку Kaspi Gold'));
    expect(helpText(false), isNot(contains('PDF-выписку')));
    expect(helpText(true, statements: true), contains('Kaspi Gold үзінді көшірмесін'));
  });
}
