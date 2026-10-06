/// Админка: в списке пользователей имя, фамилия, имя из Telegram и поиск по ним.
library;

import 'dart:io';

import 'package:famcoin_server/admin.dart';
import 'package:famcoin_server/auth_service.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

void main() {
  Pool? pool;
  final users = <String>[];

  setUpAll(() async {
    final db = Pool.withEndpoints(
      [Endpoint(host: 'localhost', port: int.parse(Platform.environment['TEST_DB_PORT'] ?? '5433'), database: 'famcoin', username: 'famcoin', password: 'famcoin')],
      settings: const PoolSettings(maxConnectionCount: 4, sslMode: SslMode.disable),
    );
    try {
      await db.execute('SELECT 1 FROM users LIMIT 1').timeout(const Duration(seconds: 3));
      pool = db;
    } catch (_) {}
  });

  tearDownAll(() async {
    final db = pool;
    if (db == null) return;
    for (final id in users) {
      try {
        await deleteUserData(db, id);
      } on ApiError {}
    }
    await db.close();
  });

  test('список пользователей показывает имя, фамилию, имя из Telegram и режим; поиск находит по имени', () async {
    final db = pool;
    if (db == null) {
      markTestSkipped('база не запущена');
      return;
    }
    final tag = DateTime.now().microsecondsSinceEpoch;
    final r = await db.execute(
      Sql.named('''INSERT INTO users (email, password_hash, display_name, profile) VALUES (@e, 'x', @d, @p:jsonb) RETURNING id'''),
      parameters: {'e': 'adm-$tag@example.test', 'd': 'Vadim TG', 'p': {'firstName': 'Вадим$tag', 'lastName': 'Тестов', 'mode': 'family', 'onboarded': true}},
    );
    users.add(r.first[0].toString());
    final admin = AdminService(db, password: 'длинный-пароль');
    for (final q in ['Вадим$tag', 'Тестов', 'vadim tg', 'adm-$tag']) {
      final found = await admin.users(q);
      final u = found.firstWhere((x) => x['email'] == 'adm-$tag@example.test', orElse: () => {});
      expect(u, isNotEmpty, reason: 'поиск «$q»');
      expect(u['firstName'], 'Вадим$tag');
      expect(u['lastName'], 'Тестов');
      expect(u['telegramName'], 'Vadim TG');
      expect(u['mode'], 'family');
    }
    expect((await admin.users('нет-такого-$tag')), isEmpty);
  });
}
