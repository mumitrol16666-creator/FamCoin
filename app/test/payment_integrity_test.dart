import 'package:famcoin/state/api_client.dart';
import 'package:famcoin/state/retryable_action.dart';
import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audit_regression_test.dart' show FakeServer;

void main() {
  test('lost payment response: retry reconciles exactly one mutation', () async {
    final f = FakeServer();
    await f.init();
    final s = f.state;
    await s.sendBatch(s.newBankDebtCommands(name: 'Loan', kind: 'loan',
        balance: kzt(1000000), payment: kzt(100000), day: 28));
    final debt = s.bankDebts.single;
    final attempt = RetryableAction();
    f.dropNextResponse = true;
    await expectLater(attempt.run((key) => s.payDebt(debtId: debt.id,
        account: 'cash', principal: kzt(100000), id: 'payment-one', commandId: key)),
        throwsA(isA<ApiException>()));
    expect(attempt.pending, isTrue);
    expect(f.ledger.balance('liability:${debt.id}'), kzt(900000));
    await attempt.run(null);
    expect(attempt.pending, isFalse);
    expect(s.debtBalance(debt.id), kzt(900000));
    expect(f.ledger.transactions.where((t) => t.type == EventType.loanPayment).length, 1);
    // A second intentional, equal-sized payment is NOT a retry.
    await RetryableAction().run((key) => s.payDebt(debtId: debt.id,
        account: 'cash', principal: kzt(100000), id: 'payment-two', commandId: key));
    expect(s.debtBalance(debt.id), kzt(800000));
  });

  test('an unresolved attempt cannot silently replace its captured payload', () async {
    final f = FakeServer();
    await f.init();
    final s = f.state;
    final attempt = RetryableAction();
    f.dropNextResponse = true;
    await expectLater(attempt.run((key) => s.addPersonDebt(kind: 'borrow',
        amount: kzt(10000), person: 'friend', account: 'cash', date: s.today,
        id: 'one', commandId: key)), throwsA(isA<ApiException>()));
    var replacementCalled = false;
    await attempt.run((key) async { replacementCalled = true; });
    expect(replacementCalled, isFalse);
    expect(s.ledger.balance('liability:friend'), kzt(10000));
  });

  test('explicit pre-commit rejection unlocks a new corrected attempt', () async {
    final f = FakeServer();
    await f.init();
    final attempt = RetryableAction();
    await expectLater(attempt.run((key) => f.state.addPersonDebt(kind: 'repaymentReceived',
        amount: kzt(10000), person: 'friend', account: 'cash', date: f.state.today,
        id: 'bad', commandId: key)), throwsA(isA<ApiException>()));
    expect(attempt.pending, isFalse);
    await attempt.run((key) => f.state.addPersonDebt(kind: 'borrow',
        amount: kzt(10000), person: 'friend', account: 'cash', date: f.state.today,
        id: 'good', commandId: key));
    expect(f.state.ledger.balance('liability:friend'), kzt(10000));
  });

  test('stale due objects preserve all paid periods; duplicate period is rejected', () async {
    final f = FakeServer();
    await f.init();
    final s = f.state;
    await s.upsert('planned', 'rent', {'name': 'Rent', 'amount': kzt(10000).toString(),
        'day': 10, 'category': 'home', 'paid': [], 'start': '2026-08-01'});
    final dates = s.dueItems(s.today);
    final august = dates.firstWhere((d) => d.period == '2026-08');
    final september = dates.firstWhere((d) => d.period == '2026-09');
    await s.payDue(august, account: 'cash', amount: kzt(10000));
    await s.payDue(september, account: 'cash', amount: kzt(10000));
    expect(s.planned.single.paid, {'2026-08', '2026-09'});
    await expectLater(s.payDue(august, account: 'cash', amount: kzt(10000)), throwsA(isA<ApiException>()));
    expect(f.ledger.transactions.where((t) => t.meta['planned'] == 'rent').length, 2);
    // Removing one payment does not erase another period's paid flag.
    final first = s.userTransactions.firstWhere((t) => t.meta['period'] == '2026-08');
    await s.deleteTransaction(first.id);
    expect(s.planned.single.paid, {'2026-09'});
    await s.restoreTransaction(first.id);
    expect(s.planned.single.paid, {'2026-08', '2026-09'});
  });

  test('closing a loan increases progress without retaining its monthly payment', () async {
    final f = FakeServer();
    await f.init();
    final s = f.state;
    for (final name in ['A', 'B']) {
      await s.sendBatch(s.newBankDebtCommands(name: name, kind: 'loan',
          balance: kzt(100000), payment: kzt(10000), day: 28));
    }
    final a = s.bankDebts.firstWhere((d) => d.name == 'A');
    await s.payDebt(debtId: a.id, account: 'cash', principal: kzt(90000));
    expect(s.debtLoadStatus.paidPercent, 45);
    await s.payDebt(debtId: a.id, account: 'cash', principal: kzt(10000));
    expect(s.debtLoadStatus.paidPercent, 50);
    expect(s.debtLoadStatus.monthlyPayments, kzt(10000));
    expect(s.debtLoadStatus.totalDebt, kzt(100000));
  });

  test('payday ratio excludes dates before the first observed day and future dates', () async {
    final f = FakeServer()..now = DateTime(2026, 9, 29);
    final s = f.state;
    await s.load();
    await s.send({'type': 'addMoneyAccount', 'accountId': 'cash'});
    await s.addIncome(amount: kzt(100000), source: 'salary', account: 'cash', date: DateTime(2026, 9, 28));
    await s.addExpense(amount: kzt(10000), category: 'food', account: 'cash', date: DateTime(2026, 9, 28));
    await s.addExpense(amount: kzt(10000), category: 'food', account: 'cash', date: DateTime(2026, 9, 29));
    expect(s.paydaySpendRatio(), closeTo(1, 0.000001));
    expect(s.paydaySpendRatio(months: 0), isNull);
  });
}
