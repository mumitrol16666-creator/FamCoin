// Diagnostic probes for immutable fcd1fa1. These assert observed defects,
// not desired behaviour; invert the relevant expectations when fixing them.
import 'package:famcoin_core/famcoin_core.dart';
import 'package:test/test.dart';

final day = DateTime(2026, 10, 1);
final end = DateTime(2026, 11, 1);

Ledger base() => Ledger()
  ..addMoneyAccount('cash')
  ..openingBalance(id: 'opening', date: day, account: 'cash', amount: kzt(100000));

void main() {
  test('C01: repeated delete/restore leaves two active copies of one purchase', () {
    final l = base()
      ..expense(id: 'e1', date: day, account: 'cash', splits: {'food': kzt(10000)})
      ..reverse('e1', newId: 'r1')
      ..restore('e1', newId: 'e2')
      ..reverse('e2', newId: 'r2');
    expect(l.isDeleted('e1'), isTrue);
    expect(l.isDeleted('e2'), isTrue);
    l.restore('e1', newId: 'e3');
    expect(l.isDeleted('e2'), isTrue, reason: 'A second copy is still offered in the bin');
    l.restore('e2', newId: 'e4');
    expect(l.balance('cash'), kzt(80000));
    expect(l.report(day, end).expense, kzt(20000));
    print('C01: one 10,000 purchase restored as two: cash=80,000, expenses=20,000');
  });

  test('C02a: received repayment can be restored after another repayment closed debt', () {
    final l = base()
      ..lendOut(id: 'lend', date: day, account: 'cash', person: 'friend', amount: kzt(50000))
      ..repaymentReceived(id: 'p1', date: day, account: 'cash', person: 'friend', principal: kzt(50000))
      ..reverse('p1', newId: 'r1')
      ..repaymentReceived(id: 'p2', date: day, account: 'cash', person: 'friend', principal: kzt(50000))
      ..restore('p1', newId: 'p3');
    expect(l.balance('receivable:friend'), -kzt(50000));
    expect(l.balance('cash'), kzt(150000));
    expect(l.report(day, end).returnedToMe, kzt(100000));
    print('C02a: loan issued=50,000; accepted returns=100,000; receivable=-50,000; cash=150,000');
  });

  for (final receivable in [true, false]) {
    test('C02b: restore write-off exceeds remaining debt (receivable=$receivable)', () {
      final l = base();
      if (receivable) {
        l.lendOut(id: 'lend', date: day, account: 'cash', person: 'friend', amount: kzt(50000));
      } else {
        l.borrow(id: 'borrow', date: day, account: 'cash', person: 'friend', amount: kzt(50000));
      }
      l.writeOff(id: 'w1', date: day, person: 'friend', amount: kzt(50000), receivable: receivable);
      l.reverse('w1', newId: 'r1');
      l.writeOff(id: 'w2', date: day, person: 'friend', amount: kzt(50000), receivable: receivable);
      l.restore('w1', newId: 'w3');
      expect(l.balance('${receivable ? 'receivable' : 'liability'}:friend'), -kzt(50000));
      expect(receivable ? l.report(day, end).expense : l.report(day, end).income, kzt(100000));
      print('C02b: receivable=$receivable, written off 100,000 against 50,000; remaining=-50,000');
    });
  }

  test('C03: deleting repaid borrowing leaves negative liability', () {
    final l = base()
      ..borrow(id: 'b1', date: day, account: 'cash', person: 'friend', amount: kzt(50000))
      ..repaymentMade(id: 'p1', date: day, account: 'cash', person: 'friend', principal: kzt(50000))
      ..reverse('b1', newId: 'r1');
    expect(l.balance('liability:friend'), -kzt(50000));
    expect(l.balance('cash'), kzt(50000));
    expect(l.report(day, end).borrowed, 0);
    expect(l.report(day, end).debtPayments, kzt(50000));
    print('C03: deleting 50,000 borrowing after repayment: liability=-50,000, cash=50,000');
  });

  test('C04: restoration breaks link between purchase and deleted refund', () {
    final l = base()
      ..expense(id: 'e1', date: day, account: 'cash', splits: {'food': kzt(10000)})
      ..refund(id: 'f1', date: day, category: 'food', amount: kzt(10000), toAccount: 'cash', meta: {'refundOf': 'e1'})
      ..reverse('f1', newId: 'rf')
      ..reverse('e1', newId: 're')
      ..restore('e1', newId: 'e2');
    expect(l.currentVersion('e1'), isNull);
    expect(l.purchaseRoot('e2'), 'e2');
    expect(() => l.restore('f1', newId: 'f2'), throwsA(isA<LedgerException>().having((e) => e.code, 'code', 'purchaseCancelled')));
    print('C04: purchase restored as e2; dependent refund cannot restore: purchaseCancelled');
  });

  test('C05: nominal n-month loan schedule can extend by a whole extra month', () {
    final schedule = buildSchedule(principal: kzt(100000), annualRatePercent: 0, months: 3)!;
    expect(schedule.months, 4);
    expect(schedule.rows.last.payment, 1);
    print('C05: 100,000 / 3 at 0%: 4 rows; payments ${schedule.rows.map((r) => r.payment / 100).toList()}');
    final early = earlyRepayment(balance: kzt(150000), annualRatePercent: 0, payment: kzt(50000), extra: kzt(50000));
    expect(early.baseline.months, 3);
    expect(early.reducePayment!.months, 4);
    print('C05: early repayment 50,000 against 150,000, preserve term 3 months → offered 4 months');
  });

  test('C06: negative release increases reservation above money balance', () {
    final l = base()..reserve(goalId: 'goal', accountId: 'cash', amount: kzt(50000));
    applyLedgerCommand(l, {'type': 'release', 'goalId': 'goal', 'accountId': 'cash', 'amount': '${-kzt(100000)}'});
    expect(l.reserved(), kzt(150000));
    expect(l.freeLiquid(), -kzt(50000));
    print('C06: release -100,000 increases reserve 50,000→150,000 with cash=100,000');
    final other = base()..reserve(goalId: 'goal', accountId: 'cash', amount: kzt(50000));
    other.ensure('expense:food', LedgerKind.expense);
    other.postFromReservation(Transaction(id: 'spend', date: day, type: EventType.expense,
        postings: [Posting('cash', -kzt(5000)), Posting('expense:food', kzt(5000))]),
        goalId: 'goal', accountId: 'cash', amount: -kzt(5000));
    expect(other.reserved(), kzt(55000));
    expect(other.balance('cash'), kzt(95000));
    print('C06: spending from reserve with negative amount also posts and increases reserve');
  });

  test('C07: restored copy and original duplicates survive snapshot reconstruction', () {
    final l = base()
      ..expense(id: 'e1', date: day, account: 'cash', splits: {'food': kzt(10000)})
      ..reverse('e1', newId: 'r1')
      ..restore('e1', newId: 'e2')
      ..reverse('e2', newId: 'r2')
      ..restore('e1', newId: 'e3')
      ..restore('e2', newId: 'e4');
    final reloaded = ledgerFromSnapshot(accounts: l.accounts.map(accountToJson), transactions: l.transactions.map(transactionToJson));
    expect(reloaded.balance('cash'), kzt(80000));
    expect(DailyTotals.rebuild(l).sameAs(DailyTotals.rebuild(reloaded)), isTrue);
  });

  test('C08: archiveAccount archived=false cannot restore an archived account', () {
    final l = base();
    applyLedgerCommand(l, {'type': 'archiveAccount', 'accountId': 'cash'});
    expect(() => applyLedgerCommand(l, {'type': 'archiveAccount', 'accountId': 'cash', 'archived': false}),
        throwsA(isA<LedgerException>().having((e) => e.code, 'code', 'accountArchived')));
    expect(l.account('cash').archived, isTrue);
    print('C08: archived=false fails accountArchived; 100,000 remains permanently archived through command API');
  });
}
