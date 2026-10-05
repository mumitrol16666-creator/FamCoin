import 'package:famcoin/l10n/app_localizations.dart';
import 'package:famcoin/theme/app_theme.dart';
import 'package:famcoin/ui/analytics/category_chart.dart';
import 'package:famcoin/ui/analytics/day_flow_chart.dart';
import 'package:famcoin/ui/analytics/expenses_tab.dart';
import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audit_regression_test.dart' show FakeServer;
import 'layout_test.dart' show pumpApp;

Future<void> pumpChart(WidgetTester tester, Widget chart, {String language = 'ru', double scale = 1, Brightness brightness = Brightness.light}) async {
  tester.view.physicalSize = const Size(320, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      locale: Locale(language),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      theme: buildTheme(brightness),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(
        body: SingleChildScrollView(padding: const EdgeInsets.all(16), child: chart),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('нажатие на сектор открывает его категорию', (tester) async {
    String? opened;
    await pumpChart(tester, CategoryChart(
      categories: [MapEntry('food', kzt(6000)), MapEntry('home', kzt(4000))],
      onOpenCategory: (id) => opened = id,
    ));
    final rect = tester.getRect(find.byKey(const ValueKey('category-donut')));
    await tester.tapAt(rect.topLeft + Offset(rect.width * .81, rect.height * .19));
    await tester.pumpAndSettle();
    expect(opened, 'food');
    expect(tester.takeException(), isNull);
  });

  testWidgets('возврат не создаёт 150% и отрицательные доли в типах расходов', (tester) async {
    final f = await pumpApp(tester, home: Scaffold(body: ExpensesTab(offset: 0, onOffset: (_) {})), size: const Size(390, 1400));
    final s = f.state;
    await s.addExpense(amount: kzt(40000), category: 'fun', account: 'cash', date: DateTime(2026, 8, 15));
    final old = s.userTransactions.firstWhere((t) => t.type == EventType.expense);
    await s.refund(old, category: 'fun', amount: kzt(40000), account: 'cash');
    await s.addExpense(amount: kzt(60000), category: 'food', account: 'cash', date: s.today);
    await s.addExpense(amount: kzt(20000), category: 'home', account: 'cash', date: s.today);
    // В рабочем приложении вкладку перестраивает ListenableBuilder экрана.
    tester.element(find.byType(ExpensesTab)).markNeedsBuild();
    await tester.pumpAndSettle();
    expect(find.text('150%'), findsNothing);
    expect(find.text('-100%'), findsNothing);
    expect(find.textContaining('Доли рассчитаны от положительных сумм'), findsOneWidget);
    expect(s.monthReport.total, kzt(40000));
    expect(tester.takeException(), isNull);
  });

  test('категории: сумма секторов точная, возвраты отделены, мелкие доступны', () {
    final data = CategoryChartData([for (var i = 1; i <= 10; i++) MapEntry('c$i', i * 100), const MapEntry('refund', -2000), const MapEntry('zero', 0)]);
    expect(data.positiveTotal, 5500);
    expect(data.netTotal, 3500);
    expect(data.main.length, 5);
    expect(data.other.length, 5);
    expect(data.main.fold(0, (s, e) => s + e.value) + data.otherTotal, data.positiveTotal);
    expect(data.main.first.key, 'c10');
    expect(data.negative.single.key, 'refund');
    expect(CategoryChartData(const [MapEntry('refund', -100)]).positiveTotal, 0);
  });

  test('дневной график сверяется с отчётом: долг, проценты, рассрочка, возврат, отмена', () async {
    final f = FakeServer();
    await f.init();
    final s = f.state;
    await s.sendBatch([
      {'type': 'openingDebt', 'id': 'debt-opening', 'date': '2026-09-01', 'debtId': 'old-loan', 'amount': '${kzt(500000)}'},
      {
        'type': 'loanPayment',
        'id': 'loan-paid',
        'date': '2026-09-05',
        'account': 'cash',
        'debtId': 'old-loan',
        'principal': '${kzt(40000)}',
        'interest': '${kzt(5000)}',
      },
      {
        'type': 'creditPurchase',
        'id': 'installment-buy',
        'date': '2026-09-02',
        'debtId': 'inst',
        'splits': {'clothes': '${kzt(60000)}'},
      },
      {'type': 'loanPayment', 'id': 'inst-paid', 'date': '2026-09-20', 'account': 'cash', 'debtId': 'inst', 'principal': '${kzt(10000)}'},
      {'type': 'borrow', 'id': 'borrowed', 'date': '2026-09-03', 'account': 'cash', 'person': 'Тест', 'amount': '${kzt(20000)}'},
      {'type': 'repaymentMade', 'id': 'repaid', 'date': '2026-09-25', 'account': 'cash', 'person': 'Тест', 'principal': '${kzt(20000)}'},
    ]);
    await s.addExpense(amount: kzt(5000), category: 'food', account: 'cash', date: DateTime(2026, 8, 15));
    final oldPurchase = s.userTransactions.firstWhere((tx) => tx.type == EventType.expense);
    await s.refund(oldPurchase, category: 'food', amount: kzt(5000), account: 'cash', date: DateTime(2026, 9, 10));
    var daily = s.dailyExpense(s.monthStart);
    expect(daily[4], kzt(5000), reason: 'только проценты, без основной суммы долга');
    expect(daily[1], kzt(60000));
    expect(daily[19], 0, reason: 'покупка в рассрочку уже учтена 2 сентября');
    expect(daily[24], 0, reason: 'возврат основной суммы не создаёт расход');
    expect(daily[9], kzt(-5000));
    expect(daily.fold(0, (sum, day) => sum + day), s.monthReport.total);
    await s.deleteTransaction('loan-paid');
    daily = s.dailyExpense(s.monthStart);
    expect(daily[4], 0);
    expect(daily.fold(0, (sum, day) => sum + day), s.monthReport.total);
    expect(s.dailyExpense(DateTime(2026, 8, 1)).fold(0, (sum, day) => sum + day), s.reportFor(DateTime(2026, 8, 1)).total);
  });

  for (final language in ['ru', 'kk']) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('категории $language, 320 px, масштаб $scale: выбор, раскрытие, отрицательный итог', (tester) async {
        String? opened;
        await pumpChart(
          tester,
          CategoryChart(
            categories: [
              for (final (i, id) in ['food', 'home', 'transport', 'fun', 'cafe', 'health', 'kids', 'gifts'].indexed) MapEntry(id, kzt(9000 - i * 1000)),
              MapEntry('clothes', kzt(-50000)),
            ],
            onOpenCategory: (id) => opened = id,
          ),
          language: language,
          scale: scale,
          brightness: language == 'kk' ? Brightness.dark : Brightness.light,
        );
        expect(tester.takeException(), isNull);
        final first = find.byKey(const ValueKey('chart-category-food'));
        await tester.ensureVisible(first);
        await tester.tap(first);
        await tester.pumpAndSettle();
        expect(opened, 'food');
        final group = find.text(language == 'ru' ? 'Другие категории (3)' : 'Басқа санаттар (3)');
        expect(find.byKey(const ValueKey('chart-category-gifts')), findsNothing);
        await tester.ensureVisible(group);
        await tester.tap(group);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('chart-category-gifts')), findsOneWidget);
        final bars = find.text(language == 'ru' ? 'Полосы' : 'Жолақтар');
        await tester.ensureVisible(bars);
        await tester.tap(bars);
        await tester.pumpAndSettle();
        for (final bar in tester.widgetList<LinearProgressIndicator>(find.byType(LinearProgressIndicator))) {
          expect(bar.value, inInclusiveRange(0, 1));
        }
        await tester.ensureVisible(find.byKey(const ValueKey('chart-category-clothes')));
        expect(find.text('−6 000 ₸'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('график: недели, точный выбор дня, будущие дни недоступны, смена месяца', (tester) async {
    final semantics = tester.ensureSemantics();
    var month = DateTime(2026, 10, 1);
    var income = List<int>.filled(31, 0)..[0] = kzt(150000);
    var expense = List<int>.filled(31, 0)..[3] = kzt(-1500);
    int? selected;
    int? today = 3;
    late StateSetter update;
    await pumpChart(
      tester,
      StatefulBuilder(
        builder: (context, set) {
          update = set;
          return DayFlowChart(
            month: month,
            income: income,
            expense: expense,
            selectedDay: selected,
            todayIndex: today,
            dayLabel: (i) => 'День ${i + 1}: ${income[i]}, ${expense[i]}',
            onSelect: (i) => set(() => selected = i),
          );
        },
      ),
      scale: 2,
    );
    expect(tester.takeException(), isNull);
    expect(tester.widget<IconButton>(find.byWidgetPredicate((w) => w is IconButton && w.tooltip == 'Следующие 7 дней')).onPressed, isNull);
    expect(tester.widget<InkWell>(find.byKey(const ValueKey('flow-day-4'))).onTap, isNull);
    await tester.tap(find.byKey(const ValueKey('flow-day-3')));
    await tester.pumpAndSettle();
    expect(selected, 3);
    expect(find.textContaining('Отрицательные расходы'), findsOneWidget);
    update(() {
      month = DateTime(2026, 9, 1);
      income = List<int>.filled(30, 0);
      expense = List<int>.filled(30, 0);
      today = null;
      selected = 29;
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('flow-day-29')), findsOneWidget);
    await tester.tap(find.byTooltip('Предыдущие 7 дней'));
    await tester.pumpAndSettle();
    expect(selected, isNull);
    expect(find.byKey(const ValueKey('flow-day-21')), findsOneWidget);
    update(() {
      month = DateTime(2026, 2, 1);
      income = List<int>.filled(28, 0);
      expense = List<int>.filled(28, 0);
      selected = null;
    });
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('flow-day-28')), findsNothing);
    update(() { income = List<int>.filled(28, 0); expense = List<int>.filled(28, 0)..[1] = kzt(-1000); selected = 1; });
    await tester.pumpAndSettle();
    expect(find.textContaining('Отрицательные расходы'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'месяц только с возвратом');
    semantics.dispose();
  });
}
