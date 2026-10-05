import 'package:famcoin_core/famcoin_core.dart';
import 'package:famcoin_server/briefs.dart';
import 'package:test/test.dart';

BriefInput _input(DateTime today, List<Map<String, dynamic>> planned) {
  final l = Ledger();
  applyLedgerCommand(l, {'type': 'addMoneyAccount', 'accountId': 'card'});
  applyLedgerCommand(l, {'type': 'opening', 'id': 'o', 'date': '2026-09-01', 'account': 'card', 'amount': '${kzt(100000)}'});
  return BriefInput(ledger: l, today: today, profile: const {}, planned: planned, limits: const [], locale: 'ru');
}

void main() {
  const rent = {'name': 'Аренда', 'amount': '15000000', 'day': 31, 'category': 'home', 'paid': <String>[]};
  const tyres = {'name': 'Колёса', 'amount': '10000000', 'day': 31, 'category': 'transport', 'paid': <String>[], 'once': '2027-03'};

  test('утренняя сводка: разовая покупка напоминает о себе только в своём месяце', () {
    // 31 октября: ежемесячный платёж к оплате, покупка на март — нет.
    final october = morningBrief(_input(DateTime(2026, 10, 31), [rent, tyres])).body;
    expect(october, contains('Аренда'));
    expect(october, isNot(contains('Колёса')));

    // 29 марта: покупка — «в ближайшие 3 дня», 31-го — «сегодня к оплате».
    expect(morningBrief(_input(DateTime(2027, 3, 29), [tyres])).body, contains('В ближайшие 3 дня: Колёса (31.03)'));
    final march = morningBrief(_input(DateTime(2027, 3, 31), [rent, tyres])).body;
    expect(march, allOf(contains('Сегодня к оплате:'), contains('Колёса — 100 000 ₸'), contains('Аренда — 150 000 ₸')));

    // Куплена — больше не напоминает; в апреле её тоже нет.
    final bought = {...tyres, 'paid': ['2027-03']};
    expect(morningBrief(_input(DateTime(2027, 3, 31), [bought])).body, isNot(contains('Колёса')));
    expect(morningBrief(_input(DateTime(2027, 4, 30), [tyres])).body, isNot(contains('Колёса')));
  });

  test('утренняя сводка заканчивается советом дня (D97): на языке владельца, назавтра другой', () {
    final today = DateTime(2026, 10, 3);
    final ru = morningBrief(_input(today, const [])).body.split('\n').last;
    expect(ru, '💡 Совет: ${moneyTipOfDay(today).ru}');
    expect(morningBrief(_input(today.add(const Duration(days: 1)), const [])).body.split('\n').last, isNot(ru));

    final kkInput = BriefInput(ledger: Ledger(), today: today, profile: const {}, planned: const [], limits: const [], locale: 'kk');
    expect(morningBrief(kkInput).body.split('\n').last, '💡 Кеңес: ${moneyTipOfDay(today).kk}');
    // Вечерний отчёт без совета — один в день достаточно.
    expect(eveningBrief(_input(today, const [])).body, isNot(contains('💡')));
  });

  test('вечерний отчёт: платёж по кредиту отдельно от расходов', () {
    final l = Ledger();
    applyLedgerCommand(l, {'type': 'addMoneyAccount', 'accountId': 'card'});
    applyLedgerCommand(l, {'type': 'opening', 'id': 'o', 'date': '2026-10-01', 'account': 'card', 'amount': '${kzt(300000)}'});
    applyLedgerCommand(l, {'type': 'openingDebt', 'id': 'd', 'date': '2026-10-01', 'debtId': 'red', 'amount': '${kzt(500000)}'});
    applyLedgerCommand(l, {'type': 'loanPayment', 'id': 'p1', 'date': '2026-10-02', 'account': 'card', 'debtId': 'red', 'principal': '${kzt(40000)}', 'interest': '${kzt(12000)}'});
    applyLedgerCommand(l, {'type': 'expense', 'id': 'e1', 'date': '2026-10-02', 'account': 'card', 'splits': {'food': '${kzt(2180)}'}});
    final body = eveningBrief(BriefInput(ledger: l, today: DateTime(2026, 10, 2), profile: const {}, planned: const [], limits: const [], locale: 'ru')).body;
    expect(body, contains('Сегодня потрачено: <b>14 180 ₸</b>'));
    expect(body, contains('С начала месяца: доходы 0 ₸, расходы 14 180 ₸.'));
    expect(body, contains('С начала месяца погашено долгов: 40 000 ₸.'));

    final nudge = monthNudge(month: DateTime(2026, 10, 1), income: 0, expense: l.report(DateTime(2026, 10, 1), DateTime(2026, 11, 1)).total, locale: 'ru');
    expect(nudge.body, contains('расходы 14 180 ₸'));
  });

  test('вечерний отчёт называет категории словами, а не кодами', () {
    final l = Ledger();
    applyLedgerCommand(l, {'type': 'addMoneyAccount', 'accountId': 'card'});
    applyLedgerCommand(l, {'type': 'opening', 'id': 'o', 'date': '2026-10-01', 'account': 'card', 'amount': '${kzt(100000)}'});
    applyLedgerCommand(l, {'type': 'expense', 'id': 'e1', 'date': '2026-10-02', 'account': 'card', 'splits': {'food': '${kzt(2180)}', 'c569095a1a770': '${kzt(1300)}'}});
    final input = BriefInput(
      ledger: l,
      today: DateTime(2026, 10, 2),
      profile: const {},
      planned: const [],
      limits: [{'category': 'food', 'amount': '${kzt(2000)}'}],
      locale: 'ru',
      categories: const {'c569095a1a770': {'name': 'Собака'}},
    );
    final body = eveningBrief(input).body;
    expect(body, allOf(contains('• Продукты: 2 180 ₸'), contains('• Собака: 1 300 ₸'), contains('Лимит «Продукты» превышен')));
    expect(body, isNot(contains('food')));
    expect(eveningBrief(BriefInput(ledger: l, today: DateTime(2026, 10, 2), profile: const {}, planned: const [], limits: const [], locale: 'kk')).body, contains('Азық-түлік'));
  });
}
