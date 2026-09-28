/// Оплата Pro звёздами Telegram (D52).
///
/// Приложение просит ссылку на счёт, Telegram открывает её с кнопкой
/// «Оплатить». Бот подтверждает предоплату, по успешному платежу Pro
/// продлевается на [proDays] дней. Каждый платёж записывается один раз по
/// `telegram_payment_charge_id`. Срок проверяется по расписанию: за две
/// недели — напоминание, по истечении — тариф возвращается к обычному,
/// данные остаются (D06).
library;

import 'dart:async';
import 'dart:io';

import 'package:postgres/postgres.dart';

import 'auth_service.dart';
import 'notifications.dart';
import 'telegram.dart';

class BillingService {
  BillingService(this.db, this.telegram, this.notifications, {int? stars, int? days})
      : proStars = stars ?? 950,
        proDays = days ?? 365 {
    telegram
      ..onPreCheckout = _preCheckout
      ..onPayment = _paid;
  }

  final Pool db;
  final Telegram telegram;
  final NotificationService notifications;

  /// Цена в звёздах и срок в днях. Ориентир в тенге — только подпись:
  /// 950 ⭐ ≈ 10 000 ₸, для другой цены (например, тестовой) — пропорционально.
  final int proStars;
  final int proDays;
  int get priceTenge => (proStars * 10000 / 950).round();
  static const remindDays = 14;

  Timer? _timer;
  bool _busy = false;

  void start() {
    _timer = Timer.periodic(const Duration(minutes: 5), (_) => tick());
  }

  void stop() => _timer?.cancel();

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

  Future<void> _paid(int chatId, Map<String, dynamic> from, Map<String, dynamic> p) async {
    final userId = _userFromPayload(p['invoice_payload']);
    final chargeId = p['telegram_payment_charge_id'] as String?;
    final stars = p['total_amount'] as int? ?? 0;
    if (userId == null || chargeId == null || p['currency'] != 'XTR') {
      stderr.writeln('billing: платёж с неизвестным payload от $chatId');
      return;
    }
    final telegramUserId = from['id'] as int? ?? chatId;

    DateTime? until;
    String locale = 'ru';
    int? linkedChat;
    await db.runTx((tx) async {
      final u = await tx.execute(
        Sql.named('SELECT locale, telegram_chat_id, pro_until FROM users WHERE id = @u FOR UPDATE'),
        parameters: {'u': userId},
      );
      if (u.isEmpty) return;
      locale = u.first[0] as String;
      linkedChat = u.first[1] as int?;
      // Дубль события (Telegram может доставить повторно) — ничего не меняем.
      final dup = await tx.execute(Sql.named('SELECT pro_until FROM payments WHERE charge_id = @c'), parameters: {'c': chargeId});
      if (dup.isNotEmpty) {
        until = dup.first[0] as DateTime;
        return;
      }
      final upd = await tx.execute(
        Sql.named('''
          UPDATE users
          SET plan = 'pro',
              pro_until = GREATEST(coalesce(pro_until, now()), now()) + make_interval(days => @d),
              revision = revision + 1
          WHERE id = @u RETURNING pro_until'''),
        parameters: {'u': userId, 'd': proDays},
      );
      until = upd.first[0] as DateTime;
      await tx.execute(
        Sql.named('''
          INSERT INTO payments (user_id, charge_id, telegram_user_id, stars, period_days, pro_until)
          VALUES (@u, @c, @t, @s, @d, @until)'''),
        parameters: {'u': userId, 'c': chargeId, 't': telegramUserId, 's': stars, 'd': proDays, 'until': until},
      );
    });
    final when = until;
    if (when == null) {
      await telegram.send(chatId, 'Оплата получена, но аккаунт не найден. Напишите в поддержку FamCoin, звёзды вернём.');
      stderr.writeln('billing: оплата $chargeId для несуществующего $userId');
      return;
    }
    final kk = locale == 'kk';
    final date = _date(when);
    final title = kk ? 'Pro қосылды' : 'Pro включён';
    final body = kk ? 'Төлем қабылданды. Pro $date дейін жарамды.' : 'Оплата получена. Pro действует до $date.';
    await notifications.notify(userId, 'system', title, body);
    // notify() уже отправил в привязанный чат; платившему из другого чата — отдельно.
    if (linkedChat != chatId) await telegram.send(chatId, '<b>$title</b>\n$body');
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

  /// Возврат звёзд: платёж помечается, срок Pro уменьшается на оплаченный период.
  Future<void> refund(String paymentId) async {
    final p = await db.execute(
      Sql.named('SELECT user_id, charge_id, telegram_user_id, period_days, status FROM payments WHERE id = @p'),
      parameters: {'p': paymentId},
    );
    if (p.isEmpty) throw ApiError(404, 'not_found');
    if (p.first[4] == 'refunded') throw ApiError(409, 'already_refunded');
    final ok = await telegram.refundStars(telegramUserId: p.first[2] as int, chargeId: p.first[1] as String);
    if (!ok) throw ApiError(502, 'telegram_refund_failed');
    await db.runTx((tx) async {
      await tx.execute(Sql.named("UPDATE payments SET status = 'refunded', refunded_at = now() WHERE id = @p"), parameters: {'p': paymentId});
      await tx.execute(
        Sql.named('''
          UPDATE users SET
            pro_until = pro_until - make_interval(days => @d),
            plan = CASE WHEN pro_until - make_interval(days => @d) > now() THEN 'pro' ELSE 'free' END,
            revision = revision + 1
          WHERE id = @u AND pro_until IS NOT NULL'''),
        parameters: {'u': p.first[0].toString(), 'd': p.first[3] as int},
      );
    });
  }

  static String _date(DateTime t) {
    final l = t.toUtc().add(kzOffset);
    return '${l.day.toString().padLeft(2, '0')}.${l.month.toString().padLeft(2, '0')}.${l.year}';
  }
}
