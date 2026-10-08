/// Оплата Pro звёздами Telegram (D52).
///
/// Приложение просит ссылку на счёт, Telegram открывает её с кнопкой
/// «Оплатить». Бот подтверждает предоплату, по успешному платежу Pro
/// продлевается на [proDays] дней. Каждый платёж записывается один раз по
/// `telegram_payment_charge_id`. Срок проверяется по расписанию: за две
/// недели — напоминание, по истечении — тариф возвращается к обычному,
/// данные остаются (D06).
///
/// Оплата сначала сохраняется в очередь `payment_inbox` и только после этого
/// подтверждается Telegram; Pro выдаётся из очереди с повторами, неудачи видны
/// в админке и приходят оператору (D151).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:postgres/postgres.dart';

import 'auth_service.dart';
import 'notifications.dart';
import 'telegram.dart';

class BillingService {
  BillingService(this.db, this.telegram, this.notifications, {int? stars, int? days, this.adminChat})
      : proStars = stars ?? 950,
        proDays = days ?? 365 {
    telegram
      ..onPreCheckout = _preCheckout
      ..onPayment = receive
      ..onPaymentStuck = (id, n) => _alert('оплату из Telegram (update $id) не удаётся сохранить в базе уже $n раз подряд. '
          'Событие не подтверждено и повторяется — проверьте базу.');
  }

  final Pool db;
  final Telegram telegram;
  final NotificationService notifications;

  /// Чат оператора (TELEGRAM_ADMIN_CHAT) для сигналов о застрявших оплатах.
  final int? adminChat;

  /// После стольких неудачных выдач Pro запись очереди становится «нужен
  /// разбор» (failed) и оператор получает сигнал; повторы идут и дальше, раз в час.
  static const maxInboxAttempts = 10;

  /// Паузы между повторами выдачи (около часа на все попытки до failed).
  static const inboxPauses = [
    Duration(seconds: 30),
    Duration(minutes: 1),
    Duration(minutes: 2),
    Duration(minutes: 5),
    Duration(minutes: 10),
    Duration(minutes: 15),
  ];
  static const failedPause = Duration(hours: 1);

  /// Цена в звёздах и срок в днях. Ориентир в тенге — только подпись:
  /// 950 ⭐ ≈ 10 000 ₸, для другой цены (например, тестовой) — пропорционально.
  final int proStars;
  final int proDays;
  int get priceTenge => (proStars * 10000 / 950).round();
  static const remindDays = 14;

  Timer? _timer;
  Timer? _inboxTimer;
  bool _busy = false;
  bool _retrying = false;

  void start() {
    _timer = Timer.periodic(const Duration(minutes: 5), (_) => tick());
    // Оплаты, сохранённые до перезапуска, но не проведённые, — сразу при старте.
    unawaited(retryInbox());
    _inboxTimer = Timer.periodic(const Duration(seconds: 30), (_) => retryInbox());
  }

  void stop() {
    _timer?.cancel();
    _inboxTimer?.cancel();
  }

  bool get enabled => telegram.enabled;

  // ------------------------------------------------------------ для приложения

  Future<Map<String, Object?>> info(String userId) async {
    final u = await db.execute(Sql.named('SELECT plan, pro_until FROM users WHERE id = @u'), parameters: {'u': userId});
    if (u.isEmpty) throw ApiError(401, 'unauthorized');
    final rows = await db.execute(
      Sql.named('SELECT id, stars, period_days, pro_until, status, created_at FROM payments WHERE user_id = @u ORDER BY created_at DESC LIMIT 20'),
      parameters: {'u': userId},
    );
    return {
      'available': enabled,
      'stars': proStars,
      'days': proDays,
      'priceTenge': priceTenge,
      'plan': u.first[0],
      'proUntil': (u.first[1] as DateTime?)?.toIso8601String(),
      'payments': [
        for (final r in rows)
          {
            'id': r[0].toString(),
            'stars': r[1],
            'days': r[2],
            'proUntil': (r[3] as DateTime).toIso8601String(),
            'status': r[4],
            'createdAt': (r[5] as DateTime).toIso8601String(),
          },
      ],
    };
  }

