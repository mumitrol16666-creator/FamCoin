// Read-only product audit probes. These assertions document the CURRENT
// behavior, including defects; turn them into correct-behavior regressions
// when implementing fixes. No real Telegram network calls are made.
import 'dart:async';
import 'dart:io';

import 'package:famcoin_core/famcoin_core.dart';
import 'package:famcoin_server/auth_service.dart';
import 'package:famcoin_server/export.dart';
import 'package:famcoin_server/ledger_service.dart';
import 'package:famcoin_server/statement.dart';
import 'package:famcoin_server/statement_plan.dart';
import 'package:famcoin_server/telegram.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

class _StopPolling implements Exception {}

class _PaymentPollingProbe extends Telegram {
  _PaymentPollingProbe(super.db) : super(token: 'synthetic-test-token');
  final offsets = <int>[];

  @override
  Future<Map<String, dynamic>?> call(String method, Map<String, Object?> body) async {
    if (method != 'getUpdates') fail('Unexpected Telegram method: $method');
    offsets.add(body['offset'] as int);
    if (offsets.length > 1) throw _StopPolling();
    return {
      'result': [
        {
          'update_id': 100,
          'message': {
            'chat': {'id': 42, 'type': 'private'},
            'from': {'id': 42},
            'successful_payment': {
              'currency': 'XTR',
              'total_amount': 950,
              'telegram_payment_charge_id': 'synthetic-charge',
            },
          },
        },
      ],
    };
  }
}

Ledger _memoryLedger() {
  final l = Ledger()..addMoneyAccount('kaspi');
  applyLedgerCommand(l, {'type': 'opening', 'id': 'opening', 'date': '2026-09-01', 'account': 'kaspi', 'amount': '${kzt(100000)}'});
  return l;
}

BankStatement _groceryStatement() => BankStatement(
  rows: [StatementRow(DateTime(2026, 9, 12), -kzt(5000), RowKind.purchase, 'Покупка', 'MAGNUM')],
  from: DateTime(2026, 9, 1), to: DateTime(2026, 9, 30),
  opening: kzt(100000), closing: kzt(95000),
);

LedgerView _withDue(Ledger l, {bool loan = false}) => LedgerView(
  ledger: l, profile: const {}, locale: 'ru',
  entities: {
    'account': {'kaspi': {'name': 'Kaspi Gold', 'type': 'card'}},
    'planned': {'utilities': {
      'name': loan ? 'Рассрочка' : 'Коммунальные услуги', 'amount': '${kzt(5000)}',
      'day': 15, 'category': 'utilities', 'start': '2026-09-01', 'paid': <String>[],
      if (loan) 'debtId': 'bank',
    }},
    if (loan) 'debt': {'bank': {'name': 'Рассрочка'}},
  },
);

