import 'package:famcoin_core/famcoin_core.dart';
import 'package:test/test.dart';
void main() {
  test('deleted versioned plans cannot be recreated, including legacy revision 0', () {
    for (final revision in [0, 1, 5]) {
      expect(() => mergePlannedUpsert(null, {'rev': revision}), throwsA(isA<LedgerException>().having((e) => e.code, 'code', 'entityChanged')));
    }
    expect(mergePlannedUpsert(null, {'name': 'new'})['rev'], 1);
  });
  test('installment allocates principal once across overdue and future periods', () {
    final l = Ledger()..openingDebt(id: 'open', date: DateTime(2026, 1, 1), debtId: 'red', amount: 120000);
    final budget = DebtDueBudget(l);
    expect([for (var i = 0; i < 4; i++) budget.take(debtId: 'red', amount: 50000, kind: 'installment')], [50000, 50000, 20000, 0]);
  });
  test('loan allocation includes interest separately from outstanding principal', () {
    final l = Ledger()..openingDebt(id: 'open', date: DateTime(2026, 1, 1), debtId: 'loan', amount: 100000);
    final budget = DebtDueBudget(l);
    expect(budget.take(debtId: 'loan', amount: 60000, kind: 'loan', rate: 24), 60000);
    expect(budget.take(debtId: 'loan', amount: 60000, kind: 'loan', rate: 24), 42840);
    expect(budget.take(debtId: 'loan', amount: 60000, kind: 'loan', rate: 24), 0);
  });
  test('historical piggy transfer is bounded at every subsequent date', () {
    final l = Ledger()..addMoneyAccount('cash')..addMoneyAccount('piggy-g');
    l.openingBalance(id: 'open', date: DateTime(2026, 9, 1), account: 'piggy-g', amount: 50000);
    applyLedgerCommand(l, {'type': 'transfer', 'id': 'withdraw', 'date': '2026-10-02', 'from': 'piggy-g', 'to': 'cash', 'amount': '30000'});
    l.income(id: 'later', date: DateTime(2026, 10, 3), account: 'piggy-g', source: 'salary', amount: 30000);
    expect(l.availableFrom('piggy-g', DateTime(2026, 9, 30)), 20000);
    expect(() => applyLedgerCommand(l, {'type': 'transfer', 'id': 'stale', 'date': '2026-09-30', 'from': 'piggy-g', 'to': 'cash', 'amount': '50000'}), throwsA(isA<LedgerException>()));
    expect(l.balance('piggy-g'), 50000);
    expect(() => applyLedgerCommand(l, {'type': 'archiveAccount', 'accountId': 'piggy-g'}), throwsA(isA<LedgerException>()));
  });
  test('replaying a piggy withdrawal with the same transaction id remains idempotent', () {
    final l = Ledger()..addMoneyAccount('cash')..addMoneyAccount('piggy-g');
    l.openingBalance(id: 'open', date: DateTime(2026, 9, 1), account: 'piggy-g', amount: 50000);
    final c = {'type': 'transfer', 'id': 'withdraw', 'date': '2026-09-02', 'from': 'piggy-g', 'to': 'cash', 'amount': '50000'};
    applyLedgerCommand(l, c);
    applyLedgerCommand(l, c);
    expect(l.balance('piggy-g'), 0);
    expect(l.balance('cash'), 50000);
  });

}