  /// Ссылка на счёт. Внутри — id пользователя: оплатить может любой чат,
  /// Pro получит именно тот аккаунт, из которого нажали кнопку.
  Future<Map<String, Object?>> invoice(String userId) async {
    if (!enabled) throw ApiError(503, 'telegram_unavailable');
    final u = await db.execute(Sql.named('SELECT locale FROM users WHERE id = @u'), parameters: {'u': userId});
    if (u.isEmpty) throw ApiError(401, 'unauthorized');
    final kk = u.first[0] == 'kk';
    final url = await telegram.createStarsInvoice(
      title: kk ? 'FamCoin Pro — 1 жыл' : 'FamCoin Pro — 1 год',
      description: kk
          ? 'Бірнеше шот, қосымша лимиттер мен мақсаттар, кеңейтілген есептер. Бір реттік төлем, автоұзартусыз.'
          : 'Несколько счетов, дополнительные лимиты и цели, расширенные отчёты. Разовый платёж, без автопродления.',
      payload: 'pro:$userId',
      stars: proStars,
      label: kk ? 'Pro, 1 жыл' : 'Pro, 1 год',
    );
    if (url == null) throw ApiError(503, 'telegram_unavailable');
    return {'url': url, 'stars': proStars, 'days': proDays};
  }

  /// Та же ссылка для кнопки в чате бота; `null` — оплата не подключена.
  Future<String?> proLink(String userId) async {
    try {
      return (await invoice(userId))['url'] as String?;
    } on ApiError {
      return null;
    }
  }

  // ------------------------------------------------------------------ бот

  /// Payload вида `pro:<uuid>`; иначе счёт не наш.
  String? _userFromPayload(Object? payload) {
    final m = RegExp(r'^pro:([0-9a-f-]{36})$').firstMatch('$payload');
    return m?[1];
  }

  Future<String?> _preCheckout(Map<String, dynamic> q) async {
    final userId = _userFromPayload(q['invoice_payload']);
    if (userId == null || q['currency'] != 'XTR') return 'Этот счёт не относится к FamCoin.';
    if (q['total_amount'] != proStars) return 'Цена изменилась. Откройте счёт в приложении заново.';
    final u = await db.execute(Sql.named('SELECT 1 FROM users WHERE id = @u'), parameters: {'u': userId});
    if (u.isEmpty) return 'Аккаунт не найден. Войдите в FamCoin и нажмите кнопку ещё раз.';
    return null;
  }

  /// Успешная оплата из Telegram. Сначала событие сохраняется в очередь
  /// `payment_inbox`: исключение здесь значит «не сохранено», Telegram не
  /// получит подтверждения и пришлёт оплату снова. Потом Pro выдаётся из
  /// очереди; сбой выдачи оплату уже не теряет — запись остаётся в очереди с
  /// ошибкой и повторяется ([retryInbox]).
  Future<void> receive(int chatId, Map<String, dynamic> from, Map<String, dynamic> p) async {
    final chargeId = p['telegram_payment_charge_id'] as String?;
    if (chargeId == null) {
      stderr.writeln('billing: оплата без charge_id от $chatId: ${jsonEncode(p)}');
      return;
    }
    final ours = _userFromPayload(p['invoice_payload']) != null && p['currency'] == 'XTR';
    final saved = await db.execute(
      Sql.named('''
        INSERT INTO payment_inbox (charge_id, chat_id, sender, payment, status, last_error, next_at)
        VALUES (@c, @chat, @from:jsonb, @p:jsonb, @st, @err, CASE WHEN @st = 'failed' THEN 'infinity'::timestamptz ELSE now() END)
        ON CONFLICT (charge_id) DO NOTHING
        RETURNING 1'''),
      parameters: {
        'c': chargeId,
        'chat': chatId,
        'from': from,
        'p': p,
        'st': ours ? 'pending' : 'failed',
        'err': ours ? null : 'счёт не FamCoin Pro',
      },
    );
    if (!ours) {
      if (saved.isNotEmpty) await _alert('оплата $chargeId от чата $chatId по чужому счёту (${p['invoice_payload']}, ${p['currency']}) — разберите в админке, звёзды, видимо, нужно вернуть.');
      return;
    }
    await _processSafely(chargeId);
  }

