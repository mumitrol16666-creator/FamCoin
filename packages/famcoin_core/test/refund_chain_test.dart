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

  test('старую версию правленной покупки нельзя показать в корзине и восстановить (повторный аудит, F01)', () {
    final l = ledgerWithPurchase();
    applyLedgerCommand(l, {'type': 'reverse', 'txId': 'e1', 'id': 'e1-rev'});
    applyLedgerCommand(l, {'type': 'expense', 'id': 'e2', 'date': '2026-09-02', 'account': 'cash', 'splits': {'cafe': '300000'}, 'meta': {'edited': 'e1'}});
    expect(l.isDeleted('e1'), isFalse, reason: 'e1 отменена правкой, а не настоящим удалением — в корзине быть не должна');
    expect(
      () => applyLedgerCommand(l, {'type': 'restore', 'txId': 'e1', 'id': 'e1-restore'}),
      throwsA(isA<LedgerException>().having((e) => e.code, 'code', 'restoreSuperseded')),
    );
    expect(l.balance('cash'), 10000000 - 300000, reason: 'должна остаться только новая сумма покупки, без задвоения');
  });

  test('восстановление возврата заново проверяет лимит — покупку успели урезать (повторный аудит, F02)', () {
    final l = Ledger();
    for (final c in [
      {'type': 'addMoneyAccount', 'accountId': 'cash'},
      {'type': 'opening', 'id': 'o1', 'date': '2026-09-01', 'account': 'cash', 'amount': '10000000'},
      {'type': 'expense', 'id': 'e1', 'date': '2026-09-02', 'account': 'cash', 'splits': {'cafe': '500000'}},
      {'type': 'refund', 'id': 'r1', 'date': '2026-09-03', 'category': 'cafe', 'amount': '200000', 'toAccount': 'cash', 'meta': {'refundOf': 'e1'}},
    ]) {
      applyLedgerCommand(l, c);
    }
    // Удаляем возврат — теперь по e1 «ничего не возвращено», значит правка,
    // занижающая сумму ниже 200 000 ₸, ядром больше не отклоняется (F03
    // проверяет только ДЕЙСТВУЮЩИЕ возвраты, а r1 сейчас отменён).
    applyLedgerCommand(l, {'type': 'reverse', 'txId': 'r1', 'id': 'r1-rev'});
    applyLedgerCommand(l, {'type': 'reverse', 'txId': 'e1', 'id': 'e1-rev'});
    applyLedgerCommand(l, {'type': 'expense', 'id': 'e2', 'date': '2026-09-02', 'account': 'cash', 'splits': {'cafe': '150000'}, 'meta': {'edited': 'e1'}});
    // Покупка теперь 150 000 ₸ — восстановление старого возврата (200 000 ₸)
    // превысило бы стоимость покупки в этой категории.
    expect(
      () => applyLedgerCommand(l, {'type': 'restore', 'txId': 'r1', 'id': 'r1-restore'}),
      throwsA(isA<LedgerException>().having((e) => e.code, 'code', 'refundExceeds')),
    );
    expect(l.balance('cash'), 10000000 - 150000);
  });

  test('восстановление платежа по кредиту заново проверяет остаток долга (повторный аудит, F02)', () {
    final l = Ledger();
    for (final c in [
      {'type': 'addMoneyAccount', 'accountId': 'cash'},
      {'type': 'opening', 'id': 'o1', 'date': '2026-09-01', 'account': 'cash', 'amount': '10000000'},
      {'type': 'openingDebt', 'id': 'd1', 'date': '2026-09-01', 'debtId': 'red', 'amount': '5000000'},
      {'type': 'loanPayment', 'id': 'p1', 'date': '2026-09-05', 'account': 'cash', 'debtId': 'red', 'principal': '5000000'},
    ]) {
      applyLedgerCommand(l, c);
    }
    expect(l.balance('liability:red'), 0, reason: 'долг полностью погашен первым платежом');
    applyLedgerCommand(l, {'type': 'reverse', 'txId': 'p1', 'id': 'p1-rev'});
    // После отмены остаток долга снова 5 000 000 — платим его ЕЩЁ РАЗ другим платежом.
    applyLedgerCommand(l, {'type': 'loanPayment', 'id': 'p2', 'date': '2026-09-06', 'account': 'cash', 'debtId': 'red', 'principal': '5000000'});
    expect(l.balance('liability:red'), 0);
    // Восстановить отменённый p1 сейчас — значит списать тело долга ещё на
    // 5 000 000, хотя остаток уже 0: без повторной проверки получился бы
    // отрицательный долг.
    expect(
      () => applyLedgerCommand(l, {'type': 'restore', 'txId': 'p1', 'id': 'p1-restore'}),
      throwsA(isA<LedgerException>().having((e) => e.code, 'code', 'principalExceeds')),
    );
  });

  test('правку покупки нельзя занизить ниже уже возвращённой суммы (повторный аудит, F03)', () {
    final l = ledgerWithPurchase();
    applyLedgerCommand(l, {'type': 'refund', 'id': 'r1', 'date': '2026-09-03', 'category': 'cafe', 'amount': '200000', 'toAccount': 'cash', 'meta': {'refundOf': 'e1'}});
    applyLedgerCommand(l, {'type': 'reverse', 'txId': 'e1', 'id': 'e1-rev'});
    // Покупка была 250 000 ₸, возвращено уже 200 000 ₸ — занизить до 150 000 ₸ нельзя.
    expect(
      () => applyLedgerCommand(l, {'type': 'expense', 'id': 'e2', 'date': '2026-09-02', 'account': 'cash', 'splits': {'cafe': '150000'}, 'meta': {'edited': 'e1'}}),
      throwsA(isA<LedgerException>().having((e) => e.code, 'code', 'editBelowRefunded')),
    );
    // Ровно на границе (равно уже возвращённой сумме) — можно.
    applyLedgerCommand(l, {'type': 'expense', 'id': 'e3', 'date': '2026-09-02', 'account': 'cash', 'splits': {'cafe': '200000'}, 'meta': {'edited': 'e1'}});
    expect(l.currentVersion('e1')!.id, 'e3');
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
