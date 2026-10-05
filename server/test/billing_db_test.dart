/// Оплата Pro через Telegram (S02): повторная доставка одной оплаты не
/// продлевает Pro дважды, а оплата, обработчик которой упал, при повторной
/// доставке проводится ровно один раз. Нужна база (порт `TEST_DB_PORT`, по
/// умолчанию 5433); без базы тесты пропускаются.
library;

import 'dart:io';

import 'package:famcoin_server/auth_service.dart';
import 'package:famcoin_server/billing.dart';
import 'package:famcoin_server/ledger_service.dart';
import 'package:famcoin_server/notifications.dart';
import 'package:famcoin_server/telegram.dart';
import 'package:famcoin_server/webpush.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

class _FakeTelegram extends Telegram {
  _FakeTelegram(super.db) : super(token: 'test');

  /// То, что Telegram ещё не получил подтверждение: события по update_id.
  final updates = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>?> call(String method, Map<String, Object?> body) async {
    if (method != 'getUpdates') return {'ok': true};
    final from = body['offset'] as int;
    return {
      'ok': true,
      'result': [
        for (final u in updates)
          if ((u['update_id'] as int) >= from) u,
      ],
    };
  }
}

Map<String, dynamic> _paid(int updateId, String userId, String charge) => {
      'update_id': updateId,
      'message': {
        'chat': {'id': 4242, 'type': 'private'},
        'from': {'id': 4242},
        'successful_payment': {'telegram_payment_charge_id': charge, 'currency': 'XTR', 'total_amount': 950, 'invoice_payload': 'pro:$userId'},
      },
    };

void main() {
  Pool? pool;
  final created = <String>[];

  setUpAll(() async {
    final db = Pool.withEndpoints(
      [Endpoint(host: 'localhost', port: int.parse(Platform.environment['TEST_DB_PORT'] ?? '5433'), database: 'famcoin', username: 'famcoin', password: 'famcoin')],
      settings: const PoolSettings(maxConnectionCount: 4, sslMode: SslMode.disable),
    );
    try {
      await db.execute('SELECT 1 FROM payments LIMIT 1').timeout(const Duration(seconds: 3));
      pool = db;
    } catch (_) {}
  });

  tearDownAll(() async {
    final db = pool;
    if (db == null) return;
    for (final id in created) {
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

  Future<String> newUser() async {
    final r = await pool!.execute(
      Sql.named("INSERT INTO users (email, password_hash) VALUES (@e, 'x') RETURNING id"),
      parameters: {'e': 'billing-${DateTime.now().microsecondsSinceEpoch}@example.test'},
    );
    final id = r.first[0].toString();
    created.add(id);
    return id;
  }

  (_FakeTelegram, BillingService) service() {
    final tg = _FakeTelegram(pool!);
    final notifications = NotificationService(pool!, LedgerService(pool!), tg, WebPush(pool!, subject: 'mailto:test@example.test'));
    return (tg, BillingService(pool!, tg, notifications));
  }

  Future<List<Object?>> state(String userId) async {
    final u = await pool!.execute(Sql.named('SELECT plan, pro_until FROM users WHERE id = @u'), parameters: {'u': userId});
    final p = await pool!.execute(Sql.named('SELECT count(*) FROM payments WHERE user_id = @u'), parameters: {'u': userId});
    return [u.first[0], u.first[1], p.first[0]];
  }

  test('одна и та же оплата, доставленная дважды (в том числе одновременно), даёт один платёж и одно продление Pro', () async {
    if (skip()) return;
    final userId = await newUser();
    final (tg, _) = service();
    final charge = 'charge-${DateTime.now().microsecondsSinceEpoch}';
    final payment = _paid(1, userId, charge)['message']['successful_payment'] as Map<String, dynamic>;

    await tg.onPayment!(4242, const {'id': 4242}, payment);
    final first = await state(userId);
    expect(first[0], 'pro');
    expect(first[2], 1);

    await Future.wait([
      tg.onPayment!(4242, const {'id': 4242}, payment),
      tg.onPayment!(4242, const {'id': 4242}, payment),
    ]);
    final second = await state(userId);
    expect(second[2], 1, reason: 'повтор после commit или потери ответа платёж не добавляет');
    expect(second[1], first[1], reason: 'срок Pro не продлевается второй раз');
  });

  test('две оплаты в пачке, обработчик первой упал и процесс перезапущен: обе проведены, offset не перепрыгнул потерянное событие', () async {
    if (skip()) return;
    final a = await newUser();
    final b = await newUser();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final (tg, _) = service();
    tg.updates
      ..add(_paid(500, a, 'charge-a-$stamp'))
      ..add(_paid(501, b, 'charge-b-$stamp'));

    // Краткий обрыв базы: обработчик падает до записи.
    final real = tg.onPayment!;
    var outage = true;
    tg.onPayment = (chat, from, payment) async {
      if (outage) throw StateError('connection closed');
      await real(chat, from, payment);
    };
    await tg.pollOnce();
    expect((await state(a))[2], 0);
    expect((await state(b))[2], 0, reason: 'вторая оплата не обработана и не подтверждена раньше первой');
    expect(tg.offset, 0);

    // «Перезапуск»: новый транспорт с offset 0 получает то же, что не подтверждено.
    final (restarted, _) = service();
    restarted.updates.addAll(tg.updates);
    outage = false;
    await restarted.pollOnce();
    final sa = await state(a);
    final sb = await state(b);
    expect([sa[0], sa[2], sb[0], sb[2]], ['pro', 1, 'pro', 1]);
    expect(restarted.offset, 502);

    // Повторная доставка уже подтверждённых событий ничего не меняет.
    await real(4242, const {'id': 4242}, _paid(500, a, 'charge-a-$stamp')['message']['successful_payment'] as Map<String, dynamic>);
    expect((await state(a))[2], 1);
  });
}
