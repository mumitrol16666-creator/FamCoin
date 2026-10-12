/// D167, часть 3, с базой: планировщик напоминаний (полдень, вечер, отметки
/// стадий), кнопка «Оплатил» записывает платёж и закрывает срок, повтор не
/// дублирует, «Отменить» возвращает всё назад.
library;

import 'dart:io';

import 'package:famcoin_core/famcoin_core.dart';
import 'package:famcoin_server/auth_service.dart';
import 'package:famcoin_server/chat_entry.dart';
import 'package:famcoin_server/ledger_service.dart';
import 'package:famcoin_server/notifications.dart';
import 'package:famcoin_server/telegram.dart';
import 'package:famcoin_server/webpush.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

class _Telegram extends Telegram {
  _Telegram(super.db) : super(token: 'test');
  final calls = <(String, Map<String, Object?>)>[];
  @override
  Future<Map<String, dynamic>?> call(String method, Map<String, Object?> body) async {
    calls.add((method, body));
    return {'ok': true, 'result': {}};
  }
  Map<String, Object?> last(String method) => calls.lastWhere((c) => c.$1 == method).$2;
}

class _Push extends WebPush {
  _Push(super.db) : super(subject: 'mailto:test@example.test');
  @override
  Future<bool> sendToUser(String userId, String title, String body, {String tag = 'famcoin', String? url}) async => true;
}

