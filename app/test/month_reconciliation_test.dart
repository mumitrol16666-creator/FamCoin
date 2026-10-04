import 'package:famcoin/ui/budget/month_close_screen.dart';
import 'package:famcoin/ui/widgets/common.dart';
import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audit_regression_test.dart' show FakeServer;
import 'layout_test.dart' show pumpApp;

void main() {
  test(
    'кофе первого числа не меняет сверку; корректировка относится к концу месяца',
    () async {
      final f = FakeServer();
      await f.init();
      final s = f.state;
      final september = DateTime(2026, 9);
      expect(() => s.closeMonth(september), throwsA(isA<LedgerException>()));
      f.now = DateTime(2026, 10, 1);
      await s.addExpense(
        amount: kzt(1000),
        category: 'cafe',
        account: 'cash',
        date: f.now,
      );
      expect(s.ledger.balance('cash'), kzt(99000));
      expect(s.balancesAtMonthEnd(september)['cash'], kzt(100000));
      await s.adjustBalance(
        account: 'cash',
        actualBalance: kzt(98000),
        reason: 'Выписка на 30 сентября',
        date: DateTime(2026, 9, 30),
      );
      expect(s.balancesAtMonthEnd(september)['cash'], kzt(98000));
      expect(s.ledger.balance('cash'), kzt(97000));
      await s.closeMonth(september);
      expect(s.isMonthClosed(september), isTrue);
      await s.addExpense(
        amount: kzt(500),
        category: 'cafe',
        account: 'cash',
        date: f.now,
      );
      expect(s.isMonthClosed(september), isTrue);
      expect(s.balancesAtMonthEnd(september)['cash'], kzt(98000));
      await s.addExpense(
        amount: kzt(200),
        category: 'cafe',
        account: 'cash',
        date: DateTime(2026, 9, 30),
      );
      expect(s.isMonthClosed(september), isFalse);
      expect(s.monthNeedsRecheck(september), isTrue);
      expect(s.balancesAtMonthEnd(september)['cash'], kzt(97800));
      await s.refresh();
      expect(s.monthNeedsRecheck(september), isTrue);
      await s.closeMonth(september);
      expect(s.isMonthClosed(september), isTrue);
      expect(
        s.monthReconciliation(september)!['snapshot']['balances']['cash'],
        '9780000',
      );
    },
  );

  test('историческая корректировка архивного счёта сохраняет архив и правильную дату', () async {
    final f = FakeServer();
    await f.init();
    f.now = DateTime(2026, 10, 2);
    await f.state.send({'type': 'archiveAccount', 'accountId': 'cash'});
    await f.state.adjustBalance(account: 'cash', actualBalance: -123, reason: 'Выписка', date: DateTime(2026, 9, 30));
    expect(f.state.ledger.account('cash').archived, isTrue);
    expect(f.state.balancesAtMonthEnd(DateTime(2026, 9))['cash'], -123);
    await f.state.refresh();
    expect(f.state.ledger.account('cash').archived, isTrue);
    expect(f.state.ledger.transactions.last.date, DateTime(2026, 9, 30));
  });

  test('старая отметка без снимка требует повторной проверки', () async {
    final f = FakeServer();
    await f.init();
    f.now = DateTime(2026, 10, 1);
    await f.state.send({
      'type': 'updateProfile',
      'profile': {
        'closedMonths': ['2026-09'],
      },
    });
    expect(f.state.isMonthClosed(DateTime(2026, 9)), isFalse);
    expect(f.state.monthNeedsRecheck(DateTime(2026, 9)), isTrue);
  });

  test('корректировка принимает отрицательный остаток с копейками', () {
    expect(amountToField(-123), '-1.23');
    expect(amountToField(-23), '-0.23');
    expect(parseAmount('-1,23', allowNegative: true), -123);
    expect(parseAmount('-1,23'), isNull);
    expect(parseAmount('NaN', allowNegative: true), isNull);
  });

  testWidgets('текущий месяц недоступен для сверки даже по прямому переходу', (
    tester,
  ) async {
    await pumpApp(
      tester,
      home: MonthCloseScreen(month: DateTime(2026, 9)),
      size: const Size(360, 740),
    );
    expect(find.textContaining('Сверка откроется'), findsOneWidget);
    expect(find.text('Подтвердить сверку'), findsNothing);
    expect(find.text('Исправить'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'отмена корректировки не подтверждает счёт, после проверки можно закрыть',
    (tester) async {
      final f = await pumpApp(
        tester,
        home: MonthCloseScreen(month: DateTime(2026, 9)),
        size: const Size(360, 740),
      );
      f.now = DateTime(2026, 10, 1);
      await f.state.refresh();
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Исправить'), 180);
      await tester.tap(find.text('Исправить'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Исправляем остаток на конец дня'),
        findsOneWidget,
      );
      Navigator.of(
        tester.element(find.textContaining('Исправляем остаток на конец дня')),
      ).pop();
      await tester.pumpAndSettle();
      expect(find.text('Совпадает'), findsOneWidget);
      await Scrollable.ensureVisible(
        tester.element(find.text('Совпадает')),
        alignment: .5,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Совпадает'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Подтвердить сверку'), 250);
      await tester.tap(find.text('Подтвердить сверку'));
      await tester.pumpAndSettle();
      expect(f.state.isMonthClosed(DateTime(2026, 9)), isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}
