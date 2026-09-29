/// Регрессионные проверки по аудиту 28.09.2026 (F02–F06): деньги и связь
/// с сервером. Сервер-заглушка ведёт настоящий журнал ядром, как боевой API:
/// проверяет команды, помнит commandId и умеет «терять» ответ и сеть.
library;

import 'dart:convert';

import 'package:famcoin/state/api_client.dart';
import 'package:famcoin/state/app_state.dart';
import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class FakeServer {
  DateTime now = DateTime(2026, 9, 28);
  bool offline = false;

  /// Следующая команда применяется на сервере, но ответ до клиента не доходит.
  bool dropNextResponse = false;
  int revision = 0;
  int applied = 0;
  final ledger = Ledger();
  final entities = <String, Map<String, Map<String, dynamic>>>{};
  var profile = <String, dynamic>{};
  final seen = <String>{};

  late final AppState state = AppState(
    token: 'test-only',
    clock: () => now,
    api: ApiClient(baseUrl: 'http://fake.test', client: MockClient(_handle)),
  );

  Future<http.Response> _handle(http.Request req) async {
    if (offline) throw http.ClientException('offline');
    if (req.url.path == '/state') return http.Response(jsonEncode(_snapshot()), 200, headers: {'content-type': 'application/json; charset=utf-8'});
    final cmd = jsonDecode(req.body) as Map<String, dynamic>;
    final id = cmd['commandId'] as String;
    if (seen.contains(id)) return http.Response(jsonEncode({'revision': revision, 'repeated': true}), 200);
    try {
      _apply(cmd);
    } on LedgerException catch (e) {
      return http.Response(jsonEncode({'error': 'ledger', 'message': e.message, 'code': e.code}), 422, headers: {'content-type': 'application/json; charset=utf-8'});
    }
    seen.add(id);
    revision++;
    applied++;
    if (dropNextResponse) {
      dropNextResponse = false;
      throw http.ClientException('connection reset');
    }
    return http.Response(jsonEncode({'revision': revision, 'repeated': false}), 200);
  }

  void _apply(Map<String, dynamic> c) {
    switch (c['type']) {
      case 'batch':
        for (final item in (c['commands'] as List).cast<Map<String, dynamic>>()) {
          _apply(item);
        }
      case 'payPlannedPeriod':
      case 'setPlannedPeriodPaid':
        final latest = entities['planned']?[c['plannedId']];
        if (latest == null) throw LedgerException('План платежа не найден', code: 'plannedNotFound');
        for (final part in expandPlannedCommand(c, latest)) {
          _apply(part);
        }
      case 'upsertEntity':
        entities.putIfAbsent(c['kind'] as String, () => {})[c['entityId'] as String] = Map<String, dynamic>.from(c['data'] as Map);
      case 'deleteEntity':
        entities[c['kind']]?.remove(c['entityId']);
      case 'updateProfile':
        profile = {...profile, ...(c['profile'] as Map).cast<String, dynamic>()};
      default:
        applyLedgerCommand(ledger, c);
    }
  }

  Map<String, Object?> _snapshot() => {
        'revision': revision,
        'plan': 'free',
        'email': 'audit@example.test',
        'profile': profile,
        'accounts': [for (final a in ledger.accounts) accountToJson(a)],
        'transactions': [for (final t in ledger.transactions) transactionToJson(t)],
        'reservations': reservationsToJson(ledger),
        'entities': [
          for (final kind in entities.entries)
            for (final e in kind.value.entries) {'kind': kind.key, 'id': e.key, 'data': e.value},
        ],
      };

  Future<void> init() async {
    await state.load();
    await state.sendBatch([
      {'type': 'addMoneyAccount', 'accountId': 'cash'},
      {'type': 'opening', 'id': 'opening', 'date': '2026-09-28', 'account': 'cash', 'amount': '10000000'},
    ]);
  }

  Future<void> plan() => state.upsert('planned', 'rent', {
        'name': 'Rent',
        'amount': '1000000',
        'day': 10,
        'category': 'home',
        'paid': [],
        'start': '2026-09-01',
      });
}

