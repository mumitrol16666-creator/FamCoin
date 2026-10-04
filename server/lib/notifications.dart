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
      if (now.hour >= morningHour && now.hour < eveningHour) await _run('morning', now);
      if (now.hour >= eveningHour) await _run('evening', now);
      if (now.hour >= monthHour) await runMonth(now);
    } catch (e, st) {
      stderr.writeln('notifications: ${e.runtimeType}\n$st');
    } finally {
      _busy = false;
    }
  }

  /// Отправляет сводку тем, кому она включена и сегодня ещё не отправлялась.
  Future<void> _run(String kind, DateTime now) async {
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
      await Future.wait([for (final id in ids.skip(i).take(concurrency)) _deliver(kind, flag, today, now, id)]);
    }
  }

  Future<void> _deliver(String kind, String flag, String today, DateTime now, String userId) async {
    try {
      await db.execute(
        Sql.named('UPDATE users SET notif = notif || jsonb_build_object(@flag::text, @today::text) WHERE id = @u'),
        parameters: {'flag': flag, 'today': today, 'u': userId},
      );
      await sendBrief(userId, kind, DateTime(now.year, now.month, now.day)).timeout(const Duration(seconds: 90));
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
      await Future.wait([for (final id in ids.skip(i).take(concurrency)) _deliverMonth(id, month, key, flag, preparation)]);
    }
  }

  static String _day(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _deliverMonth(String userId, DateTime month, String key, String flag, int? preparation) async {
    try {
      final claim = await db.execute(
        Sql.named("UPDATE users SET notif = notif || jsonb_build_object(@flag::text, @k::text) WHERE id = @u AND coalesce(notif->>@flag, '') <> @k AND coalesce((notif->>'month')::boolean, true) RETURNING id"),
        parameters: {'k': key, 'flag': flag, 'u': userId},
      );
      if (claim.isEmpty) return;
      await sendMonthNudge(userId, month, preparationDays: preparation).timeout(const Duration(seconds: 90));
    } catch (e) {
      stderr.writeln('month nudge for $userId: ${e.runtimeType}');
    }
  }

  /// Предпросмотр никогда не предлагает закрыть незавершённый месяц.
  Future<void> sendMonthNudgePreview(String userId, DateTime now) => sendMonthNudge(userId, previousMonth(now), preview: true);

  /// Уведомление «Сверьте <месяц>»: итоги коротко, ссылка открывает сверку в приложении.
  Future<void> sendMonthNudge(String userId, DateTime month, {int? preparationDays, bool preview = false}) async {
    final s = await ledger.state(userId);
    // Пока уведомление готовилось, пользователь мог завершить сверку.
    // state также восстанавливает ложные отметки старого алгоритма.
    if (!preview && preparationDays == null && (s['monthReconciliations'] as List).cast<Map>().any(
        (r) => r['month'] == _day(month) && r['invalidatedAt'] == null)) return;
    final r = _ledgerOf(s).report(month, DateTime(month.year, month.month + 1, 1));
    final locale = s['locale'] as String? ?? 'ru';
    final brief = preparationDays == null
        ? monthNudge(month: month, income: r.income, expense: r.total, locale: locale)
        : monthPreparation(month: month, days: preparationDays, locale: locale);
    await notify(userId, 'system', brief.title, brief.body, openQuery: 'close=${monthKey(month)}');
  }

  Future<void> sendBrief(String userId, String kind, DateTime today) async {
    final s = await ledger.state(userId);
    final l = _ledgerOf(s);
    final entities = (s['entities'] as List).cast<Map<String, dynamic>>();
    List<Map<String, dynamic>> ofKind(String k) => [for (final e in entities) if (e['kind'] == k) Map<String, dynamic>.from(e['data'] as Map)];
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
    );
    final brief = kind == 'morning' ? morningBrief(input) : eveningBrief(input);
    await notify(userId, kind, brief.title, brief.body);
  }

  Ledger _ledgerOf(Map<String, Object?> s) => ledgerFromSnapshot(
        accounts: (s['accounts'] as List).cast(),
        transactions: (s['transactions'] as List).cast(),
        reservations: (s['reservations'] as List).cast(),
      );

  /// Сохраняет уведомление и, если привязан Telegram, отправляет туда.
  /// [openQuery] — что приложению открыть по нажатию, например `close=2026-09`:
  /// push ведёт на `./?close=2026-09`, в Telegram уходит ссылка на сайт.
  Future<void> notify(String userId, String kind, String title, String body, {String? openQuery}) async {
    await db.execute(
      Sql.named('INSERT INTO notifications (user_id, kind, title, body) VALUES (@u, @k, @t, @b)'),
      parameters: {'u': userId, 'k': kind, 't': title, 'b': body},
    );
    final chat = await db.execute(Sql.named('SELECT telegram_chat_id FROM users WHERE id = @u'), parameters: {'u': userId});
    final chatId = chat.isEmpty ? null : chat.first[0] as int?;
    final site = origin;
    final link = openQuery != null && site != null && site.startsWith('https://') ? '\n$site/?$openQuery' : '';
    if (chatId != null) await telegram.send(chatId, '<b>$title</b>\n$body$link');
    await push.sendToUser(userId, title, body.replaceAll(RegExp(r'</?b>'), ''), tag: kind, url: openQuery == null ? null : './?$openQuery');
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
