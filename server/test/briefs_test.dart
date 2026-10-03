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
