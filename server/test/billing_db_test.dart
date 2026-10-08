/// Оплата Pro через Telegram (S02): повторная доставка одной оплаты не
/// продлевает Pro дважды, а оплата, обработчик которой упал, при повторной
/// доставке проводится ровно один раз. Нужна база (порт `TEST_DB_PORT`, по
/// умолчанию 5433); без базы тесты пропускаются.
library;

import 'dart:io';
import 'dart:convert';
import 'package:shelf/shelf.dart';
import 'package:famcoin_server/api.dart';
import 'package:famcoin_server/admin.dart';
import 'package:famcoin_server/ai.dart';

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

  /// Отправленные сообщения: чат и текст.
  final sent = <(Object?, String)>[];

  /// Возвраты звёзд: что просили и что уже возвращено на стороне Telegram.
  final refundCalls = <String>[];
  final refundedCharges = <String>{};

  @override
  Future<RefundOutcome> refundStars({required int telegramUserId, required String chargeId}) async {
    refundCalls.add(chargeId);
    return refundedCharges.add(chargeId) ? RefundOutcome.refunded : RefundOutcome.alreadyRefunded;
  }

  @override
  Future<Map<String, dynamic>?> call(String method, Map<String, Object?> body) async {
    if (method == 'sendMessage') sent.add((body['chat_id'], '${body['text']}'));
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

/// Выдача Pro падает, пока [failing] (таблица платежей недоступна).
class _FlakyBilling extends BillingService {
  _FlakyBilling(super.db, super.telegram, super.notifications, {super.adminChat});

  bool failing = true;

  @override
  Future<ProGrant?> grant(TxSession tx, {required String userId, required String chargeId, required int telegramUserId, required int stars}) {
    if (failing) throw StateError('таблица payments недоступна');
    return super.grant(tx, userId: userId, chargeId: chargeId, telegramUserId: telegramUserId, stars: stars);
  }
}

/// Локальная часть возврата падает [failures] раз — уже после того, как
/// Telegram вернул звёзды.
class _CrashOnApply extends BillingService {
  _CrashOnApply(super.db, super.telegram, super.notifications);

  int failures = 1;

  @override
  Future<bool> applyRefund(String paymentId) {
    if (failures > 0) {
      failures--;
      throw StateError('сбой записи после возврата в Telegram');
    }
    return super.applyRefund(paymentId);
  }
}

/// Процесс «падает» сразу после сохранения оплаты в очередь, до выдачи Pro.
class _CrashAfterSave extends BillingService {
  _CrashAfterSave(super.db, super.telegram, super.notifications);

  @override
  Future<void> process(String chargeId) async {}
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
  final charges = <String>[];

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
    await db.execute(Sql.named('DELETE FROM payment_inbox WHERE charge_id = ANY(@c)'), parameters: {'c': charges});
    await db.execute(Sql.named("DELETE FROM payment_inbox WHERE payment->>'invoice_payload' = ANY(@p)"), parameters: {'p': [for (final id in created) 'pro:$id']});
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

  NotificationService notif(Telegram tg) => NotificationService(pool!, LedgerService(pool!), tg, WebPush(pool!, subject: 'mailto:test@example.test'));

  Future<Map<String, Object?>> inboxRow(String charge) async {
    final r = await pool!.execute(Sql.named('SELECT status, attempts, last_error FROM payment_inbox WHERE charge_id = @c'), parameters: {'c': charge});
    return r.isEmpty ? {} : {'status': r.first[0], 'attempts': r.first[1], 'error': r.first[2]};
  }

  /// Подошло время повтора (не ждать паузу в тесте).
  Future<void> due(String charge) =>
      pool!.execute(Sql.named('UPDATE payment_inbox SET next_at = now() WHERE charge_id = @c'), parameters: {'c': charge});

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

  test('выдача Pro падает дольше предела: оплата подтверждена Telegram только после сохранения, видна в админке, оператору сигнал; после восстановления Pro выдан ровно один раз', () async {
    if (skip()) return;
    final userId = await newUser();
    final charge = 'charge-long-${DateTime.now().microsecondsSinceEpoch}';
    charges.add(charge);
    final tg = _FakeTelegram(pool!);
    final billing = _FlakyBilling(pool!, tg, notif(tg), adminChat: 999);
    tg.updates.add(_paid(700, userId, charge));

    await tg.pollOnce();
    expect(tg.offset, 701, reason: 'оплата сохранена в очереди — только тогда Telegram получает подтверждение');
    expect((await state(userId))[2], 0);
    expect(await inboxRow(charge), {'status': 'pending', 'attempts': 1, 'error': contains('таблица payments недоступна')});

    for (var i = 2; i <= BillingService.maxInboxAttempts + 3; i++) {
      await due(charge);
      await billing.retryInbox();
    }
    final failed = await inboxRow(charge);
    expect(failed['status'], 'failed', reason: 'после предела — «нужен разбор», а не пропуск');
    expect(failed['attempts'], BillingService.maxInboxAttempts + 3, reason: 'повторы продолжаются и после предела');
    final alerts = tg.sent.where((m) => m.$1 == 999).toList();
    expect(alerts, hasLength(1), reason: 'оператор получает сигнал один раз');
    expect(alerts.single.$2, contains(charge));
    final listed = (await billing.inbox()).where((p) => p['chargeId'] == charge).toList();
    expect(listed, hasLength(1));
    expect(listed.single['status'], 'failed');
    expect('${listed.single['email']}', startsWith('billing-'));
    expect((await state(userId))[0], isNot('pro'));

    // База восстановилась: ближайший повтор выдаёт Pro.
    billing.failing = false;
    await due(charge);
    await billing.retryInbox();
    final after = await state(userId);
    expect([after[0], after[2]], ['pro', 1]);
    expect((await inboxRow(charge))['status'], 'done');
    expect((await billing.inbox()).where((p) => p['chargeId'] == charge), isEmpty);

    // Ни повтор из админки, ни повторная доставка события больше ничего не меняют.
    await expectLater(billing.retry(charge), throwsA(isA<ApiError>().having((e) => e.status, 'status', 404)));
    final (again, _) = service();
    again.updates.add(_paid(700, userId, charge));
    await again.pollOnce();
    final last = await state(userId);
    expect(last[2], 1);
    expect(last[1], after[1], reason: 'срок Pro не продлён второй раз');
  });

  test('перезапуск между сохранением оплаты и выдачей Pro: после старта Pro выдан ровно один раз', () async {
    if (skip()) return;
    final userId = await newUser();
    final charge = 'charge-crash-${DateTime.now().microsecondsSinceEpoch}';
    charges.add(charge);
    final tg = _FakeTelegram(pool!);
    _CrashAfterSave(pool!, tg, notif(tg));
    tg.updates.add(_paid(800, userId, charge));
    await tg.pollOnce();
    expect(tg.offset, 801);
    expect(await inboxRow(charge), {'status': 'pending', 'attempts': 0, 'error': null});
    expect((await state(userId))[2], 0);

    // Новый процесс: при старте проводит всё сохранённое.
    final tg2 = _FakeTelegram(pool!);
    final restarted = BillingService(pool!, tg2, notif(tg2));
    await restarted.retryInbox();
    final s = await state(userId);
    expect([s[0], s[2]], ['pro', 1]);
    expect((await inboxRow(charge))['status'], 'done');
    expect(tg2.sent.where((m) => m.$2.contains('Pro')), hasLength(1), reason: 'платившему пришло «Pro включён»');

    await restarted.retryInbox();
    expect((await state(userId))[1], s[1]);
  });

  test('перезапуск после выдачи Pro, но до отметки в очереди: повтор не продлевает Pro и не шлёт уведомление второй раз', () async {
    if (skip()) return;
    final userId = await newUser();
    final charge = 'charge-mark-${DateTime.now().microsecondsSinceEpoch}';
    charges.add(charge);
    final (tg, _) = service();
    tg.updates.add(_paid(900, userId, charge));
    await tg.pollOnce();
    final granted = await state(userId);
    expect([granted[0], granted[2]], ['pro', 1]);

    // Отметка «проведено» потерялась (запись снова pending).
    await pool!.execute(Sql.named("UPDATE payment_inbox SET status = 'pending', done_at = NULL WHERE charge_id = @c"), parameters: {'c': charge});
    final tg2 = _FakeTelegram(pool!);
    final restarted = BillingService(pool!, tg2, notif(tg2));
    await restarted.retryInbox();
    final s = await state(userId);
    expect(s[2], 1);
    expect(s[1], granted[1], reason: 'срок Pro тот же');
    expect((await inboxRow(charge))['status'], 'done');
    expect(tg2.sent, isEmpty, reason: 'повторного «Pro включён» нет');
  });

  // CS06 (аудит 08.10): внешний возврат и локальная запись разнесены сохраняемым
  // намерением — сбой между ними доводится повтором ровно один раз.
  Future<(String, DateTime)> paidPro(_FakeTelegram tg, String userId, String charge) async {
    charges.add(charge);
    await tg.onPayment!(4242, const {'id': 4242}, _paid(1, userId, charge)['message']['successful_payment'] as Map<String, dynamic>);
    final r = await pool!.execute(Sql.named('SELECT p.id, u.pro_until FROM payments p JOIN users u ON u.id = p.user_id WHERE p.charge_id = @c'), parameters: {'c': charge});
    return (r.first[0].toString(), r.first[1] as DateTime);
  }

  Future<(String, DateTime?)> refundState(String paymentId) async {
    final r = await pool!.execute(Sql.named('SELECT p.status, u.pro_until FROM payments p JOIN users u ON u.id = p.user_id WHERE p.id = @p'), parameters: {'p': paymentId});
    return (r.first[0] as String, r.first[1] as DateTime?);
  }

  test('CS06: Telegram вернул звёзды, наша запись упала — повтор получает «уже возвращено» и уменьшает Pro ровно один раз', () async {
    if (skip()) return;
    final userId = await newUser();
    final tg = _FakeTelegram(pool!);
    final billing = _CrashOnApply(pool!, tg, notif(tg));
    final (paymentId, until) = await paidPro(tg, userId, 'charge-refund-${DateTime.now().microsecondsSinceEpoch}');

    await expectLater(billing.refund(paymentId), throwsA(isA<StateError>()));
    expect(await refundState(paymentId), ('refund_requested', until), reason: 'намерение сохранено, Pro пока не тронут');
    expect(tg.refundedCharges, hasLength(1), reason: 'звёзды уже у покупателя');

    // Повтор из админки: Telegram отвечает «уже возвращено» — это подтверждение.
    await billing.refund(paymentId);
    final (status, after) = await refundState(paymentId);
    expect(status, 'refunded');
    expect(until.difference(after!).inDays, BillingService(pool!, tg, notif(tg)).proDays, reason: 'срок уменьшен на оплаченный период');
    await expectLater(billing.refund(paymentId), throwsA(isA<ApiError>().having((e) => e.code, 'code', 'already_refunded')));
    expect((await refundState(paymentId)).$2, after, reason: 'второго уменьшения нет');
  });

  test('CS06: перезапуск между Telegram и нашей записью — новый процесс доводит возврат сам; двойное нажатие не уменьшает Pro дважды', () async {
    if (skip()) return;
    final userId = await newUser();
    final tg = _FakeTelegram(pool!);
    final crashed = _CrashOnApply(pool!, tg, notif(tg));
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final (first, until) = await paidPro(tg, userId, 'charge-r1-$stamp');
    await expectLater(crashed.refund(first), throwsA(isA<StateError>()));

    // Новый процесс: через минуту незавершённый возврат доводится по расписанию.
    final restarted = BillingService(pool!, tg, notif(tg));
    await pool!.execute(Sql.named("UPDATE payments SET refund_requested_at = now() - interval '2 minutes' WHERE id = @p"), parameters: {'p': first});
    expect(await restarted.retryRefunds(), 1);
    final (status, after) = await refundState(first);
    expect(status, 'refunded');
    expect(until.difference(after!).inDays, restarted.proDays);
    expect(await restarted.retryRefunds(), 0);

    // Вторая оплата и два одновременных «Вернуть звёзды».
    final (second, before) = await paidPro(tg, userId, 'charge-r2-$stamp');
    // Второе нажатие либо тоже доводит тот же возврат, либо узнаёт, что он уже сделан.
    Future<void> click(BillingService b) => b.refund(second).catchError((Object e) {
          if (e is! ApiError || e.code != 'already_refunded') throw e;
        });
    await Future.wait([click(restarted), click(BillingService(pool!, tg, notif(tg)))]);
    final (status2, after2) = await refundState(second);
    expect(status2, 'refunded');
    expect(before.difference(after2!).inDays, restarted.proDays, reason: 'срок уменьшен один раз');
  });
  test('FV-S02: inbox serializes infinity for missing user alongside a pending payment', () async {
    if (skip()) return;
    final (tg, billing) = service();
    final id = await newUser();
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final missing = 'missing-$suffix', pending = 'pending-$suffix';
    charges.addAll([missing, pending]);
    await billing.receive(123, {'id': 123}, {'telegram_payment_charge_id': missing, 'currency': 'XTR', 'total_amount': 950, 'invoice_payload': 'pro:00000000-0000-0000-0000-000000000001'});
    await pool!.execute(Sql.named("INSERT INTO payment_inbox (charge_id, chat_id, sender, payment) VALUES (@c,123,'{}'::jsonb,@p:jsonb)"),
      parameters: {'c': pending, 'p': {'invoice_payload': 'pro:$id', 'total_amount': 950}});
    final rows = await billing.inbox();
    expect(rows.singleWhere((r) => r['chargeId'] == missing)['nextAt'], isNull);
    expect(rows.singleWhere((r) => r['chargeId'] == pending)['nextAt'], isA<String>());
    expect(tg.sent, isNotEmpty);
  });

  test('billing HTTP response exposes the effective AI service quota', () async {
    if (skip()) return;
    final auth = AuthService(pool!);
    final registered = await auth.register('quota-${DateTime.now().microsecondsSinceEpoch}@example.test', 'Test-pass-12345', 'ru');
    created.add((registered['user'] as Map)['id'] as String);
    final (tg, billing) = service();
    final handler = buildHandler(auth, LedgerService(pool!), notif(tg), AdminService(pool!, password: null),
      telegram: tg, billing: billing, ai: AiService(pool!, ChatModel(apiKey: null), chatQuota: 25));
    final response = await handler(Request('GET', Uri.parse('http://test/billing'), headers: {'authorization': 'Bearer ${registered['token']}'}));
    expect(response.statusCode, 200);
    expect((jsonDecode(await response.readAsString()) as Map)['aiChatQuota'], 25);
  });

}
