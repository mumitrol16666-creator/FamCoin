/// Защита от отмены покупки с действующим возвратом (D139): приложение
/// проверяет это у себя, но второй телефон мог добавить возврат, пока на
/// первом данные не обновились — сервер не должен принимать такую отмену от
/// клиента. Правка покупки (отмена старой версии и новая в одном пакете) и
/// внутренние команды (импорт, бот) проходят как раньше.
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

  Future<String> owner() async {
    final r = await pool!.execute(
      Sql.named("INSERT INTO users (email, password_hash, plan) VALUES (@e, 'x', 'pro') RETURNING id"),
      parameters: {'e': 'refund-${DateTime.now().microsecondsSinceEpoch}-${seq++}@example.test'},
    );
    final id = r.first[0].toString();
    users.add(id);
    return id;
  }

  /// Покупка 10 000 ₸ и возврат по ней 3 000 ₸.
  Future<String> withRefund(LedgerService ledger) async {
    final id = await owner();
    await ledger.command(id, {
      'type': 'batch', 'commandId': 'setup-$id',
      'commands': [
        {'type': 'addMoneyAccount', 'accountId': 'card'},
        {'type': 'opening', 'id': 'o', 'date': '2026-09-01', 'account': 'card', 'amount': '${kzt(100000)}'},
        {'type': 'expense', 'id': 'e1', 'date': '2026-09-10', 'account': 'card', 'splits': {'food': '${kzt(10000)}'}, 'meta': {'who': 'me'}},
        {'type': 'refund', 'id': 'r1', 'date': '2026-09-11', 'category': 'food', 'amount': '${kzt(3000)}', 'toAccount': 'card', 'meta': {'refundOf': 'e1', 'who': 'me'}},
      ],
    });
    return id;
  }

  test('клиент не может отменить покупку с действующим возвратом', () async {
    if (skip()) return;
    final ledger = LedgerService(pool!);
    final id = await withRefund(ledger);
    await expectLater(
      ledger.command(id, {'type': 'reverse', 'txId': 'e1', 'id': 'x1', 'commandId': 'del-$id'}, fromClient: true),
      throwsA(isA<ApiError>().having((e) => e.ledgerCode, 'ledgerCode', 'hasRefunds')),
    );
    // Журнал не изменился.
    final view = (await ledger.view(id))!;
    expect(view.ledger.balance('card'), kzt(93000));
  });

  test('сначала возврат, потом покупка: оба удаления проходят, в том числе одним пакетом', () async {
    if (skip()) return;
    final ledger = LedgerService(pool!);
    final id = await withRefund(ledger);
    await ledger.command(id, {
      'type': 'batch', 'commandId': 'both-$id',
      'commands': [
        {'type': 'reverse', 'txId': 'r1', 'id': 'x-r1'},
        {'type': 'reverse', 'txId': 'e1', 'id': 'x-e1'},
      ],
    }, fromClient: true);
    final view = (await ledger.view(id))!;
    expect(view.ledger.balance('card'), kzt(100000));
  });

  test('правка покупки с возвратом (старая отменяется, новая в том же пакете) проходит', () async {
    if (skip()) return;
    final ledger = LedgerService(pool!);
    final id = await withRefund(ledger);
    await ledger.command(id, {
      'type': 'batch', 'commandId': 'edit-$id',
      'commands': [
        {'type': 'reverse', 'txId': 'e1', 'id': 'x-e1'},
        {'type': 'expense', 'id': 'e2', 'date': '2026-09-10', 'account': 'card', 'splits': {'food': '${kzt(12000)}'}, 'meta': {'who': 'me', 'edited': 'e1'}},
      ],
    }, fromClient: true);
    final view = (await ledger.view(id))!;
    expect(view.ledger.balance('card'), kzt(100000 - 12000 + 3000));
  });

  test('внутренние команды (импорт, бот) защитой не затрагиваются', () async {
    if (skip()) return;
    final ledger = LedgerService(pool!);
    final id = await withRefund(ledger);
    await ledger.command(id, {'type': 'reverse', 'txId': 'e1', 'id': 'x1', 'commandId': 'undo-$id'});
    final view = (await ledger.view(id))!;
    expect(view.ledger.isReversed('e1'), isTrue);
  });
}
