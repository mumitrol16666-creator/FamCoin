import 'package:famcoin/state/app_scope.dart';
import 'package:famcoin/ui/analytics/day_flow_chart.dart';
import 'package:famcoin/ui/budget/sheets.dart';
import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'layout_test.dart' show pumpApp;

void main() {
  testWidgets('a refund bar is above zero and positive expense is below zero', (tester) async {
    await pumpApp(tester, size: const Size(390, 844), home: Scaffold(
      body: DayFlowChart(income: const [0, 0], expense: [kzt(20000), -kzt(20000)],
          selectedDay: null, onSelect: (_) {}, dayLabel: (i) => 'day $i'),
    ));
    final chart = tester.getRect(find.byType(DayFlowChart));
    final refund = tester.getRect(find.byKey(const ValueKey('day-1-refund')));
    final expense = tester.getRect(find.byKey(const ValueKey('day-0-expense')));
    expect(refund.height, greaterThan(0));
    expect(expense.height, greaterThan(0));
    expect(refund.bottom, lessThanOrEqualTo(chart.center.dy + .01));
    expect(expense.top, greaterThanOrEqualTo(chart.center.dy - .01));
    expect(tester.getSize(find.byKey(const ValueKey('day-1-expense'))).height, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('payment form retries a lost response without another payment', (tester) async {
    final f = await pumpApp(tester, size: const Size(390, 844), home: Scaffold(
      body: Builder(builder: (context) => FilledButton(
        onPressed: () => showBankPaySheet(context, AppScope.of(context).state.bankDebts.single),
        child: const Text('open-payment'),
      )),
    ));
    await f.state.sendBatch(f.state.newBankDebtCommands(name: 'Loan', kind: 'loan',
        balance: kzt(1000000), payment: kzt(100000), day: 28));
    await tester.tap(find.text('open-payment'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '100000');
    f.dropNextResponse = true;
    // Localized action label is read from the modal's FilledButton, rather
    // than relying on any button outside the modal route.
    final actionButton = find.byType(FilledButton).last;
    await tester.ensureVisible(actionButton);
    await tester.tap(actionButton);
    await tester.pumpAndSettle();
    expect(find.text('Повторить проверку оплаты'), findsOneWidget);
    final close = tester.widget<IconButton>(find.byTooltip('Закрыть').last);
    expect(close.onPressed, isNull);
    await tester.tap(find.text('Повторить проверку оплаты'));
    await tester.pumpAndSettle();
    expect(find.text('Повторить проверку оплаты'), findsNothing);
    expect(f.ledger.transactions.where((t) => t.type == EventType.loanPayment).length, 1);
    expect(f.state.debtBalance(f.state.bankDebts.single.id), kzt(900000));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
