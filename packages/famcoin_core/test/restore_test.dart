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
    // После повторного удаления в корзине только последняя версия.
    applyLedgerCommand(l, {'type': 'reverse', 'txId': 'e1-back', 'id': 'e1-back-rev'});
    expect(l.isDeleted('e1'), isFalse);
    expect(l.isDeleted('e1-back'), isTrue);
    expect(() => l.restore('e1', newId: 'old-back'),
        throwsA(isA<LedgerException>().having((e) => e.code, 'code', 'restoreSuperseded')));
    l.restore('e1-back', newId: 'latest-back');
    expect(() => l.restore('e1', newId: 'duplicate'),
        throwsA(isA<LedgerException>().having((e) => e.code, 'code', 'alreadyRestored')));
    expect(l.balance('cash'), 9750000);
  });

  test('C01/T01 после reload одна живая версия за несколько циклов корзины', () {
    var l = base();
    var latest = 'e1';
    final versions = <String>['e1'];
    for (var cycle = 0; cycle < 3; cycle++) {
      l.reverse(latest, newId: 'delete-$cycle');
      l = ledgerFromSnapshot(accounts: l.accounts.map(accountToJson),
          transactions: l.transactions.map(transactionToJson));
      expect(l.transactions.where((t) => l.isDeleted(t.id)).map((t) => t.id), [latest]);
      expect(l.balance('cash'), 10000000);
      final next = 'restored-$cycle';
      l.restore(latest, newId: next);
      for (final old in versions) {
        expect(() => l.restore(old, newId: 'duplicate-$cycle-$old'),
            throwsA(isA<LedgerException>().having((e) => e.code, 'code', 'alreadyRestored')));
      }
      expect(l.balance('cash'), 9750000);
      expect(l.transactions.where((t) => t.type == EventType.expense && !l.isReversed(t.id)), hasLength(1));
      latest = next;
      versions.add(next);
    }
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
