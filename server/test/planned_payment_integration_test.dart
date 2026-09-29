import 'dart:io';

import 'package:famcoin_server/auth_service.dart';
import 'package:famcoin_server/ledger_service.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

/// Opt-in, disposable database only. CI supplies a fresh PostgreSQL service;
/// no production URL, token or credential is read by this test.
void main() {
  final enabled = Platform.environment['FAMCOIN_INTEGRATION'] == '1';
  group('atomic planned payment', () {
    late Pool db;
    late String user;
    late LedgerService service;

    setUpAll(() async {
      db = Pool.withEndpoints([
        Endpoint(host: '127.0.0.1', port: 5432, database: 'famcoin_test',
            username: 'postgres', password: 'test-only'),
      ], settings: const PoolSettings(maxConnectionCount: 4, sslMode: SslMode.disable));
      final files = Directory('migrations').listSync().whereType<File>()
          .where((f) => f.path.endsWith('.sql')).toList()..sort((a, b) => a.path.compareTo(b.path));
      for (final file in files) {
        await db.execute(file.readAsStringSync(), queryMode: QueryMode.simple);
      }
    });
    tearDownAll(() async { await db.close(); });
    setUp(() async {
      final result = await db.execute("INSERT INTO users (email, password_hash) VALUES (gen_random_uuid()::text || '@test.invalid', 'not-a-login') RETURNING id::text");
      user = result.single[0] as String;
      service = LedgerService(db);
      await service.command(user, {'commandId': 'setup', 'type': 'batch', 'commands': [
        {'type': 'addMoneyAccount', 'accountId': 'cash'},
        {'type': 'opening', 'id': 'opening', 'date': '2026-08-01', 'account': 'cash', 'amount': '10000000'},
        {'type': 'upsertEntity', 'kind': 'planned', 'entityId': 'rent', 'data': {
          'name': 'Rent', 'category': 'home', 'amount': '1000000', 'day': 10,
          'paid': [], 'start': '2026-08-01',
        }},
      ]});
    });
    tearDown(() async {
      // Fixture cleanup is explicit: the schema does not cascade from
      // ledger_accounts into postings/reservations. Only this test user in
      // the opt-in disposable database is touched; never change constraints.
      await db.runTx((s) async {
        await s.execute(Sql.named('DELETE FROM reservations WHERE user_id = @u'), parameters: {'u': user});
        await s.execute(Sql.named('DELETE FROM postings WHERE user_id = @u'), parameters: {'u': user});
        await s.execute(Sql.named('DELETE FROM transactions WHERE user_id = @u'), parameters: {'u': user});
        await s.execute(Sql.named('DELETE FROM users WHERE id = @u'), parameters: {'u': user});
      });
      service.forget(user);
    });
    Map<String, dynamic> payment(String period, String id) => {
      'type': 'payPlannedPeriod', 'commandId': 'command-$id', 'id': id,
      'plannedId': 'rent', 'period': period, 'date': '$period-10',
      'account': 'cash', 'amount': '1000000', 'interest': '0', 'expectedDebtId': null,
    };
    Future<Set<String>> paid() async {
      final result = await db.execute(Sql.named("SELECT data FROM entities WHERE user_id = @u AND kind = 'planned' AND id = 'rent'"), parameters: {'u': user});
      return ((result.single[0] as Map)['paid'] as List).cast<String>().toSet();
    }
    test('two clients paying different periods preserve both flags', () async {
      final otherClient = LedgerService(db);
      await Future.wait([
        service.command(user, payment('2026-08', 'aug')),
        otherClient.command(user, payment('2026-09', 'sep')),
      ]);
      expect(await paid(), {'2026-08', '2026-09'});
      final rows = await db.execute(Sql.named("SELECT count(*) FROM transactions WHERE user_id = @u AND type = 'expense'"), parameters: {'u': user});
      expect(rows.single[0], 2);
    });
    test('same period is paid at most once even with different command IDs', () async {
      await service.command(user, payment('2026-08', 'one'));
      await expectLater(service.command(user, payment('2026-08', 'two')), throwsA(isA<ApiError>()));
      expect(await paid(), {'2026-08'});
      final rows = await db.execute(Sql.named("SELECT count(*) FROM transactions WHERE user_id = @u AND type = 'expense'"), parameters: {'u': user});
      expect(rows.single[0], 1);
    });
    test('same command ID is idempotent and a failed payment rolls back the flag', () async {
      final command = payment('2026-08', 'one');
      await service.command(user, command);
      expect((await service.command(user, command)).repeated, isTrue);
      await expectLater(service.command(user, {...payment('2026-09', 'bad'), 'account': 'missing'}), throwsA(isA<ApiError>()));
      expect(await paid(), {'2026-08'});
    });
  }, skip: enabled ? false : 'Set FAMCOIN_INTEGRATION=1 with a disposable local famcoin_test database');
}
