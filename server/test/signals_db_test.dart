/// D167, часть 2, с базой: сигнал записывается и уходит один раз на ключ,
/// хук команды вызывает проверку в фоне, выключатель «signals» глушит.
library;

import 'dart:async';
import 'dart:io';

import 'package:famcoin_core/famcoin_core.dart';
import 'package:famcoin_server/auth_service.dart';
import 'package:famcoin_server/ledger_service.dart';
import 'package:famcoin_server/notifications.dart';
import 'package:famcoin_server/telegram.dart';
import 'package:famcoin_server/webpush.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

class _Telegram extends Telegram {
  _Telegram(super.db) : super(token: 'test');
  final delivered = <String>[];
  @override
  Future<Map<String, dynamic>?> call(String method, Map<String, Object?> body) async {
    if (method == 'sendMessage') delivered.add('${body['text']}');
    return {'ok': true, 'result': {}};
  }
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

  Future<String> owner(LedgerService ledger) async {
    final r = await AuthService(pool!).register('signals-${DateTime.now().microsecondsSinceEpoch}-${seq++}@example.test', 'Test-pass-12345', 'ru');
    final id = ((r['user'] as Map)['id']) as String;
    users.add(id);
    Future<void> cmd(Map<String, dynamic> c) => ledger.command(id, {'commandId': 'c${seq++}-${DateTime.now().microsecondsSinceEpoch}', ...c});
    await cmd({'type': 'updateProfile', 'profile': {'onboarded': true, 'dailyLimit': '${kzt(5000)}'}});
    await cmd({'type': 'addMoneyAccount', 'accountId': 'cash'});
    await cmd({'type': 'opening', 'id': 'op', 'date': '2026-09-01', 'account': 'cash', 'amount': '${kzt(100000)}'});
    await cmd({'type': 'upsertEntity', 'kind': 'limit', 'entityId': 'lim-cafe', 'data': {'category': 'cafe', 'amount': '${kzt(10000)}'}});
    await pool!.execute(Sql.named('UPDATE users SET telegram_chat_id = @c WHERE id = @u'), parameters: {'c': 910000000 + DateTime.now().microsecondsSinceEpoch % 99999999, 'u': id});
    return id;
  }

  test('сигнал уходит один раз на ключ: 80 %, затем превышение; выключатель глушит', () async {
    if (skip()) return;
    final ledger = LedgerService(pool!);
    final tg = _Telegram(pool!);
    final n = NotificationService(pool!, ledger, tg, _Push(pool!));
    final id = await owner(ledger);
    final today = DateTime(2026, 10, 12, 14);
    Future<void> spend(String txId, int amount) => ledger.command(id, {'commandId': 'x-$txId', 'type': 'expense', 'id': txId, 'date': '2026-10-12', 'account': 'cash', 'splits': {'cafe': '${kzt(amount)}'}});
    const expense = {'type': 'expense'};

    await spend('a', 8500);
    expect(await n.checkSignals(id, expense, now: today), 2, reason: 'лимит «Кафе» на 85 % и дневной лимит 5 000 исчерпан');
    expect(await n.checkSignals(id, expense, now: today), 0, reason: 'те же ключи — повтора нет');
    expect(tg.delivered.first, contains('Лимит «Кафе»: 85 %'));
    expect(tg.delivered.last, contains('Дневной лимит исчерпан'));

    await spend('b', 2000);
    expect(await n.checkSignals(id, expense, now: today), 1, reason: 'превышение — новый ключ');
    expect(tg.delivered.last, contains('Лимит «Кафе» превышен'));
    expect(await n.checkSignals(id, {'type': 'transfer'}, now: today), 0, reason: 'не расход — не считаем');

    await n.updateSettings(id, {'signals': false});
    await spend('c', 4000); // дневной лимит исчерпан, но сигналы выключены
    expect(await n.checkSignals(id, expense, now: today), 0);
    expect((await n.settings(id))['signals'], isFalse);

    final rows = await pool!.execute(Sql.named("SELECT kind, dedup_key FROM notifications WHERE user_id = @u ORDER BY created_at"), parameters: {'u': id});
    expect([for (final r in rows) r[1]], ['limit80:cafe:2026-10', 'daily:2026-10-12', 'limit100:cafe:2026-10']);
    expect(rows.every((r) => r[0] == 'system'), isTrue);
  });

  test('хук команды вызывает проверку после записи расхода, не блокируя ответ', () async {
    if (skip()) return;
    final ledger = LedgerService(pool!);
    final called = Completer<Map<String, dynamic>>();
    ledger.onApplied = (userId, cmd) {
      if (!called.isCompleted) called.complete(cmd);
    };
    final id = await owner(ledger); // команды подготовки тоже проходят через хук
    expect((await called.future)['type'], 'updateProfile');
    final after = Completer<Map<String, dynamic>>();
    ledger.onApplied = (userId, cmd) => after.complete(cmd);
    await ledger.command(id, {'commandId': 'h1', 'type': 'expense', 'id': 'h', 'date': '2026-10-12', 'account': 'cash', 'splits': {'cafe': '${kzt(100)}'}});
    expect((await after.future)['type'], 'expense');
    // Повтор той же команды хук не вызывает.
    var again = false;
    ledger.onApplied = (_, __) => again = true;
    await ledger.command(id, {'commandId': 'h1', 'type': 'expense', 'id': 'h', 'date': '2026-10-12', 'account': 'cash', 'splits': {'cafe': '${kzt(100)}'}});
    expect(again, isFalse);
  });
}
