import 'dart:async';
import 'dart:io';

import 'package:famcoin_server/admin.dart';
import 'package:famcoin_server/ai.dart';
import 'package:famcoin_server/api.dart';
import 'package:famcoin_server/auth_service.dart';
import 'package:famcoin_server/billing.dart';
import 'package:famcoin_server/chat_entry.dart';
import 'package:famcoin_server/ledger_service.dart';
import 'package:famcoin_server/maintenance.dart';
import 'package:famcoin_server/notifications.dart';
import 'package:famcoin_server/speech.dart';
import 'package:famcoin_server/telegram.dart';
import 'package:famcoin_server/webpush.dart';
import 'package:postgres/postgres.dart';
import 'package:shelf/shelf_io.dart' as io;

Future<void> main() async {
  // Неперехваченная ошибка в фоновой задаче (таймер, опрос бота) раньше
  // роняла бы весь процесс вместе с обычными запросами. Теперь она попадает
  // в журнал, а сервер продолжает работать.
  await runZonedGuarded(_run, (e, st) => stderr.writeln('uncaught: ${e.runtimeType}: $e\n$st'));
}

Future<void> _run() async {
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
    settings: PoolSettings(
      maxConnectionCount: 16,
      sslMode: SslMode.disable,
      // Предохранители на каждом соединении API (резервное копирование и
      // восстановление подключаются отдельно и без них): зависший запрос не
      // должен держать блокировку пользователя и соединение бесконечно.
      onOpen: (c) => c.execute(
        "SET statement_timeout = '60s'; SET lock_timeout = '15s'; SET idle_in_transaction_session_timeout = '30s'",
        queryMode: QueryMode.simple,
      ),
    ),
  );

  await _migrate(db);

  final auth = AuthService(db);
  final ledger = LedgerService(db);
  final telegram = Telegram(db, token: env['TELEGRAM_BOT_TOKEN']);
  final notifications = NotificationService(db, ledger, telegram, WebPush(db, subject: pushSubject(env['CORS_ORIGIN'])), origin: env['CORS_ORIGIN'])..start();
  final billing = BillingService(
    db,
    telegram,
    notifications,
    stars: int.tryParse(env['PRO_STARS'] ?? ''),
    days: int.tryParse(env['PRO_DAYS'] ?? ''),
  )..start();
  Maintenance(db).start();
  final ai = AiService(db, ChatModel(apiKey: env['OPENAI_API_KEY'], model: env['OPENAI_CHAT_MODEL']), chatQuota: int.tryParse(env['AI_CHAT_QUOTA'] ?? ''));
  print(ai.model.enabled ? 'ai: консультант — ${ai.model.model}, ${ai.chatQuota} сообщений в месяц' : 'ai: OPENAI_API_KEY не задан, консультант выключен');
  final admin = AdminService(db, password: env['ADMIN_PASSWORD']);
  final handler = buildHandler(auth, ledger, notifications, admin, telegram: telegram, billing: billing, ai: ai, allowedOrigin: env['CORS_ORIGIN'] ?? '*');

  // Бот слушает «/start <код>», сообщения с тратами и платежи только при заданном токене.
  if (telegram.enabled) {
    final speech = Speech(apiKey: env['OPENAI_API_KEY'], model: env['OPENAI_TRANSCRIBE_MODEL']);
    ChatEntry(db, ledger, telegram, origin: env['CORS_ORIGIN'], speech: speech).attach();
    print(speech.enabled ? 'speech: голосовые в боте распознаёт ${speech.model}' : 'speech: OPENAI_API_KEY не задан, голосовые в боте выключены');
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
