/// Уведомления: расписание сводок, хранение, доставка в Telegram.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:famcoin_core/famcoin_core.dart';
import 'package:postgres/postgres.dart';

import 'auth_service.dart';
import 'briefs.dart';
import 'ledger_service.dart';
import 'telegram.dart';
import 'webpush.dart';

/// Казахстан с 2024 года живёт по единому времени UTC+5.
const kzOffset = Duration(hours: 5);
const morningHour = 8;
const eveningHour = 21;

/// Сколько сводок берём за одну минутную проверку и сколько шлём одновременно.
const batchSize = 500;
const concurrency = 8;

/// Напоминание закрыть месяц (D75): со скольки часов и в какие дни месяца.
const monthHour = 9;
const monthWindowDays = 10;

/// Внешняя доставка уведомления (Telegram, push) после неудачи: паузы между
/// повторами и сколько попыток до «не доставлено» (в приложении оно есть всё равно).
const deliverPauses = [Duration(minutes: 1), Duration(minutes: 5), Duration(minutes: 15), Duration(hours: 1)];
const maxDeliverAttempts = 8;

class NotificationService {
  NotificationService(this.db, this.ledger, this.telegram, this.push, {this.origin});

  final Pool db;
  final LedgerService ledger;
  final Telegram telegram;
  final WebPush push;

  /// Адрес сайта (https://…) для ссылки из Telegram; без него ссылки нет.
  final String? origin;
  Timer? _timer;
  bool _busy = false;

