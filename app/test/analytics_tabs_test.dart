/// Пять вкладок аналитики (D66): переключаются, месяц общий для «Обзора» и
/// «Расходов», числа на «Бюджете» и «Капитале» совпадают с тем, что реально
/// в журнале — не просто «экран открылся без ошибок».
library;

import 'package:famcoin/ui/analytics/analytics_screen.dart';
import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'layout_test.dart' show pumpApp;

void main() {
  testWidgets('пять вкладок открываются без ошибок, месяц общий для Обзора и Расходов', (tester) async {
    final f = await pumpApp(tester, home: const AnalyticsScreen(), size: const Size(390, 844));
    await f.state.upsert('limit', 'l1', {'category': 'food', 'amount': '10000000'});
    await f.state.addExpense(amount: kzt(30000), category: 'food', account: 'cash', date: f.state.today);
    await tester.pump();

    Finder tabFinder(String label) => find.descendant(of: find.byType(TabBar), matching: find.text(label));

    for (final tab in ['Обзор', 'Расходы', 'Бюджет', 'Капитал', 'История']) {
      await tester.tap(tabFinder(tab));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'вкладка «$tab» не должна падать');
    }

    // Обзор → сентябрь; переключаемся на предыдущий месяц через общий навигатор.
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
    expect(find.text('100 000 ₸'), findsWidgets); // план
    expect(find.text('40 000 ₸'), findsWidgets); // факт
    expect(find.textContaining('Потрачено 40%'), findsOneWidget);
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
    await tester.tap(tabFinder('Обзор'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Капитал: чистый капитал и разбивка совпадают с ledger.netWorth()', (tester) async {
    final f = await pumpApp(tester, home: const AnalyticsScreen(), size: const Size(390, 844));
    await f.state.sendBatch(f.state.newBankDebtCommands(name: 'Kaspi', kind: 'loan', balance: kzt(200000), payment: kzt(20000), day: 5, rate: 20));
    await tester.pump();

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
