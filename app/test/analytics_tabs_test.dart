/// Три вкладки аналитики (D136: «Месяц», «Деньги», «Бюджет»): переключаются,
/// числа на «Бюджете» и «Деньгах» совпадают с тем, что реально в журнале —
/// не просто «экран открылся без ошибок».
library;

import 'package:famcoin/ui/analytics/analytics_screen.dart';
import 'package:famcoin/ui/analytics/money_tab.dart';
import 'package:famcoin/ui/analytics/month_tab.dart';
import 'package:famcoin/ui/analytics/trend_chart.dart';
import 'package:famcoin/ui/budget/budget_forecast_card.dart';
import 'package:famcoin/ui/budget/budget_screen.dart';
import 'package:famcoin/ui/widgets/common.dart';
import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'layout_test.dart' show pumpApp;

void main() {
  testWidgets('сравнение месяцев внизу «Месяца» открывает выбранный месяц, график капитала там не повторяется', (tester) async {
    // Высокий экран: длинный список «Месяца» строится целиком, без прокрутки.
    await pumpApp(tester, home: const AnalyticsScreen(initialSection: AnalyticsSection.history), size: const Size(390, 3200));
    expect(find.byType(MonthTab), findsOneWidget);
    expect(find.descendant(of: find.byType(MonthTab), matching: find.byType(TrendChart)), findsNothing);
    final august = find.textContaining('Август');
    await tester.tap(august);
    await tester.pumpAndSettle();
    expect(find.byType(MonthTab), findsOneWidget);
    expect(find.textContaining('Август'), findsWidgets);
    expect(find.byType(BudgetForecastCard), findsNothing);
    expect(find.text('Наблюдения'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('три вкладки открываются без ошибок, капитал и счета — на «Деньгах»', (tester) async {
    final f = await pumpApp(tester, home: const AnalyticsScreen(), size: const Size(390, 844));
    await f.state.upsert('limit', 'l1', {'category': 'food', 'amount': '10000000'});
    await f.state.addExpense(amount: kzt(30000), category: 'food', account: 'cash', date: f.state.today);
    await tester.pump();

    Finder tabFinder(String label) => find.descendant(of: find.byType(TabBar), matching: find.text(label));

    for (final tab in ['Месяц', 'Деньги', 'Бюджет']) {
      await tester.ensureVisible(tabFinder(tab));
      await tester.tap(tabFinder(tab));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'вкладка «$tab» не должна падать');
    }
    expect(find.byTooltip('Предыдущий месяц'), findsNothing);

    await tester.tap(tabFinder('Деньги'));
    await tester.pumpAndSettle();
    expect(find.byType(MoneyTab), findsOneWidget);
    expect(find.text('Всего денег сейчас'), findsOneWidget);
    expect(find.byType(TrendChart), findsOneWidget);

    // Предыдущий месяц на «Месяце»: он показывается и после возврата на вкладку.
    await tester.tap(tabFinder('Месяц'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Предыдущий месяц').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('Август'), findsWidgets);
    await tester.tap(tabFinder('Деньги'));
    await tester.pumpAndSettle();
    await tester.tap(tabFinder('Месяц'));
    await tester.pumpAndSettle();
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
    expect(find.byType(BudgetScreen), findsOneWidget);
    // «Бюджет» — кнопки направлений со сводкой (D135); подробности — на экране «Лимиты».
    expect(find.textContaining('Потрачено ${moneyInText(kzt(40000))} из ${moneyInText(kzt(100000))}'), findsOneWidget);
    await tester.tap(find.text('Лимиты'));
    await tester.pumpAndSettle();
    expect(find.text(moneyInText(kzt(100000))), findsWidgets); // план
    expect(find.text(moneyInText(kzt(40000))), findsWidgets); // факт
    expect(find.text('40%'), findsOneWidget);
    Navigator.of(tester.element(find.byType(BudgetLimitsPage))).pop();
    await tester.pumpAndSettle();
    expect(find.text('План / факт'), findsNothing);
    expect(find.text('Доходы'), findsNothing, reason: 'месячный отчёт находится на вкладке «Месяц»');
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
    await tester.tap(find.text('Прогноз'));
    await tester.pumpAndSettle();
    expect(find.textContaining('внесены не все доходы'), findsWidgets);
    Navigator.of(tester.element(find.byType(BudgetForecastPage))).pop();
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.descendant(of: find.byType(TabBar), matching: find.text('Месяц')));
    await tester.tap(find.descendant(of: find.byType(TabBar), matching: find.text('Месяц')));
    await tester.pumpAndSettle();
    expect(find.textContaining('1350%', skipOffstage: false), findsNothing);
    expect(tester.takeException(), isNull);

    // Доходы записаны — доля снова показывается как доля.
    await s.addIncome(amount: kzt(400000), source: 'salary', account: 'cash', date: DateTime(2026, 8, 20));
    expect(s.incomeLooksIncomplete, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Месяц: выбранный день не переживает смену месяца (F05)', (tester) async {
    final f = await pumpApp(tester, home: const AnalyticsScreen(), size: const Size(390, 3200));
    await f.state.addExpense(amount: kzt(1000), category: 'food', account: 'cash', date: DateTime(2026, 8, 31));
    await tester.pump();

    // Уходим в август и выбираем 31-е число через календарь (по умолчанию
    // открывается на последнем дне).
    await tester.tap(find.byTooltip('Предыдущий месяц').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Выбрать день'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ОК')); // подтверждение пикера — по-русски кириллицей
    await tester.pumpAndSettle();

    // Возврат на сентябрь (30 дней) с «застрявшим» днём 31 не должен падать
    // RangeError-ом при построении графика.
    await tester.tap(find.byTooltip('Следующий месяц').first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Деньги: чистый капитал и разбивка совпадают с ledger.netWorth()', (tester) async {
    final f = await pumpApp(tester, home: const AnalyticsScreen(), size: const Size(390, 844));
    await f.state.sendBatch(f.state.newBankDebtCommands(name: 'Kaspi', kind: 'loan', balance: kzt(200000), payment: kzt(20000), day: 5, rate: 20));
    await tester.pump();

    await tester.ensureVisible(find.descendant(of: find.byType(TabBar), matching: find.text('Деньги')));
    await tester.tap(find.descendant(of: find.byType(TabBar), matching: find.text('Деньги')));
    await tester.pumpAndSettle();
    final nw = f.state.ledger.netWorth();
    expect(nw.liabilities, kzt(200000));
    expect(nw.capital, kzt(100000 - 200000)); // 100 000 ₸ открытие счёта из FakeServer.init()
    expect(find.text('−200 000 ₸'), findsOneWidget); // обязательства строкой с минусом
    expect(find.text('−100 000 ₸'), findsWidgets); // капитал отрицательный
    await tester.pumpWidget(const SizedBox());
  });

  for (final locale in ['ru', 'kk']) {
    testWidgets('«Месяц» и «Деньги» на 320 px и тексте 200 % без переполнений, $locale', (tester) async {
      final f = await pumpApp(tester, home: const AnalyticsScreen(), size: const Size(320, 2600), textScale: 2, locale: Locale(locale));
      final s = f.state;
      await s.addExpense(amount: kzt(30000), category: 'food', account: 'cash', date: s.today);
      await s.addIncome(amount: kzt(400000), source: 'salary', account: 'cash', date: s.today);
      await s.addPersonDebt(kind: 'lendOut', amount: kzt(50000), person: 'Друг', account: 'cash', date: s.today);
      await s.sendBatch(s.newBankDebtCommands(name: 'Kaspi', kind: 'loan', balance: kzt(200000), payment: kzt(20000), day: 5, rate: 20));
      await tester.pumpAndSettle();
      expect(find.byType(MonthTab), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.descendant(of: find.byType(TabBar), matching: find.byType(Tab)).at(1));
      await tester.pumpAndSettle();
      expect(find.byType(MoneyTab), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