  /// Выдаёт Pro по сохранённой оплате. Ошибка записывается в очередь (попытки,
  /// текст, время следующего повтора), наружу не уходит.
  Future<void> _processSafely(String chargeId) async {
    try {
      await process(chargeId);
    } catch (e, st) {
      stderr.writeln('billing: оплата $chargeId не проведена: ${e.runtimeType}\n$st');
      try {
        await _failed(chargeId, e);
      } catch (_) {
        // База недоступна: запись осталась как была и придёт в retryInbox.
      }
    }
  }

  Future<void> _failed(String chargeId, Object e) async {
    final r = await db.execute(
      Sql.named('''
        UPDATE payment_inbox SET
          attempts = attempts + 1,
          last_error = left(@e, 500),
          status = CASE WHEN attempts + 1 >= @max THEN 'failed' ELSE status END,
          next_at = now() + make_interval(secs => CASE WHEN attempts + 1 >= @max THEN @late ELSE (@pauses::int[])[least(attempts + 1, @n)] END)
        WHERE charge_id = @c AND status <> 'done'
        RETURNING attempts'''),
      parameters: {
        'c': chargeId,
        'e': '${e.runtimeType}: $e',
        'max': maxInboxAttempts,
        'late': failedPause.inSeconds,
        'pauses': [for (final d in inboxPauses) d.inSeconds],
        'n': inboxPauses.length,
      },
    );
    if (r.isNotEmpty && r.first[0] == maxInboxAttempts) {
      await _alert('оплату $chargeId не удаётся провести уже $maxInboxAttempts раз (${e.runtimeType}). '
          'Pro не выдан; повтор раз в час, вручную — «Повторить» в админке, раздел «Платежи».');
    }
  }

  /// Проводит одну сохранённую оплату. Платёж, продление Pro и отметка `done`
  /// в очереди — одна транзакция: перезапуск в любом месте оставляет либо
  /// непроведённую запись, либо проведённую целиком, а повтор проведённой
  /// ничего не меняет (дубль по `charge_id`).
  Future<void> process(String chargeId) async {
    late final int chatId;
    ProGrant? granted;
    String? userId;
    var missing = false;
    await db.runTx((tx) async {
      final row = await tx.execute(
        Sql.named("SELECT chat_id, sender, payment FROM payment_inbox WHERE charge_id = @c AND status <> 'done' FOR UPDATE"),
        parameters: {'c': chargeId},
      );
      if (row.isEmpty) return;
      chatId = row.first[0] as int;
      final from = Map<String, dynamic>.from(row.first[1] as Map);
      final p = Map<String, dynamic>.from(row.first[2] as Map);
      userId = _userFromPayload(p['invoice_payload']);
      final g = await grant(
        tx,
        userId: userId!,
        chargeId: chargeId,
        telegramUserId: from['id'] as int? ?? chatId,
        stars: p['total_amount'] as int? ?? 0,
      );
      if (g == null) {
        missing = true;
        await tx.execute(
          Sql.named("UPDATE payment_inbox SET status = 'failed', last_error = 'аккаунт не найден', next_at = 'infinity' WHERE charge_id = @c"),
          parameters: {'c': chargeId},
        );
        return;
      }
      granted = g;
      await tx.execute(
        Sql.named("UPDATE payment_inbox SET status = 'done', done_at = now(), last_error = NULL WHERE charge_id = @c"),
        parameters: {'c': chargeId},
      );
    });
    if (missing) {
      await telegram.send(chatId, 'Оплата получена, но аккаунт не найден. Напишите в поддержку FamCoin, звёзды вернём.');
      await _alert('оплата $chargeId для несуществующего аккаунта $userId — нужен возврат звёзд.');
      return;
    }
    final g = granted;
    if (g == null || !g.fresh) return;
    // Pro уже выдан и записан; сбой уведомления оплату не откатывает.
    try {
      final kk = g.locale == 'kk';
      final date = _date(g.until);
      final title = kk ? 'Pro қосылды' : 'Pro включён';
      final body = kk ? 'Төлем қабылданды. Pro $date дейін жарамды.' : 'Оплата получена. Pro действует до $date.';
      await notifications.notify(userId!, 'system', title, body);
      // notify() уже отправил в привязанный чат; платившему из другого чата — отдельно.
      if (g.linkedChat != chatId) await telegram.send(chatId, '<b>$title</b>\n$body');
    } catch (e, st) {
      stderr.writeln('billing: Pro по оплате $chargeId выдан, уведомление не ушло: ${e.runtimeType}\n$st');
    }
  }

