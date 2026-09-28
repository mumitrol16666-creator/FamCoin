/// Админка: пользователи, блокировки, тариф, сброс пароля, статистика.
///
/// Вход по ADMIN_PASSWORD; без него админка выключена. Каждое действие
/// записывается в admin_audit.
library;

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:postgres/postgres.dart';

import 'auth_service.dart';

class AdminService {
  AdminService(this.db, {required this.password});

  final Pool db;
  final String? password;
  final Map<String, DateTime> _sessions = {};

  bool get enabled => password != null && password!.length >= 8;

  static String _sha(String v) => sha256.convert(utf8.encode(v)).toString();

  String login(String given) {
    if (!enabled) throw ApiError(404, 'admin_disabled');
    // Сравнение хешей постоянной длины: время ответа не зависит от совпавших символов.
    if (_sha(given) != _sha(password!)) throw ApiError(401, 'invalid_credentials');
    final token = base64Url.encode(List<int>.generate(32, (_) => Random.secure().nextInt(256))).replaceAll('=', '');
    _sessions[_sha(token)] = DateTime.now().add(const Duration(hours: 12));
    return token;
  }

  void require(String? token) {
    if (!enabled) throw ApiError(404, 'admin_disabled');
    final exp = token == null ? null : _sessions[_sha(token)];
    if (exp == null || exp.isBefore(DateTime.now())) throw ApiError(401, 'unauthorized');
  }

  Future<void> _audit(String action, {String? target, Map<String, Object?> details = const {}}) => db.execute(
        Sql.named('INSERT INTO admin_audit (action, target, details) VALUES (@a, @t, @d:jsonb)'),
        parameters: {'a': action, 't': target, 'd': details},
      );

  Future<Map<String, Object?>> stats() async {
    final r = await db.execute('''
      SELECT
        (SELECT count(*) FROM users),
        (SELECT count(*) FROM users WHERE created_at > now() - interval '7 days'),
        (SELECT count(*) FROM users WHERE last_seen_at > now() - interval '1 day'),
        (SELECT count(*) FROM users WHERE plan = 'pro'),
        (SELECT count(*) FROM transactions),
        (SELECT count(*) FROM commands WHERE created_at > now() - interval '1 day'),
        (SELECT count(*) FROM users WHERE telegram_chat_id IS NOT NULL),
        pg_size_pretty(pg_database_size(current_database()))''');
    final x = r.first;
    final byDay = await db.execute('''
      SELECT to_char(d, 'YYYY-MM-DD'),
        (SELECT count(*) FROM users WHERE created_at::date = d),
        (SELECT count(*) FROM commands WHERE created_at::date = d)
      FROM generate_series(current_date - 13, current_date, '1 day') d ORDER BY d''');
    return {
      'users': x[0], 'newWeek': x[1], 'activeDay': x[2], 'pro': x[3], 'transactions': x[4], 'commandsDay': x[5], 'telegram': x[6], 'dbSize': x[7],
      'byDay': [for (final d in byDay) {'date': d[0], 'signups': d[1], 'commands': d[2]}],
    };
  }

  Future<List<Map<String, Object?>>> users(String query) async {
    final rows = await db.execute(
      Sql.named('''
        SELECT u.id, u.email, u.locale, u.plan, u.created_at, u.last_seen_at,
               u.locked_until > now(), u.failed_attempts, u.telegram_chat_id IS NOT NULL,
               (SELECT count(*) FROM transactions t WHERE t.user_id = u.id),
               (u.profile->>'onboarded') = 'true'
        FROM users u
        WHERE @q = '' OR u.email ILIKE '%' || @q || '%'
        ORDER BY u.created_at DESC LIMIT 200'''),
      parameters: {'q': query.trim()},
    );
    return [
      for (final r in rows)
        {
          'id': r[0].toString(), 'email': r[1], 'locale': r[2], 'plan': r[3],
          'createdAt': (r[4] as DateTime).toIso8601String(),
          'lastSeenAt': (r[5] as DateTime?)?.toIso8601String(),
          'locked': r[6] == true, 'failedAttempts': r[7], 'telegram': r[8] == true,
          'transactions': r[9], 'onboarded': r[10] == true,
        },
    ];
  }

  Future<void> unlock(String userId) async {
    await db.execute(Sql.named('UPDATE users SET locked_until = NULL, failed_attempts = 0 WHERE id = @u'), parameters: {'u': userId});
    await _audit('unlock', target: userId);
  }

  Future<void> setPlan(String userId, String plan) async {
    if (plan != 'free' && plan != 'pro') throw ApiError(400, 'bad_request');
    await db.execute(Sql.named('UPDATE users SET plan = @p, revision = revision + 1 WHERE id = @u'), parameters: {'p': plan, 'u': userId});
    await _audit('plan', target: userId, details: {'plan': plan});
  }

  /// Временный пароль: показывается администратору один раз, все сессии закрываются.
  Future<String> resetPassword(String userId) async {
    const alphabet = 'abcdefghjkmnpqrstuvwxyz23456789';
    final rnd = Random.secure();
    final temp = List.generate(10, (_) => alphabet[rnd.nextInt(alphabet.length)]).join();
    await db.runTx((tx) async {
      final r = await tx.execute(
        Sql.named("UPDATE users SET password_hash = crypt(@pw, gen_salt('bf', 12)), locked_until = NULL, failed_attempts = 0 WHERE id = @u"),
        parameters: {'pw': temp, 'u': userId},
      );
      if (r.affectedRows == 0) throw ApiError(404, 'not_found');
      await tx.execute(Sql.named('DELETE FROM sessions WHERE user_id = @u'), parameters: {'u': userId});
    });
    await _audit('reset_password', target: userId);
    return temp;
  }

  Future<void> deleteUser(String userId, String email) async {
    final r = await db.execute(
      Sql.named('DELETE FROM users WHERE id = @u AND lower(email) = lower(@e)'),
      parameters: {'u': userId, 'e': email},
    );
    if (r.affectedRows == 0) throw ApiError(400, 'bad_request');
    await _audit('delete_user', target: userId, details: {'email': email});
  }

  Future<List<Map<String, Object?>>> audit() async {
    final rows = await db.execute('''
      SELECT a.at, a.action, a.target, a.details, u.email
      FROM admin_audit a LEFT JOIN users u ON u.id = a.target
      ORDER BY a.id DESC LIMIT 200''');
    return [
      for (final r in rows)
        {'at': (r[0] as DateTime).toIso8601String(), 'action': r[1], 'target': r[2]?.toString(), 'details': r[3], 'email': r[4]},
    ];
  }
}