  void start() {
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => _tick());
  }

  void stop() => _timer?.cancel();

  Future<void> _tick() async {
    if (_busy) return;
    _busy = true;
    try {
      final now = DateTime.now().toUtc().add(kzOffset);
      if (now.hour >= morningHour && now.hour < eveningHour) await runBriefs('morning', now);
      if (now.hour >= eveningHour) await runBriefs('evening', now);
      if (now.hour >= monthHour) await runMonth(now);
      await retryDeliveries();
    } catch (e, st) {
      stderr.writeln('notifications: ${e.runtimeType}\n$st');
    } finally {
      _busy = false;
    }
  }

  /// Отправляет сводку тем, кому она включена и сегодня ещё не отправлялась.
  Future<void> runBriefs(String kind, DateTime now) async {
    final today = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final flag = kind == 'morning' ? 'sentMorning' : 'sentEvening';
    final users = await db.execute(
      Sql.named('''
        SELECT id FROM users
        WHERE (profile->>'onboarded') = 'true'
          AND coalesce((notif->>@kind)::boolean, true)
          AND coalesce(notif->>@flag, '') <> @today
        LIMIT $batchSize'''),
      parameters: {'kind': kind, 'flag': flag, 'today': today},
    );
    // По нескольку человек одновременно: последовательная отправка 1000
    // сводок (запрос к базе, Telegram, push) растягивалась бы на минуты.
    final ids = [for (final r in users) r[0].toString()];
    for (var i = 0; i < ids.length; i += concurrency) {
      await Future.wait([for (final id in ids.skip(i).take(concurrency)) deliverBrief(kind, now, id)]);
    }
  }

  /// Отметка «сегодня отправлено» ставится той же транзакцией, что запись
  /// уведомления (CS05): сбой при подготовке сводки оставляет её неотмеченной,
  /// и следующая минутная проверка повторит её, а не потеряет.
  Future<void> deliverBrief(String kind, DateTime now, String userId) async {
    final today = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final flag = kind == 'morning' ? 'sentMorning' : 'sentEvening';
    try {
      await sendBrief(userId, kind, DateTime(now.year, now.month, now.day), dedupKey: '$kind:$today', mark: (flag: flag, value: today))
          .timeout(const Duration(seconds: 90));
    } catch (e) {
      stderr.writeln('brief $kind for $userId: ${e.runtimeType}');
    }
  }

  /// Подготовка за 3 дня / за день и одно напоминание после конца месяца.
  /// У каждой стадии своя метка; атомарный захват защищает от двух обработчиков.
  Future<void> runMonth(DateTime now) async {
    if (now.hour < monthHour) return;
    final preparation = monthPreparationDays(now);
    if (preparation == null && now.day > monthWindowDays) return;
    final month = preparation == null ? previousMonth(now) : DateTime(now.year, now.month, 1);
    final key = monthKey(month);
    final flag = preparation == null ? 'sentMonth' : 'sentMonthPrepare$preparation';
    final users = await db.execute(
      Sql.named('''
        SELECT u.id FROM users u
        WHERE (u.profile->>'onboarded') = 'true'
          AND coalesce((u.notif->>'month')::boolean, true)
          AND coalesce(u.notif->>@flag, '') <> @key
          AND NOT EXISTS (SELECT 1 FROM month_reconciliations r
            WHERE r.user_id = u.id AND r.month = @from::date AND r.invalidated_at IS NULL)
          AND (EXISTS (
            SELECT 1 FROM transactions t
            WHERE t.user_id = u.id AND t.type <> 'reversal'
              AND t.date >= @from::date AND t.date < @to::date
              AND EXISTS (SELECT 1 FROM postings p WHERE p.user_id = t.user_id AND p.tx_id = t.id)
              AND NOT EXISTS (SELECT 1 FROM transactions rev WHERE rev.user_id = t.user_id AND rev.reverses = t.id))
            OR EXISTS (SELECT 1 FROM month_reconciliations r WHERE r.user_id = u.id AND r.month = @from::date AND r.invalidated_at IS NOT NULL))
        LIMIT $batchSize'''),
      parameters: {'key': key, 'flag': flag, 'from': _day(month), 'to': _day(DateTime(month.year, month.month + 1, 1))},
    );
    final ids = [for (final r in users) r[0].toString()];
    for (var i = 0; i < ids.length; i += concurrency) {
      await Future.wait([for (final id in ids.skip(i).take(concurrency)) deliverMonthNudge(id, month, key, flag, preparation)]);
    }
  }

  static String _day(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// Как у сводок (CS05): отметка стадии — вместе с записью уведомления, ключ
  /// `стадия:месяц` не даёт двум обработчикам записать его дважды.
  Future<void> deliverMonthNudge(String userId, DateTime month, String key, String flag, int? preparation) async {
    try {
      await sendMonthNudge(userId, month, preparationDays: preparation, dedupKey: '$flag:$key', mark: (flag: flag, value: key))
          .timeout(const Duration(seconds: 90));
    } catch (e) {
      stderr.writeln('month nudge for $userId: ${e.runtimeType}');
    }
  }

  /// Предпросмотр никогда не предлагает закрыть незавершённый месяц.
  Future<void> sendMonthNudgePreview(String userId, DateTime now) => sendMonthNudge(userId, previousMonth(now), preview: true);

  /// Уведомление «Сверьте <месяц>»: итоги коротко, ссылка открывает сверку в приложении.
  Future<void> sendMonthNudge(String userId, DateTime month, {int? preparationDays, bool preview = false, String? dedupKey, ({String flag, String value})? mark}) async {
    final s = await ledger.state(userId);
    // Пока уведомление готовилось, пользователь мог завершить сверку.
    // state также восстанавливает ложные отметки старого алгоритма.
    if (!preview && preparationDays == null && (s['monthReconciliations'] as List).cast<Map>().any(
        (r) => r['month'] == _day(month) && r['invalidatedAt'] == null)) {
      if (mark != null) await _mark(userId, mark);
      return;
    }
    final r = _ledgerOf(s).report(month, DateTime(month.year, month.month + 1, 1));
    final locale = s['locale'] as String? ?? 'ru';
    final brief = preparationDays == null
        ? monthNudge(month: month, income: r.income, expense: r.total, locale: locale)
        : monthPreparation(month: month, days: preparationDays, locale: locale);
    await notify(userId, 'system', brief.title, brief.body, openQuery: 'close=${monthKey(month)}', dedupKey: dedupKey, mark: mark);
  }

  Future<void> _mark(String userId, ({String flag, String value}) mark) => db.execute(
        Sql.named('UPDATE users SET notif = notif || jsonb_build_object(@flag::text, @v::text) WHERE id = @u'),
        parameters: {'flag': mark.flag, 'v': mark.value, 'u': userId},
      );

  Future<void> sendBrief(String userId, String kind, DateTime today, {String? dedupKey, ({String flag, String value})? mark}) async {
    final s = await ledger.state(userId);
    final l = _ledgerOf(s);
    final entities = (s['entities'] as List).cast<Map<String, dynamic>>();
    // id записи нужен сроку возврата личного долга: части к сроку ищутся по нему (N01).
    List<Map<String, dynamic>> ofKind(String k) => [for (final e in entities) if (e['kind'] == k) {...Map<String, dynamic>.from(e['data'] as Map), 'id': e['id']}];
    final preferences = await settings(userId);
    final input = BriefInput(
      monthRemindersEnabled: preferences['month'] != false,
      ledger: l,
      today: today,
      profile: Map<String, dynamic>.from(s['profile'] as Map? ?? const {}),
      // Разовые покупки (D88) напоминают о себе так же, как платежи.
      planned: [...ofKind('planned'), ...ofKind('purchase')],
      limits: ofKind('limit'),
      locale: s['locale'] as String? ?? 'ru',
      categories: {for (final e in entities) if (e['kind'] == 'category') e['id'] as String: Map<String, dynamic>.from(e['data'] as Map)},
      debts: {for (final e in entities) if (e['kind'] == 'debt') e['id'] as String: Map<String, dynamic>.from(e['data'] as Map)},
    );
    final brief = kind == 'morning' ? morningBrief(input) : eveningBrief(input);
    await notify(userId, kind, brief.title, brief.body, dedupKey: dedupKey, mark: mark);
  }

  Ledger _ledgerOf(Map<String, Object?> s) => ledgerFromSnapshot(
        accounts: (s['accounts'] as List).cast(),
        transactions: (s['transactions'] as List).cast(),
        reservations: (s['reservations'] as List).cast(),
      );

  /// Сохраняет уведомление, затем доставляет его в Telegram (если привязан)
  /// и push. [openQuery] — что приложению открыть по нажатию, например
  /// `close=2026-09`: push ведёт на `./?close=2026-09`, в Telegram уходит ссылка
  /// на сайт.
  ///
  /// Сначала запись в приложении, потом внешние каналы (CS05): сбой Telegram или
  /// push оставляет уведомление в приложении, а доставка повторяется сама
  /// ([retryDeliveries]) — каждым каналом отдельно, уже доставленный не
  /// дублируется. С [dedupKey] уведомление записывается один раз на ключ:
  /// второй обработчик или перезапуск ничего не добавляют. [mark] — отметка в
  /// `users.notif`, которая ставится той же транзакцией, что запись. `false` —
  /// такое уведомление уже было.
  Future<bool> notify(String userId, String kind, String title, String body, {String? openQuery, String? dedupKey, ({String flag, String value})? mark}) async {
    final id = await db.runTx((tx) async {
      final r = await tx.execute(
        Sql.named('''
          INSERT INTO notifications (user_id, kind, title, body, open_query, dedup_key, deliver_status)
          VALUES (@u, @k, @t, @b, @q, @d, 'pending')
          ON CONFLICT (user_id, dedup_key) WHERE dedup_key IS NOT NULL DO NOTHING
          RETURNING id'''),
        parameters: {'u': userId, 'k': kind, 't': title, 'b': body, 'q': openQuery, 'd': dedupKey},
      );
      if (mark != null) {
        await tx.execute(
          Sql.named('UPDATE users SET notif = notif || jsonb_build_object(@flag::text, @v::text) WHERE id = @u'),
          parameters: {'flag': mark.flag, 'v': mark.value, 'u': userId},
        );
      }
      return r.isEmpty ? null : r.first[0].toString();
    });
    if (id == null) return false;
    await deliver(id);
    return true;
  }

  /// Внешняя доставка одного сохранённого уведомления: недоставленные каналы
  /// по очереди. Не бросает: итог пишется в запись (попытки, ошибка, время
  /// следующего повтора; после [maxDeliverAttempts] — «не доставлено»).
  Future<void> deliver(String id) async {
    Timer? heartbeat;
    try {
      final rows = await db.execute(
        Sql.named('''
          WITH claimed AS (
            UPDATE notifications SET deliver_token = gen_random_uuid(), deliver_lease_until = now() + interval '2 minutes'
            WHERE id = @id AND deliver_status = 'pending' AND deliver_next_at <= now()
              AND (deliver_lease_until IS NULL OR deliver_lease_until <= now())
            RETURNING *
          )
          SELECT n.user_id, n.kind, n.title, n.body, n.open_query, n.tg_done, n.push_done, u.telegram_chat_id, n.deliver_token
          FROM claimed n JOIN users u ON u.id = n.user_id '''),
        parameters: {'id': id},
      );
      if (rows.isEmpty) return;
      final r = rows.first;
      final userId = r[0].toString();
      final kind = r[1] as String, title = r[2] as String, body = r[3] as String, openQuery = r[4] as String?;
      var tgDone = r[5] == true, pushDone = r[6] == true;
      final chatId = r[7] as int?;
      final token = r[8].toString();
      var renewing = false;
      heartbeat = Timer.periodic(const Duration(seconds: 30), (_) async {
        if (renewing) return;
        renewing = true;
        try {
          await db.execute(
            Sql.named("UPDATE notifications SET deliver_lease_until = now() + interval '2 minutes' WHERE id = @id AND deliver_token = @token"),
            parameters: {'id': id, 'token': token},
          );
        } catch (_) {
          // При падении процесса аренда истечёт, и запись подберёт другой worker.
        } finally { renewing = false; }
      });
      Future<bool> saveChannels() async {
        final saved = await db.execute(
          Sql.named('UPDATE notifications SET tg_done = tg_done OR @tg, push_done = push_done OR @push WHERE id = @id AND deliver_token = @token RETURNING id'),
          parameters: {'id': id, 'token': token, 'tg': tgDone, 'push': pushDone},
        );
        return saved.isNotEmpty;
      }
      String? error;
      if (!tgDone) {
        if (chatId == null || !telegram.enabled) {
          tgDone = true; // некуда — не ошибка
        } else {
          final site = origin;
          final link = openQuery != null && site != null && site.startsWith('https://') ? '\n$site/?$openQuery' : '';
          try {
            tgDone = await telegram.send(chatId, '<b>$title</b>\n$body$link');
          } catch (e) {
            tgDone = false;
          }
          if (!tgDone) error = 'telegram';
        }
      }
      if (!await saveChannels()) return;
      if (!pushDone) {
        try {
          pushDone = await push.sendToUser(userId, title, body.replaceAll(RegExp(r'</?b>'), ''), tag: kind, url: openQuery == null ? null : './?$openQuery');
        } catch (e) {
          pushDone = false;
        }
        if (!pushDone) error = error == null ? 'push' : '$error, push';
      }
      if (!await saveChannels()) return;
      final done = tgDone && pushDone;
      await db.execute(
        Sql.named('''
          UPDATE notifications SET
            tg_done = tg_done OR @tg, push_done = push_done OR @push, deliver_error = @e,
            deliver_token = NULL, deliver_lease_until = NULL,
            deliver_attempts = deliver_attempts + CASE WHEN @ok THEN 0 ELSE 1 END,
            deliver_status = CASE WHEN @ok THEN 'done' WHEN deliver_attempts + 1 >= @max THEN 'failed' ELSE 'pending' END,
            deliver_next_at = now() + make_interval(secs => (@pauses::int[])[least(deliver_attempts + 1, @n)])
          WHERE id = @id AND deliver_token = @token'''),
        parameters: {
          'id': id,
          'token': token,
          'tg': tgDone,
          'push': pushDone,
          'e': error,
          'ok': done,
          'max': maxDeliverAttempts,
          'pauses': [for (final d in deliverPauses) d.inSeconds],
          'n': deliverPauses.length,
        },
      );
    } catch (e, st) {
      stderr.writeln('notification delivery $id: ${e.runtimeType}\n$st');
    } finally {
      heartbeat?.cancel();
    }
  }

  /// Повтор внешней доставки уведомлений, у которых подошло время: каждую
  /// минуту и после перезапуска. Возвращает, сколько записей взято.
  Future<int> retryDeliveries() async {
    final rows = await db.execute("SELECT id FROM notifications WHERE deliver_status = 'pending' AND deliver_next_at <= now() AND (deliver_lease_until IS NULL OR deliver_lease_until <= now()) ORDER BY deliver_next_at LIMIT 200");
    for (var i = 0; i < rows.length; i += concurrency) {
      await Future.wait([for (final r in rows.skip(i).take(concurrency)) deliver(r[0].toString())]);
    }
    return rows.length;
  }

  Future<List<Map<String, Object?>>> list(String userId, {int limit = 50}) async {
    final rows = await db.execute(
      Sql.named('SELECT id, kind, title, body, created_at, read_at FROM notifications WHERE user_id = @u ORDER BY created_at DESC LIMIT @n'),
      parameters: {'u': userId, 'n': limit},
    );
    return [
      for (final r in rows)
        {'id': r[0].toString(), 'kind': r[1], 'title': r[2], 'body': r[3], 'createdAt': (r[4] as DateTime).toIso8601String(), 'read': r[5] != null},
    ];
  }

  Future<void> markRead(String userId) => db.execute(
        Sql.named('UPDATE notifications SET read_at = now() WHERE user_id = @u AND read_at IS NULL'),
        parameters: {'u': userId},
      );

  Future<Map<String, Object?>> settings(String userId) async {
    final r = await db.execute(Sql.named('SELECT notif, telegram_chat_id IS NOT NULL FROM users WHERE id = @u'), parameters: {'u': userId});
    if (r.isEmpty) throw ApiError(401, 'unauthorized');
    final notif = Map<String, dynamic>.from(r.first[0] as Map);
    return {
      'morning': notif['morning'] != false,
      'evening': notif['evening'] != false,
      'month': notif['month'] != false,
      'telegramLinked': r.first[1] == true,
      'telegramAvailable': telegram.enabled,
      'pushDevices': await push.deviceCount(userId),
    };
  }

  Future<void> updateSettings(String userId, Map<String, dynamic> body) async {
    final patch = <String, Object?>{};
    for (final k in ['morning', 'evening', 'month']) {
      if (body[k] is bool) patch[k] = body[k];
    }
    if (patch.isEmpty) throw ApiError(400, 'bad_request');
    await db.execute(
      Sql.named('UPDATE users SET notif = notif || @p:jsonb WHERE id = @u'),
      parameters: {'p': patch, 'u': userId},
    );
  }

  /// Код для «/start <код>»: живёт 15 минут.
  Future<String> linkCode(String userId) async {
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rnd = Random.secure();
    final code = List.generate(8, (_) => alphabet[rnd.nextInt(alphabet.length)]).join();
    await db.execute(Sql.named('DELETE FROM telegram_links WHERE user_id = @u OR expires_at < now()'), parameters: {'u': userId});
    await db.execute(
      Sql.named("INSERT INTO telegram_links (code, user_id, expires_at) VALUES (@c, @u, now() + interval '15 minutes')"),
      parameters: {'c': code, 'u': userId},
    );
    return code;
  }

  Future<void> unlink(String userId) =>
      db.execute(Sql.named('UPDATE users SET telegram_chat_id = NULL WHERE id = @u'), parameters: {'u': userId});
}
