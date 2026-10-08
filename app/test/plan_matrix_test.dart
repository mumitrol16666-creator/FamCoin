/// Таблица тарифа и проверки доступа — одна матрица (аудит 08.10, UI03).
library;

import 'package:famcoin/ui/more/tariff_screen.dart';
import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'layout_test.dart' show pumpApp;

/// Ячейки строки таблицы: текст или галочка в столбцах «Обычный» и Pro.
List<String> rowCells(WidgetTester tester, String name) {
  final row = find.ancestor(of: find.text(name), matching: find.byType(Row)).first;
  final cells = find.descendant(of: row, matching: find.byType(SizedBox)).evaluate().where((e) => (e.widget as SizedBox).width == 72).toList();
  return [
    for (final c in cells)
      if (find.descendant(of: find.byWidget(c.widget), matching: find.byIcon(Icons.check)).evaluate().isNotEmpty)
        '✓'
      else
        (find.descendant(of: find.byWidget(c.widget), matching: find.byType(Text)).evaluate().single.widget as Text).data!,
  ];
}

void main() {
  testWidgets('экран «Тариф» показывает ровно матрицу: сравнение всем, консультант в Pro с квотой, импорт во Free — сводка, без «скоро»', (tester) async {
    await pumpApp(tester, home: const TariffScreen(), size: const Size(390, 2400));
    await tester.pumpAndSettle();
    expect(rowCells(tester, 'Сравнения с прошлыми месяцами'), ['✓', '✓']);
    expect(rowCells(tester, 'ИИ-консультант'), ['—', '$proAiQuestionsPerMonth/мес']);
    expect(rowCells(tester, 'Импорт выписки Kaspi (PDF в Telegram)'), ['сводка', '✓']);
    expect(rowCells(tester, 'Счета'), ['$freeMoneyAccounts', '∞']);
    expect(rowCells(tester, 'Лимиты'), ['$freeLimits', '∞']);
    expect(rowCells(tester, 'Цели и резервы'), ['$freeGoals', '∞']);
    expect(rowCells(tester, 'Досрочное погашение, стратегии'), ['—', '✓']);
    expect(find.text('скоро'), findsNothing, reason: 'работающее не продаётся как будущее, несделанное не обещается');
  });

  testWidgets('квота консультанта берётся с сервера, включая нестандартный лимит', (tester) async {
    final f = await pumpApp(tester, home: const SizedBox(), size: const Size(390, 2400));
    f.aiLimit = 25;
    final context = tester.element(find.byType(SizedBox).first);
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const TariffScreen()));
    await tester.pumpAndSettle();
    expect(rowCells(tester, 'ИИ-консультант'), ['—', '25/мес']);
    expect(find.text('100/мес'), findsNothing);
  });

  testWidgets('квота не пришла (нет связи с /billing): консультант в Pro — галочка, а не «—», и без числа', (tester) async {
    final f = await pumpApp(tester, home: const SizedBox(), size: const Size(390, 2400));
    f.offline = true;
    final context = tester.element(find.byType(SizedBox).first);
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const TariffScreen()));
    await tester.pumpAndSettle();
    expect(rowCells(tester, 'ИИ-консультант'), ['—', '✓']);
    expect(find.textContaining('/мес'), findsNothing);
  });

  test('проверки доступа берут числа из той же матрицы', () {
    expect(planAllowsMore(PlanFeature.accounts, pro: false, count: freeMoneyAccounts - 1), isTrue);
    expect(planAllowsMore(PlanFeature.accounts, pro: false, count: freeMoneyAccounts), isFalse);
    expect(planAllowsMore(PlanFeature.limits, pro: false, count: freeLimits), isFalse);
    expect(planAllowsMore(PlanFeature.goals, pro: false, count: freeGoals), isFalse);
    expect(planAllowsMore(PlanFeature.goals, pro: true, count: 50), isTrue);
    expect(planAllows(PlanFeature.compare, pro: false), isTrue, reason: 'сравнение месяцев доступно в обычной версии');
    expect(planAllows(PlanFeature.ai, pro: false), isFalse);
    expect(planAccess(PlanFeature.ai, pro: true).perMonth, proAiQuestionsPerMonth);
    expect(planAllows(PlanFeature.statementImport, pro: false), isFalse, reason: 'запись выписки — в Pro');
    expect(planAccess(PlanFeature.statementImport, pro: false).previewOnly, isTrue, reason: 'сводка — всем');
    expect(planAllows(PlanFeature.early, pro: false), isFalse);
  });
}
