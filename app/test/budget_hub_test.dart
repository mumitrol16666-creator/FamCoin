/// «Бюджет» как набор кнопок-направлений (D135): сводки, значки внимания,
/// переходы на отдельные экраны, вёрстка на узком экране.
library;

import 'package:famcoin/state/models.dart';
import 'package:famcoin/ui/budget/budget_screen.dart';
import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'layout_test.dart' show pumpApp;

void main() {
  testWidgets('пустой бюджет: шесть кнопок со сводкой «нет», без значков внимания', (tester) async {
    await pumpApp(tester, home: const BudgetScreen(), size: const Size(390, 844));
    await tester.pumpAndSettle();
    for (final title in ['Лимиты', 'Платежи', 'Разовые покупки', 'Цели', 'Долги', 'Прогноз']) {
      expect(find.text(title), findsOneWidget, reason: title);
    }
    expect(find.text('Не заданы'), findsOneWidget);
    expect(find.text('Платежей нет'), findsOneWidget);
    expect(find.text('Нет запланированных'), findsOneWidget);
    expect(find.text('Целей нет'), findsOneWidget);
    expect(find.text('Долгов нет'), findsOneWidget);
    expect(find.textContaining('К концу месяца ≈'), findsOneWidget);
    expect(find.textContaining('Превышены'), findsNothing);
    expect(find.textContaining('Просрочено'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('значки внимания и сводки: превышенный лимит, просроченный платёж, долги, цель', (tester) async {
    final f = await pumpApp(tester, home: const BudgetScreen(), size: const Size(390, 844));
    final s = f.state;
    await s.upsert('limit', 'l1', {'category': 'food', 'amount': '${kzt(10000)}'});
    await s.addExpense(amount: kzt(12000), category: 'food', account: 'cash', date: s.today);
    await s.upsert('planned', 'rent', PlannedInfo('rent', 'Аренда', kzt(150000), 10, 'home', null, const {}, start: DateTime(2026, 9, 1)).toJson());
    await s.addPersonDebt(kind: 'borrow', amount: kzt(80000), person: 'Теща', account: 'cash', date: s.today);
    await s.addPersonDebt(kind: 'lendOut', amount: kzt(20000), person: 'Друг', account: 'cash', date: s.today);
    await s.sendBatch(s.newGoalCommands(name: 'Отпуск', target: kzt(200000)));
    await s.depositToGoal(s.goals.single, from: 'cash', amount: kzt(30000));
    await tester.pumpAndSettle();
    expect(find.text('Превышены: 1'), findsOneWidget);
    expect(find.textContaining('Потрачено 12'), findsOneWidget);
    expect(find.text('Просрочено: 1'), findsOneWidget, reason: 'аренда за 10 сентября не отмечена');
    expect(find.textContaining('Я должен: 80'), findsOneWidget);
    expect(find.textContaining('Мне должны: 20'), findsOneWidget);
    expect(find.textContaining('Накоплено 30'), findsOneWidget);
  });

  testWidgets('каждая кнопка открывает свой экран с содержимым направления', (tester) async {
    await pumpApp(tester, home: const BudgetScreen(), size: const Size(390, 844));
    await tester.pumpAndSettle();
    for (final (tile, page) in <(String, Type)>[
      ('Лимиты', BudgetLimitsPage),
      ('Платежи', BudgetPaymentsPage),
      ('Разовые покупки', BudgetPurchasesPage),
      ('Цели', BudgetGoalsPage),
      ('Долги', BudgetDebtsPage),
      ('Прогноз', BudgetForecastPage),
    ]) {
      await tester.tap(find.text(tile));
      await tester.pumpAndSettle();
      expect(find.byType(page), findsOneWidget, reason: tile);
      expect(find.byType(AppBar), findsOneWidget);
      Navigator.of(tester.element(find.byType(page))).pop();
      await tester.pumpAndSettle();
    }
    expect(find.byType(BudgetScreen), findsOneWidget);
  });

  testWidgets('экран «Платежи» и «Цели» содержат прежние кнопки добавления', (tester) async {
    await pumpApp(tester, home: const BudgetPaymentsPage(), size: const Size(390, 844));
    await tester.pumpAndSettle();
    expect(find.text('Добавить платёж'), findsOneWidget);
    expect(find.text('Календарь платежей'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await pumpApp(tester, home: const BudgetGoalsPage(), size: const Size(390, 844));
    await tester.pumpAndSettle();
    expect(find.text('Добавить'), findsOneWidget);
  });

  for (final (name, size, scale) in [
    ('360×732', const Size(360, 732), 1.0),
    ('320×694', const Size(320, 694), 1.0),
    ('320×694 и текст 200 %', const Size(320, 694), 2.0),
  ]) {
    testWidgets('вёрстка $name — без переполнений, все кнопки доступны', (tester) async {
      final f = await pumpApp(tester, home: const BudgetScreen(), size: size, textScale: scale);
      final s = f.state;
      await s.upsert('limit', 'l1', {'category': 'food', 'amount': '${kzt(10000)}'});
      await s.addExpense(amount: kzt(12000), category: 'food', account: 'cash', date: s.today);
      await s.addPersonDebt(kind: 'borrow', amount: kzt(80000), person: 'Теща', account: 'cash', date: s.today);
      await tester.pumpAndSettle();
      for (final title in ['Лимиты', 'Платежи', 'Разовые покупки', 'Цели', 'Долги', 'Прогноз']) {
        await tester.scrollUntilVisible(find.text(title), 200, scrollable: find.byType(Scrollable).first);
        expect(find.text(title), findsOneWidget, reason: title);
      }
      expect(tester.takeException(), isNull);
    });
  }
}
