import 'package:famcoin_core/famcoin_core.dart';
import 'package:test/test.dart';

void main() {
  test('доходы по категориям: каждая категория своей суммой, займ и перевод не доход, итог = заработанное (D165)', () {
    final l = Ledger();
    applyLedgerCommand(l, {'type': 'addMoneyAccount', 'accountId': 'kaspi'});
    applyLedgerCommand(l, {'type': 'addMoneyAccount', 'accountId': 'cash'});
    applyLedgerCommand(l, {'type': 'income', 'id': 'i1', 'date': '2026-10-02', 'account': 'kaspi', 'source': 'salary', 'amount': '${kzt(300000)}'});
    applyLedgerCommand(l, {'type': 'income', 'id': 'i2', 'date': '2026-10-05', 'account': 'kaspi', 'source': 'side', 'amount': '${kzt(8000)}'});
    applyLedgerCommand(l, {'type': 'income', 'id': 'i3', 'date': '2026-10-06', 'account': 'cash', 'source': 'side', 'amount': '${kzt(1500)}'});
    applyLedgerCommand(l, {'type': 'income', 'id': 'i4', 'date': '2026-09-30', 'account': 'cash', 'source': 'salary', 'amount': '${kzt(99000)}'});
    applyLedgerCommand(l, {'type': 'borrow', 'id': 'b1', 'date': '2026-10-07', 'account': 'kaspi', 'person': 'Вадим', 'amount': '${kzt(50000)}'});
    applyLedgerCommand(l, {'type': 'transfer', 'id': 't1', 'date': '2026-10-07', 'from': 'kaspi', 'to': 'cash', 'amount': '${kzt(10000)}'});
    applyLedgerCommand(l, {'type': 'income', 'id': 'i5', 'date': '2026-10-08', 'account': 'cash', 'source': 'cashback', 'amount': '${kzt(700)}'});
    applyLedgerCommand(l, {'type': 'reverse', 'txId': 'i5', 'id': 'x5'});
    final from = DateTime(2026, 10, 1), to = DateTime(2026, 11, 1);
    final m = l.incomeByCategory(from, to);
    expect(m['income:salary'], kzt(300000), reason: 'сентябрьская зарплата не попала в октябрь');
    expect(m['income:side'], kzt(9500), reason: 'подработка с двух счетов складывается');
    expect(m['income:cashback'] ?? 0, 0, reason: 'отменённый доход сокращается до нуля');
    expect(m.keys.where((k) => !k.startsWith('income:')), isEmpty, reason: 'займ и перевод не доход');
    expect(m.values.fold(0, (a, b) => a + b), l.report(from, to).earned);
  });
}
