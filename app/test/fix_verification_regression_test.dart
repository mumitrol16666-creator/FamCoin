// Регрессии повторной проверки: долг, сроки, копилки и рассрочки.
import 'package:famcoin/state/api_client.dart';
import 'package:famcoin/state/models.dart';
import 'package:famcoin/ui/budget/debt_screens.dart';
import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'audit_regression_test.dart' show FakeServer;
import 'layout_test.dart' show pumpApp;
import 'debt_pay_test.dart' show phoneDebt;

final deadline = DateTime(2026, 9, 30);
Future<FakeServer> person() async {
  final f = FakeServer();
  await f.init();
  await f.state.addPersonDebt(kind: 'borrow', amount: kzt(80000), person: 'Друг', account: 'cash', date: f.state.today, dueDate: deadline);
  return f;
}
Future<(FakeServer, GoalInfo)> piggy() async {
  final f = FakeServer();
  await f.init();
  final s = f.state;
  await s.addPurchase(name: 'Колёса', amount: kzt(50000), month: DateTime(2026, 9, 1), category: 'transport');
  await s.startSavingFor(s.purchases.single);
  final goal = s.goals.single;
  await s.depositToGoal(goal, from: 'cash', amount: kzt(50000));
  return (f, goal);
}

void main() {
  test('positive N01/N02 original partial and new-cycle scenarios now work', () async {
    final f = await person();
    final s = f.state;
    final first = s.dueItems(deadline).single;
    await s.payDue(first, account: 'cash', amount: kzt(30000));
    expect(s.dueItems(deadline).single.payAmount, kzt(50000));
    expect(s.monthEndForecast.remainingObligations, kzt(50000));
    await s.payDue(s.dueItems(deadline).single, account: 'cash', amount: kzt(50000));
    expect(s.personDebts, isEmpty);
    await s.addPersonDebt(kind: 'borrow', amount: kzt(20000), person: 'Друг', account: 'cash', date: s.today, dueDate: deadline);
    expect(s.dueItems(deadline).single.planned.id, isNot(first.planned.id));
    await s.payDue(s.dueItems(deadline).single, account: 'cash', amount: kzt(20000));
    expect(s.ledger.balance('cash'), kzt(100000));
    expect(s.personDebts, isEmpty);
    s.dispose();
  });

  test('FV-C01 remaining N01: delete part after final payment permits replacement and rejects over-restoration', () async {
    final f = await person();
    final s = f.state;
    await s.payDue(s.dueItems(deadline).single, account: 'cash', amount: kzt(30000));
    final part = s.userTransactions.singleWhere((t) => t.meta['part'] == true);
    await s.payDue(s.dueItems(deadline).single, account: 'cash', amount: kzt(50000));
    await s.deleteTransaction(part.id);
    expect(s.personDebts.single.amount, kzt(30000));
    final reopened = s.dueItems(deadline).single;
    expect(reopened.payAmount, kzt(30000));
    await s.payDue(reopened, account: 'cash', amount: kzt(30000));
    expect(s.ledger.balance('cash'), kzt(100000));
    expect(s.personDebts, isEmpty);
    await expectLater(s.send({'type': 'restore', 'txId': part.id, 'id': 'restore-old-part'}),
      throwsA(isA<ApiException>().having((e) => e.ledgerCode, 'code', 'principalExceeds')));
    s.dispose();
  });

  test('FV-C02 new N02: stale rescheduling is rejected without a second personal due', () async {
    final f = await person();
    final a = f.state;
    final b = f.newClient();
    await b.load();
    final stale = b.personDebts.single;
    await a.setPersonDue(a.personDebts.single, DateTime(2026, 10, 1));
    await expectLater(b.setPersonDue(stale, DateTime(2026, 10, 2)), throwsA(isA<ApiException>().having((e) => e.ledgerCode, 'code', 'entityChanged')));
    await a.refresh();
    expect(a.personDebts.single.amount, kzt(80000));
    expect(a.planned.where((p) => p.person == 'Друг'), hasLength(1));
    final dues = a.dueItems(DateTime(2026, 10, 31));
    expect(dues.map((d) => d.date), [DateTime(2026, 10, 1)]);
    expect(dues.fold<int>(0, (sum, d) => sum + d.payAmount), kzt(80000));
    a.dispose();
    b.dispose();
  });

  test('positive N03 stale edit preserves paid and rejects stale conditions revision', () async {
    final f = FakeServer();
    await f.init();
    final a = f.state;
    await a.upsert('planned', 'rent', PlannedInfo('rent', 'Аренда', kzt(10000), 30, 'home', null, const {}, start: DateTime(2026, 9, 1)).toJson());
    final b = f.newClient();
    await b.load();
    final old = b.planned.single;
    await a.payDue(a.dueItems(deadline).single, account: 'cash', amount: kzt(10000));
    await b.upsert('planned', 'rent', old.copyWith(name: 'Аренда жилья').toJson());
    await a.refresh();
    expect(a.planned.single.paid, {'2026-09'});
    expect(a.dueItems(deadline), isEmpty);
    await expectLater(a.upsert('planned', 'rent', old.copyWith(name: 'Старый конфликт').toJson()),
        throwsA(isA<ApiException>().having((e) => e.ledgerCode, 'code', 'entityChanged')));
    expect(a.planned.single.name, 'Аренда жилья');
    a.dispose();
    b.dispose();
  });

  test('FV-C05 N03 neighbor: stale editor cannot recreate a deleted plan', () async {
    final f = FakeServer();
    await f.init();
    final a = f.state;
    await a.upsert('planned', 'rent', PlannedInfo('rent', 'Аренда', kzt(10000), 30, 'home', null, const {}, start: DateTime(2026, 9, 1)).toJson());
    final b = f.newClient();
    await b.load();
    final old = b.planned.single;
    await a.payDue(a.dueItems(deadline).single, account: 'cash', amount: kzt(10000));
    await a.delete('planned', 'rent');
    await expectLater(b.upsert('planned', 'rent', old.copyWith(name: 'Старая форма').toJson()), throwsA(isA<ApiException>().having((e) => e.ledgerCode, 'code', 'entityChanged')));
    await a.refresh();
    expect(a.ledger.balance('cash'), kzt(90000));
    expect(a.planned, isEmpty);
    expect(a.dueItems(deadline), isEmpty);
    a.dispose();
    b.dispose();
  });

  test('positive N05 original late withdrawal leaves every dated balance nonnegative', () async {
    final (f, goal) = await piggy();
    final s = f.state;
    f.now = DateTime(2026, 10, 5);
    await s.withdrawFromGoal(goal, to: 'cash', amount: kzt(30000), date: DateTime(2026, 10, 2));
    expect(s.piggyAvailableOn(goal, deadline), kzt(20000));
    await s.payDue(DueItem(s.purchases.single, deadline, '2026-09'), account: 'cash', amount: kzt(50000), date: deadline);
    expect(s.ledger.balance(goal.account!), 0);
    expect(s.ledger.balance(goal.account!, asOf: deadline), kzt(30000));
    expect(s.ledger.balance('cash'), kzt(50000));
    s.dispose();
  });

  test('FV-C03 remaining N05: stale historical piggy transfer is rejected', () async {
    final (f, goal) = await piggy();
    final a = f.state;
    final b = f.newClient();
    await b.load();
    f.now = DateTime(2026, 10, 5);
    await b.withdrawFromGoal(b.goals.single, to: 'cash', amount: kzt(30000), date: DateTime(2026, 10, 2));
    expect(a.piggyAvailableOn(goal, deadline), kzt(50000));
    await expectLater(a.payDue(DueItem(a.purchases.single, deadline, '2026-09'), account: 'cash', amount: kzt(50000), date: deadline),
      throwsA(isA<ApiException>().having((e) => e.ledgerCode, 'code', 'entityChanged')));
    await a.refresh();
    expect(f.ledger.balance(goal.account!), kzt(20000));
    expect(a.ledger.balance('cash'), kzt(80000));
    expect(a.goals, hasLength(1));
    expect(a.ledger.account(goal.account!).archived, isFalse);
    a.dispose();
    b.dispose();
  });

  test('positive CS03 single final installment and interest cap use current debt balance', () async {
    final f = FakeServer();
    await f.init();
    await phoneDebt(f.state, balance: 10000, payment: 50000);
    expect(f.state.dueItems(deadline).single.payAmount, kzt(10000));
    expect(debtDueAmount(f.state.ledger, amount: kzt(50000), debtId: 'red', kind: 'loan', rate: 24), kzt(10200));
    f.state.dispose();
  });

  test('FV-C04 CS03 neighbor: overdue periods allocate the remaining debt only once', () async {
    final f = FakeServer();
    await f.init();
    final s = f.state;
    await phoneDebt(s, balance: 10000, payment: 50000, start: DateTime(2026, 7, 1));
    expect(s.debtBalance('red'), kzt(10000));
    final dues = s.dueItems(deadline);
    expect(dues, hasLength(1));
    expect(dues.fold<int>(0, (sum, d) => sum + d.payAmount), kzt(10000));
    expect(s.monthEndForecast.remainingObligations, kzt(10000));
    s.dispose();
  });

  testWidgets('positive N04 actual bank primary Pay closes its planned period', (tester) async {
    final f = await pumpApp(tester, home: const BankDebtScreen(debtId: 'red'), size: const Size(390, 844));
    final s = f.state;
    await phoneDebt(s);
    await tester.pumpAndSettle();
    for (var step = 0; step < 2; step++) {
      final button = find.widgetWithText(FilledButton, 'Оплатить').last;
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
    }
    expect(s.debtBalance('red'), kzt(90000));
    expect(s.planned.single.paid, {'2026-09'});
    expect(s.dueItems(deadline), isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    s.dispose();
  });

  testWidgets('positive UI extra borrowing after partial payment preserves facts and resets agreed due amount', (tester) async {
    final f = await pumpApp(tester, home: const PersonDebtScreen(person: 'Друг'), size: const Size(390, 844));
    final s = f.state;
    await s.addPersonDebt(kind: 'borrow', amount: kzt(80000), person: 'Друг', account: 'cash', date: s.today, dueDate: deadline, id: 'first-loan');
    await s.payDue(s.dueItems(deadline).single, account: 'cash', amount: kzt(30000));
    final oldPlan = s.planned.single.id;
    final original = transactionToJson(s.ledger.byId('first-loan')!);
    await tester.pumpAndSettle();
    final more = find.text('Взял ещё');
    await tester.ensureVisible(more);
    await tester.tap(more);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '20000');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.dragUntilVisible(find.text('Через неделю'), find.byType(ListView).last, const Offset(0, -200));
    await tester.ensureVisible(find.text('Через неделю'));
    await tester.tap(find.text('Через неделю'));
    await tester.pumpAndSettle();
    final save = find.widgetWithText(FilledButton, 'Сохранить');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(s.personDebts.single.amount, kzt(70000));
    expect(s.planned.single.id, isNot(oldPlan));
    expect(s.planned.single.onDate, DateTime(2026, 10, 5));
    expect(s.dueItems(DateTime(2026, 10, 31)).single.payAmount, kzt(70000));
    expect(transactionToJson(s.ledger.byId('first-loan')!), original);
    expect(s.ledger.transactions.where((t) => t.type == EventType.borrow), hasLength(2));
    expect(s.monthReport.income, 0);
    expect(s.monthReport.expense, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    s.dispose();
  });
}