void main() {
  Pool? pool;
  final users = <String>[];
  var seq = 0;

  setUpAll(() async {
    final db = Pool.withEndpoints(
      [Endpoint(host: 'localhost', port: int.parse(Platform.environment['TEST_DB_PORT'] ?? '5433'), database: 'famcoin', username: 'famcoin', password: 'famcoin')],
      settings: const PoolSettings(maxConnectionCount: 4, sslMode: SslMode.disable),
    );
    try {
      await db.execute('SELECT tg_buttons FROM notifications LIMIT 1').timeout(const Duration(seconds: 3));
      pool = db;
    } catch (_) {}
  });

  tearDownAll(() async {
    final db = pool;
    if (db == null) return;
    for (final id in users) {
      await deleteUserData(db, id);
    }
    await db.close();
  });

  bool skip() {
    if (pool != null) return false;
    if (Platform.environment['TEST_DB_REQUIRED'] == '1') fail('TEST_DB_REQUIRED=1, а база недоступна');
    markTestSkipped('база не запущена');
    return true;
  }

  test('полдень → напоминание с кнопкой; «Оплатил» → платёж и отметка; повтор; вечер молчит; «Отменить»', () async {
    if (skip()) return;
    final ledger = LedgerService(pool!);
    final tg = _Telegram(pool!);
    final n = NotificationService(pool!, ledger, tg, _Push(pool!));
    final chat = ChatEntry(pool!, ledger, tg);
    final chatId = 920000000 + DateTime.now().microsecondsSinceEpoch % 99999999;
    final r = await AuthService(pool!).register('dues-${DateTime.now().microsecondsSinceEpoch}-${seq++}@example.test', 'Test-pass-12345', 'ru');
    final id = ((r['user'] as Map)['id']) as String;
    users.add(id);
    Future<void> cmd(Map<String, dynamic> c) => ledger.command(id, {'commandId': 'c${seq++}-${DateTime.now().microsecondsSinceEpoch}', ...c});
    await cmd({'type': 'updateProfile', 'profile': {'onboarded': true}});
    await cmd({'type': 'addMoneyAccount', 'accountId': 'card'});
    await cmd({'type': 'upsertEntity', 'kind': 'account', 'entityId': 'card', 'data': {'name': 'Kaspi Gold', 'type': 'card'}});
    await cmd({'type': 'opening', 'id': 'op', 'date': '2026-09-01', 'account': 'card', 'amount': '${kzt(100000)}'});
    await cmd({'type': 'upsertEntity', 'kind': 'planned', 'entityId': 'net', 'data': {'name': 'Интернет', 'amount': '${kzt(5000)}', 'day': 12, 'category': 'home', 'start': '2026-09-01'}});
    await pool!.execute(Sql.named('UPDATE users SET telegram_chat_id = @c WHERE id = @u'), parameters: {'c': chatId, 'u': id});

    final noon = DateTime(2026, 10, 12, 12, 1);
    await n.runDueReminders('noon', noon);
    var rows = await pool!.execute(Sql.named('SELECT dedup_key, title, tg_buttons FROM notifications WHERE user_id = @u ORDER BY created_at'), parameters: {'u': id});
    expect(rows.length, 1);
    expect(rows.single[0], 'due12:2026-10-12');
    expect(rows.single[1], 'Сегодня платёж: Интернет — 5 000 ₸');
    expect(rows.single[2], isNotNull);
    final sent = tg.last('sendMessage');
    expect('${sent['text']}', contains('Оплатил'));
    final markup = sent['reply_markup'] as Map;
    expect(((markup['inline_keyboard'] as List).single as List).single['callback_data'], 'p:net:2026-10');
    await n.runDueReminders('noon', noon);
    expect((await pool!.execute(Sql.named('SELECT count(*) FROM notifications WHERE user_id = @u'), parameters: {'u': id})).single[0], 1, reason: 'стадия отмечена — второго нет');

    // Нажатие «Оплатил»: платёж записан со счёта, срок отмечен.
    Future<void> press(String data) => chat.onCallback({'id': 'q', 'data': data, 'message': {'message_id': 7, 'chat': {'id': chatId}, 'text': 'Сегодня платёж', 'reply_markup': markup}});
    await press('p:net:2026-10');
    var v = (await ledger.view(id))!;
    expect(v.ledger.liquid(), kzt(95000));
    expect((v.of('planned')['net']!['paid'] as List), ['2026-10']);
    final tx = v.ledger.transactions.where((t) => t.meta['planned'] == 'net').single;
    expect(tx.meta['period'], '2026-10');
    expect(tx.meta['viaBot'], isTrue);
    expect('${tg.last('editMessageText')['text']}', contains('✅ Оплачено: Интернет — 5 000 ₸ · Kaspi Gold'));
    expect('${tg.last('answerCallbackQuery')['text']}', 'Записано');
    await press('p:net:2026-10');
    expect((await ledger.view(id))!.ledger.liquid(), kzt(95000), reason: 'срок уже отмечен — второй записи нет');
    expect('${tg.last('answerCallbackQuery')['text']}', contains('уже отмечен'));

    // Вечер: срок закрыт — напоминания нет, но стадия отмечена.
    await n.runDueReminders('evening', DateTime(2026, 10, 12, 18, 1));
    rows = await pool!.execute(Sql.named('SELECT dedup_key FROM notifications WHERE user_id = @u ORDER BY created_at'), parameters: {'u': id});
    expect([for (final r in rows) r[0]], ['due12:2026-10-12']);
    final notif = (await pool!.execute(Sql.named('SELECT notif FROM users WHERE id = @u'), parameters: {'u': id})).single[0] as Map;
    expect(notif['sentDue18'], '2026-10-12');

    // «Отменить»: запись отменена, срок снова открыт.
    final undoMarkup = (tg.last('editMessageText')['reply_markup'] as Map);
    final undo = ((undoMarkup['inline_keyboard'] as List).last as List).single['callback_data'];
    expect(undo, 'p:net:2026-10:u');
    await press(undo as String);
    v = (await ledger.view(id))!;
    expect(v.ledger.liquid(), kzt(100000));
    expect((v.of('planned')['net']!['paid'] as List), isEmpty);
    expect('${tg.last('editMessageText')['text']}', contains('↩️ Отменено: Интернет'));
    await press(undo);
    expect((await ledger.view(id))!.ledger.liquid(), kzt(100000));
  });

  test('кнопка «Оплатил» у срока личного долга: id `pd:Имя` разбирается, возврат записан, срок отмечен', () async {
    if (skip()) return;
    final ledger = LedgerService(pool!);
    final tg = _Telegram(pool!);
    final chat = ChatEntry(pool!, ledger, tg);
    final chatId = 930000000 + DateTime.now().microsecondsSinceEpoch % 99999999;
    final r = await AuthService(pool!).register('dues-${DateTime.now().microsecondsSinceEpoch}-${seq++}@example.test', 'Test-pass-12345', 'ru');
    final id = ((r['user'] as Map)['id']) as String;
    users.add(id);
    Future<void> cmd(Map<String, dynamic> c) => ledger.command(id, {'commandId': 'c${seq++}-${DateTime.now().microsecondsSinceEpoch}', ...c});
    await cmd({'type': 'updateProfile', 'profile': {'onboarded': true}});
    await cmd({'type': 'addMoneyAccount', 'accountId': 'card'});
    await cmd({'type': 'upsertEntity', 'kind': 'account', 'entityId': 'card', 'data': {'name': 'Kaspi Gold', 'type': 'card'}});
    await cmd({'type': 'opening', 'id': 'op', 'date': '2026-09-01', 'account': 'card', 'amount': '${kzt(100000)}'});
    await cmd({'type': 'borrow', 'id': 'b', 'date': '2026-10-02', 'account': 'card', 'person': 'Maestro', 'amount': '${kzt(63000)}'});
    await cmd({'type': 'upsertEntity', 'kind': 'planned', 'entityId': 'pd:Maestro', 'data': {'name': 'Maestro', 'amount': '${kzt(63000)}', 'day': 1, 'category': 'other', 'person': 'Maestro', 'onDate': '2026-10-12'}});
    await pool!.execute(Sql.named('UPDATE users SET telegram_chat_id = @c WHERE id = @u'), parameters: {'c': chatId, 'u': id});
    Future<void> press(String data) => chat.onCallback({'id': 'q', 'data': data, 'message': {'message_id': 9, 'chat': {'id': chatId}, 'text': 'Сегодня платёж'}});
    await press('p:pd:Maestro:2026-10-12');
    expect('${tg.last('answerCallbackQuery')['text']}', 'Записано');
    final v = (await ledger.view(id))!;
    expect(v.ledger.liquid(), kzt(100000), reason: '163 000 на счёте минус 63 000 возврата');
    expect((v.of('planned')['pd:Maestro']!['paid'] as List), ['2026-10-12']);
    await press('p:pd:Maestro:2026-10-12:u');
    expect((await ledger.view(id))!.ledger.liquid(), kzt(163000));
  });

  test('без сроков сегодня стадия отмечается без уведомления; выключатель payments', () async {
    if (skip()) return;
    final ledger = LedgerService(pool!);
    final n = NotificationService(pool!, ledger, _Telegram(pool!), _Push(pool!));
    final r = await AuthService(pool!).register('dues-${DateTime.now().microsecondsSinceEpoch}-${seq++}@example.test', 'Test-pass-12345', 'ru');
    final id = ((r['user'] as Map)['id']) as String;
    users.add(id);
    Future<void> cmd(Map<String, dynamic> c) => ledger.command(id, {'commandId': 'c${seq++}-${DateTime.now().microsecondsSinceEpoch}', ...c});
    await cmd({'type': 'updateProfile', 'profile': {'onboarded': true}});
    await cmd({'type': 'addMoneyAccount', 'accountId': 'card'});
    // Платёж с 1 октября: срок 20.10 впереди, просрочки нет.
    await cmd({'type': 'upsertEntity', 'kind': 'planned', 'entityId': 'net', 'data': {'name': 'Интернет', 'amount': '${kzt(5000)}', 'day': 20, 'category': 'home', 'start': '2026-10-01'}});
    await n.runDueReminders('noon', DateTime(2026, 10, 12, 12));
    expect((await pool!.execute(Sql.named('SELECT count(*) FROM notifications WHERE user_id = @u'), parameters: {'u': id})).single[0], 0);
    var notif = (await pool!.execute(Sql.named('SELECT notif FROM users WHERE id = @u'), parameters: {'u': id})).single[0] as Map;
    expect(notif['sentDue12'], '2026-10-12');
    await n.updateSettings(id, {'payments': false});
    expect((await n.settings(id))['payments'], isFalse);
    await n.runDueReminders('noon', DateTime(2026, 10, 20, 12));
    notif = (await pool!.execute(Sql.named('SELECT notif FROM users WHERE id = @u'), parameters: {'u': id})).single[0] as Map;
    expect(notif['sentDue12'], '2026-10-12', reason: 'выключено — не трогаем');
  });
}
