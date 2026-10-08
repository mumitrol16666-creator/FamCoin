/// Итоги дня и честное сравнение месяцев (аудит 08.10, UI01 + UI06).
/// «Сегодня» заглушки — 28.09.2026, на счёте `cash` 100 000 ₸.
library;

import 'package:famcoin/state/app_scope.dart';
import 'package:famcoin/state/app_state.dart';
import 'package:famcoin/ui/analytics/month_tab.dart';
import 'package:famcoin/ui/ops/journal_screen.dart';
import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audit_regression_test.dart' show FakeServer;
import 'layout_test.dart' show pumpApp;

final today = DateTime(2026, 9, 28);

Future<FakeServer> journal(WidgetTester tester, Future<void> Function(AppState s) setup) async {
  final f = await pumpApp(tester, home: const JournalScreen(), size: const Size(390, 1600));
  await setup(f.state);
  await tester.pumpAndSettle();
  return f;
}

/// Итог дня в заголовке журнала совпадает со столбиком дня в аналитике.
int chartDay(AppState s, DateTime day) => s.dailyExpense(DateTime(day.year, day.month, 1))[day.day - 1];

Future<FakeServer> monthTab(WidgetTester tester, Future<void> Function(AppState s) setup) async {
  final f = await pumpApp(
    tester,
    home: Scaffold(
      body: Builder(
        builder: (c) => ListenableBuilder(
          listenable: AppScope.of(c).state,
          builder: (c, _) => MonthTab(offset: 0, onOffset: (_) {}, selectedDay: null, onSelectDay: (_) {}),
        ),
      ),
    ),
    size: const Size(390, 2400),
  );
  await setup(f.state);
  await tester.pumpAndSettle();
  return f;
}

