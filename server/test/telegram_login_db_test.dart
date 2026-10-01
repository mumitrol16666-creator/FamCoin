/// Вход через Telegram при одновременных входах и при отвязке чата (D78) —
/// на настоящей базе. Нужна база из docker-compose (`docker compose up -d db
/// api`, порт 5433) или любая другая с миграциями — порт задаётся
/// `TEST_DB_PORT`; без базы тесты пропускаются.
library;

import 'dart:io';

import 'package:famcoin_server/auth_service.dart';
import 'package:famcoin_server/telegram.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

Future<Pool?> _connect() async {
  final db = Pool.withEndpoints(
    [
      Endpoint(
        host: 'localhost',
        port: int.parse(Platform.environment['TEST_DB_PORT'] ?? '5433'),
        database: 'famcoin',
        username: 'famcoin',
        password: 'famcoin',
      ),
    ],
    settings: const PoolSettings(maxConnectionCount: 16, sslMode: SslMode.disable),
  );
  try {
    await db.execute('SELECT 1 FROM telegram_logins LIMIT 1').timeout(const Duration(seconds: 3));
    return db;
  } catch (_) {
    return null;
  }
}

void main() {
  Pool? pool;
  late AuthService auth;
  late Telegram bot;
  // Свой диапазон чатов на каждый запуск: тесты не мешают ни друг другу, ни прежним прогонам.
  final base = 9200000000 + (DateTime.now().microsecondsSinceEpoch % 1000000) * 1000;

  setUpAll(() async {
    pool = await _connect();
    if (pool == null) return;
    auth = AuthService(pool!);
    bot = Telegram(pool!, token: null);
  });

  tearDownAll(() async {
    final db = pool;
    if (db == null) return;
    final ids = await db.execute(
      Sql.named(r'''
        SELECT id FROM users
        WHERE telegram_chat_id BETWEEN @a AND @b
           OR substring(email from '^tg(\d+)@telegram\.local$')::bigint BETWEEN @a AND @b
           OR email LIKE @mail'''),
      parameters: {'a': base, 'b': base + 999, 'mail': 'tglink-$base-%@example.test'},
    );
    for (final r in ids) {
      await deleteUserData(db, r[0].toString());
    }
    await db.close();
  });

  /// Код входа, уже подтверждённый ботом для чата.
  Future<String> confirmed(int chat, {String name = 'User'}) async {
    final code = await auth.telegramStart();
    expect(await bot.confirmLogin(code, chat, name), isTrue);
    return code;
  }

  /// Результат проверки кода: id аккаунта или текст ошибки.
  Future<String> attempt(String code) async {
    try {
      final r = await auth.telegramCheck(code, 'ru');
      expect(r['status'], 'ok');
      expect(r['token'], isA<String>());
      return (r['user'] as Map)['id'] as String;
    } on ApiError catch (e) {
      return 'ошибка ${e.status} ${e.code}';
    } catch (e) {
      return 'ошибка ${e.runtimeType}';
    }
  }

  Future<int> count(String sql, Map<String, Object?> params) async => (await pool!.execute(Sql.named(sql), parameters: params)).first[0] as int;

  bool skip() {
    if (pool != null) return false;
    // В CI база обязана быть: молчаливый пропуск выглядел бы как успех.
    if (Platform.environment['TEST_DB_REQUIRED'] == '1') fail('TEST_DB_REQUIRED=1, а база недоступна');
    markTestSkipped('база не запущена');
    return true;
  }

  test('20 разных людей входят одновременно: 20 аккаунтов, ни одной ошибки', () async {
    if (skip()) return;
    final codes = await Future.wait([for (var i = 0; i < 20; i++) auth.telegramStart()]);
    expect(codes.toSet(), hasLength(20), reason: 'коды не повторяются');
    await Future.wait([for (var i = 0; i < 20; i++) bot.confirmLogin(codes[i], base + i, 'User $i')]);
    final ids = await Future.wait(codes.map(attempt));
    expect(ids.where((x) => x.startsWith('ошибка')), isEmpty);
    expect(ids.toSet(), hasLength(20), reason: 'у каждого свой аккаунт');
    expect(await count('SELECT count(*) FROM users WHERE telegram_chat_id BETWEEN @a AND @b', {'a': base, 'b': base + 19}), 20);
  });

  test('один человек входит на 20 устройствах сразу: 20 сессий, аккаунт один', () async {
    if (skip()) return;
    final chat = base + 100;
    final first = await attempt(await confirmed(chat));
    final codes = await Future.wait([for (var i = 0; i < 20; i++) confirmed(chat)]);
    final ids = await Future.wait(codes.map(attempt));
    expect(ids.toSet(), {first}, reason: 'все входы — в один и тот же аккаунт');
    expect(await count('SELECT count(*) FROM sessions WHERE user_id = @u', {'u': first}), 21);
    expect(await count('SELECT count(*) FROM users WHERE telegram_chat_id = @c', {'c': chat}), 1);
  });

  test('новый человек подтвердил два кода разом (телефон и сайт): оба входа успешны, аккаунт один', () async {
    if (skip()) return;
    for (var round = 0; round < 5; round++) {
      final chat = base + 200 + round;
      final c1 = await confirmed(chat), c2 = await confirmed(chat);
      final ids = await Future.wait([attempt(c1), attempt(c2)]);
      expect(ids.where((x) => x.startsWith('ошибка')), isEmpty, reason: 'раньше второй вход падал с ошибкой уникальности');
      expect(ids.toSet(), hasLength(1));
      expect(await count('SELECT count(*) FROM users WHERE telegram_chat_id = @c', {'c': chat}), 1);
    }
  });

  test('один код проверяют дважды одновременно: один вход, второй получает «код устарел»', () async {
    if (skip()) return;
    final code = await confirmed(base + 300);
    final r = await Future.wait([attempt(code), attempt(code)]);
    expect(r.where((x) => x == 'ошибка 410 code_expired'), hasLength(1));
    final id = r.firstWhere((x) => !x.startsWith('ошибка'));
    expect(await count('SELECT count(*) FROM sessions WHERE user_id = @u', {'u': id}), 1, reason: 'сессия создана один раз');
  });

  test('код достаётся первому чату: второй чат его забрать не может', () async {
    if (skip()) return;
    final code = await auth.telegramStart();
    expect(await auth.telegramCheck(code, 'ru'), {'status': 'pending'});
    final claims = await Future.wait([bot.confirmLogin(code, base + 400, 'A'), bot.confirmLogin(code, base + 401, 'B')]);
    expect(claims.where((ok) => ok), hasLength(1), reason: 'код подтвердил ровно один чат');
    final owner = claims[0] ? base + 400 : base + 401;
    final id = await attempt(code);
    expect(await count('SELECT count(*) FROM users WHERE id = @u AND telegram_chat_id = @c', {'u': id, 'c': owner}), 1);
  });

  test('после «Отвязать Telegram» вход через Telegram открывает тот же аккаунт', () async {
    if (skip()) return;
    final chat = base + 500;
    final id = await attempt(await confirmed(chat));
    // То же, что делает «Ещё → Уведомления → Отвязать Telegram».
    await pool!.execute(Sql.named('UPDATE users SET telegram_chat_id = NULL WHERE id = @u'), parameters: {'u': id});
    final again = await attempt(await confirmed(chat));
    expect(again, id, reason: 'раньше здесь была ошибка уникальности email — человек терял вход навсегда');
    expect(await count("SELECT count(*) FROM users WHERE lower(email) = @e", {'e': telegramEmail(chat)}), 1);
  });

  test('Telegram, служащий входом, нельзя привязать к другому аккаунту; обычная привязка переносит чат', () async {
    if (skip()) return;
    Future<String> emailAccount(String tag) async {
      final r = await auth.register('tglink-$base-$tag@example.test', 'Test-pass-12345', 'ru');
      return (r['user'] as Map)['id'] as String;
    }

    Future<String> linkCode(String userId, String code) async {
      await pool!.execute(
        Sql.named("INSERT INTO telegram_links (code, user_id, expires_at) VALUES (@c, @u, now() + interval '15 minutes')"),
        parameters: {'c': code, 'u': userId},
      );
      return code;
    }

    final a = await emailAccount('a'), b = await emailAccount('b');
    final suffix = (base % 100000).toString().padLeft(5, '0');

    // Чат — вход в аккаунт, созданный через Telegram: привязать его к A нельзя.
    final loginChat = base + 600;
    final tgUser = await attempt(await confirmed(loginChat));
    expect(await bot.linkChat(await linkCode(a, 'L1$suffix'), loginChat), LinkOutcome.loginChat);
    expect(await count('SELECT count(*) FROM users WHERE id = @u AND telegram_chat_id = @c', {'u': tgUser, 'c': loginChat}), 1, reason: 'чат остался у аккаунта, в который через него входят');
    expect(await count('SELECT count(*) FROM telegram_links WHERE code = @c', {'c': 'L1$suffix'}), 1, reason: 'отказ не тратит код');
    // …даже если в том аккаунте чат отвязали от уведомлений.
    await pool!.execute(Sql.named('UPDATE users SET telegram_chat_id = NULL WHERE id = @u'), parameters: {'u': tgUser});
    expect(await bot.linkChat('L1$suffix', loginChat), LinkOutcome.loginChat);

    // Обычный чат: привязывается к A, затем переносится на B — у A снимается.
    final chat = base + 601;
    expect(await bot.linkChat(await linkCode(a, 'L2$suffix'), chat), LinkOutcome.linked);
    expect(await bot.linkChat(await linkCode(b, 'L3$suffix'), chat), LinkOutcome.linked);
    expect(await count('SELECT count(*) FROM users WHERE telegram_chat_id = @c', {'c': chat}), 1);
    expect(await count('SELECT count(*) FROM users WHERE id = @u AND telegram_chat_id = @c', {'u': b, 'c': chat}), 1);
    expect(await bot.linkChat('nosuchcode', chat), LinkOutcome.notFound);

    // Вход через Telegram с привязанного чата открывает аккаунт B (D49).
    expect(await attempt(await confirmed(chat)), b);
  });

  test('база не даёт двум аккаунтам один чат (уникальный индекс)', () async {
    if (skip()) return;
    final chat = base + 700;
    final id = await attempt(await confirmed(chat));
    final other = await attempt(await confirmed(base + 701));
    expect(other, isNot(id));
    await expectLater(
      pool!.execute(Sql.named('UPDATE users SET telegram_chat_id = @c WHERE id = @u'), parameters: {'c': chat, 'u': other}),
      throwsA(isA<UniqueViolationException>()),
    );
  });
}
