/// Доставка событий Telegram (S02): событие подтверждается offset-ом только
/// после успешной обработки. Без базы: подставной транспорт, обработчики —
/// заглушки.
library;

import 'package:famcoin_server/telegram.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

/// Отдаёт заранее заданные пачки событий и записывает offset каждого опроса.
class _FakeTelegram extends Telegram {
  _FakeTelegram() : super(Pool.withEndpoints([Endpoint(host: 'localhost', port: 1, database: 'none')], settings: const PoolSettings(sslMode: SslMode.disable)), token: 'test');

  final batches = <List<Map<String, dynamic>>>[];
  final offsets = <int>[];

  @override
  Future<Map<String, dynamic>?> call(String method, Map<String, Object?> body) async {
    if (method != 'getUpdates') return {'ok': true};
    offsets.add(body['offset'] as int);
    // Telegram присылает всё, что не подтверждено offset-ом, и ничего из подтверждённого.
    final pending = [
      for (final b in batches)
        for (final u in b)
          if ((u['update_id'] as int) >= (body['offset'] as int)) u,
    ];
    return {'ok': true, 'result': pending};
  }
}

Map<String, dynamic> _payment(int updateId, String charge) => {
      'update_id': updateId,
      'message': {
        'chat': {'id': 7, 'type': 'private'},
        'from': {'id': 7},
        'successful_payment': {'telegram_payment_charge_id': charge, 'currency': 'XTR', 'total_amount': 950, 'invoice_payload': 'pro:x'},
      },
    };

Map<String, dynamic> _callback(int updateId) => {
      'update_id': updateId,
      'callback_query': {'id': 'q$updateId', 'data': 'x'},
    };

void main() {
  test('оплата: обработчик упал до сохранения — offset не двигается, событие приходит снова и обрабатывается', () async {
    final tg = _FakeTelegram()..batches.add([_callback(99), _payment(100, 'ch1')]);
    final seen = <String>[];
    var failing = true;
    tg.onPayment = (chatId, from, payment) async {
      seen.add('${payment['telegram_payment_charge_id']}');
      if (failing) throw StateError('база недоступна');
    };

    tg.onCallback = (q) async {};
    final wait = await tg.pollOnce();
    expect(seen, ['ch1']);
    expect(tg.offset, 100, reason: 'потерянное событие не подтверждено');
    expect(wait, greaterThan(Duration.zero), reason: 'пауза перед повтором');

    await tg.pollOnce();
    expect(tg.offsets, [0, 100], reason: 'второй опрос просит то же событие, а не 101');
    expect(seen, ['ch1', 'ch1']);

    failing = false;
    expect(await tg.pollOnce(), Duration.zero);
    expect(seen, ['ch1', 'ch1', 'ch1']);
    expect(tg.offset, 101);
    await tg.pollOnce();
    expect(seen.length, 3, reason: 'после подтверждения событие больше не приходит');
  });

  test('две оплаты в пачке: первая падает — вторая не обрабатывается и не подтверждается; после повтора обе проведены по порядку', () async {
    final tg = _FakeTelegram()..batches.add([_callback(99), _payment(100, 'ch1'), _payment(101, 'ch2')]);
    tg.onCallback = (q) async {};
    final done = <String>[];
    var first = 0;
    tg.onPayment = (chatId, from, payment) async {
      final charge = '${payment['telegram_payment_charge_id']}';
      if (charge == 'ch1' && first++ == 0) throw StateError('обрыв');
      done.add(charge);
    };

    await tg.pollOnce();
    expect(done, isEmpty, reason: 'более поздняя оплата не перепрыгивает упавшую');
    expect(tg.offset, 100);

    await tg.pollOnce();
    expect(done, ['ch1', 'ch2']);
    expect(tg.offset, 102);
  });

  test('повторы оплаты не прекращаются, а пауза между ними ограничена', () async {
    final tg = _FakeTelegram()..batches.add([_callback(4), _payment(5, 'ch1')]);
    tg.onCallback = (q) async {};
    var calls = 0;
    tg.onPayment = (chatId, from, payment) async {
      calls++;
      throw StateError('база всё ещё недоступна');
    };
    Duration? last;
    for (var i = 0; i < 10; i++) {
      last = await tg.pollOnce();
    }
    expect(calls, 10);
    expect(tg.offset, 5);
    expect(last, Telegram.retryPauses.last);
  });

  test('обычная кнопка, упавшая при обработке, подтверждается: повтор мог бы выполнить действие дважды', () async {
    final tg = _FakeTelegram()..batches.add([_callback(10), _callback(11)]);
    final seen = <String>[];
    tg.onCallback = (q) async {
      seen.add('${q['id']}');
      if (q['id'] == 'q10') throw StateError('сбой');
    };
    expect(await tg.pollOnce(), Duration.zero);
    expect(seen, ['q10', 'q11']);
    expect(tg.offset, 12);
  });

  test('ответ об ошибке getUpdates offset не трогает', () async {
    final tg = _FakeTelegram();
    final bad = _Broken();
    expect(await bad.pollOnce(), greaterThan(Duration.zero));
    expect(bad.offset, 0);
    expect(tg.offset, 0);
  });
}

class _Broken extends _FakeTelegram {
  @override
  Future<Map<String, dynamic>?> call(String method, Map<String, Object?> body) async => null;
}
