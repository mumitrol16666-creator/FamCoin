/// Срок возврата личного долга: части и новый цикл (аудит 08.10, N01 + N02).
/// «Сегодня» заглушки — 28.09.2026, на счёте `cash` 100 000 ₸.
library;

import 'package:famcoin/state/app_scope.dart';
import 'package:famcoin/state/app_state.dart';
import 'package:famcoin/state/models.dart';
import 'package:famcoin/ui/budget/sheets.dart';
import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audit_regression_test.dart' show FakeServer;
import 'ux_gaps_a_test.dart' show openForm, pumpWith;

Future<AppState> started() async {
  final f = FakeServer();
  await f.init();
  return f.state;
}

DueItem soleDue(AppState s) => s.dueItems(DateTime(2026, 10, 31)).single;

List<Transaction> parts(AppState s) => [
      for (final t in s.ledger.transactions)
        if (t.type == EventType.repaymentMade && !s.ledger.isReversed(t.id) && t.meta['part'] == true) t,
    ];

void main() {
  group('N01: часть долга к сроку', () {
    test('80 000 − 30 000 через оплату срока: срок остаётся на 50 000 в списке и прогнозе; вторая часть закрывает ровно остаток', () async {
      final s = await started();
      await s.addPersonDebt(kind: 'borrow', amount: kzt(80000), person: 'Друг', account: 'cash', date: s.today, dueDate: DateTime(2026, 9, 30));
      final first = soleDue(s);
      expect(first.payAmount, kzt(80000));
      expect(s.monthEndForecast.remainingObligations, kzt(80000));

      await s.payDue(first, account: 'cash', amount: kzt(30000), date: s.today);
      expect(s.personDebts.single.amount, kzt(50000));
      final left = soleDue(s);
      expect(left.period, first.period, reason: 'тот же срок, а не новый');
      expect(left.payAmount, kzt(50000));
      expect(s.planned.single.paid, isEmpty, reason: 'часть срок не закрывает');
      expect(s.monthEndForecast.remainingObligations, kzt(50000), reason: 'прогноз держит остаток');

      await s.payDue(left, account: 'cash', amount: left.payAmount, date: s.today);
      expect(s.personDebts, isEmpty);
      expect(s.dueItems(DateTime(2026, 10, 31)), isEmpty);
      expect(s.planned.single.paid, {first.period});
      expect(s.ledger.balance('cash'), kzt(100000));
      expect(parts(s), hasLength(1), reason: 'закрывающий платёж частью не помечен');
    });

    test('удаление и восстановление части пересчитывают срок; удаление части после закрытия снова открывает его', () async {
      final s = await started();
      await s.addPersonDebt(kind: 'borrow', amount: kzt(80000), person: 'Друг', account: 'cash', date: s.today, dueDate: DateTime(2026, 9, 30));
      await s.payDue(soleDue(s), account: 'cash', amount: kzt(30000), date: s.today);
      await s.payDue(soleDue(s), account: 'cash', amount: kzt(20000), date: s.today);
      expect(soleDue(s).payAmount, kzt(30000));

      final second = parts(s).last;
      await s.deleteTransaction(second.id);
      expect(soleDue(s).payAmount, kzt(50000));
      await s.restoreTransaction(second.id);
      expect(soleDue(s).payAmount, kzt(30000));
      expect(s.planned.single.paid, isEmpty, reason: 'восстановленная часть срок не закрывает');

      await s.payDue(soleDue(s), account: 'cash', amount: kzt(30000), date: s.today);
      expect(s.dueItems(DateTime(2026, 10, 31)), isEmpty);
      await s.deleteTransaction(parts(s).first.id);
      expect(s.planned.single.paid, isEmpty, reason: 'без этой части срок исполнен не полностью');
      expect(soleDue(s).payAmount, kzt(30000));
      expect(s.personDebts.single.amount, kzt(30000));
    });

    test('две части со старых форм больше остатка: вторая отклонена, переплаты нет', () async {
      final s = await started();
      await s.addPersonDebt(kind: 'borrow', amount: kzt(80000), person: 'Друг', account: 'cash', date: s.today, dueDate: DateTime(2026, 9, 30));
      final stale = soleDue(s); // обе формы открыты, пока остаток был 80 000
      await s.payDue(stale, account: 'cash', amount: kzt(50000), date: s.today);
      await expectLater(s.payDue(stale, account: 'cash', amount: kzt(50000), date: s.today), throwsA(anything));
      expect(s.personDebts.single.amount, kzt(30000));
      expect(s.ledger.balance('cash'), kzt(130000));
      expect(soleDue(s).payAmount, kzt(30000));
    });

    testWidgets('форма срока: сумма меньше остатка — подсказка про остаток; потерянный ответ и повтор дают одну часть', (tester) async {
      final f = await pumpWith(tester, (c) => showPayDueSheet(c, AppScope.of(c).state.dueItems(DateTime(2026, 10, 31)).single));
      final s = f.state;
      await s.addPersonDebt(kind: 'borrow', amount: kzt(80000), person: 'Друг', account: 'cash', date: s.today, dueDate: DateTime(2026, 9, 30));
      await openForm(tester);
      expect(find.textContaining('к сроку останется'), findsNothing, reason: 'вся сумма — подсказки нет');
      await tester.enterText(find.byType(TextField).first, '30000');
      await tester.pump();
      expect(find.textContaining('к сроку останется'), findsOneWidget);

      f.dropNextResponse = true;
      final pay = find.widgetWithText(FilledButton, 'Оплатить');
      await tester.ensureVisible(pay);
      await tester.tap(pay);
      await tester.pumpAndSettle();
      expect(f.ledger.balance(liabilityAccount('Друг')), kzt(50000), reason: 'сервер принял часть');
      await tester.ensureVisible(pay);
      await tester.tap(pay);
      await tester.pumpAndSettle();
      expect(f.ledger.balance(liabilityAccount('Друг')), kzt(50000), reason: 'повтор той же части не списал второй раз');
      expect(parts(s), hasLength(1));
      expect(soleDue(s).payAmount, kzt(50000));
    });
  });

  testWidgets('сумма больше остатка к сроку: предупреждение до нажатия, оплата не уходит (сервер её отклонил бы)', (tester) async {
    final f = await pumpWith(tester, (c) => showPayDueSheet(c, AppScope.of(c).state.dueItems(DateTime(2026, 10, 31)).single));
    final s = f.state;
    await s.addPersonDebt(kind: 'borrow', amount: kzt(80000), person: 'Друг', account: 'cash', date: s.today, dueDate: DateTime(2026, 9, 30));
    await s.payDue(soleDue(s), account: 'cash', amount: kzt(30000), date: s.today);
    await openForm(tester);
    await tester.enterText(find.byType(TextField).first, '60000');
    await tester.pump();
    expect(find.textContaining('Больше, чем осталось к сроку'), findsOneWidget);
    final pay = find.widgetWithText(FilledButton, 'Оплатить');
    await tester.ensureVisible(pay);
    await tester.tap(pay);
    await tester.pumpAndSettle();
    expect(f.ledger.balance(liabilityAccount('Друг')), kzt(50000), reason: 'лишнего не отправлено');
    expect(soleDue(s).payAmount, kzt(50000));
  });

  group('N02: новый цикл долга', () {
    test('долг закрыт через срок, новый долг тому же человеку с той же датой оплачивается', () async {
      final s = await started();
      await s.addPersonDebt(kind: 'borrow', amount: kzt(50000), person: 'Друг', account: 'cash', date: s.today, dueDate: DateTime(2026, 9, 30));
      final old = soleDue(s);
      await s.payDue(old, account: 'cash', amount: old.payAmount, date: s.today);
      expect(s.personDebts, isEmpty);

      await s.addPersonDebt(kind: 'borrow', amount: kzt(20000), person: 'Друг', account: 'cash', date: s.today, dueDate: DateTime(2026, 9, 30));
      final fresh = soleDue(s);
      expect(fresh.planned.id, isNot(old.planned.id), reason: 'новая договорённость — свой id');
      expect(fresh.payAmount, kzt(20000));
      expect(s.planned.where((p) => p.person == 'Друг'), hasLength(1), reason: 'старый исполненный срок снят');

      await s.payDue(fresh, account: 'cash', amount: fresh.payAmount, date: s.today);
      expect(s.personDebts, isEmpty);
      expect(s.ledger.balance('cash'), kzt(100000));
      // Старое погашение осталось в истории.
      expect(s.ledger.transactions.where((t) => t.type == EventType.repaymentMade && t.meta['planned'] == old.planned.id), hasLength(1));
    });

    test('«взял ещё» со сроком до закрытия: срок — весь остаток, прежние части не вычитаются второй раз', () async {
      final s = await started();
      await s.addPersonDebt(kind: 'borrow', amount: kzt(80000), person: 'Друг', account: 'cash', date: s.today, dueDate: DateTime(2026, 9, 30));
      await s.payDue(soleDue(s), account: 'cash', amount: kzt(30000), date: s.today);
      await s.addPersonDebt(kind: 'borrow', amount: kzt(20000), person: 'Друг', account: 'cash', date: s.today, dueDate: DateTime(2026, 10, 5));
      expect(s.personDebts.single.amount, kzt(70000));
      final due = soleDue(s);
      expect(due.date, DateTime(2026, 10, 5));
      expect(due.payAmount, kzt(70000));
      // Без новой даты прежняя будущая договорённость остаётся как была.
      await s.addPersonDebt(kind: 'borrow', amount: kzt(5000), person: 'Друг', account: 'cash', date: s.today);
      expect(soleDue(s).planned.id, due.planned.id);
    });

    test('новый долг без срока после погашенного: прежний исполненный срок не оживает', () async {
      final s = await started();
      await s.addPersonDebt(kind: 'borrow', amount: kzt(40000), person: 'Брат', account: 'cash', date: s.today, dueDate: DateTime(2026, 10, 10));
      await s.payDue(soleDue(s), account: 'cash', amount: kzt(40000), date: s.today);
      await s.addPersonDebt(kind: 'borrow', amount: kzt(10000), person: 'Брат', account: 'cash', date: s.today);
      expect(s.planned.where((p) => p.person == 'Брат'), isEmpty);
      expect(s.dueItems(DateTime(2026, 12, 31)), isEmpty);
    });

    test('перенос срока туда и обратно не путает погашенный цикл с новым', () async {
      final s = await started();
      await s.addPersonDebt(kind: 'borrow', amount: kzt(40000), person: 'Брат', account: 'cash', date: s.today, dueDate: DateTime(2026, 9, 30));
      await s.payDue(soleDue(s), account: 'cash', amount: kzt(40000), date: s.today);
      await s.addPersonDebt(kind: 'borrow', amount: kzt(10000), person: 'Брат', account: 'cash', date: s.today);
      await s.setPersonDue(s.personDebts.single, DateTime(2026, 9, 30));
      await s.setPersonDue(s.personDebts.single, DateTime(2026, 10, 15));
      await s.setPersonDue(s.personDebts.single, DateTime(2026, 9, 30));
      expect(s.planned.where((p) => p.person == 'Брат'), hasLength(1));
      final due = soleDue(s);
      expect(due.payAmount, kzt(10000));
      await s.payDue(due, account: 'cash', amount: due.payAmount, date: s.today);
      expect(s.personDebts, isEmpty);
      expect(s.dueItems(DateTime(2026, 12, 31)), isEmpty);
    });
  });
}
