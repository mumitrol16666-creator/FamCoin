/// Регистрация и вход (F001, F003–F005, T26).
///
/// Три неверных пароля подряд блокируют вход на 15 минут по времени базы.
/// Успешный вход сбрасывает счётчик. Ошибки сети сюда не доходят и поэтому
/// не считаются неверным паролем. Подтверждение email временно отключено.
library;

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:postgres/postgres.dart';
import 'gate.dart';

const maxFailedAttempts = 3;
const lockMinutes = 15;
const sessionDays = 30;

class ApiError implements Exception {
  ApiError(this.status, this.code, {this.retryAfterSeconds, this.attemptsLeft, this.message, this.ledgerCode});

  /// Код ошибки ядра (`LedgerException.code`): приложение переводит его.
  final String? ledgerCode;

  final int status;

  /// Машинный код ошибки; текст подбирает приложение на языке пользователя.
  final String code;
  final int? retryAfterSeconds;
  final int? attemptsLeft;

  /// Пояснение для ошибок учёта.
  final String? message;

  Map<String, Object?> toJson() => {
        'error': code,
        if (ledgerCode != null) 'code': ledgerCode,
        if (retryAfterSeconds != null) 'retryAfterSeconds': retryAfterSeconds,
        if (attemptsLeft != null) 'attemptsLeft': attemptsLeft,
        if (message != null) 'message': message,
      };
}

class AuthService {
  AuthService(this.db, {Random? random, Gate? hashGate})
      : _random = random ?? Random.secure(),
        hashGate = hashGate ?? Gate(3, overflow: () => ApiError(503, 'busy', retryAfterSeconds: 5));

  final Pool db;
  final Random _random;

  /// Не больше трёх одновременных операций с bcrypt: пачка входов не должна
  /// занимать все соединения пула и тормозить остальных.
  final Gate hashGate;

  static final _emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  static String sha256Hex(String v) => sha256.convert(utf8.encode(v)).toString();

