/// Напоминание «Сверьте <месяц>» на настоящей базе (D75): кому уходит, кому
/// нет и что не повторяется. Нужна локальная база из docker-compose
/// (`docker compose up -d db api`, порт 5433); без неё тест пропускается.
library;

import 'dart:io';

import 'package:famcoin_server/auth_service.dart';
import 'package:famcoin_server/ledger_service.dart';
import 'package:famcoin_server/notifications.dart';
import 'package:famcoin_server/telegram.dart';
import 'package:famcoin_server/webpush.dart';
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
    settings: const PoolSettings(maxConnectionCount: 3, sslMode: SslMode.disable),
  );
  try {
    await db.execute('SELECT 1 FROM notifications LIMIT 1').timeout(const Duration(seconds: 3));
    return db;
  } catch (_) {
    return null;
  }
}

void main() {
  test('месячное напоминание: уходит один раз тем, кто вёл учёт и не закрыл месяц', () async {
    final db = await _connect();
    if (db == null) {
      markTestSkipped('локальная база не запущена');
      return;
    }
    final auth = AuthService(db);
    final ledger = LedgerService(db);
    final svc = NotificationService(db, ledger, Telegram(db, token: null), WebPush(db, subject: 'mailto:test@example.com'));
    final ids = <String>[];
    var n = 0;
    Future<String> user({bool activity = true, Map<String, Object?> profile = const {}}) async {
      final email = 'monthnudge-${DateTime.now().microsecondsSinceEpoch}-${n++}@example.test';
      final r = await auth.register(email, 'Test-pass-12345', 'ru');
      final id = ((r['user'] as Map)['id']) as String;
      ids.add(id);
      Future<void> cmd(Map<String, dynamic> c) => ledger.command(id, {'commandId': 'c${n++}-${DateTime.now().microsecondsSinceEpoch}', ...c});
      await cmd({'type': 'updateProfile', 'profile': {'onboarded': true, ...profile}});
      await cmd({'type': 'addMoneyAccount', 'accountId': 'cash'});
      await cmd({'type': 'opening', 'id': 'op', 'date': '2026-07-01', 'account': 'cash', 'amount': '10000000'});
      if (activity) {
        await cmd({'type': 'income', 'id': 'i1', 'date': '2026-08-05', 'account': 'cash', 'source': 'salary', 'amount': '30000000'});
        await cmd({'type': 'expense', 'id': 'e1', 'date': '2026-08-10', 'account': 'cash', 'splits': {'food': '2000000'}});
      }
      return id;
    }

    try {
      final active = await user();
      final closed = await user(profile: {'closedMonths': ['2026-08']});
      final quiet = await user(activity: false);
      final off = await user();
      await db.execute(Sql.named("UPDATE users SET notif = notif || '{\"month\": false}'::jsonb WHERE id = @u"), parameters: {'u': off});

      Future<List<List<Object?>>> rows(String id) async =>
          [for (final r in await db.execute(Sql.named("SELECT title, body FROM notifications WHERE user_id = @u AND title LIKE 'Сверьте%'"), parameters: {'u': id})) r.toList()];

      // 2 сентября, 10:00 по Астане: прошлый месяц — август.
      await svc.runMonth(DateTime(2026, 9, 2, 10));
      final got = await rows(active);
      expect(got, hasLength(1));
      expect(got.single[0], 'Сверьте август');
      expect(got.single[1], contains('300 000 ₸'), reason: 'в тексте итоги месяца: доходы');
      expect(got.single[1], contains('20 000 ₸'), reason: 'и расходы');
      expect(await rows(closed), isEmpty, reason: 'месяц уже закрыт');
      expect(await rows(quiet), isEmpty, reason: 'в августе учёта не было');
      expect(await rows(off), isEmpty, reason: 'напоминание выключено в настройках');

      // Повторный проход (следующая минута, перезапуск сервера) не дублирует.
      await svc.runMonth(DateTime(2026, 9, 2, 10, 1));
      expect(await rows(active), hasLength(1));

      // Следующий месяц — новое напоминание.
      await db.execute(Sql.named("UPDATE users SET notif = notif - 'sentMonth' WHERE id = @u"), parameters: {'u': active});
      await svc.runMonth(DateTime(2026, 9, 3, 12));
      expect(await rows(active), hasLength(2), reason: 'после сброса метки уходит снова — метка и есть защита от повтора');
    } finally {
      for (final id in ids) {
        await deleteUserData(db, id);
      }
      await db.close();
    }
  }, timeout: const Timeout(Duration(seconds: 60)));
}