  /// Продление Pro и запись платежа внутри транзакции [tx]. `null` — аккаунта
  /// нет. Если платёж с этим `charge_id` уже есть, ничего не меняет
  /// (`fresh: false`).
  Future<ProGrant?> grant(TxSession tx, {required String userId, required String chargeId, required int telegramUserId, required int stars}) async {
    final u = await tx.execute(
      Sql.named('SELECT locale, telegram_chat_id FROM users WHERE id = @u FOR UPDATE'),
      parameters: {'u': userId},
    );
    if (u.isEmpty) return null;
    final locale = u.first[0] as String;
    final linkedChat = u.first[1] as int?;
    final dup = await tx.execute(Sql.named('SELECT pro_until FROM payments WHERE charge_id = @c'), parameters: {'c': chargeId});
    if (dup.isNotEmpty) return ProGrant(dup.first[0] as DateTime, locale, linkedChat, fresh: false);
    final upd = await tx.execute(
      Sql.named('''
        UPDATE users
        SET plan = 'pro',
            pro_until = GREATEST(coalesce(pro_until, now()), now()) + make_interval(days => @d),
            revision = revision + 1
        WHERE id = @u RETURNING pro_until'''),
      parameters: {'u': userId, 'd': proDays},
    );
    final until = upd.first[0] as DateTime;
    await tx.execute(
      Sql.named('''
        INSERT INTO payments (user_id, charge_id, telegram_user_id, stars, period_days, pro_until)
        VALUES (@u, @c, @t, @s, @d, @until)'''),
      parameters: {'u': userId, 'c': chargeId, 't': telegramUserId, 's': stars, 'd': proDays, 'until': until},
    );
    return ProGrant(until, locale, linkedChat, fresh: true);
  }

  /// Повтор непроведённых оплат, у которых подошло время: при старте сервера
  /// и каждые 30 секунд. Возвращает, сколько записей взято.
  Future<int> retryInbox() async {
    if (_retrying) return 0;
    _retrying = true;
    try {
      final rows = await db.execute(
        "SELECT charge_id FROM payment_inbox WHERE status <> 'done' AND next_at <= now() ORDER BY received_at LIMIT 20",
      );
      for (final r in rows) {
        await _processSafely(r[0] as String);
      }
      return rows.length;
    } catch (e, st) {
      stderr.writeln('billing: очередь оплат: ${e.runtimeType}\n$st');
      return 0;
    } finally {
      _retrying = false;
    }
  }

  Future<void> _alert(String text) async {
    stderr.writeln('billing: ОПЕРАТОРУ: $text');
    final chat = adminChat;
    if (chat == null) return;
    try {
      await telegram.send(chat, '⚠️ FamCoin, оплата Pro: $text');
    } catch (_) {}
  }

  // ---------------------------------------------------------------- сроки

