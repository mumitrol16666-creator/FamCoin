/// Возвраты и правки покупки (F02 аудита 28.09.2026): возврат помнит
/// покупку по всей цепочке правок, вернуть больше покупки нельзя.
library;

import 'package:famcoin_core/famcoin_core.dart';
import 'package:test/test.dart';

void main() {
  Ledger ledgerWithPurchase() {
    final l = Ledger();
    for (final c in [
      {'type': 'addMoneyAccount', 'accountId': 'cash'},
      {'type': 'opening', 'id': 'o1', 'date': '2026-09-01', 'account': 'cash', 'amount': '10000000'},
      {'type': 'expense', 'id': 'e1', 'date': '2026-09-02', 'account': 'cash', 'splits': {'cafe': '250000'}},
    ]) {
      applyLedgerCommand(l, c);
    }
    return l;
  }

  test('после правки покупки возврат привязан к исходной версии', () {
    final l = ledgerWithPurchase();
    applyLedgerCommand(l, {'type': 'refund', 'id': 'r1', 'date': '2026-09-03', 'category': 'cafe', 'amount': '250000', 'toAccount': 'cash', 'meta': {'refundOf': 'e1'}});
    // Правка только заметки: старая версия отменяется, новая ссылается на неё
    // (в приложении и на сервере это одна команда-batch).
    applyLedgerCommand(l, {'type': 'reverse', 'txId': 'e1', 'id': 'e1-rev'});
    applyLedgerCommand(l, {'type': 'expense', 'id': 'e2', 'date': '2026-09-02', 'account': 'cash', 'splits': {'cafe': '250000'}, 'meta': {'note': 'только заметка', 'edited': 'e1'}});
    expect(l.purchaseRoot('e2'), 'e1');
    expect(l.currentVersion('e1')!.id, 'e2');
    expect(l.refundedFor('e2', 'expense:cafe'), 250000);
    expect(l.balance('cash'), 10000000, reason: 'покупка возвращена полностью, лишних денег нет');

    // Повторный возврат по новой версии — отклоняется ядром (и на сервере).
    expect(
      () => applyLedgerCommand(l, {'type': 'refund', 'id': 'r2', 'date': '2026-09-04', 'category': 'cafe', 'amount': '250000', 'toAccount': 'cash', 'meta': {'refundOf': 'e2'}}),
      throwsA(isA<LedgerException>()),
    );
    expect(l.balance('cash'), 10000000);
  });

  test('частичный возврат: остаток можно вернуть, больше — нельзя', () {
    final l = ledgerWithPurchase();
    applyLedgerCommand(l, {'type': 'refund', 'id': 'r1', 'date': '2026-09-03', 'category': 'cafe', 'amount': '100000', 'toAccount': 'cash', 'meta': {'refundOf': 'e1'}});
    expect(
      () => applyLedgerCommand(l, {'type': 'refund', 'id': 'r2', 'date': '2026-09-03', 'category': 'cafe', 'amount': '200000', 'toAccount': 'cash', 'meta': {'refundOf': 'e1'}}),
      throwsA(isA<LedgerException>()),
    );
    applyLedgerCommand(l, {'type': 'refund', 'id': 'r3', 'date': '2026-09-03', 'category': 'cafe', 'amount': '150000', 'toAccount': 'cash', 'meta': {'refundOf': 'e1'}});
    expect(l.refundedFor('e1', 'expense:cafe'), 250000);
  });

  test('отменённый возврат не считается возвращённым', () {
    final l = ledgerWithPurchase();
    applyLedgerCommand(l, {'type': 'refund', 'id': 'r1', 'date': '2026-09-03', 'category': 'cafe', 'amount': '250000', 'toAccount': 'cash', 'meta': {'refundOf': 'e1'}});
    applyLedgerCommand(l, {'type': 'reverse', 'txId': 'r1', 'id': 'r1-rev'});
    expect(l.refundedFor('e1', 'expense:cafe'), 0);
    applyLedgerCommand(l, {'type': 'refund', 'id': 'r2', 'date': '2026-09-04', 'category': 'cafe', 'amount': '250000', 'toAccount': 'cash', 'meta': {'refundOf': 'e1'}});
    expect(l.balance('cash'), 10000000);
  });

  test('оплата по кредиту хранит meta (связь со сроком планового платежа)', () {
    final l = Ledger();
    for (final c in [
      {'type': 'addMoneyAccount', 'accountId': 'cash'},
      {'type': 'opening', 'id': 'o1', 'date': '2026-09-01', 'account': 'cash', 'amount': '10000000'},
      {'type': 'openingDebt', 'id': 'd1', 'date': '2026-09-01', 'debtId': 'red', 'amount': '5000000'},
      {'type': 'loanPayment', 'id': 'p1', 'date': '2026-09-05', 'account': 'cash', 'debtId': 'red', 'principal': '1000000', 'meta': {'planned': 'pl1', 'period': '2026-09'}},
    ]) {
      applyLedgerCommand(l, c);
    }
    expect(l.byId('p1')!.meta['planned'], 'pl1');
    expect(l.byId('p1')!.meta['period'], '2026-09');
  });
}
