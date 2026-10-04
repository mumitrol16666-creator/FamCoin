/// Пять вкладок аналитики (D66): переключаются, месяц общий для «Обзора» и
/// «Расходов», числа на «Бюджете» и «Капитале» совпадают с тем, что реально
/// в журнале — не просто «экран открылся без ошибок».
library;

import 'package:famcoin/ui/analytics/analytics_screen.dart';
import 'package:famcoin/ui/analytics/history_tab.dart';
import 'package:famcoin/ui/analytics/overview_tab.dart';
import 'package:famcoin/ui/analytics/trend_chart.dart';
import 'package:famcoin/ui/budget/budget_forecast_card.dart';
import 'package:famcoin/ui/budget/budget_screen.dart';
import 'package:famcoin/ui/widgets/common.dart';
import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'layout_test.dart' show pumpApp;

void main() {
  testWidgets('История открывает выбранный месяц и не повторяет график капитала', (tester) async {
    await pumpApp(tester, home: const AnalyticsScreen(initialSection: AnalyticsSection.history), size: const Size(390, 844));
    expect(find.descendant(of: find.byType(HistoryTab), matching: find.byType(TrendChart)), findsNothing);
    await tester.tap(find.textContaining('Август'));
    await tester.pumpAndSettle();
    expect(find.byType(OverviewTab), findsOneWidget);
    expect(find.textContaining('Август'), findsOneWidget);
    expect(find.byType(BudgetForecastCard), findsNothing);
    expect(find.text('Наблюдения'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('пять вкладок открываются без ошибок, месяц общий для Обзора и Расходов', (tester) async {
    final f = await pumpApp(tester, home: const AnalyticsScreen(), size: const Size(390, 844));
    await f.state.upsert('limit', 'l1', {'category': 'food', 'amount': '10000000'});
    await f.state.addExpense(amount: kzt(30000), category: 'food', account: 'cash', date: f.state.today);
    await tester.pump();

    Finder tabFinder(String label) => find.descendant(of: find.byType(TabBar), matching: find.text(label));

    for (final tab in ['Обзор', 'Расходы', 'Бюджет', 'Капитал', 'История']) {
      await tester.ensureVisible(tabFinder(tab));
      await tester.tap(tabFinder(tab));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'вкладка «$tab» не должна падать');
    }

    // Обзор → сентябрь; переключаемся на предыдущий месяц через общий навигатор.
    await tester.ensureVisible(tabFinder('Обзор'));
    await tester.tap(tabFinder('Обзор'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Предыдущий месяц').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('Август'), findsWidgets);

    // Расходы должны показывать тот же (прошлый) месяц, а не сентябрь.
    await tester.tap(tabFinder('Расходы'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Август'), findsWidgets);
    expect(find.textContaining('Сентябрь'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Бюджет: план/факт и общий процент совпадают с журналом', (tester) async {
    final f = await pumpApp(tester, home: const AnalyticsScreen(), size: const Size(390, 844));
    await f.state.upsert('limit', 'l1', {'category': 'food', 'amount': '10000000'}); // план 100 000 ₸
    await f.state.addExpense(amount: kzt(40000), category: 'food', account: 'cash', date: f.state.today); // факт 40 000 ₸
    await tester.pump();

    await tester.tap(find.descendant(of: find.byType(TabBar), matching: find.text('Бюджет')));
    await tester.pumpAndSettle();
    expect(find.text(moneyInText(kzt(100000))), findsWidgets); // план
    expect(find.text(moneyInText(kzt(40000))), findsWidgets); // факт
    expect(find.text('40%'), findsOneWidget);
    expect(find.byType(BudgetScreen), findsOneWidget);
    expect(find.text('План / факт'), findsNothing);
    expect(find.text('Доходы'), findsNothing, reason: 'месячный отчёт находится в Обзоре');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('доходов записано меньше, чем платежей (D92): вместо «1 350 % дохода» — подсказка, что внесены не все доходы', (tester) async {
    final f = await pumpApp(tester, home: const AnalyticsScreen(), size: const Size(390, 844));
    final s = f.state;
    // Средний доход считается по прошлым месяцам: в августе записали только 12 000 ₸.
    await s.addIncome(amount: kzt(12000), source: 'side', account: 'cash', date: DateTime(2026, 8, 15));
    await s.upsert('planned', 'rent', {'name': 'Аренда', 'amount': '${kzt(162000)}', 'day': 25, 'category': 'home', 'paid': []});
    expect(s.recurringShareOfIncome, 1350);
    expect(s.incomeLooksIncomplete, isTrue);
    await tester.pump();

    await tester.tap(find.descendant(of: find.byType(TabBar), matching: find.text('Бюджет')));
    await tester.pumpAndSettle();
    expect(find.textContaining('1350%'), findsNothing);
    await tester.scrollUntilVisible(find.byType(BudgetForecastCard), 350, scrollable: find.descendant(of: find.byType(BudgetScreen), matching: find.byType(Scrollable)).first);
    expect(find.textContaining('внесены не все доходы'), findsWidgets);

    await tester.ensureVisible(find.descendant(of: find.byType(TabBar), matching: find.text('Обзор')));
    await tester.tap(find.descendant(of: find.byType(TabBar), matching: find.text('Обзор')));
    await tester.pumpAndSettle();
    expect(find.textContaining('1350%', skipOffstage: false), findsNothing);
    expect(tester.takeException(), isNull);

    // Доходы записаны — доля снова показывается как доля.
    await s.addIncome(amount: kzt(400000), source: 'salary', account: 'cash', date: DateTime(2026, 8, 20));
    expect(s.incomeLooksIncomplete, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Обзор: выбранный день не переживает смену месяца с другой вкладки (F05)', (tester) async {
    final f = await pumpApp(tester, home: const AnalyticsScreen(), size: const Size(390, 844));
    await f.state.addExpense(amount: kzt(1000), category: 'food', account: 'cash', date: DateTime(2026, 8, 31));
    await tester.pump();

    Finder tabFinder(String label) => find.descendant(of: find.byType(TabBar), matching: find.text(label));

    // Август короче сентября только по индексу: уходим в август и выбираем
    // 31-е число через календарь (по умолчанию открывается на последнем дне).
    await tester.tap(find.byTooltip('Предыдущий месяц').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Выбрать день'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ОК')); // подтверждение пикера — по-русски кириллицей
    await tester.pumpAndSettle();

    // Переключаем месяц НАЗАД на сентябрь через «Расходы», а не через «Обзор».
    await tester.tap(tabFinder('Расходы'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Следующий месяц').first);
    await tester.pumpAndSettle();

    // Возврат на «Обзор» с сентябрём (30 дней) и «застрявшим» днём 31 не
    // должен падать RangeError-ом при построении графика.
    await tester.ensureVisible(tabFinder('Обзор'));
    await tester.tap(tabFinder('Обзор'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Капитал: чистый капитал и разбивка совпадают с ledger.netWorth()', (tester) async {
    final f = await pumpApp(tester, home: const AnalyticsScreen(), size: const Size(390, 844));
    await f.state.sendBatch(f.state.newBankDebtCommands(name: 'Kaspi', kind: 'loan', balance: kzt(200000), payment: kzt(20000), day: 5, rate: 20));
    await tester.pump();

    await tester.ensureVisible(find.descendant(of: find.byType(TabBar), matching: find.text('Капитал')));
    await tester.tap(find.descendant(of: find.byType(TabBar), matching: find.text('Капитал')));
    await tester.pumpAndSettle();
    final nw = f.state.ledger.netWorth();
    expect(nw.liabilities, kzt(200000));
    expect(nw.capital, kzt(100000 - 200000)); // 100 000 ₸ открытие счёта из FakeServer.init()
    expect(find.text('−200 000 ₸'), findsOneWidget); // обязательства строкой с минусом
    expect(find.text('−100 000 ₸'), findsWidgets); // капитал отрицательный
    await tester.pumpWidget(const SizedBox());
  });
}