  /// Раз в 5 минут: снять истёкший Pro, напомнить за две недели.
  Future<void> tick() async {
    if (_busy) return;
    _busy = true;
    try {
      final expired = await db.execute('''
        UPDATE users SET plan = 'free', revision = revision + 1
        WHERE plan = 'pro' AND pro_until IS NOT NULL AND pro_until < now()
        RETURNING id, locale''');
      for (final r in expired) {
        final kk = r[1] == 'kk';
        await notifications.notify(
          r[0].toString(),
          'system',
          kk ? 'Pro мерзімі аяқталды' : 'Срок Pro закончился',
          kk
              ? 'Деректер сақталды: артық шоттар мен лимиттер тарихта қалады. Pro-ны «Тариф» бөлімінде қайта қосуға болады.'
              : 'Данные сохранены: лишние счета и лимиты остаются в истории. Вернуть Pro можно в разделе «Тариф».',
        );
      }
      final soon = await db.execute(
        Sql.named('''
          UPDATE users SET notif = notif || jsonb_build_object('proReminded', pro_until::text)
          WHERE plan = 'pro' AND pro_until IS NOT NULL
            AND pro_until < now() + make_interval(days => @d)
            AND coalesce(notif->>'proReminded', '') <> pro_until::text
          RETURNING id, locale, pro_until'''),
        parameters: {'d': remindDays},
      );
      for (final r in soon) {
        final kk = r[1] == 'kk';
        final date = _date(r[2] as DateTime);
        await notifications.notify(
          r[0].toString(),
          'system',
          kk ? 'Pro жақында аяқталады' : 'Pro скоро закончится',
          kk
              ? 'Pro $date дейін жарамды. «Тариф» бөлімінде тағы бір жылға ұзартуға болады.'
              : 'Pro действует до $date. Продлить ещё на год можно в разделе «Тариф».',
        );
      }
      // Последним: сбой здесь не должен помешать напоминаниям выше.
      await retryRefunds();
    } catch (e, st) {
      stderr.writeln('billing: ${e.runtimeType}\n$st');
    } finally {
      _busy = false;
    }
  }

  // --------------------------------------------------------------- админка

  Future<List<Map<String, Object?>>> all() async {
    final rows = await db.execute('''
      SELECT p.id, u.email, p.stars, p.period_days, p.pro_until, p.status, p.created_at, p.refunded_at, p.charge_id
      FROM payments p JOIN users u ON u.id = p.user_id
      ORDER BY p.created_at DESC LIMIT 200''');
    return [
      for (final r in rows)
        {
          'id': r[0].toString(),
          'email': r[1],
          'stars': r[2],
          'days': r[3],
          'proUntil': (r[4] as DateTime).toIso8601String(),
          'status': r[5],
          'createdAt': (r[6] as DateTime).toIso8601String(),
          'refundedAt': (r[7] as DateTime?)?.toIso8601String(),
          'chargeId': r[8],
        },
    ];
  }

  /// Непроведённые оплаты для админки: ждут повтора (pending) или нужен
  /// разбор (failed). Пользователь — по счёту `pro:<id>`.
  Future<List<Map<String, Object?>>> inbox() async {
    final rows = await db.execute('''
      SELECT i.charge_id, i.status, i.attempts, i.last_error, i.received_at, i.next_at, i.chat_id,
             (i.payment->>'total_amount')::int, u.email
      FROM payment_inbox i
      LEFT JOIN users u ON u.id::text = substring(i.payment->>'invoice_payload' from 5)
      WHERE i.status <> 'done'
      ORDER BY i.received_at DESC LIMIT 200''');
    return [
      for (final r in rows)
        {
          'chargeId': r[0],
          'status': r[1],
          'attempts': r[2],
          'lastError': r[3],
          'receivedAt': (r[4] as DateTime).toIso8601String(),
          'nextAt': (r[5] as DateTime).toIso8601String(),
          'chatId': r[6],
          'stars': r[7],
          'email': r[8],
        },
    ];
  }