void main() {
  group('UI01: итог дня в журнале — тот же, что в аналитике', () {
    testWidgets('покупка 10 000 и возврат 4 000 в тот же день — 6 000', (tester) async {
      final f = await journal(tester, (s) async {
        await s.addExpense(amount: kzt(10000), category: 'food', account: 'cash', date: today, id: 'buy');
        await s.refund(s.ledger.byId('buy')!, category: 'food', amount: kzt(4000), account: 'cash', date: today);
      });
      expect(chartDay(f.state, today), kzt(6000));
      expect(find.text('− ${formatMoney(kzt(6000))}'), findsOneWidget);
      expect(find.text('− ${formatMoney(kzt(10000))}'), findsNothing);
    });

    testWidgets('покупка в рассрочку и проценты по кредиту входят в итог дня', (tester) async {
      final f = await journal(tester, (s) async {
        await s.sendBatch(s.installmentPurchaseCommands(name: 'Телефон', amount: kzt(120000), category: 'other', months: 12, day: 10, date: today));
        await s.sendBatch([
          {'type': 'upsertEntity', 'kind': 'debt', 'entityId': 'red', 'data': {'name': 'Кредит', 'kind': 'loan', 'rate': 20}},
          {'type': 'openingDebt', 'id': 'od', 'date': '2026-09-01', 'debtId': 'red', 'amount': '${kzt(50000)}'},
          {'type': 'loanPayment', 'id': 'lp', 'date': '2026-09-28', 'account': 'cash', 'debtId': 'red', 'principal': '${kzt(9000)}', 'interest': '${kzt(1000)}'},
        ]);
      });
      expect(chartDay(f.state, today), kzt(121000), reason: 'рассрочка 120 000 + проценты 1 000; тело кредита — не расход');
      expect(find.text('− ${formatMoney(kzt(121000))}'), findsOneWidget);
    });

    testWidgets('возврат за покупку прошлого месяца: день с чистым возвратом подписан, а не показан расходом', (tester) async {
      final f = await journal(tester, (s) async {
        await s.addExpense(amount: kzt(10000), category: 'food', account: 'cash', date: DateTime(2026, 8, 30), id: 'aug');
        await s.refund(s.ledger.byId('aug')!, category: 'food', amount: kzt(4000), account: 'cash', date: today);
      });
      expect(chartDay(f.state, today), -kzt(4000));
      expect(find.text('возвращено ${formatMoney(kzt(4000))}'), findsOneWidget);
      expect(find.text('− ${formatMoney(kzt(10000))}'), findsOneWidget, reason: '30 августа — своя покупка');
    });

    testWidgets('удалённая покупка не входит; в «Удалённых», «Истории» и при поиске итог дня не выводится', (tester) async {
      final f = await journal(tester, (s) async {
        await s.addExpense(amount: kzt(3000), category: 'food', account: 'cash', date: today, id: 'kept', note: 'хлеб');
        await s.addExpense(amount: kzt(7000), category: 'food', account: 'cash', date: today, id: 'gone', note: 'сыр');
        await s.deleteTransaction('gone');
      });
      expect(find.text('− ${formatMoney(kzt(3000))}'), findsOneWidget);
      await tester.tap(find.text('Удалённые'));
      await tester.pumpAndSettle();
      expect(find.textContaining('− '), findsNothing, reason: 'отменённое — не текущий расход');
      await tester.tap(find.text('Всё'));
      await tester.pumpAndSettle();
      expect(find.textContaining('− '), findsNothing);
      await tester.tap(find.text('Действующие'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'хлеб');
      await tester.pumpAndSettle();
      expect(find.textContaining('− '), findsNothing, reason: 'итог дня не выдаётся за итог найденного');
      // Восстановление возвращает покупку и в итог.
      await tester.enterText(find.byType(TextField).first, '');
      await f.state.restoreTransaction('gone');
      await tester.pumpAndSettle();
      expect(find.text('− ${formatMoney(kzt(10000))}'), findsOneWidget);
    });
  });

  group('UI06: сравнение с прошлым месяцем', () {
    testWidgets('учёт начат в этом месяце: сравнения нет, вместо него — «нет данных»', (tester) async {
      // Учёт с 20 сентября: август не учитывался, сентябрь — не база.
      final f = await monthTab(tester, (s) async {
        await s.send({'type': 'opening', 'id': 'o1', 'date': '2026-09-20', 'account': 'cash', 'amount': '${kzt(1)}'});
        await s.addExpense(amount: kzt(9240), category: 'food', account: 'cash', date: today);
      });
      expect(f.state.hasComparablePrev(DateTime(2026, 9, 1)), isFalse);
      expect(find.text('За прошлый месяц пока нет данных для сравнения'), findsOneWidget);
      expect(find.textContaining('к прошлому месяцу'), findsNothing);
      expect(find.textContaining('Свободных денег'), findsNothing);
    });

    testWidgets('учёт шёл весь прошлый месяц, трат в нём не было: честный ноль — сравнение есть и названо точно; заём его не меняет', (tester) async {
      final f = await monthTab(tester, (s) async {
        await s.send({'type': 'opening', 'id': 'o1', 'date': '2026-08-01', 'account': 'cash', 'amount': '${kzt(1)}'});
        await s.addExpense(amount: kzt(9240), category: 'food', account: 'cash', date: today);
        // Заём меняет деньги на счёте, но не «доходы минус расходы».
        await s.addPersonDebt(kind: 'borrow', amount: kzt(50000), person: 'Друг', account: 'cash', date: today);
      });
      final s = f.state;
      expect(s.hasComparablePrev(DateTime(2026, 9, 1)), isTrue);
      expect(s.reportFor(DateTime(2026, 9, 1)).result - s.reportFor(DateTime(2026, 8, 1)).result, -kzt(9240));
      expect(find.textContaining('Доходы минус расходы: −${formatMoney(kzt(9240))} к прошлому месяцу'), findsOneWidget);
      expect(find.textContaining('Свободных денег'), findsNothing);
      expect(find.text('За прошлый месяц пока нет данных для сравнения'), findsNothing);
    });
  });
}