void main() {
  test('S-IMPORT: unrelated MAGNUM purchase auto-pays utility due by amount/date alone', () {
    final l = _memoryLedger();
    final v = _withDue(l);
    final plan = planImport(_groceryStatement(), v, 'kaspi', 'aaaaaaaaaaaa', DateTime(2026, 10, 5));
    final op = plan.ops.single;
    expect(op.group, PlanGroup.planned);
    expect(op.command['splits'], {'utilities': '${kzt(5000)}'});
    expect((op.command['meta'] as Map)['note'], 'Коммунальные услуги');
    expect(op.mark, (kind: 'planned', id: 'utilities', period: '2026-09'));
    final mark = markCommand(op.mark!, v, {});
    expect((mark['data'] as Map)['paid'], ['2026-09']);
    print('S-IMPORT ordinary: MAGNUM 5000 => utilities 5000, paid=2026-09');
  });

  test('S-IMPORT: unrelated MAGNUM purchase is skipped as a loan payment', () {
    final l = _memoryLedger();
    applyLedgerCommand(l, {'type': 'openingDebt', 'id': 'loan-open', 'date': '2026-09-01', 'debtId': 'bank', 'amount': '${kzt(50000)}'});
    final plan = planImport(_groceryStatement(), _withDue(l, loan: true), 'kaspi', 'aaaaaaaaaaaa', DateTime(2026, 10, 5));
    expect(plan.ops, isEmpty);
    expect(plan.loans.single.name, 'Рассрочка');
    expect(plan.balanceAtEnd, kzt(100000));
    expect(plan.gap, isNull);
    print('S-IMPORT loan: MAGNUM 5000 omitted, ledger 100000 vs bank 95000, gap suppressed');
  });

  test('S-CSV: transfer export loses transferred amount and target account', () {
    final l = _memoryLedger()..addMoneyAccount('cash');
    applyLedgerCommand(l, {'type': 'transfer', 'id': 'move-1', 'date': '2026-09-12', 'from': 'kaspi', 'to': 'cash', 'amount': '${kzt(15000)}'});
    final csv = csvJournal({
      'accounts': [for (final a in l.accounts) accountToJson(a)],
      'transactions': [transactionToJson(l.byId('move-1')!)],
    }, headers: ['Date', 'Time', 'Type', 'Category', 'Account', 'Amount', 'Note', 'Who', 'Status', 'ID'], names: {'kaspi': 'Kaspi Gold', 'cash': 'Наличные'});
    final line = csv.split('\n')[1];
    expect(line, contains(';Kaspi Gold;0;'));
    expect(line, isNot(contains('15000')));
    expect(line, isNot(contains('Наличные')));
    print('S-CSV: $line');
  });

  test('S-TG: successful_payment offset advances despite failed handler', () async {
    // No connection is ever acquired. This pool exists only for the type.
    final unused = Pool.withEndpoints([Endpoint(host: '127.0.0.1', port: 1, database: 'unused')]);
    addTearDown(unused.close);
    final bot = _PaymentPollingProbe(unused);
    var attempts = 0;
    bot.onPayment = (_, __, ___) async { attempts++; throw StateError('Synthetic DB outage before recording payment'); };
    await expectLater(bot.pollForever(), throwsA(isA<_StopPolling>()));
    expect(attempts, 1);
    expect(bot.offsets, [0, 101]);
    print('S-TG: handler failed; next getUpdates offset=101 acknowledges update_id=100');
  });

  group('PostgreSQL atomicity probes', () {
    late Pool db;
    late LedgerService service;
    late String userId;
    var seq = 0;

    setUpAll(() async {
      db = Pool.withEndpoints([
        Endpoint(host: '127.0.0.1', port: int.parse(Platform.environment['TEST_DB_PORT'] ?? '55442'), database: 'famcoin', username: 'famcoin', password: 'famcoin'),
      ], settings: const PoolSettings(maxConnectionCount: 8, sslMode: SslMode.disable));
      await db.execute('SELECT 1 FROM commands LIMIT 1');
    });
    tearDownAll(() => db.close());
    setUp(() async {
      final rows = await db.execute(Sql.named("INSERT INTO users (email, password_hash, locale, plan) VALUES (@e, 'test-only', 'ru', 'pro') RETURNING id"), parameters: {'e': 'audit-server-${DateTime.now().microsecondsSinceEpoch}-${seq++}@example.invalid'});
      userId = rows.single[0].toString();
      service = LedgerService(db);
      await service.command(userId, {'commandId': 'setup', 'type': 'batch', 'commands': [
        {'type': 'addMoneyAccount', 'accountId': 'kaspi'},
        {'type': 'opening', 'id': 'opening', 'date': '2026-09-01', 'account': 'kaspi', 'amount': '${kzt(100000)}'},
        {'type': 'upsertEntity', 'kind': 'account', 'entityId': 'kaspi', 'data': {'name': 'Kaspi Gold', 'type': 'card'}},
      ]});
    });
    tearDown(() => deleteUserData(db, userId));

    test('S-CACHE: view sees in-flight expense that is later rolled back', () async {
      final lockReady = Completer<void>();
      final release = Completer<void>();
      final lock = db.runTx((s) async {
        await s.execute(Sql.named("SELECT id FROM entities WHERE user_id=@u AND kind='account' AND id='kaspi' FOR UPDATE"), parameters: {'u': userId});
        lockReady.complete();
        await release.future;
      });
      await lockReady.future;
      Object? failure;
      final mutation = service.command(userId, {'commandId': 'rollback-probe', 'type': 'batch', 'commands': [
        {'type': 'expense', 'id': 'not-committed', 'date': '2026-09-12', 'account': 'kaspi', 'splits': {'food': '${kzt(5000)}'}},
        {'type': 'upsertEntity', 'kind': 'account', 'entityId': 'kaspi', 'data': {'name': 'blocked write'}},
        {'type': 'unknown-command-for-rollback'},
      ]}).then<void>((_) {}, onError: (Object e) { failure = e; });
      try {
        // Wait for a real PostgreSQL row-lock wait, not a timing assumption.
        var blocked = false;
        for (var i = 0; i < 100; i++) {
          final rows = await db.execute("SELECT count(*) FROM pg_stat_activity WHERE datname=current_database() AND wait_event_type='Lock' AND query LIKE '%INSERT INTO entities%' AND query NOT LIKE '%pg_stat_activity%'");
          if ((rows.single[0] as int) > 0) { blocked = true; break; }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(blocked, isTrue, reason: 'writer must be blocked after mutating the cached ledger');
        final read = (await service.view(userId))!;
        final inDb = await db.execute(Sql.named("SELECT count(*) FROM transactions WHERE user_id=@u AND id='not-committed'"), parameters: {'u': userId});
        expect(inDb.single[0], 0);
        expect(read.ledger.balance('kaspi'), kzt(95000));
        expect(read.ledger.byId('not-committed'), isNotNull);
        print('S-CACHE during transaction: view balance=95000, PostgreSQL transaction count=0');
      } finally {
        release.complete();
        await lock;
        await mutation;
      }
      expect(failure, isA<ApiError>());
      final after = (await service.view(userId))!;
      expect(after.ledger.balance('kaspi'), kzt(100000));
      expect(after.ledger.byId('not-committed'), isNull);
      print('S-CACHE after rollback: view balance=100000, rejected expense absent');
    });

    test('control: failed batch rolls back journal, entities and command id', () async {
      await expectLater(service.command(userId, {'commandId': 'failed-batch', 'type': 'batch', 'commands': [
        {'type': 'expense', 'id': 'rolled-back', 'date': '2026-09-12', 'account': 'kaspi', 'splits': {'food': '${kzt(5000)}'}},
        {'type': 'upsertEntity', 'kind': 'account', 'entityId': 'kaspi', 'data': {'name': 'should roll back'}},
        {'type': 'not-a-command'},
      ]}), throwsA(isA<ApiError>()));
      final state = await service.state(userId);
      final v = (await service.view(userId))!;
      expect(v.ledger.balance('kaspi'), kzt(100000));
      expect(v.of('account')['kaspi']?['name'], 'Kaspi Gold');
      expect(state['revision'], 1);
      final rows = await db.execute(Sql.named("SELECT count(*) FROM commands WHERE user_id=@u AND id='failed-batch'"), parameters: {'u': userId});
      expect(rows.single[0], 0);
    });

    test('S-CACHE: a previously returned view changes after a later command', () async {
      final before = (await service.view(userId))!;
      expect(before.ledger.balance('kaspi'), kzt(100000));
      await service.command(userId, {'commandId': 'later', 'type': 'expense', 'id': 'later', 'date': '2026-09-12', 'account': 'kaspi', 'splits': {'food': '${kzt(5000)}'}});
      expect(before.ledger.balance('kaspi'), kzt(95000));
      print('S-CACHE escaped snapshot: previously returned view balance changed from100000 to95000');
    });

    test('control: concurrent same command id applies once', () async {
      final command = <String, dynamic>{'commandId': 'duplicate', 'type': 'expense', 'id': 'once', 'date': '2026-09-12', 'account': 'kaspi', 'splits': {'food': '${kzt(5000)}'}};
      final results = await Future.wait(List.generate(8, (_) => service.command(userId, command)));
      expect(results.where((r) => !r.repeated).length, 1);
      expect((await service.view(userId))!.ledger.balance('kaspi'), kzt(95000));
      expect((await service.state(userId))['revision'], 2);
    });

    for (final erase in ['reset', 'delete']) {
      test('S-ERASE: $erase races with command and fails foreign key validation', () async {
        final lockReady = Completer<void>();
        final release = Completer<void>();
        final rowLock = db.runTx((s) async {
          await s.execute(Sql.named("SELECT id FROM transactions WHERE user_id=@u AND id='opening' FOR UPDATE"), parameters: {'u': userId});
          lockReady.complete();
          await release.future;
        });
        await lockReady.future;
        Object? error;
        final erasing = (erase == 'reset' ? resetUserData(db, userId) : deleteUserData(db, userId))
          .then<void>((_) {}, onError: (Object e) { error = e; });
        try {
          var blocked = false;
          for (var i = 0; i < 100; i++) {
            final rows = await db.execute("SELECT count(*) FROM pg_stat_activity WHERE datname=current_database() AND wait_event_type='Lock' AND query LIKE '%DELETE FROM transactions%' AND query NOT LIKE '%pg_stat_activity%'");
            if ((rows.single[0] as int) > 0) { blocked = true; break; }
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          expect(blocked, isTrue);
          await service.command(userId, {'commandId': 'while-erasing', 'type': 'expense', 'id': 'while-erasing', 'date': '2026-09-12', 'account': 'kaspi', 'splits': {'food': '${kzt(5000)}'}});
        } finally {
          release.complete();
          await rowLock;
          await erasing;
        }
        expect(error, isA<ServerException>());
        expect((error as ServerException).code, '23503');
        final after = (await service.view(userId))!;
        expect(after.ledger.balance('kaspi'), kzt(95000));
        print('S-ERASE $erase: failed SQLSTATE23503, account still exists; concurrent expense committed');
      });
    }
  });
}
