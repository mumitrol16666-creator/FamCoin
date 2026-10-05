import 'dart:io';

import 'package:famcoin_core/famcoin_core.dart';
import 'package:famcoin_server/auth_service.dart';
import 'package:famcoin_server/ledger_service.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

void main() {
  test(
      'старый снимок с займом: чтение не снимает сверку, реальная правка снимает, повторная сверка сохраняет v2',
      () async {
    final db = Pool.withEndpoints([
      Endpoint(
          host: 'localhost',
          port: int.parse(Platform.environment['TEST_DB_PORT'] ?? '5433'),
          database: 'famcoin',
          username: 'famcoin',
          password: 'famcoin')
    ], settings: const PoolSettings(sslMode: SslMode.disable));
    try {
      await db
          .execute('SELECT 1 FROM month_reconciliations LIMIT 1')
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      await db.close();
      if (Platform.environment['TEST_DB_REQUIRED'] == '1')
        fail('База недоступна');
      markTestSkipped('локальная база не запущена');
      return;
    }
    final user = await AuthService(db).register(
        'debt-help-${DateTime.now().microsecondsSinceEpoch}@example.test',
        'Test-pass-12345',
        'ru');
    final id = (user['user'] as Map)['id'] as String;
    final service = LedgerService(db, clock: () => DateTime.utc(2026, 10, 2));
    var n = 0;
    Future<void> command(Map<String, dynamic> c) async =>
        service.command(id, {'commandId': 'c${n++}', ...c});
    Future<Map> record() async =>
        ((await service.state(id))['monthReconciliations'] as List).single
            as Map;
    Future<void> close() async => command({
          'type': 'closeMonth',
          'month': '2026-09-01',
          'expectedRevision': (await service.state(id))['revision']
        });
    try {
      await command({'type': 'addMoneyAccount', 'accountId': 'cash'});
      await command({
        'type': 'opening',
        'id': 'o',
        'date': '2026-09-01',
        'account': 'cash',
        'amount': '10000000'
      });
      await command({
        'type': 'borrow',
        'id': 'b',
        'date': '2026-09-02',
        'account': 'cash',
        'person': 'Друг',
        'amount': '5000000'
      });
      await command({
        'type': 'repaymentMade',
        'id': 'r',
        'date': '2026-09-03',
        'account': 'cash',
        'person': 'Друг',
        'principal': '1000000'
      });
      await close();
      final old = reconciliationSnapshot(
          (await service.view(id))!.ledger, DateTime(2026, 9),
          version: 1);
      expect(old['income'], '5000000');
      expect(old['expense'], '1000000');
      await db.execute(
          Sql.named(
              'UPDATE month_reconciliations SET snapshot = @snapshot, invalidated_at = now() WHERE user_id = @u'),
          parameters: {'snapshot': old, 'u': id});
      expect((await record())['invalidatedAt'], isNull,
          reason: 'обновление правил не меняет подтверждённые суммы');
      await command({
        'type': 'expense',
        'id': 'late',
        'date': '2026-09-30',
        'account': 'cash',
        'splits': {'cafe': '100000'}
      });
      expect((await record())['invalidatedAt'], isNotNull);
      await command({'type': 'reverse', 'id': 'undo', 'txId': 'late'});
      expect((await record())['invalidatedAt'], isNull);
      await close();
      final fresh = await record();
      expect(fresh['snapshot']['version'], 2);
      expect(fresh['snapshot']['income'], '0');
      expect(fresh['snapshot']['expense'], '0');
      expect(fresh['snapshot']['balances']['cash'], '14000000');
    } finally {
      await db.execute(Sql.named('DELETE FROM postings WHERE user_id = @u'), parameters: {'u': id});
      await db.execute(Sql.named('DELETE FROM users WHERE id = @u'),
          parameters: {'u': id});
      await db.close();
    }
  });
}