  String _newToken() {
    final bytes = List<int>.generate(32, (_) => _random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  static void validateCredentials(String email, String password) {
    if (email.length > 254 || !_emailRe.hasMatch(email)) throw ApiError(400, 'invalid_email');
    if (password.length < 8 || password.length > 128) throw ApiError(400, 'weak_password');
  }

  Future<Map<String, Object?>> register(String email, String password, String locale) async {
    email = email.trim();
    validateCredentials(email, password);
    if (locale != 'ru' && locale != 'kk') locale = 'ru';
    return hashGate.run(() => db.runTx((tx) async {
      final existing = await tx.execute(
        Sql.named('SELECT 1 FROM users WHERE lower(email) = lower(@email)'),
        parameters: {'email': email},
      );
      if (existing.isNotEmpty) throw ApiError(409, 'email_taken');
      final rows = await tx.execute(
        Sql.named("INSERT INTO users (email, password_hash, locale) VALUES (@email, crypt(@pw, gen_salt('bf', 12)), @locale) RETURNING id"),
        parameters: {'email': email, 'pw': password, 'locale': locale},
      );
      return _openSession(tx, rows.first[0].toString(), email, locale);
    }));
  }

  Future<Map<String, Object?>> login(String email, String password) async {
    email = email.trim();
    // Счётчик и блокировка меняются в одной транзакции с блокировкой строки:
    // параллельные попытки не обходят лимит.
    final result = await hashGate.run(() => db.runTx<Object>((tx) async {
      final rows = await tx.execute(
        Sql.named('''
          SELECT id, email, locale, failed_attempts,
                 ceil(extract(epoch FROM locked_until - now()))::int,
                 password_hash = crypt(@pw, password_hash)
          FROM users WHERE lower(email) = lower(@email)
          FOR UPDATE'''),
        parameters: {'email': email, 'pw': password},
      );
      // Неизвестный email получает тот же ответ, что и неверный пароль.
      if (rows.isEmpty) return ApiError(401, 'invalid_credentials');
      final r = rows.first;
      final userId = r[0].toString();
      final lockedFor = r[4] as int?;
      if (lockedFor != null && lockedFor > 0) {
        return ApiError(423, 'locked', retryAfterSeconds: lockedFor);
      }
      if (r[5] != true) {
        final failed = (r[3] as int) + 1;
        if (failed >= maxFailedAttempts) {
          await tx.execute(
            Sql.named("UPDATE users SET failed_attempts = 0, locked_until = now() + make_interval(mins => $lockMinutes) WHERE id = @id"),
            parameters: {'id': userId},
          );
          return ApiError(423, 'locked', retryAfterSeconds: lockMinutes * 60);
        }
        await tx.execute(
          Sql.named('UPDATE users SET failed_attempts = @f, locked_until = NULL WHERE id = @id'),
          parameters: {'f': failed, 'id': userId},
        );
        return ApiError(401, 'invalid_credentials', attemptsLeft: maxFailedAttempts - failed);
      }
      await tx.execute(
        Sql.named('UPDATE users SET failed_attempts = 0, locked_until = NULL WHERE id = @id'),
        parameters: {'id': userId},
      );
      return _openSession(tx, userId, r[1] as String, r[2] as String);
    }));
    // Ошибка возвращается после коммита, чтобы счётчик попыток сохранился.
    if (result is ApiError) throw result;
    return result as Map<String, Object?>;
  }

  Future<Map<String, Object?>> _openSession(Session tx, String userId, String email, String locale, {String via = 'password', String? name}) async {
    final token = _newToken();
    await tx.execute(
      Sql.named("INSERT INTO sessions (token_hash, user_id, expires_at, via) VALUES (@h, @id, now() + make_interval(days => $sessionDays), @via)"),
      parameters: {'h': sha256Hex(token), 'id': userId, 'via': via},
    );
    return {'token': token, 'user': {'id': userId, 'email': email, 'locale': locale, if (name != null) 'name': name}};
  }

  // ------------------------------------------------------ Telegram (D49)

  String _code(int len) {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789';
    return List.generate(len, (_) => chars[_random.nextInt(chars.length)]).join();
  }

  /// Код входа: приложение открывает t.me/<бот>?start=login_<код>, бот
  /// отмечает чат, приложение опрашивает [telegramCheck]. Живёт 10 минут.
  Future<String> telegramStart() async {
    final code = _code(12);
    await db.execute("DELETE FROM telegram_logins WHERE expires_at < now()");
    await db.execute(
      Sql.named("INSERT INTO telegram_logins (code, expires_at) VALUES (@c, now() + interval '10 minutes')"),
      parameters: {'c': code},
    );
    return code;
  }

  /// `pending`, пока бот не отметил чат; затем — сессия. Аккаунт по chat_id
  /// либо уже есть (в т.ч. привязанный через уведомления), либо создаётся.
  Future<Map<String, Object?>> telegramCheck(String code, String locale) async {
    if (locale != 'ru' && locale != 'kk') locale = 'ru';
    return db.runTx((tx) async {
      final rows = await tx.execute(
        Sql.named('SELECT chat_id, name FROM telegram_logins WHERE code = @c AND expires_at > now() FOR UPDATE'),
        parameters: {'c': code},
      );
      if (rows.isEmpty) throw ApiError(410, 'code_expired');
      final chatId = rows.first[0] as int?;
      if (chatId == null) return {'status': 'pending'};
      final name = rows.first[1] as String?;
      await tx.execute(Sql.named('DELETE FROM telegram_logins WHERE code = @c'), parameters: {'c': code});

      var user = await tx.execute(
        Sql.named('SELECT id, email, locale, display_name FROM users WHERE telegram_chat_id = @c'),
        parameters: {'c': chatId},
      );
      var isNew = false;
      if (user.isEmpty) {
        isNew = true;
        user = await tx.execute(
          Sql.named('''
            INSERT INTO users (email, password_hash, locale, telegram_chat_id, display_name)
            VALUES (@email, crypt(@pw, gen_salt('bf', 12)), @locale, @c, @n)
            RETURNING id, email, locale, display_name'''),
          parameters: {'email': 'tg$chatId@telegram.local', 'pw': _newToken(), 'locale': locale, 'c': chatId, 'n': name},
        );
      } else if (name != null && user.first[3] == null) {
        await tx.execute(Sql.named('UPDATE users SET display_name = @n WHERE id = @id'), parameters: {'n': name, 'id': user.first[0].toString()});
      }
      final r = user.first;
      final session = await _openSession(tx, r[0].toString(), r[1] as String, r[2] as String, via: 'telegram', name: (r[3] as String?) ?? name);
      return {'status': 'ok', 'isNew': isNew, ...session};
    });
  }

  /// Отметка активности — для админки («был в приложении»).
  Future<void> touch(String userId) => db.execute(
        Sql.named("UPDATE users SET last_seen_at = now() WHERE id = @u AND (last_seen_at IS NULL OR last_seen_at < now() - interval '5 minutes')"),
        parameters: {'u': userId},
      );

  /// Id владельца по токену сессии или `null`.
  Future<String?> userIdFor(String token) async {
    final rows = await db.execute(
      Sql.named('SELECT user_id FROM sessions WHERE token_hash = @h AND expires_at > now()'),
      parameters: {'h': sha256Hex(token)},
    );
    return rows.isEmpty ? null : rows.first[0].toString();
  }

  /// Смена пароля: проверяет текущий и закрывает все сессии, кроме текущей.
  /// Сессия, открытая через Telegram, задаёт пароль без текущего — это и
  /// есть восстановление (D49).
  Future<void> changePassword(String userId, String token, String current, String next) async {
    if (next.length < 8 || next.length > 128) throw ApiError(400, 'weak_password');
    await hashGate.run(() => db.runTx((tx) async {
      final via = await tx.execute(Sql.named('SELECT via FROM sessions WHERE token_hash = @h'), parameters: {'h': sha256Hex(token)});
      final trusted = via.isNotEmpty && via.first[0] == 'telegram';
      final rows = await tx.execute(
        Sql.named('SELECT password_hash = crypt(@pw, password_hash) FROM users WHERE id = @id FOR UPDATE'),
        parameters: {'pw': current, 'id': userId},
      );
      if (rows.isEmpty || (!trusted && rows.first[0] != true)) throw ApiError(401, 'invalid_credentials');
      await tx.execute(
        Sql.named("UPDATE users SET password_hash = crypt(@pw, gen_salt('bf', 12)) WHERE id = @id"),
        parameters: {'pw': next, 'id': userId},
      );
      await tx.execute(
        Sql.named('DELETE FROM sessions WHERE user_id = @id AND token_hash <> @h'),
        parameters: {'id': userId, 'h': sha256Hex(token)},
      );
    }));
  }

  /// Выход на всех устройствах, кроме текущего.
  Future<int> logoutOthers(String userId, String token) async {
    final r = await db.execute(
      Sql.named('DELETE FROM sessions WHERE user_id = @id AND token_hash <> @h'),
      parameters: {'id': userId, 'h': sha256Hex(token)},
    );
    return r.affectedRows;
  }

  Future<int> sessionCount(String userId) async {
    final r = await db.execute(
      Sql.named('SELECT count(*) FROM sessions WHERE user_id = @id AND expires_at > now()'),
      parameters: {'id': userId},
    );
    return r.first[0] as int;
  }

  Future<void> logout(String token) => db.execute(
        Sql.named('DELETE FROM sessions WHERE token_hash = @h'),
        parameters: {'h': sha256Hex(token)},
      );

  /// Язык интерфейса: на нём же формируются сводки в Telegram.
  Future<void> setLocale(String userId, String locale) async {
    if (locale != 'ru' && locale != 'kk') throw ApiError(400, 'bad_request');
    await db.execute(Sql.named('UPDATE users SET locale = @l WHERE id = @u'), parameters: {'l': locale, 'u': userId});
  }
}

/// «Начать всё заново»: стереть журнал, справочники, планы, уведомления и
/// анкету, оставив аккаунт, вход, тариф и настройки Telegram.
Future<void> resetUserData(Pool db, String userId) => db.runTx((tx) async {
      for (final table in ['postings', 'reservations', 'transactions', 'ledger_accounts', 'entities', 'commands', 'notifications']) {
        await tx.execute(Sql.named('DELETE FROM $table WHERE user_id = @u'), parameters: {'u': userId});
      }
      final r = await tx.execute(
        Sql.named("UPDATE users SET profile = '{}'::jsonb, revision = revision + 1 WHERE id = @u"),
        parameters: {'u': userId},
      );
      if (r.affectedRows == 0) throw ApiError(404, 'not_found');
    });

/// Полное удаление аккаунта со всеми данными — одной транзакцией.
/// Проводки ссылаются на счета журнала, а операции — друг на друга, поэтому
/// каскад от `users` их не удаляет: журнал очищается явно по порядку, остальное
/// (справочники, команды, сессии, уведомления, платежи) — каскадом.
Future<void> deleteUserData(Pool db, String userId) => db.runTx((tx) async {
      for (final table in ['postings', 'reservations', 'transactions', 'ledger_accounts']) {
        await tx.execute(Sql.named('DELETE FROM $table WHERE user_id = @u'), parameters: {'u': userId});
      }
      final r = await tx.execute(Sql.named('DELETE FROM users WHERE id = @u'), parameters: {'u': userId});
      if (r.affectedRows == 0) throw ApiError(404, 'not_found');
    });
