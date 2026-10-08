/// Серверные команды из технического аудита 05.10.2026: отметка срока без
/// потери чужих отметок (R01) и лимит обычной версии при возврате счёта из архива (C08).
library;

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
      settings: const PoolSettings(maxConnectionCount: 6, sslMode: SslMode.disable),
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
        // уже удалён
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

  Future<String> owner(LedgerService ledger, {String plan = 'pro'}) async {
    final r = await pool!.execute(
      Sql.named("INSERT INTO users (email, password_hash, plan) VALUES (@e, 'x', @p) RETURNING id"),
      parameters: {'e': 'paid-${DateTime.now().microsecondsSinceEpoch}-${seq++}@example.test', 'p': plan},
    );
    final id = r.first[0].toString();
    users.add(id);
    return id;
  }

  Future<List<String>> paid(String userId, String id) async {
    final r = await pool!.execute(
      Sql.named("SELECT data FROM entities WHERE user_id = @u AND kind = 'planned' AND id = @id"),
      parameters: {'u': userId, 'id': id},
    );
    return ((r.first[0] as Map)['paid'] as List).cast<String>();
  }

  test('R01: две отметки разных сроков подряд со «старых» копий не теряют друг друга', () async {
    if (skip()) return;
    final ledger = LedgerService(pool!);
    final id = await owner(ledger);
    await ledger.command(id, {
      'type': 'upsertEntity', 'commandId': 'p-$id', 'kind': 'planned', 'entityId': 'rent',
      'data': {'name': 'Аренда', 'amount': '1000000', 'day': 10, 'category': 'home', 'paid': <String>[]},
    });
    await ledger.command(id, {'type': setPaidCommand, 'commandId': 'a-$id', 'kind': 'planned', 'entityId': 'rent', 'period': '2026-09', 'paid': true});
    await ledger.command(id, {'type': setPaidCommand, 'commandId': 'b-$id', 'kind': 'planned', 'entityId': 'rent', 'period': '2026-10', 'paid': true});
    expect(await paid(id, 'rent'), ['2026-09', '2026-10']);
    await ledger.command(id, {'type': setPaidCommand, 'commandId': 'c-$id', 'kind': 'planned', 'entityId': 'rent', 'period': '2026-09', 'paid': false});
    expect(await paid(id, 'rent'), ['2026-10'], reason: 'снята только одна отметка');
    // Платёж удалён — отметка ничего не делает и не падает.
    await ledger.command(id, {'type': 'deleteEntity', 'commandId': 'd-$id', 'kind': 'planned', 'entityId': 'rent'});
    await ledger.command(id, {'type': setPaidCommand, 'commandId': 'e-$id', 'kind': 'planned', 'entityId': 'rent', 'period': '2026-11', 'paid': true});
  });

  test('R01: отметка в одной пачке с оплатой — оба применяются или ни одного; связь с копилкой снимается', () async {
    if (skip()) return;
    final ledger = LedgerService(pool!);
    final id = await owner(ledger);
    await ledger.command(id, {
      'type': 'batch', 'commandId': 'setup-$id',
      'commands': [
        {'type': 'addMoneyAccount', 'accountId': 'acc'},
        {'type': 'opening', 'id': 'o', 'date': '2026-09-01', 'account': 'acc', 'amount': '${kzt(100000)}'},
        {'type': 'upsertEntity', 'kind': 'planned', 'entityId': 'rent', 'data': {'name': 'Аренда', 'amount': '1000000', 'day': 10, 'category': 'home', 'paid': <String>[], 'goal': 'g'}},
      ],
    });
    // Оплата срока: расход со связью и отметка.
    await ledger.command(id, {
      'type': 'batch', 'commandId': 'pay-$id',
      'commands': [
        {'type': 'expense', 'id': 'pay1', 'date': '2026-09-10', 'account': 'acc', 'splits': {'home': '${kzt(10000)}'}, 'meta': {'planned': 'rent', 'period': '2026-09'}},
        {'type': setPaidCommand, 'kind': 'planned', 'entityId': 'rent', 'period': '2026-09', 'paid': true, 'clearGoal': true},
      ],
    });
    expect(await paid(id, 'rent'), ['2026-09']);
    final goal = (await pool!.execute(Sql.named("SELECT data FROM entities WHERE user_id = @u AND id = 'rent'"), parameters: {'u': id})).first[0] as Map;
    expect(goal.containsKey('goal'), isFalse);
    // Та же оплата другой командой (второе устройство): ядро отклоняет срок, отметка не меняется.
    await expectLater(
      ledger.command(id, {
        'type': 'batch', 'commandId': 'pay2-$id',
        'commands': [
          {'type': 'expense', 'id': 'pay2', 'date': '2026-09-10', 'account': 'acc', 'splits': {'home': '${kzt(10000)}'}, 'meta': {'planned': 'rent', 'period': '2026-09'}},
          {'type': setPaidCommand, 'kind': 'planned', 'entityId': 'rent', 'period': '2026-09', 'paid': true},
        ],
      }),
      throwsA(isA<ApiError>().having((e) => e.ledgerCode, 'code', 'occurrencePaid')),
    );
    final r = await pool!.execute(Sql.named("SELECT count(*) FROM transactions WHERE user_id = @u AND type = 'expense'"), parameters: {'u': id});
    expect(r.first[0], 1);
  });

  test('отметка с плохими данными отклоняется', () async {
    if (skip()) return;
    final ledger = LedgerService(pool!);
    final id = await owner(ledger);
    for (final bad in [
      {'kind': 'limit', 'entityId': 'x', 'period': '2026-09'},
      {'kind': 'planned', 'entityId': 'x', 'period': ''},
      {'kind': 'planned', 'entityId': 'x', 'period': 'длинный-период-длинный-период'},
    ]) {
      await expectLater(ledger.command(id, {'type': setPaidCommand, 'commandId': 'bad-${bad.hashCode}-$id', ...bad}), throwsA(isA<ApiError>()), reason: '$bad');
    }
  });

  test('C08: возврат из архива в обычной версии не обходит лимит одного счёта; в Pro разрешён', () async {
    if (skip()) return;
    final ledger = LedgerService(pool!);
    final free = await owner(ledger, plan: 'free');
    await ledger.command(free, {
      'type': 'batch', 'commandId': 'setup-$free',
      'commands': [
        {'type': 'addMoneyAccount', 'accountId': 'old'},
        {'type': 'archiveAccount', 'accountId': 'old'},
        {'type': 'addMoneyAccount', 'accountId': 'new'},
      ],
    });
    await expectLater(
      ledger.command(free, {'type': 'archiveAccount', 'commandId': 'un1-$free', 'accountId': 'old', 'archived': false}),
      throwsA(isA<ApiError>().having((e) => e.status, 'status', 402)),
    );
    // Освободили место — вернуть можно.
    await ledger.command(free, {'type': 'archiveAccount', 'commandId': 'ar-$free', 'accountId': 'new'});
    await ledger.command(free, {'type': 'archiveAccount', 'commandId': 'un2-$free', 'accountId': 'old', 'archived': false});

    final pro = await owner(ledger);
    await ledger.command(pro, {
      'type': 'batch', 'commandId': 'setup-$pro',
      'commands': [
        {'type': 'addMoneyAccount', 'accountId': 'old'},
        {'type': 'archiveAccount', 'accountId': 'old'},
        {'type': 'addMoneyAccount', 'accountId': 'new'},
      ],
    });
    await ledger.command(pro, {'type': 'archiveAccount', 'commandId': 'un3-$pro', 'accountId': 'old', 'archived': false});
  });

  // N03 (аудит 08.10): правка условий со старой формы не трогает оплату, а
  // правка по устаревшей версии условий получает отказ, а не затирает чужую.
  group('N03: условия платежа отдельно от оплаты', () {
    Map<String, dynamic> rent({String name = 'Аренда', List<String> paid = const [], int? rev}) =>
        {'name': name, 'amount': '1000000', 'day': 10, 'category': 'home', 'paid': paid, if (rev != null) 'rev': rev};
    Future<Map> stored(String userId) async =>
        (await pool!.execute(Sql.named("SELECT data FROM entities WHERE user_id = @u AND kind = 'planned' AND id = 'rent'"), parameters: {'u': userId})).first[0] as Map;
    Future<void> upsert(LedgerService l, String userId, String cmd, Map<String, dynamic> data) =>
        l.command(userId, {'type': 'upsertEntity', 'commandId': '$cmd-$userId', 'kind': 'planned', 'entityId': 'rent', 'data': data});

    test('форма открыта до оплаты на другом устройстве: новое название сохраняется, оплата остаётся', () async {
      if (skip()) return;
      final ledger = LedgerService(pool!);
      final id = await owner(ledger);
      await ledger.command(id, {
        'type': 'batch', 'commandId': 'setup-$id',
        'commands': [
          {'type': 'addMoneyAccount', 'accountId': 'acc'},
          {'type': 'opening', 'id': 'o', 'date': '2026-09-01', 'account': 'acc', 'amount': '${kzt(100000)}'},
          {'type': 'upsertEntity', 'kind': 'planned', 'entityId': 'rent', 'data': rent()},
        ],
      });
      expect((await stored(id))['rev'], 1);
      // Устройство A оплатило сентябрь.
      await ledger.command(id, {
        'type': 'batch', 'commandId': 'pay-$id',
        'commands': [
          {'type': 'expense', 'id': 'pay1', 'date': '2026-09-10', 'account': 'acc', 'splits': {'home': '${kzt(10000)}'}, 'meta': {'planned': 'rent', 'period': '2026-09'}},
          {'type': setPaidCommand, 'kind': 'planned', 'entityId': 'rent', 'period': '2026-09', 'paid': true},
        ],
      });
      // Устройство B сохраняет форму, открытую раньше: в ней ещё нет оплаты.
      await upsert(ledger, id, 'b', rent(name: 'Аренда квартиры', rev: 1));
      final after = await stored(id);
      expect(after['name'], 'Аренда квартиры');
      expect(after['paid'], ['2026-09'], reason: 'старая форма не вернула неоплаченный срок');
      expect(after['rev'], 2);
    });

    test('форма открыта до отмены оплаты: сохранение не возвращает снятую отметку', () async {
      if (skip()) return;
      final ledger = LedgerService(pool!);
      final id = await owner(ledger);
      await upsert(ledger, id, 'new', rent(paid: ['2026-09']));
      // B снял отметку (удалил оплату), A сохраняет форму со старой отметкой.
      await ledger.command(id, {'type': setPaidCommand, 'commandId': 'unpay-$id', 'kind': 'planned', 'entityId': 'rent', 'period': '2026-09', 'paid': false});
      await upsert(ledger, id, 'a', rent(name: 'Аренда (новая)', paid: ['2026-09'], rev: 1));
      final after = await stored(id);
      expect(after['name'], 'Аренда (новая)');
      expect(after['paid'], isEmpty, reason: 'снятая на другом устройстве отметка не вернулась');
    });

    test('две правки условий по одной версии: вторая отклонена entityChanged, первая не затёрта; старое приложение без rev оплату не трогает', () async {
      if (skip()) return;
      final ledger = LedgerService(pool!);
      final id = await owner(ledger);
      await upsert(ledger, id, 'new', rent());
      await upsert(ledger, id, 'a', rent(name: 'Аренда A', rev: 1));
      await expectLater(upsert(ledger, id, 'b', rent(name: 'Аренда B', rev: 1)), throwsA(isA<ApiError>().having((e) => e.ledgerCode, 'code', 'entityChanged')));
      expect((await stored(id))['name'], 'Аренда A');
      expect((await stored(id))['rev'], 2);

      await ledger.command(id, {'type': setPaidCommand, 'commandId': 'pay-$id', 'kind': 'planned', 'entityId': 'rent', 'period': '2026-09', 'paid': true});
      await upsert(ledger, id, 'old-app', rent(name: 'Аренда C'));
      final after = await stored(id);
      expect([after['name'], after['paid'], after['rev']], ['Аренда C', ['2026-09'], 3]);
    });
  });
}