  /// «Повторить» из админки: провести оплату сейчас. Возвращает статус после попытки.
  Future<String> retry(String chargeId) async {
    final r = await db.execute(
      Sql.named("UPDATE payment_inbox SET next_at = now() WHERE charge_id = @c AND status <> 'done' RETURNING 1"),
      parameters: {'c': chargeId},
    );
    if (r.isEmpty) throw ApiError(404, 'not_found');
    await _processSafely(chargeId);
    final s = await db.execute(Sql.named('SELECT status FROM payment_inbox WHERE charge_id = @c'), parameters: {'c': chargeId});
    return s.first[0] as String;
  }

  /// Возврат звёзд (CS06): сначала сохраняется намерение (`refund_requested`),
  /// потом Telegram возвращает звёзды, потом платёж помечается возвращённым и
  /// срок Pro уменьшается на оплаченный период — ровно один раз ([applyRefund]).
  /// Если сбой случился между Telegram и нашей записью, повтор (кнопка ещё раз
  /// или [retryRefunds]) получает от Telegram «уже возвращено» и доводит
  /// локальную часть; ответ 200 на повтор не считается новым возвратом.
  Future<void> refund(String paymentId) async {
    final p = await db.execute(
      Sql.named('SELECT user_id, charge_id, telegram_user_id, period_days, status FROM payments WHERE id = @p'),
      parameters: {'p': paymentId},
    );
    if (p.isEmpty) throw ApiError(404, 'not_found');
    if (p.first[4] == 'refunded') throw ApiError(409, 'already_refunded');
    await db.execute(
      Sql.named("UPDATE payments SET status = 'refund_requested', refund_requested_at = now() WHERE id = @p AND status = 'paid'"),
      parameters: {'p': paymentId},
    );
    final outcome = await telegram.refundStars(telegramUserId: p.first[2] as int, chargeId: p.first[1] as String);
    if (outcome == RefundOutcome.failed) throw ApiError(502, 'telegram_refund_failed');
    await applyRefund(paymentId);
  }

  /// Локальная часть подтверждённого возврата: переход `refund_requested` →
  /// `refunded` и уменьшение срока Pro одной транзакцией. Повтор ничего не
  /// меняет (`false`).
  Future<bool> applyRefund(String paymentId) => db.runTx((tx) async {
        final r = await tx.execute(
          Sql.named("UPDATE payments SET status = 'refunded', refunded_at = now() WHERE id = @p AND status = 'refund_requested' RETURNING user_id, period_days"),
          parameters: {'p': paymentId},
        );
        if (r.isEmpty) return false;
        await tx.execute(
          Sql.named('''
            UPDATE users SET
              pro_until = pro_until - make_interval(days => @d),
              plan = CASE WHEN pro_until - make_interval(days => @d) > now() THEN 'pro' ELSE 'free' END,
              revision = revision + 1
            WHERE id = @u AND pro_until IS NOT NULL'''),
          parameters: {'u': r.first[0].toString(), 'd': r.first[1] as int},
        );
        return true;
      });

  /// Доводит возвраты, запрошенные больше минуты назад и не завершённые (сбой
  /// или перезапуск между Telegram и нашей записью). Раз в 5 минут.
  Future<int> retryRefunds() async {
    final rows = await db.execute("SELECT id FROM payments WHERE status = 'refund_requested' AND refund_requested_at < now() - interval '1 minute' LIMIT 20");
    for (final r in rows) {
      try {
        await refund(r[0].toString());
      } catch (e) {
        stderr.writeln('billing: возврат ${r[0]} не доведён: ${e is ApiError ? e.code : e.runtimeType}');
      }
    }
    return rows.length;
  }

  static String _date(DateTime t) {
    final l = t.toUtc().add(kzOffset);
    return '${l.day.toString().padLeft(2, '0')}.${l.month.toString().padLeft(2, '0')}.${l.year}';
  }
}

/// Итог выдачи Pro по одной оплате.
class ProGrant {
  ProGrant(this.until, this.locale, this.linkedChat, {required this.fresh});

  final DateTime until;
  final String locale;
  final int? linkedChat;

  /// Платёж записан сейчас; `false` — он уже был проведён раньше.
  final bool fresh;
}