void main() {
  test('F02: правка покупки сохраняет уже сделанный возврат, повторный возврат отклоняется', () async {
    final f = FakeServer();
    await f.init();
    final s = f.state;
    await s.addExpense(amount: kzt(2500), category: 'cafe', account: 'cash', date: s.today);
    final old = s.userTransactions.firstWhere((t) => t.type == EventType.expense);
    await s.refund(old, category: 'cafe', amount: kzt(2500), account: 'cash');
    await s.editExpense(old, splits: {'cafe': kzt(2500)}, account: 'cash', date: old.date, who: 'me', note: 'note only');
    final edited = s.userTransactions.firstWhere((t) => t.type == EventType.expense);
    expect(s.refundedFor(edited.id, 'cafe'), kzt(2500));

    // Даже если форма пропустит проверку — сервер (то же ядро) откажет.
    await expectLater(s.refund(edited, category: 'cafe', amount: kzt(2500), account: 'cash'), throwsA(isA<ApiException>()));
    expect(s.ledger.balance('cash'), kzt(100000));
    expect(f.ledger.balance('cash'), kzt(100000));
  });

  test('возврат уменьшает траты дня покупки, а не дня возврата; покупку с возвратом нельзя удалить', () async {
    final f = FakeServer();
    await f.init();
    final s = f.state;
    await s.addExpense(amount: kzt(1590), category: 'cafe', account: 'cash', date: s.today);
    expect(s.spentToday(), kzt(1590));
    final coffee = s.userTransactions.firstWhere((t) => t.type == EventType.expense);
    await s.refund(coffee, category: 'cafe', amount: kzt(1590), account: 'cash');
    expect(s.spentToday(), 0, reason: 'возврат сегодняшней покупки снимает её с дневного лимита');
    expect(s.ledger.balance('cash'), kzt(100000));

    // «Отменить» после возврата — отказ, иначе деньги вернулись бы дважды.
    await expectLater(s.deleteTransaction(coffee.id), throwsA(isA<LedgerException>().having((e) => e.code, 'code', 'hasRefunds')));
    expect(s.ledger.balance('cash'), kzt(100000));

    // Вчерашняя покупка, возврат сегодня: сегодняшние траты не меняются, вчерашние уменьшаются.
    final yesterday = s.today.subtract(const Duration(days: 1));
    await s.addExpense(amount: kzt(940), category: 'transport', account: 'cash', date: yesterday);
    await s.addExpense(amount: kzt(500), category: 'food', account: 'cash', date: s.today);
    final taxi = s.userTransactions.firstWhere((t) => t.date == yesterday);
    expect(s.dailyExpense(s.monthStart)[yesterday.day - 1], kzt(940));
    await s.refund(taxi, category: 'transport', amount: kzt(940), account: 'cash');
    expect(s.spentToday(), kzt(500));
    expect(s.dailyExpense(s.monthStart)[yesterday.day - 1], 0);

    // Возврат по удалённой покупке (старые данные) не вычитается из трат дня.
    await s.addExpense(amount: kzt(1000), category: 'cafe', account: 'cash', date: s.today);
    final latte = s.userTransactions.firstWhere((t) => t.type == EventType.expense && t.amountOn('expense:cafe') == kzt(1000));
    await s.refund(latte, category: 'cafe', amount: kzt(1000), account: 'cash');
    await s.send({'type': 'reverse', 'txId': latte.id, 'id': 'latte-rev'}); // мимо защиты, как в старых данных
    expect(s.spentToday(), kzt(500));
  });

  test('F03: удаление оплаты снова открывает срок планового платежа', () async {
    final f = FakeServer();
    await f.init();
    await f.plan();
    final s = f.state;
    final due = s.upcoming.firstWhere((d) => d.period == '2026-09');
    await s.payDue(due, account: 'cash', amount: kzt(10000));
    expect(s.planned.single.paid, contains('2026-09'));
    final payment = s.userTransactions.firstWhere((t) => t.type == EventType.expense);
    expect(payment.meta['planned'], 'rent');
    expect(payment.meta['period'], '2026-09');
    await s.deleteTransaction(payment.id);
    expect(s.planned.single.paid.contains('2026-09'), isFalse);
    expect(s.upcoming.any((d) => d.period == '2026-09'), isTrue);
    expect(s.ledger.balance('cash'), kzt(100000));
  });

  test('корзина: удалённая оплата восстанавливается и снова отмечает срок', () async {
    final f = FakeServer();
    await f.init();
    await f.plan();
    final s = f.state;
    final due = s.upcoming.firstWhere((d) => d.period == '2026-09');
    await s.payDue(due, account: 'cash', amount: kzt(10000));
    final payment = s.userTransactions.firstWhere((t) => t.type == EventType.expense);
    await s.deleteTransaction(payment.id);
    expect(s.deletedTransactions.map((t) => t.id), [payment.id]);
    expect(s.ledger.balance('cash'), kzt(100000));

    await s.restoreTransaction(payment.id);
    expect(s.deletedTransactions, isEmpty);
    expect(s.ledger.balance('cash'), kzt(90000));
    expect(s.planned.single.paid, contains('2026-09'));
    expect(s.upcoming.any((d) => d.period == '2026-09'), isFalse);
    final restored = s.userTransactions.firstWhere((t) => t.type == EventType.expense);
    expect(restored.meta['restoredFrom'], payment.id);
    expect(f.ledger.balance('cash'), kzt(90000), reason: 'сервер применил ту же команду');
  });

  test('D64: неизрасходованный дневной лимит переносится на следующий день', () async {
    final f = FakeServer();
    await f.init();
    final s = f.state;
    await s.setDailyLimit(kzt(4000));
    expect(s.dailyLimitSince, s.today);
    expect(s.dailyLimitAvailable, kzt(4000));
    expect(s.dailyLimitCarry, 0);

    // Потратили 1500 из 4000 — на завтра должно перейти 2500.
    await s.addExpense(amount: kzt(1500), category: 'cafe', account: 'cash', date: s.today);
    expect(s.dailyLimitAvailable, kzt(2500));

    f.now = f.now.add(const Duration(days: 1));
    expect(s.dailyLimitAvailable, kzt(4000 + 2500), reason: 'вчерашний остаток 2500 добавился к сегодняшним 4000');
    expect(s.dailyLimitCarry, kzt(2500));
    expect(s.spentToday(), 0);

    // Перерасход сегодня уменьшает доступное на будущее.
    await s.addExpense(amount: kzt(8000), category: 'cafe', account: 'cash', date: s.today);
    expect(s.dailyLimitAvailable, kzt(4000 + 2500 - 8000));

    f.now = f.now.add(const Duration(days: 1));
    expect(s.dailyLimitAvailable, kzt(4000 * 3 - 1500 - 8000), reason: 'перерасход вчера уменьшил доступное и сегодня');

    // Сброс переноса — считаем заново с сегодняшнего дня, сумма лимита та же.
    await s.resetDailyLimitCarry();
    expect(s.dailyLimitSince, s.today);
    expect(s.dailyLimitAvailable, kzt(4000));
    expect(s.dailyLimitCarry, 0);

    // Смена суммы лимита не сбрасывает перенос; удаление лимита — сбрасывает.
    await s.addExpense(amount: kzt(1000), category: 'cafe', account: 'cash', date: s.today);
    final sinceBefore = s.dailyLimitSince;
    await s.setDailyLimit(kzt(5000));
    expect(s.dailyLimitSince, sinceBefore);
    expect(s.dailyLimitAvailable, kzt(5000 - 1000));
    await s.setDailyLimit(null);
    expect(s.dailyLimitSince, isNull);
  });

  test('F04: неоплаченный сентябрьский срок остаётся просроченным в октябре', () async {
    final f = FakeServer();
    await f.init();
    await f.plan();
    expect(f.state.upcoming.any((d) => d.period == '2026-09'), isTrue);
    f.now = DateTime(2026, 10, 1);
    expect(f.state.upcoming.any((d) => d.period == '2026-09'), isTrue);
    expect(f.state.upcoming.any((d) => d.period == '2026-10'), isTrue);
    // Оплата в октябре закрывает именно сентябрьский срок.
    final due = f.state.upcoming.firstWhere((d) => d.period == '2026-09');
    await f.state.payDue(due, account: 'cash', amount: kzt(10000));
    expect(f.state.upcoming.any((d) => d.period == '2026-09'), isFalse);
    expect(f.state.upcoming.any((d) => d.period == '2026-10'), isTrue);
  });

  test('F05: без сети запись не появляется в остатке, после восстановления связи сохраняется один раз', () async {
    final f = FakeServer();
    await f.init();
    final s = f.state;
    f.offline = true;
    await expectLater(s.addIncome(amount: kzt(777), source: 'salary', account: 'cash', date: s.today), throwsA(isA<ApiException>()));
    expect(s.busy, isFalse);
    expect(s.ledger.balance('cash'), kzt(100000));
    expect(s.userTransactions.where((t) => t.type == EventType.income), isEmpty);

    f.offline = false;
    await s.addIncome(amount: kzt(777), source: 'salary', account: 'cash', date: s.today);
    expect(s.ledger.balance('cash'), kzt(100777));
    expect(f.ledger.balance('cash'), kzt(100777));
  });

  test('F06: повтор после потери ответа сервера не создаёт вторую операцию', () async {
    final f = FakeServer();
    await f.init();
    final s = f.state;
    final appliedBefore = f.applied;
    // Форма создаёт id один раз и повторяет их при повторном «Сохранить».
    const txId = 'income-888';
    const commandId = 'cmd-888';
    f.dropNextResponse = true;
    await expectLater(
      s.addIncome(amount: kzt(888), source: 'salary', account: 'cash', date: s.today, id: txId, commandId: commandId),
      throwsA(isA<ApiException>()),
    );
    // Сервер принял, клиент не знает — на экране пока ничего.
    expect(f.ledger.balance('cash'), kzt(100888));
    expect(s.ledger.balance('cash'), kzt(100000));

    await s.addIncome(amount: kzt(888), source: 'salary', account: 'cash', date: s.today, id: txId, commandId: commandId);
    expect(f.applied - appliedBefore, 1);
    expect(s.userTransactions.where((t) => t.type == EventType.income).length, 1);
    expect(s.ledger.balance('cash'), kzt(100888));
    expect(s.revision, f.revision);
  });
}
