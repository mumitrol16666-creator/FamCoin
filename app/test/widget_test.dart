import 'dart:convert';

import 'package:famcoin/state/api_client.dart';
import 'package:famcoin/state/app_state.dart';
import 'package:famcoin/state/models.dart';
import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Сервер-заглушка: принимает команды и выдаёт ревизии по порядку.
AppState stateWithFakeServer({required DateTime now}) {
  var revision = 0;
  final client = MockClient((req) async {
    if (req.url.path == '/state') {
      return http.Response(
        jsonEncode({'revision': revision, 'plan': 'free', 'email': 'a@b.kz', 'profile': {}, 'accounts': [], 'transactions': [], 'reservations': [], 'entities': []}),
        200,
      );
    }
    revision++;
    return http.Response(jsonEncode({'revision': revision}), 200);
  });
  return AppState(api: ApiClient(client: client, baseUrl: 'http://test'), token: 't', clock: () => now);
}

void main() {
  test('анкета, расход, плановый платёж и ориентир считаются ядром', () async {
    final state = stateWithFakeServer(now: DateTime(2026, 9, 22, 12));
    await state.load();
    final account = state.newAccountCommands(name: 'Kaspi', type: 'card', balance: kzt(300000));
    await state.sendBatch([
      ...account,
      ...state.newBankDebtCommands(name: 'Kaspi Red', kind: 'creditCard', balance: kzt(200000), payment: kzt(25000), day: 1, rate: 22),
      {'type': 'updateProfile', 'profile': {'onboarded': true, 'incomeDay': 5}},
    ]);
    final kaspi = account.first['accountId'] as String;

    expect(state.onboarded, isTrue);
    expect(state.ledger.balance(kaspi), kzt(300000));
    expect(state.totalBankDebt, kzt(200000));
    expect(state.daysToIncome, 13);
    // Платёж 1 октября — до зарплаты 5-го, поэтому входит в обязательства.
    expect(state.obligationsUntilIncome, kzt(25000));
    expect(state.guide.base, kzt(275000));

    await state.addExpense(amount: kzt(2500), category: 'cafe', account: kaspi, date: state.today);
    expect(state.ledger.balance(kaspi), kzt(297500));
    expect(state.spentToday(), kzt(2500));
    // T22: норма дня не меняется после покупки, меняется остаток дня.
    expect(state.guide.dailyBudget, kzt(275000) ~/ 13 ~/ 100 * 100);
    expect(state.guide.remainingToday, state.guide.dailyBudget - kzt(2500));
    expect(state.monthReport.expense, kzt(2500));

    // Оплата срока: деньги уходят, долг уменьшается на тело, срок отмечен.
    final due = state.upcoming.single;
    await state.payDue(due, account: kaspi, amount: kzt(25000), interest: kzt(3000));
    expect(state.debtBalance(state.bankDebts.single.id), kzt(178000));
    expect(state.upcoming, isEmpty);
    expect(state.obligationsUntilIncome, 0);
    expect(state.monthReport.expense, kzt(5500), reason: 'проценты — расход, тело — нет');

    // Удаление операции — отменяющая запись.
    final coffee = state.userTransactions.firstWhere((t) => t.type == EventType.expense);
    await state.deleteTransaction(coffee.id);
    expect(state.ledger.balance(kaspi), kzt(275000));
    expect(state.userTransactions.where((t) => t.id == coffee.id), isEmpty);
  });

  test('T33: оплата планового платежа не уменьшает дневной бюджет второй раз', () async {
    final state = stateWithFakeServer(now: DateTime(2026, 9, 22));
    await state.load();
    final acc = state.newAccountCommands(name: 'Kaspi', type: 'card', balance: kzt(320000));
    await state.sendBatch([
      ...acc,
      {'type': 'upsertEntity', 'kind': 'planned', 'entityId': 'rent', 'data': {'name': 'Аренда', 'amount': '15000000', 'day': 25, 'category': 'home', 'paid': [], 'start': '2026-09-22'}},
      {'type': 'updateProfile', 'profile': {'onboarded': true, 'incomeDay': 10}},
    ]);
    final account = acc.first['accountId'] as String;
    await state.addExpense(amount: kzt(2500), category: 'cafe', account: account, date: state.today);
    final before = state.guide;
    await state.payDue(state.upcoming.single, account: account, amount: kzt(150000));
    final after = state.guide;
    expect(after.dailyBudget, before.dailyBudget);
    expect(after.remainingToday, before.remainingToday);
    expect(state.monthReport.expense, kzt(152500), reason: 'аренда — обычный расход в отчёте');
  });

  test('платёж, добавленный сегодня, не считается просроченным за прошлые даты', () async {
    final state = stateWithFakeServer(now: DateTime(2026, 9, 22));
    await state.load();
    await state.sendBatch([
      ...state.newAccountCommands(name: 'Kaspi', type: 'card', balance: kzt(100000)),
      {'type': 'upsertEntity', 'kind': 'planned', 'entityId': 'rent', 'data': {'name': 'Аренда', 'amount': '15000000', 'day': 25, 'category': 'home', 'paid': [], 'start': '2026-09-22'}},
      {'type': 'upsertEntity', 'kind': 'planned', 'entityId': 'net', 'data': {'name': 'Интернет', 'amount': '600000', 'day': 10, 'category': 'phone', 'paid': [], 'start': '2026-09-22'}},
    ]);
    // До 1 октября: аренда 25 сентября входит, интернет 10 сентября — нет.
    expect(state.obligationsUntilIncome, kzt(150000));
    expect(state.guide.deficit, isTrue, reason: '100 000 < 150 000');
    expect(state.upcoming.map((d) => d.planned.id), ['rent', 'net']);
  });

  test('изменение с разбивкой, возврат и аналитика месяца', () async {
    final state = stateWithFakeServer(now: DateTime(2026, 9, 22));
    await state.load();
    final acc = state.newAccountCommands(name: 'Kaspi', type: 'card', balance: kzt(100000));
    await state.sendBatch([...acc, {'type': 'updateProfile', 'profile': {'onboarded': true}}]);
    final account = acc.first['accountId'] as String;

    await state.addExpense(amount: kzt(12340), category: 'food', account: account, date: DateTime(2026, 9, 21), note: 'Magnum');
    final purchase = state.userTransactions.firstWhere((t) => t.type == EventType.expense);

    // T24: одна покупка на две категории, общий расход не удваивается.
    await state.editExpense(purchase, splits: {'food': kzt(8340), 'household': kzt(4000)}, account: account, date: purchase.date, who: 'shared', note: 'Magnum');
    expect(state.userTransactions.where((t) => t.type == EventType.expense).length, 1);
    expect(state.monthReport.expense, kzt(12340));
    expect(state.categoriesFor(state.monthStart).map((e) => e.key), ['food', 'household']);
    expect(state.ledger.balance(account), kzt(100000 - 12340));

    // Частичный возврат по одной категории.
    final edited = state.userTransactions.firstWhere((t) => t.type == EventType.expense);
    await state.refund(edited, category: 'household', amount: kzt(1500), account: account);
    expect(state.refundedFor(edited.id, 'household'), kzt(1500));
    expect(state.monthReport.expense, kzt(12340 - 1500));
    expect(state.monthReport.income, 0, reason: 'возврат — не доход');
    expect(state.ledger.balance(account), kzt(100000 - 12340 + 1500));

    final days = state.dailyExpense(state.monthStart);
    expect(days.length, 30);
    // Возврат уменьшает расходы дня покупки (21-го), день возврата не трогает.
    expect(days[20], kzt(12340 - 1500));
    expect(days[21], 0);
    expect(state.categoryTransactions('household', state.monthStart).length, 2);
    expect(state.expenseByWho(state.monthStart)['shared'], kzt(12340));
  });

  test('сверка остатка: разница в журнале и отчёте, но не в доходах', () async {
    final state = stateWithFakeServer(now: DateTime(2026, 9, 22));
    await state.load();
    final acc = state.newAccountCommands(name: 'Наличные', type: 'cash', balance: kzt(50000));
    await state.sendBatch([...acc, {'type': 'updateProfile', 'profile': {'onboarded': true}}]);
    final account = acc.first['accountId'] as String;
    await state.adjustBalance(account: account, actualBalance: kzt(48500), reason: 'Пересчитал');
    expect(state.ledger.balance(account), kzt(48500));
    expect(state.monthAdjustments, -kzt(1500));
    expect(state.monthReport.expense, 0);
    expect(state.monthReport.income, 0);
    expect(state.userTransactions.first.type, EventType.adjustment);
    expect(state.userTransactions.first.meta['reason'], 'Пересчитал');
  });

  test('без даты зарплаты: снятие даты сохраняется, период — до конца месяца', () async {
    final state = stateWithFakeServer(now: DateTime(2026, 9, 27));
    await state.load();
    await state.sendBatch([...state.newAccountCommands(name: 'K', type: 'card', balance: kzt(30000)), {'type': 'updateProfile', 'profile': {'onboarded': true, 'incomeDay': 10}}]);
    expect(state.hasPayDay, isTrue);
    expect(state.daysToIncome, 13);
    await state.setIncomeDay(null);
    expect(state.hasPayDay, isFalse);
    expect(state.profile.containsKey('incomeDay'), isTrue);
    expect(state.nextIncomeDate, DateTime(2026, 10, 1));
    expect(state.daysToIncome, 4);
    expect(state.guide.dailyBudget, kzt(7500));
  });

  test('платёж с прошедшей датой: «не оплачено» показывает срок этого месяца как просроченный', () async {
    final state = stateWithFakeServer(now: DateTime(2026, 9, 27));
    await state.load();
    await state.sendBatch([...state.newAccountCommands(name: 'K', type: 'card', balance: kzt(100000)), {'type': 'updateProfile', 'profile': {'onboarded': true}}]);
    await state.sendBatch(state.newBankDebtCommands(name: 'Kaspi', kind: 'creditCard', balance: kzt(82000), payment: kzt(20000), day: 20, paidThisMonth: false));
    expect(state.upcoming.first.date, DateTime(2026, 9, 20));
    await state.sendBatch(state.newBankDebtCommands(name: 'Halyk', kind: 'installment', balance: kzt(50000), payment: kzt(5000), day: 20, paidThisMonth: true));
    final halyk = state.upcoming.where((d) => d.planned.name == 'Halyk').first;
    expect(halyk.date, DateTime(2026, 10, 20));
  });

  test('цель с копилкой: перевод в копилку не тратит дневной лимит и не считается расходом', () async {
    final state = stateWithFakeServer(now: DateTime(2026, 9, 27));
    await state.load();
    final acc = state.newAccountCommands(name: 'Kaspi', type: 'card', balance: kzt(100000));
    await state.sendBatch([...acc, {'type': 'updateProfile', 'profile': {'onboarded': true}}]);
    final kaspi = acc.first['accountId'] as String;
    await state.sendBatch(state.newGoalCommands(name: 'Отпуск', target: kzt(400000)));
    final goal = state.goals.single;
    expect(goal.account, isNotNull);
    expect(state.activeAccounts.map((a) => a.id), [kaspi], reason: 'копилка не предлагается для трат');
    expect(state.piggyAccounts.length, 1);

    await state.depositToGoal(goal, from: kaspi, amount: kzt(30000));
    expect(state.goalSaved(goal), kzt(30000));
    expect(state.ledger.balance(kaspi), kzt(70000));
    expect(state.ledger.liquid(), kzt(70000), reason: 'копилка не ликвидна');
    expect(state.monthReport.expense, 0);
    expect(state.ledger.netWorth().assets, kzt(100000), reason: 'деньги остались вашими');

    await state.withdrawFromGoal(goal, to: kaspi, amount: kzt(10000));
    expect(state.goalSaved(goal), kzt(20000));

    await state.closeGoal(goal, returnTo: kaspi);
    expect(state.goals, isEmpty);
    expect(state.ledger.balance(kaspi), kzt(100000));
    expect(state.piggyAccounts, isEmpty);
  });

  test('своя категория попадает в списки и в подписи', () async {
    final state = stateWithFakeServer(now: DateTime(2026, 9, 27));
    await state.load();
    final id = await state.addCategory(name: 'Собака', iconIndex: 1, income: false);
    expect(expenseCategories.any((c) => c.id == id), isTrue);
    expect(categoryById(id).name, 'Собака');
    expect(state.categoryInUse(id), isFalse);
    customCategories.clear();
  });
}
