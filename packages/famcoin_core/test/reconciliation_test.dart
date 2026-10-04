import 'package:famcoin_core/famcoin_core.dart';
import 'package:test/test.dart';

void main() {
  test(
      'остатки на границе месяца: кофе первого числа, перенос, архив и новый счёт',
      () {
    final l = Ledger();
    for (final c in <Map<String, dynamic>>[
      {'type': 'addMoneyAccount', 'accountId': 'card'},
      {'type': 'addMoneyAccount', 'accountId': 'cash'},
      {
        'type': 'opening',
        'id': 'opening',
        'date': '2026-08-01',
        'account': 'card',
        'amount': '1000000'
      },
      {
        'type': 'transfer',
        'id': 'transfer',
        'date': '2026-09-30',
        'from': 'card',
        'to': 'cash',
        'amount': '200000'
      },
      {
        'type': 'expense',
        'id': 'coffee',
        'date': '2026-10-01',
        'account': 'card',
        'splits': {'cafe': '100000'}
      },
      {'type': 'archiveAccount', 'accountId': 'cash'},
      {'type': 'addMoneyAccount', 'accountId': 'new'},
      {
        'type': 'opening',
        'id': 'new-opening',
        'date': '2026-10-01',
        'account': 'new',
        'amount': '500000'
      },
    ]) {
      applyLedgerCommand(l, c);
    }
    expect(reconciliationBalances(l, DateTime(2026, 9)),
        {'card': 800000, 'cash': 200000});
    expect(l.balance('card'), 700000);
    applyLedgerCommand(
        l, {'type': 'reverse', 'id': 'undo-coffee', 'txId': 'coffee'});
    expect(reconciliationBalances(l, DateTime(2026, 9)),
        {'card': 800000, 'cash': 200000});
    applyLedgerCommand(
        l, {'type': 'reverse', 'id': 'undo-transfer', 'txId': 'transfer'});
    expect(reconciliationBalances(l, DateTime(2026, 9)),
        {'card': 1000000, 'cash': 0});
    expect(earliestPostingDate(l.transactions.skip(l.transactions.length - 1)),
        DateTime(2026, 9, 30));
  });

  test('закрытие только после конца месяца, включая год и високосный февраль',
      () {
    expect(canReconcileMonth(DateTime(2026, 9), DateTime(2026, 9, 30, 23, 59)),
        isFalse);
    expect(canReconcileMonth(DateTime(2026, 9), DateTime(2026, 10, 1)), isTrue);
    expect(
        canReconcileMonth(DateTime(2027, 1), DateTime(2026, 10, 1)), isFalse);
    expect(canReconcileMonth(DateTime(2026, 12), DateTime(2027, 1, 1)), isTrue);
    expect(reconciliationEnd(DateTime(2028, 2)), DateTime(2028, 2, 29));
  });
}
