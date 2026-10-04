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
  test(
      'сравнение сумм: категории и дата внутри месяца, переводы, отмена и месяцы без изменения',
      () {
    final l = Ledger()
      ..addMoneyAccount('cash')
      ..addMoneyAccount('card');
    l.openingBalance(
        id: 'opening',
        date: DateTime(2026, 8, 1),
        account: 'cash',
        amount: 1000000);
    l.expense(
        id: 'old',
        date: DateTime(2026, 9, 5),
        account: 'cash',
        splits: {'cafe': 10000});
    final september = DateTime(2026, 9), october = DateTime(2026, 10);
    final sep = reconciliationSnapshot(l, september),
        oct = reconciliationSnapshot(l, october);
    l.reverse('old', newId: 'undo');
    l.expense(
        id: 'edited',
        date: DateTime(2026, 9, 20),
        account: 'cash',
        splits: {'food': 10000},
        meta: {'note': 'Исправил категорию'});
    expect(
        reconciliationChanges(sep, reconciliationSnapshot(l, september))
            .isEmpty,
        isTrue);
    expect(
        reconciliationChanges(oct, reconciliationSnapshot(l, october)).isEmpty,
        isTrue);
    l.transfer(
        id: 'transfer',
        date: DateTime(2026, 9, 30),
        from: 'cash',
        to: 'card',
        amount: 20000);
    final moved =
        reconciliationChanges(sep, reconciliationSnapshot(l, september));
    expect(moved.balances['cash'], (before: 990000, after: 970000));
    expect(moved.balances['card'], (before: 0, after: 20000));
    expect(moved.totals, isEmpty,
        reason: 'общий итог не меняется, но счета нужно проверить');
    l.reverse('transfer', newId: 'undo-transfer');
    expect(
        reconciliationChanges(sep, reconciliationSnapshot(l, september))
            .isEmpty,
        isTrue);
    l.expense(
        id: 'forgotten',
        date: DateTime(2026, 9, 30),
        account: 'cash',
        splits: {'food': 5000});
    l.income(
        id: 'offset',
        date: DateTime(2026, 9, 30),
        account: 'cash',
        source: 'salary',
        amount: 5000);
    final changedTotals =
        reconciliationChanges(sep, reconciliationSnapshot(l, september));
    expect(changedTotals.balances, isEmpty);
    expect(changedTotals.totals.keys, unorderedEquals(['income', 'expense']));
    expect(
        reconciliationChanges(oct, reconciliationSnapshot(l, october)).isEmpty,
        isTrue,
        reason:
            'в октябре не изменились ни остатки, ни итоги — повторная сверка не нужна');
    l.archiveAccount('cash');
    expect(
        reconciliationChanges(oct, reconciliationSnapshot(l, october)).isEmpty,
        isTrue);
  });

  test('нулевой счёт не создаёт расхождение; денежный поток тоже проверяется',
      () {
    final base = <String, dynamic>{
      'balances': {'cash': '100'},
      'income': '0',
      'expense': '0',
      'cashFlow': '0'
    };
    expect(
        reconciliationChanges(base, {
          ...base,
          'balances': {'cash': '100', 'empty': '0'}
        }).isEmpty,
        isTrue);
    final diff = reconciliationChanges(base, {...base, 'cashFlow': '10'});
    expect(diff.totals['cashFlow'], (before: 0, after: 10));
  });
}
