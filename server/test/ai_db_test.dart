/// ИИ-консультант (D82) на настоящей базе с подставной моделью: тариф, квота,
/// повтор отправки, разбор месяца. Нужна база из docker-compose (порт 5433,
/// `TEST_DB_PORT`); без базы тесты пропускаются.
library;

import 'dart:io';

import 'package:famcoin_server/ai.dart';
import 'package:famcoin_server/auth_service.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

class _FakeModel extends ChatModel {
  _FakeModel() : super(apiKey: 'test', model: 'fake');

  bool down = false;
  final seen = <List<Map<String, String>>>[];

  @override
  Future<AiReply?> complete(List<Map<String, String>> messages) async {
    seen.add(messages);
    return down ? null : AiReply('ответ ${seen.length}', tokensIn: 700, tokensOut: 90);
  }
}

void main() {
  Pool? pool;
  late _FakeModel model;
  late AiService ai;
  final stamp = DateTime.now().microsecondsSinceEpoch;
  var n = 0;

  setUpAll(() async {
    final db = Pool.withEndpoints(
      [Endpoint(host: 'localhost', port: int.parse(Platform.environment['TEST_DB_PORT'] ?? '5433'), database: 'famcoin', username: 'famcoin', password: 'famcoin')],
      settings: const PoolSettings(maxConnectionCount: 4, sslMode: SslMode.disable),
    );
    try {
      await db.execute('SELECT request_id FROM ai_messages LIMIT 1').timeout(const Duration(seconds: 3));
      pool = db;
    } catch (_) {
      return;
    }
    model = _FakeModel();
    ai = AiService(pool!, model, chatQuota: 3);
  });

  tearDownAll(() async {
    final db = pool;
    if (db == null) return;
    final ids = await db.execute(Sql.named('SELECT id FROM users WHERE email LIKE @m'), parameters: {'m': 'ai-$stamp-%@example.test'});
    for (final r in ids) {
      await deleteUserData(db, r[0].toString());
    }
    await db.close();
  });

  bool skip() {
    if (pool != null) return false;
    if (Platform.environment['TEST_DB_REQUIRED'] == '1') fail('TEST_DB_REQUIRED=1, а база недоступна');
    markTestSkipped('база не запущена');
    return true;
  }

  Future<String> user({String plan = 'pro'}) async {
    final r = await pool!.execute(
      Sql.named("INSERT INTO users (email, password_hash, plan) VALUES (@e, 'x', @p) RETURNING id"),
      parameters: {'e': 'ai-$stamp-${n++}@example.test', 'p': plan},
    );
    return r.first[0].toString();
  }

  Map<String, dynamic> ask(String q, String id) => {'question': q, 'requestId': id, 'locale': 'ru', 'context': {'report': {'income': 300000}}};

  Future<String> code(Future<Object?> Function() f) async {
    try {
      await f();
      return 'ok';
    } on ApiError catch (e) {
      return '${e.status} ${e.code}';
    }
  }

  test('вопрос → ответ сохранён, квота списана; модель видит правила, снимок и историю', () async {
    if (skip()) return;
    final u = await user();
    final a = await ai.chat(u, ask('Сколько я заработал?', 'r1'));
    expect(a['answer'], startsWith('ответ'));
    expect(a['quota'], {'used': 1, 'limit': 3, 'left': 2});
    final sent = model.seen.last;
    expect(sent.first['role'], 'system');
    expect(sent.first['content'], allOf(contains('Отвечай на русском'), isNot(contains('300000'))), reason: 'данные человека не смешиваются с правилами');
    expect(sent[1], containsPair('role', 'user'));
    expect(sent[1]['content'], allOf(startsWith('ДАННЫЕ ПРИЛОЖЕНИЯ'), contains('"income":300000')));
    expect(sent.last, {'role': 'user', 'content': 'Сколько я заработал?'});

    await ai.chat(u, ask('А потратил?', 'r2'));
    expect(model.seen.last.map((m) => m['role']), ['system', 'user', 'user', 'assistant', 'user']);
    final st = await ai.status(u);
    expect((st['messages'] as List).map((m) => (m as Map)['role']), ['user', 'assistant', 'user', 'assistant']);
    expect(st['quota'], {'used': 2, 'limit': 3, 'left': 1});
  });

  test('повтор той же отправки: тот же ответ, модель не спрашивается, квота не списывается', () async {
    if (skip()) return;
    final u = await user();
    final first = await ai.chat(u, ask('Вопрос', 'same'));
    final calls = model.seen.length;
    final again = await ai.chat(u, ask('Вопрос', 'same'));
    expect(again['answer'], first['answer']);
    expect(again['repeated'], isTrue);
    expect(model.seen.length, calls);
    expect((again['quota'] as Map)['used'], 1);
  });

  test('обычный тариф, исчерпанная квота, недоступная модель, плохой запрос', () async {
    if (skip()) return;
    expect(await code(() async => ai.chat(await user(plan: 'free'), ask('Вопрос', 'f1'))), '402 plan_limit');

    final u = await user();
    expect(await code(() => ai.chat(u, {'question': '', 'requestId': 'x', 'context': {}})), '400 bad_request');
    expect(await code(() => ai.chat(u, {'question': 'q', 'requestId': 'x', 'context': 'нет'})), '400 bad_request');
    expect(await code(() => ai.chat(u, {'question': 'q', 'requestId': 'x', 'context': {'big': 'я' * maxContextBytes}})), '413 too_large');

    model.down = true;
    expect(await code(() => ai.chat(u, ask('Вопрос', 'd1'))), '503 ai_unavailable');
    model.down = false;
    expect(((await ai.status(u))['quota'] as Map)['used'], 0, reason: 'неудачная попытка квоту не тратит');

    for (var i = 0; i < 3; i++) {
      await ai.chat(u, ask('Вопрос $i', 'q$i'));
    }
    expect(await code(() => ai.chat(u, ask('Ещё', 'q9'))), '429 ai_quota');
    expect((await ai.chat(u, ask('Вопрос 0', 'q0')))['repeated'], isTrue, reason: 'уже полученный ответ доступен и после исчерпания квоты');

    await ai.clear(u);
    final st = await ai.status(u);
    expect(st['messages'], isEmpty);
    expect((st['quota'] as Map)['left'], 0, reason: 'новый разговор квоту не возвращает');
  });

  test('разбор месяца: пишется один раз, текущий месяц не разбирается', () async {
    if (skip()) return;
    final u = await user();
    expect((await ai.reviewFor(u, '2026-08'))['review'], isNull);
    final first = await ai.review(u, {'period': '2026-08', 'locale': 'ru', 'context': {'report': {'income': 1}}});
    final calls = model.seen.length;
    expect((first['review'] as Map)['text'], startsWith('ответ'));
    expect(model.seen.last.first['content'], contains('ежемесячный разбор'));
    final again = await ai.review(u, {'period': '2026-08', 'locale': 'ru', 'context': {'report': {'income': 2}}});
    expect((again['review'] as Map)['text'], (first['review'] as Map)['text']);
    expect(model.seen.length, calls);
    expect(((await ai.status(u))['quota'] as Map)['used'], 0, reason: 'разбор не тратит квоту чата');

    final now = DateTime.now().toUtc().add(const Duration(hours: 5));
    expect(await code(() => ai.review(u, {'period': '${now.year}-${now.month.toString().padLeft(2, '0')}', 'context': {}})), '400 bad_request');
    expect(await code(() => ai.review(u, {'period': 'сентябрь', 'context': {}})), '400 bad_request');
  });

  test('ответ модели: JSON, простой текст, пустота', () {
    expect(parseReply('{"answer": " Да. ", "insufficient_data": true}')!.text, 'Да.');
    expect(parseReply('{"answer": "Да.", "insufficient_data": true}')!.insufficientData, isTrue);
    expect(parseReply('Просто текст')!.text, 'Просто текст');
    expect(parseReply('{"other": 1}'), isNull);
    expect(parseReply('  '), isNull);
  });
}
