import 'dart:io';

import 'package:famcoin_server/auth_service.dart';
import 'package:famcoin_server/ledger_service.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

void main() {
  test(
      'сохранение, граница UTC+5, защита от гонки и повторная сверка на PostgreSQL',
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
    final auth = AuthService(db);
    var now = DateTime.utc(2026, 9, 30, 18, 59); // 23:59 в Казахстане
    final service = LedgerService(db, clock: () => now);
    final user = await auth.register(
        'reconcile-${DateTime.now().microsecondsSinceEpoch}@example.test',
        'Test-pass-12345',
        'ru');
    final id = (user['user'] as Map)['id'] as String;
    var n = 0;
    Future<void> cmd(Map<String, dynamic> c) async {
      await service.command(id, {'commandId': 'c${n++}', ...c});
    }

    Future<void> close(String month, {int? revision}) async {
      final state = await service.state(id);
      await cmd({
        'type': 'closeMonth',
        'month': month,
        'expectedRevision': revision ?? state['revision']
      });
    }

    Future<Map> row(String month) async {
      final state = await service.state(id);
      return (state['monthReconciliations'] as List)
          .cast<Map>()
          .singleWhere((r) => r['month'] == month);
    }

    Matcher error(String code) =>
        isA<ApiError>().having((e) => e.ledgerCode, 'ledgerCode', code);
    try {
      await cmd({'type': 'addMoneyAccount', 'accountId': 'cash'});
      await cmd({
        'type': 'opening',
        'id': 'opening',
        'date': '2026-09-01',
        'account': 'cash',
        'amount': '10000000'
      });
      await expectLater(close('2026-09-01'), throwsA(error('monthNotEnded')));
      await expectLater(
          cmd({
            'type': 'updateProfile',
            'profile': {
              'closedMonths': ['2026-09']
            }
          }),
          throwsA(error('monthNotEnded')));
      await expectLater(close('2026-10-01'), throwsA(error('monthNotEnded')));
      now = DateTime.utc(2026, 9, 30, 19); // 00:00 первого октября
      await cmd({
        'type': 'expense',
        'id': 'coffee',
        'date': '2026-10-01',
        'account': 'cash',
        'splits': {'cafe': '100000'}
      });
      final revision = (await service.state(id))['revision'] as int;
      await close('2026-09-01');
      expect((await row('2026-09-01'))['snapshot']['balances']['cash'],
          '10000000');
      // Повтор того же запроса после потери ответа не создаёт новый снимок.
      final repeated = await service.command(id, {
        'commandId': 'c${n - 1}',
        'type': 'closeMonth',
        'month': '2026-09-01',
        'expectedRevision': revision
      });
      expect(repeated.repeated, isTrue);
      final otherDevice = LedgerService(db, clock: () => now);
      await otherDevice.command(id, {
        'commandId': 'other-device',
        'type': 'expense',
        'id': 'later-coffee',
        'date': '2026-10-02',
        'account': 'cash',
        'splits': {'cafe': '20000'}
      });
      expect((await row('2026-09-01'))['invalidatedAt'], isNull);
      await expectLater(close('2026-09-01', revision: revision),
          throwsA(error('monthChanged')));
      now = DateTime.utc(2026, 11, 1);
      await close('2026-10-01');
      // Правка сентября меняет также октябрьский остаток.
      await cmd({
        'type': 'expense',
        'id': 'late-september',
        'date': '2026-09-30',
        'account': 'cash',
        'splits': {'food': '50000'}
      });
      expect((await row('2026-09-01'))['invalidatedAt'], isNotNull);
      expect((await row('2026-10-01'))['invalidatedAt'], isNotNull);
      expect(
          (await row('2026-09-01'))['snapshot']['balances']['cash'], '10000000',
          reason: 'старый снимок сохраняется до повторного подтверждения');
      await close('2026-09-01');
      expect((await row('2026-09-01'))['invalidatedAt'], isNull);
      expect(
          (await row('2026-09-01'))['snapshot']['balances']['cash'], '9950000');
      await cmd({
        'type': 'reverse',
        'id': 'undo-september',
        'txId': 'late-september'
      });
      expect((await row('2026-09-01'))['invalidatedAt'], isNotNull);
      // Старый экран сверял текущие суммы: его отметка не подтверждает снимок.
      await expectLater(cmd({'type': 'updateProfile', 'profile': {'closedMonths': ['2026-09']}}), throwsA(error('monthClientUpdate')));
      expect((await row('2026-09-01'))['invalidatedAt'], isNotNull);
      await close('2026-09-01');
      expect((await row('2026-09-01'))['snapshot']['balances']['cash'], '10000000');
      await cmd({'type': 'archiveAccount', 'accountId': 'cash'});
      await expectLater(cmd({'type': 'adjustment', 'id': 'bad-archive-adjust', 'account': 'cash', 'date': '2026-11-01', 'delta': '100', 'reason': 'Проверка', 'allowArchived': true}), throwsA(error('monthNotEnded')));
      await cmd({'type': 'adjustment', 'id': 'archive-adjust', 'account': 'cash', 'date': '2026-09-30', 'delta': '100', 'reason': 'Выписка', 'allowArchived': true});
      expect((await service.state(id))['accounts'], contains(isA<Map>().having((a) => a['id'], 'id', 'cash').having((a) => a['archived'], 'archived', true)));
      expect((await row('2026-09-01'))['invalidatedAt'], isNotNull);
      await resetUserData(db, id);
      service.forget(id);
      expect((await service.state(id))['monthReconciliations'], isEmpty);
    } finally {
      await deleteUserData(db, id);
      await db.close();
    }
  });
}
