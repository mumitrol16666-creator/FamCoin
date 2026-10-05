import 'package:famcoin_core/famcoin_core.dart';
import 'package:test/test.dart';

void main() {
  final september = DateTime(2026, 9),
      october = DateTime(2026, 10),
      november = DateTime(2026, 11);
  Ledger base() => Ledger()
    ..addMoneyAccount('cash')
    ..openingBalance(
      id: 'opening',
      date: september,
      account: 'cash',
      amount: kzt(100000),
    );

  test('заём, покупка и возврат в другом месяце: расход один раз, капитал не меняется от возврата', () {
    final l = base();
    applyLedgerCommand(l, {
      'type': 'borrow',
      'id': 'borrow',
      'date': '2026-09-02',
      'account': 'cash',
      'person': 'Друг',
      'amount': '${kzt(20000)}',
    });
    expect(l.netWorth().capital, kzt(100000));
    l.expense(
      id: 'purchase',
      date: september,
      account: 'cash',
      splits: {'food': kzt(20000)},
    );
    expect(l.report(september, october).income, 0);
    expect(l.report(september, october).expense, kzt(20000));
    expect(l.report(september, october).cashFlow, 0);
    expect(l.netWorth().capital, kzt(80000));
    applyLedgerCommand(l, {
      'type': 'repaymentMade',
      'id': 'repay',
      'date': '2026-10-02',
      'account': 'cash',
      'person': 'Друг',
      'principal': '${kzt(20000)}',
    });
    expect(l.report(october, november).expense, 0);
    expect(l.report(october, november).debtPayments, kzt(20000));
    expect(l.report(october, november).cashFlow, -kzt(20000));
    expect(
      l.report(september, november).result,
      -kzt(20000),
      reason: 'закрытие долга не выравнивает доходы и расходы',
    );
    expect(l.netWorth().capital, kzt(80000));
  });

  test('выдача и возврат займа: основной долг не доход и не расход, проценты — доход', () {
    final l = base();
    applyLedgerCommand(l, {
      'type': 'lendOut',
      'id': 'lend',
      'date': '2026-09-02',
      'account': 'cash',
      'person': 'Друг',
      'amount': '${kzt(20000)}',
    });
    expect(l.netWorth().money, kzt(80000));
    expect(l.netWorth().receivables, kzt(20000));
    expect(l.netWorth().capital, kzt(100000));
    expect(l.report(september, october).expense, 0);
    applyLedgerCommand(l, {
      'type': 'repaymentReceived',
      'id': 'return',
      'date': '2026-10-02',
      'account': 'cash',
      'person': 'Друг',
      'principal': '${kzt(20000)}',
      'interest': '${kzt(1000)}',
    });
    expect(l.report(october, november).income, kzt(1000));
    expect(l.report(october, november).cashFlow, kzt(21000));
    expect(l.netWorth().capital, kzt(101000));
  });

  test('старое подтверждение сверки сохраняется при смене отчёта, новая покупка обнаруживается', () {
    final l = base();
    applyLedgerCommand(l, {
      'type': 'borrow',
      'id': 'b',
      'date': '2026-09-02',
      'account': 'cash',
      'person': 'Друг',
      'amount': '${kzt(20000)}',
    });
    applyLedgerCommand(l, {
      'type': 'repaymentMade',
      'id': 'r',
      'date': '2026-09-03',
      'account': 'cash',
      'person': 'Друг',
      'principal': '${kzt(5000)}',
    });
    // Реальный формат снимка до изменения правил отчёта, без поля version.
    final saved = <String, dynamic>{
      'asOf': '2026-09-30',
      'balances': {'cash': '${kzt(115000)}'},
      'income': '${kzt(20000)}',
      'expense': '${kzt(5000)}',
      'cashFlow': '${kzt(15000)}',
      'transactionCount': 3,
    };
    expect(
      reconciliationChanges(
        saved,
        reconciliationSnapshot(
          l,
          september,
          version: reconciliationVersion(saved),
        ),
      ).isEmpty,
      isTrue,
    );
    final fresh = reconciliationSnapshot(l, september);
    expect(fresh['version'], 2);
    expect(fresh['income'], '0');
    expect(fresh['expense'], '0');
    l.expense(
      id: 'late',
      date: september,
      account: 'cash',
      splits: {'cafe': kzt(1000)},
    );
    for (final snapshot in [saved, fresh]) {
      final diff = reconciliationChanges(
        snapshot,
        reconciliationSnapshot(
          l,
          september,
          version: reconciliationVersion(snapshot),
        ),
      );
      expect(diff.balances['cash'], (before: kzt(115000), after: kzt(114000)));
      expect(
        diff.totals['expense']!.after - diff.totals['expense']!.before,
        kzt(1000),
      );
    }
  });

  test('старые сверки исключали погашения записанных рассрочек, новые отдельно показывают все погашения', () {
    final l = base();
    applyLedgerCommand(l, {
      'type': 'creditPurchase',
      'id': 'purchase',
      'date': '2026-09-02',
      'debtId': 'installment',
      'splits': {'clothes': '${kzt(30000)}'},
    });
    applyLedgerCommand(l, {
      'type': 'loanPayment',
      'id': 'pay',
      'date': '2026-09-03',
      'account': 'cash',
      'debtId': 'installment',
      'principal': '${kzt(10000)}',
    });
    expect(l.report(september, october).debtPayments, kzt(10000));
    expect(
      reconciliationSnapshot(l, september, version: 1)['expense'],
      '${kzt(30000)}',
    );
    expect(reconciliationSnapshot(l, september)['expense'], '${kzt(30000)}');
  });
}
