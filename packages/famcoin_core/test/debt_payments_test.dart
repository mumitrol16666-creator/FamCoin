import 'package:famcoin_core/famcoin_core.dart';
import 'package:test/test.dart';

Ledger _base() {
  final l = Ledger();
  applyLedgerCommand(l, {'type': 'addMoneyAccount', 'accountId': 'kaspi'});
  applyLedgerCommand(l, {'type': 'opening', 'id': 'o', 'date': '2026-09-01', 'account': 'kaspi', 'amount': '${kzt(300000)}'});
  return l;
}

void main() {
  final from = DateTime(2026, 9, 1), to = DateTime(2026, 10, 1);

  test('платёж по кредиту: тело — в «кредиты и долги», проценты — расход, вместе — «всего ушло» (D98)', () {
    final l = _base();
    applyLedgerCommand(l, {'type': 'openingDebt', 'id': 'd', 'date': '2026-09-01', 'debtId': 'red', 'amount': '${kzt(500000)}'});
    applyLedgerCommand(l, {'type': 'loanPayment', 'id': 'p1', 'date': '2026-09-05', 'account': 'kaspi', 'debtId': 'red', 'principal': '${kzt(40000)}', 'interest': '${kzt(12000)}'});
    applyLedgerCommand(l, {'type': 'expense', 'id': 'e1', 'date': '2026-09-06', 'account': 'kaspi', 'splits': {'food': '${kzt(5000)}'}});
    final r = l.report(from, to);
    expect(r.expense, kzt(17000), reason: 'проценты и продукты');
    expect(r.debtPayments, kzt(40000));
    expect(r.total, kzt(57000));
    expect(r.result, -kzt(57000));
    expect(l.debtPaymentsIn(from, to).map((t) => t.id), ['p1']);
    // Долг стал меньше на тело платежа — учёт долгов не изменился.
    expect(l.balance(liabilityAccount('red')), kzt(460000));

    // Отменённый платёж не считается; в другом месяце его тоже нет.
    applyLedgerCommand(l, {'type': 'reverse', 'txId': 'p1', 'id': 'rv'});
    expect(l.report(from, to).debtPayments, 0);
  });

  test('взятое в долг деньгами — в доходах месяца с подписью «в т.ч. взято в долг», в заработанное не входит; старый долг без движения по счёту не считается (D102, D105)', () {
    final l = _base();
    applyLedgerCommand(l, {'type': 'borrow', 'id': 'b1', 'date': '2026-09-03', 'account': 'kaspi', 'person': 'Вадим', 'amount': '${kzt(50000)}'});
    applyLedgerCommand(l, {'type': 'openingDebt', 'id': 'd', 'date': '2026-09-04', 'debtId': 'Яков', 'amount': '${kzt(20000)}'});
    applyLedgerCommand(l, {'type': 'borrow', 'id': 'b2', 'date': '2026-09-05', 'account': 'kaspi', 'person': 'Олег', 'amount': '${kzt(1000)}'});
    applyLedgerCommand(l, {'type': 'reverse', 'txId': 'b2', 'id': 'x2'});
    final r = l.report(from, to);
    expect(r.borrowed, kzt(50000));
    expect(r.earned, 0, reason: 'заработанного нет');
    expect(r.income, kzt(50000), reason: 'деньги пришли — в доходах месяца (D105)');
    expect(r.result, kzt(50000));
    expect(l.balance('kaspi'), kzt(350000), reason: 'старый долг остаток счёта не менял');
    expect(l.report(DateTime(2026, 10, 1), DateTime(2026, 11, 1)).debtPayments, 0);
  });

  test('покупка в рассрочку записана расходом — платежи по ней второй раз не считаются', () {
    final l = _base();
    applyLedgerCommand(l, {'type': 'creditPurchase', 'id': 'c1', 'date': '2026-09-02', 'debtId': 'inst', 'splits': {'clothes': '${kzt(60000)}'}});
    applyLedgerCommand(l, {'type': 'loanPayment', 'id': 'p1', 'date': '2026-09-20', 'account': 'kaspi', 'debtId': 'inst', 'principal': '${kzt(10000)}'});
    final r = l.report(from, to);
    expect(r.expense, kzt(60000));
    expect(r.debtPayments, 0);
    expect(r.total, kzt(60000));
  });

  test('возврат личного долга тоже «ушло», а деньги, взятые в долг, — пришло: месяц сходится в ноль', () {
    final l = _base();
    applyLedgerCommand(l, {'type': 'borrow', 'id': 'b', 'date': '2026-09-03', 'account': 'kaspi', 'person': 'Асхат', 'amount': '${kzt(20000)}'});
    applyLedgerCommand(l, {'type': 'repaymentMade', 'id': 'r1', 'date': '2026-09-25', 'account': 'kaspi', 'person': 'Асхат', 'principal': '${kzt(20000)}'});
    final r = l.report(from, to);
    expect(r.earned, 0);
    expect(r.income, kzt(20000), reason: 'взял 20 000 — доход месяца (D105)');
    expect(r.debtPayments, kzt(20000));
    expect(r.result, 0, reason: 'взял и вернул — месяц в ноль, без «кассового разрыва»');
    expect(expenseTypeOf('debts'), ExpenseType.mandatory);
  });
}
