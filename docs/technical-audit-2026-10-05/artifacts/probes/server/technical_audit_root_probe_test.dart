// Diagnostic assertions describe the observed baseline, not desired behaviour.
import 'package:famcoin_core/famcoin_core.dart';
import 'package:famcoin_server/briefs.dart';
import 'package:test/test.dart';

void main() {
  test('ROOT-04 brief still demands a payment for fully repaid debt', () {
    final l = Ledger();
    for (final c in <Map<String, dynamic>>[
      {'type': 'addMoneyAccount', 'accountId': 'cash'},
      {'type': 'opening', 'id': 'o', 'date': '2026-09-01', 'account': 'cash', 'amount': '${kzt(100000)}'},
      {'type': 'openingDebt', 'id': 'debt', 'date': '2026-09-01', 'debtId': 'installment', 'amount': '${kzt(50000)}'},
      {'type': 'loanPayment', 'id': 'paid', 'date': '2026-09-28', 'account': 'cash', 'debtId': 'installment', 'principal': '${kzt(50000)}'},
    ]) { applyLedgerCommand(l, c); }
    expect(l.balance('liability:installment'), 0);
    final body = morningBrief(BriefInput(ledger: l, today: DateTime(2026, 10, 5), profile: const {}, limits: const [], locale: 'ru', planned: [
      {'name': 'Рассрочка', 'debtId': 'installment', 'amount': '${kzt(10000)}', 'day': 5, 'category': 'other', 'start': '2026-09-01', 'paid': ['2026-09']}
    ])).body;
    expect(body, contains('Сегодня к оплате:'));
    expect(body, contains('Рассрочка — 10 000 ₸'));
    print('ROOT-04 server: zero debt, but morning brief asks 10000 KZT payment.');
  });
}
