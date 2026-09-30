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
      if (now.hour >= monthHour && now.day <= monthWindowDays) await runMonth(now);
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

  /// Раз в месяц, в первые дни: тем, кто ещё не закрыл прошлый месяц и вёл в нём
  /// учёт, — «Сверьте сентябрь» (D75). Метка `sentMonth` не даёт повторить.
  Future<void> runMonth(DateTime now) async {
    final month = previousMonth(now);
    final key = monthKey(month);
    final users = await db.execute(
      Sql.named('''
        SELECT u.id FROM users u
        WHERE (u.profile->>'onboarded') = 'true'
          AND coalesce((u.notif->>'month')::boolean, true)
          AND coalesce(u.notif->>'sentMonth', '') <> @key
          AND NOT (coalesce(u.profile->'closedMonths', '[]'::jsonb) @> to_jsonb(@key::text))
          AND EXISTS (
            SELECT 1 FROM transactions t
            WHERE t.user_id = u.id AND t.type IN ('expense', 'income')
              AND t.date >= @from::date AND t.date < @to::date)
        LIMIT $batchSize'''),
      parameters: {'key': key, 'from': _day(month), 'to': _day(DateTime(now.year, now.month, 1))},
    );
    final ids = [for (final r in users) r[0].toString()];
    for (var i = 0; i < ids.length; i += concurrency) {
      await Future.wait([for (final id in ids.skip(i).take(concurrency)) _deliverMonth(id, month, key)]);
    }
  }

  static String _day(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _deliverMonth(String userId, DateTime month, String key) async {
    try {
      await db.execute(
        Sql.named("UPDATE users SET notif = notif || jsonb_build_object('sentMonth', @k::text) WHERE id = @u"),
        parameters: {'k': key, 'u': userId},
      );
      await sendMonthNudge(userId, month).timeout(const Duration(seconds: 90));
    } catch (e) {
      stderr.writeln('month nudge for $userId: ${e.runtimeType}');
    }
  }

  /// Пробное уведомление по кнопке в настройках: показывает то, что придёт
  /// в начале месяца. Берёт текущий месяц, если в нём уже есть операции
  /// (так видно живые цифры), иначе прошлый.
  Future<void> sendMonthNudgePreview(String userId, DateTime now) async {
    final current = DateTime(now.year, now.month, 1);
    final r = await db.execute(
      Sql.named("SELECT EXISTS (SELECT 1 FROM transactions WHERE user_id = @u AND type IN ('expense', 'income') AND date >= @from::date AND date < @to::date)"),
      parameters: {'u': userId, 'from': _day(current), 'to': _day(DateTime(now.year, now.month + 1, 1))},
    );
    await sendMonthNudge(userId, r.first[0] == true ? current : previousMonth(now));
  }

  /// Уведомление «Сверьте <месяц>»: итоги коротко, ссылка открывает сверку в приложении.
  Future<void> sendMonthNudge(String userId, DateTime month) async {
    final s = await ledger.state(userId);
    final r = _ledgerOf(s).report(month, DateTime(month.year, month.month + 1, 1));
    final brief = monthNudge(month: month, income: r.income, expense: r.expense, locale: s['locale'] as String? ?? 'ru');
    await notify(userId, 'system', brief.title, brief.body, openQuery: 'close=${monthKey(month)}');
  }

  Future<void> sendBrief(String userId, String kind, DateTime today) async {
    final s = await ledger.state(userId);
    final l = _ledgerOf(s);
    final entities = (s['entities'] as List).cast<Map<String, dynamic>>();
    List<Map<String, dynamic>> ofKind(String k) => [for (final e in entities) if (e['kind'] == k) Map<String, dynamic>.from(e['data'] as Map)];
    final input = BriefInput(
      ledger: l,
      today: today,
      profile: Map<String, dynamic>.from(s['profile'] as Map? ?? const {}),
      planned: ofKind('planned'),
      limits: ofKind('limit'),
      locale: s['locale'] as String? ?? 'ru',
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
