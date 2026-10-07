/// Исправления по аудиту расчётов (D138): каждый тест повторяет сценарий, на
/// котором баг был подтверждён.
library;

import 'package:famcoin/ui/analytics/analytics_screen.dart';
import 'package:famcoin/ui/budget/budget_screen.dart';
import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'layout_test.dart' show pumpApp;

List<String> _texts(WidgetTester tester) => [for (final t in tester.widgetList<Text>(find.byType(Text))) if (t.data != null) t.data!.replaceAll(' ', ' ')];

void main() {
  testWidgets('«Деньги» обновляются при открытом экране: расход и новый счёт видны сразу', (tester) async {
    final f = await pumpApp(tester, home: const AnalyticsScreen(initialSection: AnalyticsSection.capital), size: const Size(390, 1200));
    expect(_texts(tester), contains('100 000 ₸'));
    await f.state.addExpense(amount: kzt(40000), category: 'food', account: 'cash', date: f.state.today);
    await tester.pump();
    expect(f.state.ledger.balance('cash'), kzt(60000));
    expect(_texts(tester), contains('60 000 ₸'));
    expect(_texts(tester), isNot(contains('100 000 ₸')));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('«Деньги»: деньги на архивном счёте названы отдельной строкой', (tester) async {
    final f = await pumpApp(tester, home: const AnalyticsScreen(initialSection: AnalyticsSection.capital), size: const Size(390, 1200));
    final s = f.state;
    await s.sendBatch(s.newAccountCommands(name: 'Old card', type: 'card', balance: kzt(50000)));
    final old = s.moneyAccounts.firstWhere((a) => a.name == 'Old card');
    await s.send({'type': 'archiveAccount', 'accountId': old.id});
    await tester.pump();
    expect(_texts(tester), contains('на архивных счетах: 50 000 ₸'));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('«Деньги»: подпись «за 6 месяцев» считает ровно шесть месяцев, а не всю историю', (tester) async {
    final f = await pumpApp(tester, home: const AnalyticsScreen(initialSection: AnalyticsSection.capital), size: const Size(390, 1600));
    final s = f.state;
    await s.addIncome(amount: kzt(200000), source: 'salary', account: 'cash', date: DateTime(2026, 1, 15));
    await s.addIncome(amount: kzt(50000), source: 'salary', account: 'cash', date: DateTime(2026, 8, 10));
    await tester.pump();
    final label = _texts(tester).firstWhere((t) => t.contains('за последние 6 месяцев'), orElse: () => '');
    expect(label, contains('50 000'), reason: 'за полгода капитал вырос на 50 000 ₸, а не на 250 000');
    expect(label, isNot(contains('250 000')));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('рассрочка: последний срок не больше остатка долга, «Списалось» проходит', (tester) async {
    final f = await pumpApp(tester, home: const SizedBox(), size: const Size(390, 1200));
    final s = f.state;
    await s.sendBatch(s.installmentPurchaseCommands(name: 'Phone', amount: kzt(100000), category: 'household', months: 3, day: 10, date: s.today, firstDueNextMonth: false));
    final horizon = DateTime(2027, 12, 31);
    for (var i = 0; i < 2; i++) {
      final due = s.dueItems(horizon).first;
      expect(due.payAmount, kzt(33334));
      await s.payDue(due, account: 'cash', amount: due.payAmount, date: s.today);
    }
    final debtId = s.bankDebts.single.id;
    final last = s.dueItems(horizon).single;
    expect(s.debtBalance(debtId), kzt(33332));
    expect(last.payAmount, kzt(33332), reason: 'платить больше остатка нельзя');
    await s.payDue(last, account: 'cash', amount: last.payAmount, date: s.today);
    expect(s.debtBalance(debtId), 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('покупка, уже отложенная в копилку, не вычитается из свободных денег второй раз', (tester) async {
    final f = await pumpApp(tester, home: const SizedBox(), size: const Size(390, 1200));
    final s = f.state;
    await s.addIncome(amount: kzt(50000), source: 'salary', account: 'cash', date: s.today);
    await s.addPurchase(name: 'Шины', amount: kzt(100000), month: DateTime(s.today.year, s.today.month, 1), category: 'transport');
    await s.startSavingFor(s.purchases.single);
    await s.depositToGoal(s.goals.single, from: 'cash', amount: kzt(100000));
    expect(s.ledger.liquid(), kzt(50000));
    expect(s.freeMoney, kzt(50000));
    expect(s.limitExplain.shortfall, 0);
    expect(s.monthEndForecast.remainingObligations, 0);
    // Сам расход при оплате остаётся полным.
    expect(s.dueItems(DateTime(s.today.year, s.today.month + 1, 0)).single.payAmount, kzt(100000));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('плитка «Платежи» не считает разовые покупки, которых нет на странице платежей', (tester) async {
    final f = await pumpApp(tester, home: const Scaffold(body: BudgetScreen()), size: const Size(390, 1200));
    final s = f.state;
    await s.addPurchase(name: 'Шины', amount: kzt(100000), month: DateTime(2026, 8, 1), category: 'transport');
    await tester.pump();
    expect(_texts(tester).where((t) => t.contains('Просрочено')), isEmpty);
    expect(_texts(tester).where((t) => t.startsWith('Ближайший')), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
}
