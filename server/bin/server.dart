import 'dart:io';

import 'package:famcoin_server/admin.dart';
import 'package:famcoin_server/api.dart';
import 'package:famcoin_server/auth_service.dart';
import 'package:famcoin_server/billing.dart';
import 'package:famcoin_server/ledger_service.dart';
import 'package:famcoin_server/notifications.dart';
import 'package:famcoin_server/telegram.dart';
import 'package:famcoin_server/webpush.dart';
import 'package:postgres/postgres.dart';
import 'package:shelf/shelf_io.dart' as io;

Future<void> main() async {
  final env = Platform.environment;
  final db = Pool.withEndpoints(
    [
      Endpoint(
        host: env['DB_HOST'] ?? 'localhost',
        port: int.parse(env['DB_PORT'] ?? '5432'),
        database: env['DB_NAME'] ?? 'famcoin',
        username: env['DB_USER'] ?? 'famcoin',
        password: env['DB_PASSWORD'] ?? 'famcoin',
      ),
    ],
    settings: const PoolSettings(maxConnectionCount: 10, sslMode: SslMode.disable),
  );

  await _migrate(db);

  final auth = AuthService(db);
  final ledger = LedgerService(db);
  final telegram = Telegram(db, token: env['TELEGRAM_BOT_TOKEN']);
  final notifications = NotificationService(db, ledger, telegram, WebPush(db, subject: pushSubject(env['CORS_ORIGIN'])))..start();
  final billing = BillingService(
    db,
    telegram,
    notifications,
    stars: int.tryParse(env['PRO_STARS'] ?? ''),
    days: int.tryParse(env['PRO_DAYS'] ?? ''),
  )..start();
  final admin = AdminService(db, password: env['ADMIN_PASSWORD']);
  final handler = buildHandler(auth, ledger, notifications, admin, telegram: telegram, billing: billing, allowedOrigin: env['CORS_ORIGIN'] ?? '*');

  // Бот слушает «/start <код>» и платежи только при заданном токене.
  if (telegram.enabled) {
    telegram.pollForever();
    print('telegram: бот включён, Pro — ${billing.proStars} ⭐ на ${billing.proDays} дней');
  } else {
    print('telegram: TELEGRAM_BOT_TOKEN не задан, доставка в Telegram и оплата выключены');
  }
  print(admin.enabled ? 'admin: /api/admin/' : 'admin: ADMIN_PASSWORD не задан (мин. 8 символов), админка выключена');

  final port = int.parse(env['PORT'] ?? '8080');
  await io.serve(handler, InternetAddress.anyIPv4, port);
  print('FamCoin API: http://0.0.0.0:$port');
}

/// Применяет SQL-файлы из migrations/ по порядку; каждый — один раз.
Future<void> _migrate(Pool db) async {
  for (var i = 0; ; i++) {
    try {
      await db.execute('SELECT 1');
      break;
    } catch (_) {
      if (i > 30) rethrow;
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  }
  await db.execute('CREATE TABLE IF NOT EXISTS schema_migrations (name text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())');
  final dir = Directory(Platform.environment['MIGRATIONS_DIR'] ?? 'migrations');
  final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.sql')).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final f in files) {
    final name = f.uri.pathSegments.last;
    final done = await db.execute(Sql.named('SELECT 1 FROM schema_migrations WHERE name = @n'), parameters: {'n': name});
    if (done.isNotEmpty) continue;
    await db.runTx((tx) async {
      await tx.execute(f.readAsStringSync(), queryMode: QueryMode.simple);
      await tx.execute(Sql.named('INSERT INTO schema_migrations (name) VALUES (@n)'), parameters: {'n': name});
    });
    print('migration applied: $name');
  }
}
