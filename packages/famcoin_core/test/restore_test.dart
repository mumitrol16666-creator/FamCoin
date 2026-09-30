/// Корзина: удалённую операцию можно восстановить, история сохраняется.
library;

import 'package:famcoin_core/famcoin_core.dart';
import 'package:test/test.dart';

void main() {
  Ledger base() {
    final l = Ledger();
    for (final c in [
      {'type': 'addMoneyAccount', 'accountId': 'cash'},
      {'type': 'opening', 'id': 'o1', 'date': '2026-09-01', 'account': 'cash', 'amount': '10000000'},
      {'type': 'expense', 'id': 'e1', 'date': '2026-09-02', 'account': 'cash', 'splits': {'cafe': '250000'}, 'meta': {'note': 'кофе', 'planned': 'p1', 'period': '2026-09'}},
    ]) {
      applyLedgerCommand(l, c);
    }
    return l;
  }

  test('восстановление возвращает эффект операции и помнит исходную запись', () {
    final l = base();
    applyLedgerCommand(l, {'type': 'reverse', 'txId': 'e1', 'id': 'e1-rev'});
    expect(l.balance('cash'), 10000000);
    applyLedgerCommand(l, {'type': 'restore', 'txId': 'e1', 'id': 'e1-back'});
    expect(l.balance('cash'), 9750000);
    final back = l.byId('e1-back')!;
    expect(back.type, EventType.expense);
    expect(back.meta['restoredFrom'], 'e1');
    expect(back.meta['note'], 'кофе');
    expect(back.meta['planned'], 'p1');
    // История: исходная, отменяющая и восстановленная записи остаются.
    expect(l.transactions.map((t) => t.id), containsAll(['e1', 'e1-rev', 'e1-back']));
    expect(l.isReversed('e1'), isTrue);
    expect(l.isReversed('e1-back'), isFalse);
    expect(l.isDeleted('e1'), isFalse, reason: 'восстановленная запись ушла из корзины');
    expect(l.isRestored('e1'), isTrue);
    // Второй раз ту же запись восстановить нельзя — иначе задвоение.
    expect(
      () => applyLedgerCommand(l, {'type': 'restore', 'txId': 'e1', 'id': 'e1-back-2'}),
      throwsA(isA<LedgerException>().having((e) => e.code, 'code', 'alreadyRestored')),
    );
    // Only the latest version of this logical operation belongs in Trash.
    applyLedgerCommand(l, {'type': 'reverse', 'txId': 'e1-back', 'id': 'e1-back-rev'});
    expect(l.isDeleted('e1'), isFalse);
    expect(l.isDeleted('e1-back'), isTrue);
  });

  test('восстановить можно только удалённую операцию', () {
    final l = base();
    expect(
      () => applyLedgerCommand(l, {'type': 'restore', 'txId': 'e1', 'id': 'x'}),
      throwsA(isA<LedgerException>().having((e) => e.code, 'code', 'restoreNotReversed')),
    );
    expect(
      () => applyLedgerCommand(l, {'type': 'restore', 'txId': 'nope', 'id': 'x'}),
      throwsA(isA<LedgerException>().having((e) => e.code, 'code', 'noSuchTransaction')),
    );
  });

  test('у ошибок ядра есть машинный код', () {
    final l = base();
    expect(
      () => applyLedgerCommand(l, {'type': 'refund', 'id': 'r', 'date': '2026-09-03', 'category': 'cafe', 'amount': '300000', 'toAccount': 'cash', 'meta': {'refundOf': 'e1'}}),
      throwsA(isA<LedgerException>().having((e) => e.code, 'code', 'refundExceeds')),
    );
    expect(
      () => applyLedgerCommand(l, {'type': 'expense', 'id': 'e2', 'date': '2026-09-03', 'account': 'nope', 'splits': {'cafe': '100'}}),
      throwsA(isA<LedgerException>().having((e) => e.code, 'code', 'accountNotFound')),
    );
    expect(
      () => applyLedgerCommand(l, {'type': 'transfer', 'id': 't1', 'date': '2026-09-03', 'from': 'cash', 'to': 'cash', 'amount': '100'}),
      throwsA(isA<LedgerException>().having((e) => e.code, 'code', 'sameAccounts')),
    );
  });
}
