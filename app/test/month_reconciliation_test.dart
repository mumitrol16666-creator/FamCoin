import 'package:famcoin/state/app_state.dart';
import 'package:famcoin/ui/budget/month_close_screen.dart';
import 'package:famcoin/ui/widgets/common.dart';
import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audit_regression_test.dart' show FakeServer;
import 'layout_test.dart' show pumpApp;
import 'day_rollover_test.dart' show openApp;

void main() {
  test('кофе первого числа не меняет сверку; корректировка относится к концу месяца', () async {
    final f = FakeServer();
    await f.init();
    final s = f.state;
    final september = DateTime(2026, 9);
    expect(() => s.closeMonth(september), throwsA(isA<LedgerException>()));
    f.now = DateTime(2026, 10, 1);
    await s.addExpense(amount: kzt(1000), category: 'cafe', account: 'cash', date: f.now);
    expect(s.ledger.balance('cash'), kzt(99000));
    expect(s.balancesAtMonthEnd(september)['cash'], kzt(100000));
    await s.adjustBalance(account: 'cash', actualBalance: kzt(98000), reason: 'Выписка на 30 сентября', date: DateTime(2026, 9, 30));
    expect(s.balancesAtMonthEnd(september)['cash'], kzt(98000));
    expect(s.ledger.balance('cash'), kzt(97000));
    await s.closeMonth(september);
    expect(s.isMonthClosed(september), isTrue);
    await s.addExpense(amount: kzt(500), category: 'cafe', account: 'cash', date: f.now);
    expect(s.isMonthClosed(september), isTrue);
    expect(s.balancesAtMonthEnd(september)['cash'], kzt(98000));
    await s.addExpense(amount: kzt(200), category: 'cafe', account: 'cash', date: DateTime(2026, 9, 30));
    expect(s.isMonthClosed(september), isFalse);
    expect(s.monthNeedsRecheck(september), isTrue);
    expect(s.balancesAtMonthEnd(september)['cash'], kzt(97800));
    await s.refresh();
    expect(s.monthNeedsRecheck(september), isTrue);
    await s.closeMonth(september);
    expect(s.isMonthClosed(september), isTrue);
    expect(s.monthReconciliation(september)!['snapshot']['balances']['cash'], '9780000');
  });

  test('перенос операции из сверенного месяца в текущий сначала спрашивает; отмена не отправляет batch', () async {
    final f = FakeServer();
    await f.init();
    f.now = DateTime(2026, 10, 2);
    await f.state.addExpense(amount: kzt(100), category: 'cafe', account: 'cash', date: DateTime(2026, 9, 30));
    final old = f.state.userTransactions.firstWhere((t) => t.type == EventType.expense);
    await f.state.closeMonth(DateTime(2026, 9));
    final before = f.revision;
    var asked = 0;
    f.state.confirmReconciliationEdit = (month) async {
      asked++;
      expect(month, DateTime(2026, 9));
      return false;
    };
    await expectLater(
      f.state.sendBatch([
        {'type': 'reverse', 'txId': old.id, 'id': 'undo-for-edit'},
        {
          'type': 'expense',
          'id': 'new-date',
          'date': '2026-10-02',
          'account': 'cash',
          'splits': {'cafe': '20000'},
        },
      ]),
      throwsA(isA<ReconciliationEditCancelled>()),
    );
    expect(asked, 1);
    expect(f.revision, before);
    expect(f.state.ledger.isReversed(old.id), isFalse);
    expect(f.state.isMonthClosed(DateTime(2026, 9)), isTrue);
    await f.state.addExpense(amount: kzt(50), category: 'cafe', account: 'cash', date: f.now);
    expect(asked, 1, reason: 'текущая покупка не требует подтверждения');
  });

  testWidgets('настоящая оболочка: предупреждение до записи, отмена сохраняет данные, подтверждение пересчитывает', (tester) async {
    final app = await openApp(tester, now: DateTime(2026, 10, 2));
    final s = app.state;
    await s.closeMonth(DateTime(2026, 9));
    await tester.pump(const Duration(seconds: 1));
    final balance = s.ledger.balance('cash');
    final revision = s.revision;
    final cancelled = expectLater(
      s.addExpense(amount: kzt(1000), category: 'cafe', account: 'cash', date: DateTime(2026, 9, 30)),
      throwsA(isA<ReconciliationEditCancelled>()),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Пересчитать остатки?'), findsOneWidget);
    expect(find.textContaining('включая текущий'), findsOneWidget);
    expect(s.revision, revision);
    await tester.tap(find.text('Отмена'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await cancelled;
    expect(s.ledger.balance('cash'), balance);
    final saving = s.addExpense(amount: kzt(1000), category: 'cafe', account: 'cash', date: DateTime(2026, 9, 30));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.text('Пересчитать и сохранить'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await saving;
    expect(s.ledger.balance('cash'), balance - kzt(1000));
    expect(s.monthNeedsRecheck(DateTime(2026, 9)), isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

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

  testWidgets('текущий месяц недоступен для сверки даже по прямому переходу', (tester) async {
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

  testWidgets('отмена корректировки не подтверждает счёт, после проверки можно закрыть', (tester) async {
    final f = await pumpApp(
      tester,
      home: MonthCloseScreen(month: DateTime(2026, 9)),
      size: const Size(360, 740),
    );
    f.now = DateTime(2026, 10, 1);
    await f.state.refresh();
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Исправить'), 180);
    await Scrollable.ensureVisible(tester.element(find.text('Исправить')), alignment: .5);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Исправить'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Исправляем остаток на конец дня'), findsOneWidget);
    Navigator.of(tester.element(find.textContaining('Исправляем остаток на конец дня'))).pop();
    await tester.pumpAndSettle();
    expect(find.text('Совпадает'), findsOneWidget);
    await Scrollable.ensureVisible(tester.element(find.text('Совпадает')), alignment: .5);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Совпадает'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Подтвердить сверку'), 250);
    await tester.tap(find.text('Подтвердить сверку'));
    await tester.pumpAndSettle();
    expect(f.state.isMonthClosed(DateTime(2026, 9)), isTrue);
    expect(tester.takeException(), isNull);
  });
  test('правка категории не предупреждает и не снимает сверку; отмена реальной правки восстанавливает её', () async {
    final f = FakeServer();
    await f.init();
    f.now = DateTime(2026, 11, 20);
    final s = f.state;
    await s.addExpense(amount: kzt(100), category: 'cafe', account: 'cash', date: DateTime(2026, 9, 30));
    final old = s.userTransactions.firstWhere((t) => t.type == EventType.expense);
    await s.closeMonth(DateTime(2026, 9));
    await s.closeMonth(DateTime(2026, 10));
    var asked = 0;
    s.confirmReconciliationEdit = (_) async {
      asked++;
      return true;
    };
    await s.sendBatch([
      {'type': 'reverse', 'txId': old.id, 'id': 'edit-undo'},
      {
        'type': 'expense',
        'id': 'edit-replacement',
        'date': '2026-09-29',
        'account': 'cash',
        'splits': {'food': '10000'},
        'meta': {'note': 'Другая категория'},
      },
    ]);
    expect(asked, 0);
    expect(s.isMonthClosed(DateTime(2026, 9)), isTrue);
    expect(s.isMonthClosed(DateTime(2026, 10)), isTrue);
    await s.refresh();
    expect(s.isMonthClosed(DateTime(2026, 9)), isTrue);
    await s.send({
      'type': 'expense',
      'id': 'forgotten',
      'date': '2026-09-30',
      'account': 'cash',
      'splits': {'food': '5000'},
    });
    expect(asked, 1);
    expect(s.monthChanges(DateTime(2026, 9))!.balances['cash'], (before: kzt(99900), after: kzt(99850)));
    expect(s.monthToClose, DateTime(2026, 9), reason: 'старое расхождение видно даже после 15 числа');
    expect(s.monthChangesSinceConfirmation(DateTime(2026, 9))!.map((t) => t.id), contains('forgotten'));
    await s.send({'type': 'reverse', 'id': 'undo-forgotten', 'txId': 'forgotten'});
    expect(s.isMonthClosed(DateTime(2026, 9)), isTrue);
    expect(s.isMonthClosed(DateTime(2026, 10)), isTrue);
    await s.refresh();
    expect(s.isMonthClosed(DateTime(2026, 9)), isTrue);
    expect(s.monthToClose, isNull);
  });

  testWidgets('повторная сверка показывает было → стало и записи; нет шага лимитов', (tester) async {
    final f = await pumpApp(
      tester,
      home: MonthCloseScreen(month: DateTime(2026, 9)),
      size: const Size(320, 740),
    );
    f.now = DateTime(2026, 10, 2);
    await f.state.closeMonth(DateTime(2026, 9));
    await f.state.addExpense(amount: kzt(500), category: 'cafe', account: 'cash', date: DateTime(2026, 9, 30));
    await tester.pumpAndSettle();
    expect(find.textContaining('${moneyInText(kzt(100000))} → ${moneyInText(kzt(99500))}'), findsOneWidget);
    expect(find.textContaining('Расходы: ${moneyInText(0)} → ${moneyInText(kzt(500))}'), findsOneWidget);
    expect(find.text('3. Текущие планы'), findsNothing);
    await tester.scrollUntilVisible(find.text('Записи после подтверждения'), 150);
    await Scrollable.ensureVisible(tester.element(find.text('Записи после подтверждения')), alignment: .5);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Записи после подтверждения'));
    await tester.pumpAndSettle();
    expect(find.textContaining('30.09.2026'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('старая отметка объясняется обновлением, без заявления об изменении операций', (tester) async {
    final f = await pumpApp(
      tester,
      home: MonthCloseScreen(month: DateTime(2026, 9)),
      size: const Size(360, 740),
    );
    f.now = DateTime(2026, 10, 2);
    await f.state.send({
      'type': 'updateProfile',
      'profile': {
        'closedMonths': ['2026-09'],
      },
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('Это не означает, что ваши операции изменились.'), findsOneWidget);
    expect(find.text('Нужна повторная сверка'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
