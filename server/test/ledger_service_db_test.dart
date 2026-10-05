/// Согласованность чтения и записи журнала на настоящей базе (S03, S05).
///
/// Гонки проверяются не паузами, а состоянием ожидания: чужая транзакция
/// держит блокировку строки, а тест ждёт в `pg_stat_activity`, пока нужный
/// запрос действительно встанет на ней (`wait_event_type = 'Lock'`). Нужна
/// база (порт `TEST_DB_PORT`, по умолчанию 5433); без неё тесты пропускаются.
library;

import 'dart:async';
import 'dart:io';

import 'package:famcoin_core/famcoin_core.dart';
import 'package:famcoin_server/auth_service.dart';
import 'package:famcoin_server/ledger_service.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

void main() {
  Pool? pool;
  final users = <String>[];
  var seq = 0;

  setUpAll(() async {
    final db = Pool.withEndpoints(
      [Endpoint(host: 'localhost', port: int.parse(Platform.environment['TEST_DB_PORT'] ?? '5433'), database: 'famcoin', username: 'famcoin', password: 'famcoin')],
      settings: const PoolSettings(maxConnectionCount: 12, sslMode: SslMode.disable),
    );
    try {
      await db.execute('SELECT 1 FROM transactions LIMIT 1').timeout(const Duration(seconds: 3));
      pool = db;
    } catch (_) {}
  });

  tearDownAll(() async {
    final db = pool;
    if (db == null) return;
    for (final id in users) {
      try {
        await deleteUserData(db, id);
      } on ApiError {
        // уже удалён самим тестом
      }
    }
    await db.close();
  });

  bool skip() {
    if (pool != null) return false;
    if (Platform.environment['TEST_DB_REQUIRED'] == '1') fail('TEST_DB_REQUIRED=1, а база недоступна');
    markTestSkipped('база не запущена');
    return true;
  }

  /// Владелец со счётом `acc` и 100 000 ₸.
  Future<String> owner(LedgerService ledger) async {
    final r = await pool!.execute(
      Sql.named("INSERT INTO users (email, password_hash, plan) VALUES (@e, 'x', 'pro') RETURNING id"),
      parameters: {'e': 'ledger-${DateTime.now().microsecondsSinceEpoch}-${seq++}@example.test'},
    );
    final id = r.first[0].toString();
    users.add(id);
    await ledger.command(id, {
      'type': 'batch',
      'commandId': 'setup-$id',
      'commands': [
        {'type': 'addMoneyAccount', 'accountId': 'acc'},
        {'type': 'opening', 'id': 'open', 'date': '2026-09-01', 'account': 'acc', 'amount': '${kzt(100000)}'},
        {'type': 'upsertEntity', 'kind': 'goal', 'entityId': 'g0', 'data': {'name': 'старая цель'}},
      ],
    });
    return id;
  }

  Map<String, dynamic> expense(String id, num tenge) => {
        'type': 'expense',
        'id': id,
        'date': '2026-09-02',
        'account': 'acc',
        'splits': {'food': '${kzt(tenge)}'},
      };

  /// Чужая транзакция держит блокировку, пока не вызван [release].
  ({Future<void> done, void Function() release, Future<void> locked}) hold(String sql, Map<String, Object?> params) {
    final release = Completer<void>();
    final locked = Completer<void>();
    final done = pool!.runTx((tx) async {
      await tx.execute(Sql.named(sql), parameters: params);
      locked.complete();
      await release.future;
    });
    return (done: done, release: release.complete, locked: locked.future);
  }

  /// Ждём, пока запрос с таким текстом встанет на блокировке.
  Future<void> waitLock(String like) async {
    for (var i = 0; i < 400; i++) {
      final r = await pool!.execute(
        Sql.named("SELECT count(*) FROM pg_stat_activity WHERE wait_event_type = 'Lock' AND query LIKE @q AND pid <> pg_backend_pid()"),
        parameters: {'q': like},
      );
      if ((r.first[0] as int) > 0) return;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    fail('запрос "$like" не встал на блокировку');
  }

  Future<int> txCount(String userId, String txId) async =>
      (await pool!.execute(Sql.named('SELECT count(*) FROM transactions WHERE user_id = @u AND id = @t'), parameters: {'u': userId, 't': txId})).first[0] as int;

  group('S03: кеш журнала и чтение для бота', () {
    test('T36: прогретый кеш, команда застряла на блокировке и откатилась — читатель не видит неподтверждённый расход', () async {
      if (skip()) return;
      final ledger = LedgerService(pool!);
      final id = await owner(ledger);
      final warm = await ledger.view(id); // прогрев кеша
      expect(warm!.ledger.balance('acc'), kzt(100000));

      // Другая транзакция держит запись справочника, в которую упрётся команда.
      final lock = hold("SELECT 1 FROM entities WHERE user_id = @u AND kind = 'goal' AND id = 'g0' FOR UPDATE", {'u': id});
      await lock.locked;
      final batch = ledger.command(id, {
        'type': 'batch',
        'commandId': 'bad-${DateTime.now().microsecondsSinceEpoch}',
        'commands': [
          expense('not-committed', 5000),
          {'type': 'upsertEntity', 'kind': 'goal', 'entityId': 'g0', 'data': {'name': 'новая цель'}},
          {'type': 'expense', 'id': 'broken', 'date': 'не дата', 'account': 'acc', 'splits': {'food': '1'}},
        ],
      });
      final failure = expectLater(batch, throwsA(isA<ApiError>()));
      await waitLock('%INSERT INTO entities%');

      // Читатель идёт, пока команда в середине (расход уже применён в памяти).
      final reader = ledger.view(id);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      lock.release();
      await failure;
      await lock.done;

      final seen = await reader;
      expect(seen!.ledger.byId('not-committed'), isNull, reason: 'расхода в таблице transactions нет — и читатель его не видит');
      expect(seen.ledger.balance('acc'), kzt(100000));
      expect(await txCount(id, 'not-committed'), 0);
      expect((await ledger.view(id))!.ledger.balance('acc'), kzt(100000), reason: 'и после отката');
    });

    test('T37: выданный ранее view не меняется после следующей успешной команды', () async {
      if (skip()) return;
      final ledger = LedgerService(pool!);
      final id = await owner(ledger);
      final before = (await ledger.view(id))!;
      expect(before.ledger.balance('acc'), kzt(100000));
      final txs = before.ledger.transactions.length;

      await ledger.command(id, {...expense('e1', 5000), 'commandId': 'e1-$id'});

      expect(before.ledger.balance('acc'), kzt(100000), reason: 'старый снимок остался прежним');
      expect(before.ledger.transactions.length, txs);
      expect(before.ledger.byId('e1'), isNull);
      final after = (await ledger.view(id))!;
      expect(after.ledger.balance('acc'), kzt(95000));
      expect(after.ledger.byId('e1'), isNotNull);
    });

    test('T37b: отказанная команда кеш не портит — следующий читатель видит прежний журнал без перечитывания', () async {
      if (skip()) return;
      final ledger = LedgerService(pool!);
      final id = await owner(ledger);
      final before = (await ledger.view(id))!.ledger;
      await expectLater(
        ledger.command(id, {'type': 'batch', 'commandId': 'x-$id', 'commands': [expense('half', 1000), {'type': 'nope'}]}),
        throwsA(isA<ApiError>()),
      );
      final after = (await ledger.view(id))!.ledger;
      expect(after.byId('half'), isNull);
      expect(after.balance('acc'), kzt(100000));
      expect(identical(after, before), isTrue, reason: 'кеш не выбрасывался: команда меняла копию');
    });

    test('T38: холодный кеш и команда в середине записи: ревизия, журнал и справочники — из одного снимка', () async {
      if (skip()) return;
      final writer = LedgerService(pool!);
      final id = await owner(writer);
      final cold = LedgerService(pool!); // свой пустой кеш, как другой процесс или после перезапуска

      final lock = hold("SELECT 1 FROM entities WHERE user_id = @u AND kind = 'goal' AND id = 'g0' FOR UPDATE", {'u': id});
      await lock.locked;
      final command = writer.command(id, {
        'type': 'batch',
        'commandId': 'two-$id',
        'commands': [
          expense('e2', 5000),
          {'type': 'upsertEntity', 'kind': 'goal', 'entityId': 'g0', 'data': {'name': 'новая цель'}},
        ],
      });
      await waitLock('%INSERT INTO entities%');
      final reader = cold.view(id);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      lock.release();
      await command;
      await lock.done;

      final v = (await reader)!;
      final balance = v.ledger.balance('acc');
      final goal = v.of('goal')['g0']!['name'];
      expect([balance, goal], anyOf([[kzt(100000), 'старая цель'], [kzt(95000), 'новая цель']]), reason: 'не смесь двух состояний');
    });
  });

  group('S05: сброс и удаление аккаунта против записи', () {
    /// Стирание остановлено на чужой блокировке в середине (после удаления
    /// проводок прежней операции): в это окно приходит обычная команда.
    Future<void> raceWithErase(Future<void> Function(Pool, String) erase, {required String eraseSql, required void Function(String id, Object? commandError, Object? eraseError) check}) async {
      final ledger = LedgerService(pool!);
      final id = await owner(ledger);
      final lock = hold("SELECT 1 FROM transactions WHERE user_id = @u AND id = 'open' FOR UPDATE", {'u': id});
      await lock.locked;

      Object? eraseError;
      final eraseDone = erase(pool!, id).then<void>((_) {}, onError: (Object e) => eraseError = e);
      await waitLock(eraseSql);

      Object? commandError;
      final commandDone = ledger.command(id, {...expense('late', 5000), 'commandId': 'late-$id'}).then<void>((_) {}, onError: (Object e) => commandError = e);
      await waitLock('SELECT revision, plan, profile FROM users%');
      lock.release();
      await eraseDone;
      await commandDone;
      await lock.done;
      check(id, commandError, eraseError);
    }

    test('T42: «Начать заново» и конкурентная команда сериализованы: без FK-ошибки, журнал пуст, поздняя команда не остаётся в журнале', () async {
      if (skip()) return;
      await raceWithErase(resetUserData, eraseSql: '%DELETE FROM transactions%', check: (id, commandError, eraseError) {
        expect(eraseError, isNull, reason: 'сброс не падает на внешнем ключе');
        expect(commandError, isNot(isA<PgException>()), reason: 'команда не получает ошибку базы (500)');
        expect(commandError, isA<ApiError>());
      });
    });

    test('T42b: после сброса журнал пуст и команда по старому счёту не записывается', () async {
      if (skip()) return;
      final ledger = LedgerService(pool!);
      late String id;
      await raceWithErase(resetUserData, eraseSql: '%DELETE FROM transactions%', check: (userId, commandError, eraseError) => id = userId);
      final v = (await ledger.view(id))!;
      expect(v.ledger.transactions, isEmpty);
      expect(v.ledger.byId('late'), isNull);
      expect(await txCount(id, 'late'), 0);
    });

    test('T43: удаление аккаунта и конкурентная команда: аккаунт удалён, поздняя команда получает отказ «нет аккаунта»', () async {
      if (skip()) return;
      Object? commandError;
      Object? eraseError;
      late String id;
      await raceWithErase(deleteUserData, eraseSql: '%DELETE FROM transactions%', check: (userId, c, e) {
        id = userId;
        commandError = c;
        eraseError = e;
      });
      expect(eraseError, isNull, reason: 'удаление не падает на внешнем ключе');
      expect(commandError, isA<ApiError>().having((e) => e.status, 'status', 401));
      final left = await pool!.execute(Sql.named('SELECT count(*) FROM users WHERE id = @u'), parameters: {'u': id});
      expect(left.first[0], 0);
      for (final table in ['transactions', 'postings', 'ledger_accounts']) {
        final r = await pool!.execute(Sql.named('SELECT count(*) FROM $table WHERE user_id = @u'), parameters: {'u': id});
        expect(r.first[0], 0, reason: table);
      }
    });

    test('сброс и удаление несуществующего аккаунта — 404, а не успех', () async {
      if (skip()) return;
      const ghost = '00000000-0000-4000-8000-000000000000';
      await expectLater(resetUserData(pool!, ghost), throwsA(isA<ApiError>().having((e) => e.status, 'status', 404)));
      await expectLater(deleteUserData(pool!, ghost), throwsA(isA<ApiError>().having((e) => e.status, 'status', 404)));
    });
  });
}
