// Diagnostic probes for immutable baseline fcd1fa1. These intentionally assert
// observed discrepancies, not the corrected behaviour; see app-findings.md.
import 'package:famcoin/state/app_scope.dart';
import 'package:famcoin/state/models.dart';
import 'package:famcoin/ui/budget/sheets.dart';
import 'package:famcoin/ui/more/family_screen.dart';
import 'package:famcoin/ui/widgets/common.dart';
import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audit_regression_test.dart' show FakeServer;
import 'ux_gaps_a_test.dart' show pumpForm, pumpWith, openForm, enterNote, save, tapText;

void main() {
  test('APP-01 monthly aggregate ignores weekly/yearly frequency', () async {
    final f = FakeServer();
    await f.init();
    final s = f.state;
    await s.upsert('planned', 'weekly', PlannedInfo('weekly', 'Tutor', kzt(5000), 1, 'education', null, const {}, start: DateTime(2026, 9, 1), every: everyWeek, weekday: 3).toJson());
    await s.upsert('planned', 'annual', PlannedInfo('annual', 'Insurance', kzt(120000), 15, 'other', null, const {}, start: DateTime(2026, 9, 1), every: everyYear, monthOfYear: 11).toJson());
    final october = DateTime(2026, 10, 1);
    final octoberDue = s.planned.fold<int>(0, (sum, p) => sum + p.schedule.occurrences(october, DateTime(2026, 10, 31)).length * p.amount);
    expect(octoberDue, kzt(20000));
    expect(s.recurringMonthly, kzt(125000));
    print('APP-01: October due = 20000 KZT; recurringPaymentsPerMonth = 125000 KZT.');
  });

  test('APP-02 backdated installment starts from entry day instead of purchase day', () async {
    final f = FakeServer();
    await f.init();
    f.now = DateTime(2026, 10, 5);
    final s = f.state;
    await s.sendBatch(s.installmentPurchaseCommands(name: 'Phone', amount: kzt(120000), category: 'phone', months: 12, day: 25, date: DateTime(2026, 9, 10)));
    expect(s.reportFor(DateTime(2026, 9, 1)).expense, kzt(120000));
    expect(s.planned.single.start, DateTime(2026, 11, 1));
    expect(s.dueItems(DateTime(2026, 10, 31)), isEmpty);
    expect(s.dueItems(DateTime(2026, 11, 30)).single.date, DateTime(2026, 11, 25));
    print('APP-02: purchase 2026-09-10; entered 2026-10-05; first due 2026-11-25, not 2026-10-25.');
  });

  testWidgets('APP-03 accepted payment with lost response is charged twice by form retry', (tester) async {
    final f = await pumpWith(tester, (c) => showPayDueSheet(c, AppScope.of(c).state.dueItems(DateTime(2026, 9, 30)).first));
    await f.plan();
    await openForm(tester);
    f.dropNextResponse = true;
    await tester.tap(find.widgetWithText(FilledButton, 'Оплатить'));
    await tester.pumpAndSettle();
    expect(f.ledger.balance('cash'), kzt(90000));
    expect(f.state.ledger.balance('cash'), kzt(100000));
    expect(find.widgetWithText(FilledButton, 'Оплатить'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Оплатить'));
    await tester.pumpAndSettle();
    expect(f.state.ledger.balance('cash'), kzt(80000));
    expect(f.ledger.balance('cash'), kzt(80000));
    expect(f.state.userTransactions.where((t) => t.meta['planned'] == 'rent'), hasLength(2));
    expect(f.state.planned.single.paid, {'2026-09'});
    print('APP-03: one intended 10000 KZT payment + lost reply + retry -> two expenses, cash 80000 instead of 90000.');
  });

  testWidgets('APP-04 intercepted credit payment leaves the corresponding due open', (tester) async {
    final f = await pumpForm(tester);
    final s = f.state;
    await s.sendBatch(s.newBankDebtCommands(name: 'Kaspi Red', kind: 'installment', balance: kzt(100000), payment: kzt(10000), day: 25, paidThisMonth: false));
    expect(s.dueItems(DateTime(2026, 9, 30)), hasLength(1));
    await openForm(tester);
    await tester.enterText(find.byType(TextField).first, '10000');
    await enterNote(tester, 'Kaspi Red за сентябрь');
    await save(tester);
    await tapText(tester, 'Платёж по кредиту');
    await tester.tap(find.widgetWithText(FilledButton, 'Оплатить'));
    await tester.pumpAndSettle();
    expect(s.debtBalance(s.bankDebts.single.id), kzt(90000));
    expect(s.planned.single.paid, isEmpty);
    expect(s.dueItems(DateTime(2026, 9, 30)).single.period, '2026-09');
    expect(s.userTransactions.first.meta['planned'], isNull);
    print('APP-04: Sept payment 10000 KZT recorded; debt falls to 90000, but Sept due remains unpaid 10000 KZT.');
  });

  testWidgets('APP-05 family page ignores refund while analytics subtracts it', (tester) async {
    final f = await pumpWith(tester, (c) => Navigator.push(c, MaterialPageRoute<void>(builder: (_) => const FamilyScreen())));
    final s = f.state;
    await s.setFamilyMode(true);
    await s.addExpense(amount: kzt(10000), category: 'clothes', account: 'cash', date: s.today, who: 'shared');
    final purchase = s.userTransactions.firstWhere((t) => t.type == EventType.expense);
    await s.refund(purchase, category: 'clothes', amount: kzt(4000), account: 'cash');
    expect(s.expenseByWho(s.monthStart)['shared'], kzt(6000));
    await openForm(tester);
    final row = find.widgetWithText(ListTile, 'Общее');
    final shown = tester.widget<MoneyText>(find.descendant(of: row, matching: find.byType(MoneyText)));
    expect(shown.minor, kzt(10000));
    print('APP-05: family page shared 10000 KZT; analytics shared 6000 KZT after a 4000 refund.');
  });

  test('APP-06 family analytics excludes installment expenses even with who field', () async {
    final f = FakeServer();
    await f.init();
    final s = f.state;
    await s.setFamilyMode(true);
    await s.sendBatch(s.installmentPurchaseCommands(name: 'Family phone', amount: kzt(120000), category: 'phone', months: 12, day: 25, date: s.today, who: 'shared'));
    expect(s.monthReport.expense, kzt(120000));
    expect(s.categoriesFor(s.monthStart).single.value, kzt(120000));
    expect(s.expenseByWho(s.monthStart), isEmpty);
    print('APP-06: installment expense 120000 KZT assigned shared is absent from family analytics.');
  });

  test('APP-07 dated purchase paid from goal transfers funds on a different day', () async {
    final f = FakeServer();
    await f.init();
    final s = f.state;
    await s.addPurchase(name: 'Winter tyres', amount: kzt(50000), month: DateTime(2026, 9, 1), category: 'transport');
    await s.startSavingFor(s.purchases.single);
    final goal = s.goals.single;
    await s.depositToGoal(goal, from: 'cash', amount: kzt(50000));
    f.now = DateTime(2026, 10, 5);
    final due = s.dueItems(DateTime(2026, 10, 31)).single;
    await s.payDue(due, account: 'cash', amount: kzt(50000), date: DateTime(2026, 9, 30));
    final expense = s.userTransactions.firstWhere((t) => t.type == EventType.expense);
    final release = s.userTransactions.firstWhere((t) => t.type == EventType.transfer && t.amountOn(goal.account!) < 0);
    expect(expense.date, DateTime(2026, 9, 30));
    expect(release.date, DateTime(2026, 10, 5));
    expect(s.ledger.balance('cash', asOf: DateTime(2026, 9, 30)), 0);
    expect(s.ledger.balance(goal.account!, asOf: DateTime(2026, 9, 30)), kzt(50000));
    print('APP-07: Sept 30 saved-funded purchase: cash 0/piggy 50000 instead of cash 50000/piggy 0; release dated Oct 5.');
  });
}
