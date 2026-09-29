import 'package:famcoin_core/famcoin_core.dart';
import 'package:test/test.dart';

void main() {
  final day = DateTime(2026, 9, 1);
  Ledger base() {
    final l = Ledger()..addMoneyAccount('cash');
    l.openingBalance(id: 'opening', date: day, account: 'cash', amount: kzt(200000));
    return l;
  }
  Ledger purchase() {
    final l = base();
    l.expense(id: 'purchase', date: day, account: 'cash', splits: {'food': kzt(50000)});
    return l;
  }

  test('repeated delete/restore cycles never duplicate an active operation', () {
    final l = purchase();
    l.reverse('purchase', newId: 'del-0');
    l.restore('purchase', newId: 'back-1');
    l.reverse('back-1', newId: 'del-1');
    expect(l.isDeleted('purchase'), isFalse);
    expect(l.isDeleted('back-1'), isTrue);
    l.restore('back-1', newId: 'back-2');
    expect(l.purchaseRoot('back-2'), 'purchase');
    expect(l.currentVersion('purchase')!.id, 'back-2');
    expect(l.isRestored('purchase'), isTrue);
    expect(() => l.restore('purchase', newId: 'duplicate'), throwsA(isA<LedgerException>()));
    expect(l.balance('cash'), kzt(150000));
    expect(l.report(day, DateTime(2026, 10, 1)).expense, kzt(50000));
  });

  test('a restored purchase reconnects its historical refund', () {
    final l = purchase();
    l.refund(id: 'refund', date: day, category: 'food', amount: kzt(20000),
        toAccount: 'cash', meta: {'refundOf': 'purchase'});
    l.reverse('refund', newId: 'del-refund');
    l.reverse('purchase', newId: 'del-purchase');
    l.restore('purchase', newId: 'back-purchase');
    l.restore('refund', newId: 'back-refund');
    expect(l.refundedFor('back-purchase', 'expense:food'), kzt(20000));
    expect(l.balance('cash'), kzt(170000));
    expect(() => l.refund(id: 'too-much', date: day, category: 'food',
        amount: kzt(40000), toAccount: 'cash', meta: {'refundOf': 'back-purchase'}),
        throwsA(isA<LedgerException>()));
  });

  test('restored then edited purchase keeps one identity and refund floor', () {
    final l = purchase();
    l.reverse('purchase', newId: 'del-0');
    l.restore('purchase', newId: 'back-1');
    l.refund(id: 'refund', date: day, category: 'food', amount: kzt(20000),
        toAccount: 'cash', meta: {'refundOf': 'back-1'});
    l.reverse('back-1', newId: 'del-1');
    expect(() => l.expense(id: 'bad-edit', date: day, account: 'cash',
        splits: {'food': kzt(10000)}, meta: {'edited': 'back-1'}),
        throwsA(isA<LedgerException>().having((e) => e.code, 'code', 'editBelowRefunded')));
    l.expense(id: 'edit-2', date: day, account: 'cash',
        splits: {'food': kzt(60000)}, meta: {'edited': 'back-1'});
    expect(l.purchaseRoot('edit-2'), 'purchase');
    l.reverse('edit-2', newId: 'del-2');
    expect(l.isDeleted('purchase'), isFalse);
    expect(l.isDeleted('back-1'), isFalse);
    expect(l.isDeleted('edit-2'), isTrue);
    expect(() => l.restore('purchase', newId: 'old-version'), throwsA(isA<LedgerException>()));
  });

  test('restoring an incoming repayment checks the current receivable', () {
    final l = base();
    l.lendOut(id: 'lend', date: day, account: 'cash', person: 'friend', amount: kzt(100000));
    l.repaymentReceived(id: 'partial', date: day, account: 'cash', person: 'friend', principal: kzt(60000));
    l.reverse('partial', newId: 'del-partial');
    l.repaymentReceived(id: 'full', date: day, account: 'cash', person: 'friend', principal: kzt(100000));
    expect(() => l.restore('partial', newId: 'bad-restore'),
        throwsA(isA<LedgerException>().having((e) => e.code, 'code', 'repaymentExceeds')));
    expect(l.balance('cash'), kzt(200000));
    expect(l.balance('receivable:friend'), 0);
  });

  test('incoming repayment may be restored at the exact remaining principal', () {
    final l = base();
    l.lendOut(id: 'lend', date: day, account: 'cash', person: 'friend', amount: kzt(100000));
    l.repaymentReceived(id: 'partial', date: day, account: 'cash', person: 'friend', principal: kzt(60000));
    l.reverse('partial', newId: 'del-partial');
    l.repaymentReceived(id: 'rest', date: day, account: 'cash', person: 'friend', principal: kzt(40000));
    l.restore('partial', newId: 'valid-restore');
    expect(l.balance('receivable:friend'), 0);
    expect(l.balance('cash'), kzt(200000));
  });
}
