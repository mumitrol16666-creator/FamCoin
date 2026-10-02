/// Виды справочников перечислены дважды: в коде (`entityKinds`) и в
/// ограничении таблицы `entities`. Если новый вид добавить только в код,
/// сервер примет команду, а база её отвергнет — и приложение получит 500
/// (так было с категориями, быстрыми операциями и разовыми покупками). Тест
/// сохраняет запись каждого вида на настоящей базе. Нужна база из
/// docker-compose (порт 5433, `TEST_DB_PORT`); без базы пропускается.
library;

import 'dart:io';

import 'package:famcoin_server/auth_service.dart';
import 'package:famcoin_server/ledger_service.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

void main() {
  Pool? pool;
  String? userId;

  setUpAll(() async {
    final db = Pool.withEndpoints(
      [Endpoint(host: 'localhost', port: int.parse(Platform.environment['TEST_DB_PORT'] ?? '5433'), database: 'famcoin', username: 'famcoin', password: 'famcoin')],
      settings: const PoolSettings(maxConnectionCount: 2, sslMode: SslMode.disable),
    );
    try {
      await db.execute('SELECT 1 FROM entities LIMIT 1').timeout(const Duration(seconds: 3));
      pool = db;
    } catch (_) {}
  });

  tearDownAll(() async {
    final db = pool;
    if (db == null) return;
    if (userId != null) await deleteUserData(db, userId!);
    await db.close();
  });

  test('каждый вид из entityKinds база принимает и отдаёт обратно', () async {
    final db = pool;
    if (db == null) {
      if (Platform.environment['TEST_DB_REQUIRED'] == '1') fail('TEST_DB_REQUIRED=1, а база недоступна');
      markTestSkipped('база не запущена');
      return;
    }
    final created = await db.execute(
      Sql.named("INSERT INTO users (email, password_hash, plan) VALUES (@e, 'x', 'pro') RETURNING id"),
      parameters: {'e': 'kinds-${DateTime.now().microsecondsSinceEpoch}@example.test'},
    );
    userId = created.first[0].toString();
    final ledger = LedgerService(db);
    for (final kind in entityKinds) {
      await ledger.command(userId!, {'type': 'upsertEntity', 'commandId': 'kind-$kind', 'kind': kind, 'entityId': 'id-$kind', 'data': {'name': kind}});
    }
    final view = await ledger.view(userId!);
    expect(view!.entities.keys.toSet(), entityKinds);
  });
}
