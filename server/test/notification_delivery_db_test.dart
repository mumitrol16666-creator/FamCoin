/// Уведомление сначала сохраняется, потом доставляется (аудит 08.10, CS05).
/// Отказные сценарии на настоящей базе: сбой до записи, сбой Telegram после
/// записи, два обработчика и перезапуск. Нужна база (порт `TEST_DB_PORT`, по
/// умолчанию 5433); без неё тесты пропускаются.
library;

import 'dart:io';
import 'dart:async';

import 'package:famcoin_server/auth_service.dart';
import 'package:famcoin_server/ledger_service.dart';
import 'package:famcoin_server/notifications.dart';
import 'package:famcoin_server/telegram.dart';
import 'package:famcoin_server/webpush.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

/// Telegram, который отвечает ошибкой, пока [down], и считает доставленное.
class _Telegram extends Telegram {
  _Telegram(super.db) : super(token: 'test');
  bool down = false;
  final delivered = <String>[];

  @override
  Future<Map<String, dynamic>?> call(String method, Map<String, Object?> body) async {
    if (method != 'sendMessage') return {'ok': true};
    if (down) return null;
    delivered.add('${body['text']}');
    return {'ok': true, 'result': {}};
  }
}

/// Подготовка уведомления падает [failures] раз — до того, как оно записано.
class _Flaky extends NotificationService {
  _Flaky(super.db, super.ledger, super.telegram, super.push);
  int failures = 0;

  @override
  Future<void> sendBrief(String userId, String kind, DateTime today, {String? dedupKey, ({String flag, String value})? mark}) {
    if (failures > 0) {
      failures--;
      throw StateError('сбой до записи');
    }
    return super.sendBrief(userId, kind, today, dedupKey: dedupKey, mark: mark);
  }

  @override
  Future<void> sendMonthNudge(String userId, DateTime month, {int? preparationDays, bool preview = false, String? dedupKey, ({String flag, String value})? mark}) {
    if (failures > 0) {
      failures--;
      throw StateError('сбой до записи');
    }
    return super.sendMonthNudge(userId, month, preparationDays: preparationDays, preview: preview, dedupKey: dedupKey, mark: mark);
  }
}

class _BarrierTelegram extends _Telegram {
  _BarrierTelegram(super.db);
  final started = Completer<void>();
  final release = Completer<void>();
  int calls = 0;
  @override
  Future<Map<String, dynamic>?> call(String method, Map<String, Object?> body) async {
    if (method == 'sendMessage') {
      calls++;
      if (!started.isCompleted) started.complete();
      await release.future;
    }
    return super.call(method, body);
  }
}
class _Push extends WebPush {
  _Push(super.db) : super(subject: 'mailto:test@example.test');
  bool fail = false;
  int calls = 0;
  @override
  Future<bool> sendToUser(String userId, String title, String body, {String tag = 'famcoin', String? url}) async {
    calls++;
    return !fail;
  }
}

