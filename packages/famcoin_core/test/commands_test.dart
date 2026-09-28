/// Команды и сериализация: одинаковый результат в приложении и на сервере.
library;

import 'dart:convert';

import 'package:famcoin_core/famcoin_core.dart';
import 'package:test/test.dart';

void main() {
  List<Map<String, dynamic>> commands() => [
        {'type': 'addMoneyAccount', 'accountId': 'kaspi'},
        {'type': 'opening', 'id': 'o1', 'date': '2026-09-01', 'account': 'kaspi', 'amount': '10000000'},
        {'type': 'expense', 'id': 'e1', 'date': '2026-09-02', 'account': 'kaspi', 'splits': {'food': '600000', 'household': '400000'}, 'meta': {'who': 'shared'}},
        {'type': 'lendOut', 'id': 'l1', 'date': '2026-09-03', 'account': 'kaspi', 'person': 'Асхат', 'amount': '3000000'},
        {'type': 'openingDebt', 'id': 'd1', 'date': '2026-09-01', 'debtId': 'red', 'amount': '20000000'},
        {'type': 'loanPayment', 'id': 'p1', 'date': '2026-09-05', 'account': 'kaspi', 'debtId': 'red', 'principal': '4000000', 'interest': '1200000'},
        {'type': 'reserve', 'goalId': 'trip', 'accountId': 'kaspi', 'amount': '500000'},
        {'type': 'reverse', 'txId': 'e1', 'id': 'e1-rev'},
      ];

  test('команды применяются и журнал восстанавливается из JSON без потерь', () {
    final l = Ledger();
    for (final c in commands()) {
      applyLedgerCommand(l, c);
    }
    expect(l.balance('kaspi'), kzt(100000 - 30000 - 52000));
    expect(l.isReversed('e1'), isTrue);
    expect(l.reserved(goalId: 'trip'), kzt(5000));

    // Через JSON, как по сети.
    final snapshot = jsonDecode(jsonEncode({
      'accounts': [for (final a in l.accounts) accountToJson(a)],
      'transactions': [for (final t in l.transactions) transactionToJson(t)],
      'reservations': reservationsToJson(l),
    })) as Map<String, dynamic>;
    final restored = ledgerFromSnapshot(
      accounts: (snapshot['accounts'] as List).cast(),
      transactions: (snapshot['transactions'] as List).cast(),
      reservations: (snapshot['reservations'] as List).cast(),
    );
    expect(restored.balance('kaspi'), l.balance('kaspi'));
    expect(restored.netWorth().capital, l.netWorth().capital);
    expect(restored.isReversed('e1'), isTrue);
    expect(restored.freeLiquid(), l.freeLiquid());
    expect(restored.transactions.length, l.transactions.length);
  });

  test('операция с несуществующего или не денежного счёта отклоняется', () {
    final l = Ledger();
    for (final c in commands().take(4)) {
      applyLedgerCommand(l, c);
    }
    expect(
      () => applyLedgerCommand(l, {'type': 'expense', 'id': 'x', 'date': '2026-09-04', 'account': 'receivable:Асхат', 'splits': {'food': '100'}}),
      throwsA(isA<LedgerException>()),
    );
    expect(
      () => applyLedgerCommand(l, {'type': 'expense', 'id': 'x', 'date': '2026-09-04', 'account': 'nope', 'splits': {'food': '100'}}),
      throwsA(isA<LedgerException>()),
    );
  });

  test('операция с архивного счёта отклоняется, история остаётся', () {
    final l = Ledger();
    for (final c in commands().take(2)) {
      applyLedgerCommand(l, c);
    }
    applyLedgerCommand(l, {'type': 'archiveAccount', 'accountId': 'kaspi'});
    expect(l.balance('kaspi'), kzt(100000));
    expect(
      () => applyLedgerCommand(l, {'type': 'expense', 'id': 'x', 'date': '2026-09-04', 'account': 'kaspi', 'splits': {'food': '100'}}),
      throwsA(isA<LedgerException>()),
    );
  });

  test('некорректные данные — ошибка учёта, а не падение', () {
    final l = Ledger()..addMoneyAccount('kaspi');
    for (final bad in [
      {'type': 'expense', 'id': 'x', 'date': '2026-02-30', 'account': 'kaspi', 'splits': {'food': '100'}},
      {'type': 'expense', 'id': 'x', 'date': '2026-09-01', 'account': 'kaspi', 'splits': {'food': 'abc'}},
      {'type': 'expense', 'id': 'x', 'date': '2026-09-01', 'account': 'kaspi', 'splits': {'food': '-100'}},
      {'type': 'income', 'id': 'x', 'date': '2026-09-01', 'account': 'kaspi', 'source': 'salary', 'amount': '99999999999999999'},
      {'type': 'expense', 'id': 'x', 'date': '2026-09-01', 'account': 'kaspi', 'splits': {'food': '500', 'other': '-100'}},
      {'type': 'unknown'},
      {'type': 'expense', 'date': '2026-09-01', 'account': 'kaspi', 'splits': {'food': '100'}},
    ]) {
      expect(() => applyLedgerCommand(l, bad), throwsA(isA<LedgerException>()), reason: '$bad');
    }
    expect(l.transactions, isEmpty);
  });

  test('корректировка остатка: капитал меняется, доход и расход — нет, причина обязательна', () {
    final l = Ledger();
    applyLedgerCommand(l, {'type': 'addMoneyAccount', 'accountId': 'cash'});
    applyLedgerCommand(l, {'type': 'opening', 'id': 'o', 'date': '2026-09-01', 'account': 'cash', 'amount': '5000000'});
    applyLedgerCommand(l, {'type': 'adjustment', 'id': 'adj', 'date': '2026-09-10', 'account': 'cash', 'delta': '-150000', 'reason': 'Пересчитал наличные'});
    expect(l.balance('cash'), kzt(48500));
    final r = l.report(DateTime(2026, 9, 1), DateTime(2026, 10, 1));
    expect(r.income, 0);
    expect(r.expense, 0);
    expect(l.adjustmentsFor(DateTime(2026, 9, 1), DateTime(2026, 10, 1)), -kzt(1500));
    expect(l.netWorth().capital, kzt(48500));
    expect(l.byId('adj')!.meta['reason'], 'Пересчитал наличные');
    expect(
      () => applyLedgerCommand(l, {'type': 'adjustment', 'id': 'x', 'date': '2026-09-10', 'account': 'cash', 'delta': '100', 'reason': ''}),
      throwsA(isA<LedgerException>()),
    );
  });
}
