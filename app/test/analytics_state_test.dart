/// Новая аналитика (D66): типы расходов, капитал по месяцам, прогноз,
/// план/факт, долговая нагрузка, наблюдения. Проверяет саму сборку данных
/// в AppState — формулы ядра уже проверены отдельно в famcoin_core.
library;

import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audit_regression_test.dart' show FakeServer;

void main() {
  /// «Сегодня» зафиксировано в сентябре, чтобы явно и предсказуемо иметь
  /// прошлые месяцы для истории капитала и среднего дохода.
  FakeServer setUp() {
    final f = FakeServer();
    f.now = DateTime(2026, 9, 20);
    return f;
  }

  test('expenseTypeSplit: сумма по трём типам совпадает с отчётом месяца, своя категория — свободные', () async {
    final f = setUp();
    await f.init();
    final s = f.state;
    await s.addExpense(amount: kzt(50000), category: 'home', account: 'cash', date: s.today); // обязательные
    await s.addExpense(amount: kzt(30000), category: 'food', account: 'cash', date: s.today); // обычные
    await s.addExpense(amount: kzt(20000), category: 'cafe', account: 'cash', date: s.today); // свободные
    final myCategoryId = await s.addCategory(name: 'Хобби', iconIndex: 0, income: false);
    await s.addExpense(amount: kzt(10000), category: myCategoryId, account: 'cash', date: s.today);

    final split = s.expenseTypeSplit(s.monthStart);
    expect(split.mandatory, kzt(50000));
    expect(split.regular, kzt(30000));
    expect(split.discretionary, kzt(30000)); // кафе + своя категория
    expect(split.total, s.monthReport.expense);
  });

  test('netWorthHistory: последняя точка — сегодня, остальные — конец месяца', () async {
    final f = setUp();
    final s = f.state;
    await s.load();
    // Открытие датируем сами (без f.init(), чей 28.09 оказался бы позже «сегодня» 20.09).
    await s.sendBatch([
      {'type': 'addMoneyAccount', 'accountId': 'cash'},
      {'type': 'opening', 'id': 'o1', 'date': '2026-09-01', 'account': 'cash', 'amount': kzt(100000).toString()},
    ]);
    // Капитал по месяцам: июль +100к дохода, август −20к расхода, сентябрь ещё +100к на открытие.
    await s.addIncome(amount: kzt(100000), source: 'salary', account: 'cash', date: DateTime(2026, 7, 15));
    await s.addExpense(amount: kzt(20000), category: 'food', account: 'cash', date: DateTime(2026, 8, 10));

    final history = s.netWorthHistory(3); // июль, август, сентябрь(сегодня)
    expect(history.length, 3);
    expect(history[0].capital, kzt(100000)); // конец июля: только доход
    expect(history[1].capital, kzt(100000 - 20000)); // конец августа: доход минус расход
    expect(history[2].capital, kzt(100000 - 20000 + 100000)); // сегодня: плюс открытие счёта
  });

  test('avgMonthlyIncome: считает только закончившиеся месяцы, без текущего', () async {
    final f = setUp();
    await f.init();
    final s = f.state;
    await s.addIncome(amount: kzt(300000), source: 'salary', account: 'cash', date: DateTime(2026, 6, 5));
    await s.addIncome(amount: kzt(500000), source: 'salary', account: 'cash', date: DateTime(2026, 7, 5));
    await s.addIncome(amount: kzt(400000), source: 'salary', account: 'cash', date: DateTime(2026, 8, 5));
    await s.addIncome(amount: kzt(999000), source: 'salary', account: 'cash', date: s.today); // текущий месяц — не считается
    expect(s.avgMonthlyIncome(months: 3), kzt((300000 + 500000 + 400000) ~/ 3));
  });

  test('recurringMonthly и его доля от дохода', () async {
    final f = setUp();
    await f.init();
    await f.plan(); // аренда 10 000 ₸/мес
    final s = f.state;
    // Доход за все три учитываемых месяца — средний доход не размывается нулями.
    for (final month in [6, 7, 8]) {
      await s.addIncome(amount: kzt(200000), source: 'salary', account: 'cash', date: DateTime(2026, month, 5));
    }
    expect(s.recurringMonthly, kzt(10000));
    expect(s.avgMonthlyIncome(), kzt(200000));
    expect(s.recurringShareOfIncome, closeTo(10000 * 100 / 200000, 0.001));
  });

  test('monthEndForecast: собирает вход из свободных денег, обязательств, среднего расхода и дохода', () async {
    final f = setUp();
    await f.init(); // 100 000 ₸ на счету на 28.09 — сегодня уже 20.09, поэтому баланс сейчас другой
    final s = f.state;
    // Открытие датировано 28 сентября — позже "сегодня" (20-е): переносим на начало месяца отдельным тестом,
    // чтобы не зависеть от будущей операции. Компенсируем: отменяем и заново открываем 1 сентября.
    final opening = s.userTransactions.firstWhere((t) => t.type == EventType.opening);
    await s.deleteTransaction(opening.id);
    await s.send({'type': 'opening', 'id': 'o2', 'date': '2026-09-01', 'account': 'cash', 'amount': (kzt(100000)).toString()});
    await f.plan(); // аренда 10 000 ₸, day=10, start=01.09 — в сентябре ещё не оплачена
    await s.addExpense(amount: kzt(40000), category: 'food', account: 'cash', date: s.today); // расход за 20 прошедших дней

    final due = s.dueItems(s.monthEnd.subtract(const Duration(days: 1))).fold(0, (a, d) => a + d.planned.amount);
    expect(due, kzt(10000), reason: 'аренда сентября ещё не оплачена');

    final f2 = s.monthEndForecast;
    expect(f2.current, kzt(100000 - 40000));
    expect(f2.remainingObligations, kzt(10000));
    expect(f2.expectedRegularSpend, (kzt(40000) ~/ 20) * (s.monthEnd.difference(s.today).inDays - 1));
    expect(f2.expectedIncome, 0); // дохода не было вовсе
    expect(f2.estimate, f2.current - f2.remainingObligations - f2.expectedRegularSpend + f2.expectedIncome);
  });

  test('budgetUsedPercent и monthElapsedPercent', () async {
    final f = setUp();
    await f.init();
    final s = f.state;
    await s.upsert('limit', 'l1', {'category': 'food', 'amount': '10000000'}); // 100 000 ₸
    await s.addExpense(amount: kzt(40000), category: 'food', account: 'cash', date: s.today);
    expect(s.budgetUsedPercent, closeTo(40, 0.001));
    expect(s.monthElapsedPercent, closeTo(20 * 100 / 30, 0.01)); // сентябрь — 30 дней, сегодня 20-е
  });

  test('debtLoadStatus: сумма долгов, платежи, доля от дохода и доля погашения', () async {
    final f = setUp();
    await f.init();
    final s = f.state;
    for (final month in [6, 7, 8]) {
      await s.addIncome(amount: kzt(500000), source: 'salary', account: 'cash', date: DateTime(2026, month, 5));
    }
    await s.sendBatch(s.newBankDebtCommands(name: 'Kaspi Red', kind: 'creditCard', balance: kzt(200000), payment: kzt(25000), day: 15, rate: 22));
    await s.sendBatch(s.newBankDebtCommands(name: 'Авто', kind: 'loan', balance: kzt(1000000), payment: kzt(50000), day: 5, rate: 18));
    // Погасили часть кредита: остаток должен уменьшиться, доля погашения — вырасти.
    final loan = s.bankDebts.firstWhere((d) => d.kind == 'loan');
    await s.payDebt(debtId: loan.id, account: 'cash', principal: kzt(200000), date: s.today);

    final status = s.debtLoadStatus;
    expect(status.totalDebt, kzt(200000) + kzt(1000000 - 200000));
    expect(status.monthlyPayments, kzt(25000 + 50000));
    expect(status.incomeSharePercent, closeTo((25000 + 50000) * 100 / 500000, 0.001));
    // Кредитка исключена из доли погашения (револьверный долг); заём — 20% погашено.
    expect(status.paidPercent, closeTo(20, 0.001));
  });

  test('monthsToPayoffAt: больше доплата — меньше месяцев; без долгов — ноль', () async {
    final f = setUp();
    await f.init();
    final s = f.state;
    expect(s.monthsToPayoffAt(), 0);
    await s.sendBatch(s.newBankDebtCommands(name: 'Авто', kind: 'loan', balance: kzt(500000), payment: kzt(20000), day: 5, rate: 20));
    final base = s.monthsToPayoffAt();
    final withExtra = s.monthsToPayoffAt(extraPerMonth: kzt(20000));
    expect(base, isNotNull);
    expect(withExtra, isNotNull);
    expect(withExtra!, lessThan(base!));
  });

  test('eveningDiscretionaryShare: считает только свободные категории с указанным временем', () async {
    final f = setUp();
    await f.init();
    final s = f.state;
    await s.addExpense(amount: kzt(1000), category: 'cafe', account: 'cash', date: s.today, time: '12:00'); // день
    await s.addExpense(amount: kzt(3000), category: 'cafe', account: 'cash', date: s.today, time: '21:00'); // вечер
    await s.addExpense(amount: kzt(5000), category: 'cafe', account: 'cash', date: s.today); // без времени — не считается
    await s.addExpense(amount: kzt(9000), category: 'home', account: 'cash', date: s.today, time: '22:00'); // не свободные — не считается
    expect(s.eveningDiscretionaryShare(s.monthStart), closeTo(3000 * 100 / (1000 + 3000), 0.001));
  });

  test('eveningDiscretionaryShare: null, если нет операций с указанным временем', () async {
    final f = setUp();
    await f.init();
    final s = f.state;
    await s.addExpense(amount: kzt(1000), category: 'cafe', account: 'cash', date: s.today);
    expect(s.eveningDiscretionaryShare(s.monthStart), isNull);
  });

  test('unplannedLargeExpenses: крупная покупка без лимита на категорию — «не по плану»', () async {
    final f = setUp();
    await f.init();
    final s = f.state;
    await s.upsert('limit', 'l1', {'category': 'food', 'amount': '5000000'});
    await s.addExpense(amount: kzt(25000), category: 'food', account: 'cash', date: s.today); // есть лимит — не считается
    await s.addExpense(amount: kzt(25000), category: 'fun', account: 'cash', date: s.today); // лимита нет — считается
    await s.addExpense(amount: kzt(5000), category: 'fun', account: 'cash', date: s.today); // меньше порога — не считается
    final found = s.unplannedLargeExpenses(s.monthStart, threshold: kzt(20000));
    expect(found.length, 1);
    expect(found.single.amountOn('expense:fun'), kzt(25000));
  });

  test('paydaySpendRatio: траты в день дохода выше обычных', () async {
    final f = setUp();
    await f.init();
    final s = f.state;
    final incomeDay = DateTime(2026, 9, 10);
    final otherDay1 = DateTime(2026, 9, 11);
    final otherDay2 = DateTime(2026, 9, 12);
    await s.addIncome(amount: kzt(300000), source: 'salary', account: 'cash', date: incomeDay);
    await s.addExpense(amount: kzt(40000), category: 'fun', account: 'cash', date: incomeDay);
    await s.addExpense(amount: kzt(10000), category: 'food', account: 'cash', date: otherDay1);
    await s.addExpense(amount: kzt(10000), category: 'food', account: 'cash', date: otherDay2);
    // Знаменатель — все наблюдаемые дни месяца с начала учёта (сентябрь, F13),
    // а не только дни, когда что-то потрачено: 1 день дохода (40000 ₸),
    // 29 обычных (20000 ₸ на двоих, остальные 27 — без трат, но считаются).
    expect(s.paydaySpendRatio(), closeTo(40000 / (20000 / 29), 0.001));
  });

  test('paydaySpendRatio: null без доходных дней в окне', () async {
    final f = setUp();
    await f.init();
    final s = f.state;
    await s.addExpense(amount: kzt(1000), category: 'food', account: 'cash', date: s.today);
    expect(s.paydaySpendRatio(), isNull);
  });

  test('dailyExpense: возврат за другой месяц считается по своей дате, а не по дню покупки (F03)', () async {
    final f = setUp();
    await f.init();
    final s = f.state;
    await s.addExpense(amount: kzt(50000), category: 'food', account: 'cash', date: DateTime(2026, 8, 31));
    final purchase = s.userTransactions.firstWhere((t) => t.type == EventType.expense);
    await s.refund(purchase, category: 'food', amount: kzt(20000), account: 'cash', date: DateTime(2026, 9, 2));

    final august = DateTime(2026, 8, 1);
    final september = DateTime(2026, 9, 1);
    // Сумма дневного графика месяца должна совпадать с месячным отчётом,
    // который всегда считает возврат по его собственной дате.
    expect(s.dailyExpense(august).fold<int>(0, (a, b) => a + b), s.reportFor(august).expense);
    expect(s.dailyExpense(september).fold<int>(0, (a, b) => a + b), s.reportFor(september).expense);
    expect(s.reportFor(august).expense, kzt(50000));
    expect(s.reportFor(september).expense, -kzt(20000));
  });

  test('unplannedLargeExpenses: оплата планового платежа не считается, порог — по сумме всей покупки (F11)', () async {
    final f = setUp();
    await f.init();
    final s = f.state;
    await s.upsert('planned', 'rent', {'name': 'Аренда', 'amount': '3000000', 'day': 10, 'category': 'home', 'paid': [], 'start': '2026-09-01'});
    final due = s.dueItems(s.monthEnd.subtract(const Duration(days: 1))).firstWhere((d) => d.planned.id == 'rent');
    await s.payDue(due, account: 'cash', amount: kzt(30000)); // крупный плановый платёж — заведомо «по плану»

    // Покупка 24 000 ₸ разделена на две категории без лимита: по отдельности
    // ниже порога, но сумма покупки — выше (порог не обходится разделением чека).
    await s.send({
      'type': 'expense',
      'id': 'split1',
      'date': dateToJson(s.today),
      'account': 'cash',
      'splits': {'fun': kzt(12000).toString(), 'clothes': kzt(12000).toString()},
    });

    final found = s.unplannedLargeExpenses(s.monthStart, threshold: kzt(20000));
    expect(found.length, 1);
    expect(found.single.id, 'split1');
  });

  test('dueItems/recurringMonthly/debtLoadStatus: закрытый заём не создаёт обязательств, кредитка на нуле — создаёт (F10)', () async {
    final f = setUp();
    await f.init();
    final s = f.state;
    await s.sendBatch(s.newBankDebtCommands(name: 'Авто', kind: 'loan', balance: kzt(100000), payment: kzt(100000), day: 5, rate: 10));
    final loan = s.bankDebts.firstWhere((d) => d.kind == 'loan');
    await s.payDebt(debtId: loan.id, account: 'cash', principal: kzt(100000), date: s.today);
    expect(s.debtBalance(loan.id), 0);

    expect(s.debtLoadStatus.totalDebt, 0);
    expect(s.debtLoadStatus.monthlyPayments, 0);
    expect(s.recurringMonthly, 0);
    expect(s.dueItems(s.monthEnd.subtract(const Duration(days: 1))), isEmpty);

    // Кредитка на нуле — револьверный долг, баланс может снова вырасти:
    // плановый платёж по ней всё ещё считается (в отличие от закрытого займа).
    await s.sendBatch(s.newBankDebtCommands(name: 'Kaspi Red', kind: 'creditCard', balance: 0, payment: kzt(5000), day: 15, rate: 20));
    expect(s.recurringMonthly, kzt(5000));
  });

  test('expenseTypeFor: владелец может переопределить тип своей категории (F12)', () async {
    final f = setUp();
    await f.init();
    final s = f.state;
    final medsId = await s.addCategory(name: 'Лекарства', iconIndex: 0, income: false, expenseType: ExpenseType.mandatory);
    expect(s.expenseTypeFor(medsId), ExpenseType.mandatory);

    await s.addExpense(amount: kzt(15000), category: medsId, account: 'cash', date: s.today);
    final split = s.expenseTypeSplit(s.monthStart);
    expect(split.mandatory, kzt(15000));
    expect(split.discretionary, 0);

    // Без явного выбора — по-прежнему свободные по умолчанию (D66).
    final hobbyId = await s.addCategory(name: 'Хобби', iconIndex: 1, income: false);
    expect(s.expenseTypeFor(hobbyId), ExpenseType.discretionary);
  });
}
