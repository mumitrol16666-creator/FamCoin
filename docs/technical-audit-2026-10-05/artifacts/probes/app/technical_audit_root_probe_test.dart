// Diagnostic assertions describe the observed baseline, not desired behaviour.
import 'package:famcoin/state/models.dart';
import 'package:famcoin/state/app_state.dart';
import 'package:famcoin/ui/budget/calendar_screen.dart';
import 'package:famcoin/ui/home/home_screen.dart' show DueTile;
import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audit_regression_test.dart' show FakeServer;
import 'layout_test.dart' show pumpApp;

void main() {
  test('ROOT-01 two devices paying different periods lose first paid marker', () async {
    final f = FakeServer();
    await f.init();
    await f.plan();
    final s = f.state;
    final otherDevice = AppState(api: s.api, token: 'test-only', clock: () => f.now);
    await otherDevice.load();
    final september = s.dueItems(DateTime(2026, 9, 30)).single;
    final october = otherDevice.dueItems(DateTime(2026, 10, 31)).last;
    await s.payDue(september, account: 'cash', amount: kzt(10000));
    await otherDevice.payDue(october, account: 'cash', amount: kzt(10000));
    expect(otherDevice.ledger.balance('cash'), kzt(80000));
    expect(otherDevice.planned.single.paid, {'2026-10'});
    expect(otherDevice.dueItems(DateTime(2026, 10, 31)).map((d) => d.period), ['2026-09']);
    otherDevice.dispose();
    print('ROOT-01: September and October both paid, total cash -20000 KZT; September becomes unpaid again.');
  });

  test('ROOT-02 old weekly dues disappear from historical reconciliation', () async {
    final f = FakeServer();
    await f.init();
    f.now = DateTime(2026, 12, 1);
    final s = f.state;
    await s.upsert('planned', 'weekly', PlannedInfo('weekly', 'Уроки', kzt(5000), 1, 'education', null, const {},
        start: DateTime(2026, 9, 1), every: everyWeek, weekday: 1).toJson());
    final summary = s.monthSummary(DateTime(2026, 9, 1));
    expect(summary.paymentsTotal, 4);
    expect(summary.paymentsPaid, 0);
    expect(s.dueItems(DateTime(2026, 9, 30)), isEmpty);
    print('ROOT-02: September summary 0/4 paid (20000 KZT), reconciliation pending list empty on December 1.');
  });

  test('ROOT-03 editing weekday recreates overdue periods already paid', () async {
    final f = FakeServer();
    await f.init();
    final s = f.state;
    final p = PlannedInfo('weekly', 'Уроки', kzt(5000), 1, 'education', null,
        const {'2026-09-07', '2026-09-14', '2026-09-21', '2026-09-28'}, start: DateTime(2026, 9, 1), every: everyWeek, weekday: 1);
    await s.upsert('planned', p.id, p.toJson());
    expect(s.dueItems(DateTime(2026, 9, 30)), isEmpty);
    await s.upsert('planned', p.id, p.copyWith(every: everyWeek, weekday: 2).toJson());
    final overdue = s.dueItems(DateTime(2026, 9, 30)).where((d) => d.date.isBefore(s.today));
    expect(overdue.map((d) => d.period), ['2026-09-01', '2026-09-08', '2026-09-15', '2026-09-22']);
    print('ROOT-03: fully paid September Mondays -> change weekday to Tuesday -> 4 historical overdue payments (20000 KZT).');
  });

  test('ROOT-04 application hides planned payments for fully repaid debt', () async {
    final f = FakeServer();
    await f.init();
    final s = f.state;
    await s.sendBatch(s.newBankDebtCommands(name: 'Рассрочка', kind: 'installment', balance: kzt(50000), payment: kzt(10000), day: 5));
    await s.payDebt(debtId: s.bankDebts.single.id, account: 'cash', principal: kzt(50000));
    f.now = DateTime(2026, 10, 5);
    expect(s.debtBalance(s.bankDebts.single.id), 0);
    expect(s.dueItems(DateTime(2026, 10, 31)), isEmpty);
    expect(s.planned, hasLength(1));
    print('ROOT-04 app: debt=0, due list empty; plan remains stored (paired with server ROOT-04).');
  });

  testWidgets('ROOT-04b calendar still requests payment for fully repaid debt', (tester) async {
    final f = await pumpApp(tester, home: const CalendarScreen(), size: const Size(390, 844));
    final s = f.state;
    await s.sendBatch(s.newBankDebtCommands(name: 'Рассрочка', kind: 'installment', balance: kzt(50000), payment: kzt(10000), day: 5));
    await s.payDebt(debtId: s.bankDebts.single.id, account: 'cash', principal: kzt(50000));
    f.now = DateTime(2026, 10, 5);
    await s.refresh();
    await tester.pumpAndSettle();
    expect(s.debtBalance(s.bankDebts.single.id), 0);
    expect(s.dueItems(DateTime(2026, 10, 31)), isEmpty);
    await tester.scrollUntilVisible(find.byType(DueTile), 150, scrollable: find.byType(Scrollable).first);
    final tile = tester.widget<DueTile>(find.byType(DueTile));
    expect(tile.due.period, '2026-10');
    expect(tile.due.date, DateTime(2026, 10, 5));
    expect(tile.due.planned.amount, kzt(10000));
    expect(find.text('Рассрочка'), findsOneWidget);
    expect(find.text('Списалось'), findsOneWidget);
    expect(tester.takeException(), isNull);
    print('ROOT-04b widget: debt=0 and dueItems empty, but October CalendarScreen contains unpaid DueTile for 10000 KZT and active quick-pay button.');
  });
}
