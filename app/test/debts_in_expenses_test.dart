/// D98: всё, что ушло со счёта, — в расходах. Платежи по кредитам и долгам —
/// строкой «Кредиты и долги»; «Реализовать цель» списывает накопленное
/// расходом; «Уже оплачено» в сверке записывает факт датой срока.
library;

import 'package:famcoin/l10n/app_localizations_ru.dart';
import 'package:famcoin/state/models.dart';
import 'package:famcoin/ui/budget/month_close_screen.dart';
import 'package:famcoin/ui/home/home_screen.dart';
import 'package:famcoin/ui/shell.dart';
import 'package:famcoin/ui/widgets/common.dart';
import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audit_regression_test.dart' show FakeServer;
import 'layout_test.dart' show pumpApp;

final ru = AppLocalizationsRu();

void main() {
  test('платёж по кредиту: тело — строкой «Кредиты и долги», проценты — расход, «Расходы» сверки — всё вместе', () async {
    final f = FakeServer();
    await f.init();
    final s = f.state;
    await s.sendBatch(s.newBankDebtCommands(name: 'Кредит', kind: 'loan', balance: kzt(500000), payment: kzt(50000), day: 10, paidThisMonth: false));
    final due = s.dueItems(s.today).firstWhere((d) => d.planned.debtId != null);
    await s.payDue(due, account: 'cash', amount: kzt(50000), interest: kzt(5000));

    final r = s.monthReport;
    expect(r.expense, kzt(5000));
    expect(r.debtPayments, kzt(45000));
    expect(r.total, kzt(50000));
    expect(r.result, -kzt(50000));

    final cats = {for (final e in s.categoriesFor(s.monthStart)) e.key: e.value};
    expect(cats, {debtsCategory: kzt(45000), 'interest': kzt(5000)});
    expect(s.categoryTransactions(debtsCategory, s.monthStart).map((t) => t.type), [EventType.loanPayment]);
    expect(s.expenseTypeSplit(s.monthStart).mandatory, kzt(50000));

    final sum = s.monthSummary(s.monthStart);
    expect(sum.expense, kzt(50000));
    expect(sum.debtPayments, kzt(45000));
    expect(sum.top.first.key, debtsCategory);
    // Дневной лимит платёж не трогает: он запланированный.
    expect(s.spentToday(), 0);
  });

  test('«Реализовать цель»: накопленное списывается расходом в категорию, вне лимита, цель закрыта', () async {
    final f = FakeServer();
    await f.init();
    final s = f.state;
    final before = s.ledger.balance('cash');
    await s.sendBatch(s.newGoalCommands(name: 'Ноутбук', target: kzt(300000)));
    final g = s.goals.single;
    await s.depositToGoal(g, from: 'cash', amount: kzt(60000));
    expect(s.goalSaved(g), kzt(60000));
    expect(s.ledger.balance('cash'), before - kzt(60000));

    await s.realizeGoal(g, amount: kzt(80000), category: 'education', account: 'cash');
    expect(s.goals, isEmpty);
    expect(s.piggyAccounts, isEmpty);
    // 60 000 вернулись и ушли вместе с доплатой 20 000.
    expect(s.ledger.balance('cash'), before - kzt(80000));
    expect(s.monthReport.expense, kzt(80000));
    expect(s.categoriesFor(s.monthStart).single.key, 'education');
    expect(s.spentToday(), 0, reason: 'покупка на цель — вне дневного лимита');
    expect(s.spentPlannedBetween(s.today, s.today), kzt(80000));
    final tx = s.userTransactions.firstWhere((t) => t.type == EventType.expense);
    expect(tx.meta['note'], 'Ноутбук');
    expect(tx.meta['goal'], g.id);
  });

  testWidgets('сверка: «Уже оплачено» открывает оплату датой срока и записывает расход этой датой', (tester) async {
    // Высокий экран: форма оплаты целиком в кадре, без прокрутки листа.
    final f = await pumpApp(tester, home: MonthCloseScreen(month: DateTime(2026, 9, 1)), size: const Size(390, 1400));
    final s = f.state;
    await s.upsert('planned', 'rent', PlannedInfo('', 'Аренда', kzt(150000), 5, 'home', null, const {}, start: DateTime(2026, 9, 1)).toJson());
    await tester.pump(const Duration(milliseconds: 500));

    await tester.ensureVisible(find.text(ru.monthAlreadyPaid));
    await tester.pump();
    await tester.tap(find.text(ru.monthAlreadyPaid));
    // Лист выезжает снизу: кадр на старт анимации, потом её длительность.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text(ru.payAlreadyTitle('Аренда')), findsOneWidget);
    expect(find.text('5 сент.'), findsOneWidget, reason: 'дата — срок платежа, не сегодня');
    expect(find.text(ru.markPaidOnly), findsOneWidget);

    // Лист формы прокручивается сам (SingleChildScrollView), ensureVisible его не двигает.
    await tester.ensureVisible(find.text(ru.pay));
    await tester.pump();
    await tester.tap(find.text(ru.pay));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    final tx = s.userTransactions.firstWhere((t) => t.type == EventType.expense);
    expect(tx.date, DateTime(2026, 9, 5));
    expect(s.monthReport.expense, kzt(150000));
    expect(s.dueItems(s.today).where((d) => d.planned.id == 'rent'), isEmpty, reason: 'срок отмечен оплаченным');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('главная: «Расходы» с подписью «в т.ч. кредиты и долги»', (tester) async {
    final f = await pumpApp(tester, home: const Shell(), size: const Size(390, 844), prefs: const {'pushPromptDismissed': true, 'tipsEnabled': false});
    final s = f.state;
    await s.sendBatch(s.newBankDebtCommands(name: 'Кредит', kind: 'loan', balance: kzt(500000), payment: kzt(50000), day: 10, paidThisMonth: false));
    final due = s.dueItems(s.today).firstWhere((d) => d.planned.debtId != null);
    await s.payDue(due, account: 'cash', amount: kzt(50000));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.dragUntilVisible(find.text(ru.monthReport), find.byType(ListView).first, const Offset(0, -300));
    await tester.pump(const Duration(milliseconds: 600));
    // Вкладка «Бюджет» в оболочке построена за кадром с той же подписью — ищем только на главной.
    final found = tester.widgetList<Text>(find.descendant(of: find.byType(HomeScreen), matching: find.textContaining('кредиты и долги'))).map((t) => t.data).toList();
    expect(found, [ru.reportIncludesDebts(moneyInText(kzt(50000)))], reason: 'найдено: $found');
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox());
  });
}