void main() {
  Pool? pool;
  final users = <String>[];
  var seq = 0;

  setUpAll(() async {
    final db = Pool.withEndpoints(
      [Endpoint(host: 'localhost', port: int.parse(Platform.environment['TEST_DB_PORT'] ?? '5433'), database: 'famcoin', username: 'famcoin', password: 'famcoin')],
      settings: const PoolSettings(maxConnectionCount: 6, sslMode: SslMode.disable),
    );
    try {
      await db.execute('SELECT deliver_status FROM notifications LIMIT 1').timeout(const Duration(seconds: 3));
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

  final now = DateTime(2026, 9, 2, 10);

  /// Пользователь с учётом в августе и привязанным Telegram.
  Future<String> owner(LedgerService ledger) async {
    final r = await AuthService(pool!).register('delivery-${DateTime.now().microsecondsSinceEpoch}-${seq++}@example.test', 'Test-pass-12345', 'ru');
    final id = ((r['user'] as Map)['id']) as String;
    users.add(id);
    Future<void> cmd(Map<String, dynamic> c) => ledger.command(id, {'commandId': 'c${seq++}-${DateTime.now().microsecondsSinceEpoch}', ...c});
    await cmd({'type': 'updateProfile', 'profile': {'onboarded': true}});
    await cmd({'type': 'addMoneyAccount', 'accountId': 'cash'});
    await cmd({'type': 'opening', 'id': 'op', 'date': '2026-07-01', 'account': 'cash', 'amount': '10000000'});
    await cmd({'type': 'expense', 'id': 'e1', 'date': '2026-08-10', 'account': 'cash', 'splits': {'food': '2000000'}});
    await pool!.execute(Sql.named('UPDATE users SET telegram_chat_id = @c WHERE id = @u'), parameters: {'c': 900000000 + DateTime.now().microsecondsSinceEpoch % 99999999, 'u': id});
    return id;
  }

  Future<List<List<Object?>>> stored(String userId) async => [
        for (final r in await pool!.execute(
          Sql.named('SELECT id, kind, deliver_status, deliver_attempts, tg_done FROM notifications WHERE user_id = @u ORDER BY created_at'),
          parameters: {'u': userId},
        ))
          r.toList(),
      ];

  Future<String?> flag(String userId, String name) async =>
      (await pool!.execute(Sql.named('SELECT notif->>@f FROM users WHERE id = @u'), parameters: {'f': name, 'u': userId})).first[0] as String?;

  for (final kind in ['morning', 'evening', 'month']) {
    test('$kind: сбой до записи уведомления не ставит отметку — следующий проход его записывает, и ровно один раз', () async {
      if (skip()) return;
      final ledger = LedgerService(pool!, clock: () => DateTime.utc(2026, 9, 2));
      final tg = _Telegram(pool!);
      final svc = _Flaky(pool!, ledger, tg, WebPush(pool!, subject: 'mailto:test@example.test'))..failures = 1;
      final id = await owner(ledger);
      final flagName = switch (kind) { 'morning' => 'sentMorning', 'evening' => 'sentEvening', _ => 'sentMonth' };
      Future<void> run() => kind == 'month'
          ? svc.deliverMonthNudge(id, DateTime(2026, 8, 1), '2026-08', 'sentMonth', null)
          : svc.deliverBrief(kind, now, id);

      await run(); // подготовка упала
      expect(await stored(id), isEmpty);
      expect(await flag(id, flagName), isNull, reason: 'раньше отметка ставилась до записи — напоминание терялось');

      await run();
      final rows = await stored(id);
      expect(rows, hasLength(1));
      expect(rows.single[2], 'done');
      expect(await flag(id, flagName), kind == 'month' ? '2026-08' : '2026-09-02');
      expect(tg.delivered, hasLength(1));

      await run(); // повтор (следующая минута, перезапуск)
      expect(await stored(id), hasLength(1));
      expect(tg.delivered, hasLength(1));
    });
  }

  test('сбой Telegram после записи: уведомление есть в приложении, доставка повторяется сама и не дублирует', () async {
    if (skip()) return;
    final ledger = LedgerService(pool!, clock: () => DateTime.utc(2026, 9, 2));
    final tg = _Telegram(pool!)..down = true;
    final svc = NotificationService(pool!, ledger, tg, WebPush(pool!, subject: 'mailto:test@example.test'));
    final id = await owner(ledger);

    await svc.deliverBrief('morning', now, id);
    var rows = await stored(id);
    expect(rows, hasLength(1), reason: 'запись в приложении есть, хотя Telegram недоступен');
    expect([rows.single[2], rows.single[3], rows.single[4]], ['pending', 1, false]);
    expect((await svc.list(id)), hasLength(1));
    expect(await flag(id, 'sentMorning'), '2026-09-02', reason: 'сводка подготовлена — заново не строится');

    // Прямой повтор уважает паузу: до срока новая попытка не расходуется.
    await svc.deliver(rows.single[0].toString());
    expect((await stored(id)).single[3], 1);
    tg.down = false;
    await pool!.execute(Sql.named('UPDATE notifications SET deliver_next_at = now() WHERE user_id = @u'), parameters: {'u': id});
    expect(await svc.retryDeliveries(), greaterThanOrEqualTo(1));
    rows = await stored(id);
    expect([rows.single[2], rows.single[4]], ['done', true]);
    expect(tg.delivered, hasLength(1));
    await svc.deliver(rows.single[0].toString());
    expect(tg.delivered, hasLength(1), reason: 'доставленное не отправляется второй раз');
  });

  test('два обработчика и перезапуск: одна запись, доставка после перезапуска — один раз', () async {
    if (skip()) return;
    final ledger = LedgerService(pool!, clock: () => DateTime.utc(2026, 9, 2));
    final tgA = _Telegram(pool!)..down = true;
    final tgB = _Telegram(pool!)..down = true;
    final a = NotificationService(pool!, ledger, tgA, WebPush(pool!, subject: 'mailto:test@example.test'));
    final b = NotificationService(pool!, ledger, tgB, WebPush(pool!, subject: 'mailto:test@example.test'));
    final id = await owner(ledger);

    await Future.wait([a.deliverBrief('evening', now, id), b.deliverBrief('evening', now, id)]);
    final rows = await stored(id);
    expect(rows, hasLength(1), reason: 'ключ «вид:день» не даёт второй записи');
    expect(rows.single[2], 'pending');

    // Перезапуск: новый процесс с работающим Telegram добирает недоставленное.
    final tgC = _Telegram(pool!);
    final c = NotificationService(pool!, ledger, tgC, WebPush(pool!, subject: 'mailto:test@example.test'));
    await pool!.execute(Sql.named('UPDATE notifications SET deliver_next_at = now() WHERE user_id = @u'), parameters: {'u': id});
    await c.retryDeliveries();
    await c.retryDeliveries();
    expect(tgC.delivered, hasLength(1));
    expect((await stored(id)).single[2], 'done');
    expect(tgA.delivered.length + tgB.delivered.length, 0);
  });
  test('FV-S01: direct notify and two retry workers claim one delivery', () async {
    if (skip()) return;
    final ledger = LedgerService(pool!);
    final id = await owner(ledger);
    final tg = _BarrierTelegram(pool!);
    final push = _Push(pool!);
    final service = NotificationService(pool!, ledger, tg, push);
    final direct = service.notify(id, 'system', 'race', 'body');
    await tg.started.future.timeout(const Duration(seconds: 5));
    try {
      await Future.wait([service.retryDeliveries(), service.retryDeliveries()]);
      expect(tg.calls, 1);
      expect(push.calls, 0);
    } finally { tg.release.complete(); await direct; }
    expect(push.calls, 1);
    expect((await stored(id)).single[2], 'done');
  });

  test('FV-S01: Telegram completion survives push failure; expired lease is recoverable', () async {
    if (skip()) return;
    final ledger = LedgerService(pool!);
    final id = await owner(ledger);
    final tg = _Telegram(pool!);
    final push = _Push(pool!)..fail = true;
    final service = NotificationService(pool!, ledger, tg, push);
    await service.notify(id, 'system', 'channels', 'body');
    expect(tg.delivered, hasLength(1));
    final saved = await pool!.execute(Sql.named('SELECT tg_done, push_done FROM notifications WHERE user_id=@u'), parameters: {'u': id});
    expect(saved.single.toList(), [true, false]);
    await pool!.execute(Sql.named("UPDATE notifications SET deliver_next_at=now(), deliver_token=gen_random_uuid(), deliver_lease_until=now()+interval '1 minute' WHERE user_id=@u"), parameters: {'u': id});
    await service.retryDeliveries();
    expect(push.calls, 1, reason: 'active lease is not stolen');
    await pool!.execute(Sql.named("UPDATE notifications SET deliver_lease_until=now()-interval '1 second' WHERE user_id=@u"), parameters: {'u': id});
    push.fail = false;
    await Future.wait([service.retryDeliveries(), service.retryDeliveries()]);
    expect(tg.delivered, hasLength(1));
    expect(push.calls, 2);
    expect((await stored(id)).single[2], 'done');
  });

}
