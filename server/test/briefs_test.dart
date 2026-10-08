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
  test('FV-C04: brief does not reserve the same remaining installment for a later period', () {
    final ledger = Ledger()..openingDebt(id: 'opening', date: DateTime(2026, 7, 1), debtId: 'red', amount: kzt(10000));
    final input = BriefInput(ledger: ledger, today: DateTime(2026, 9, 30), profile: {}, limits: [], locale: 'ru',
      debts: {'red': {'kind': 'installment', 'rate': 0}},
      planned: [{'id':'red-pay','name':'Рассрочка','amount':'5000000','day':30,'debtId':'red','start':'2026-07-01','paid':<String>[]}]);
    // Весь остаток распределён на июльский просроченный срок, повторного
    // требования тех же денег за сентябрь в утренней сводке быть не должно.
    expect(morningBrief(input).body, isNot(contains('Рассрочка —')));
  });

  personDueBriefTests();
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

  test('утренняя сводка: недельный платёж напоминает в свой день недели, годовой — в свой день года', () {
    // 2026-10-07 — среда; репетитор по средам, страховка 7 октября раз в год.
    const tutor = {'name': 'Репетитор', 'amount': '500000', 'day': 1, 'every': 'week', 'weekday': 3, 'category': 'education', 'paid': <String>[]};
    const insurance = {'name': 'Страховка', 'amount': '12000000', 'day': 7, 'every': 'year', 'monthOfYear': 10, 'category': 'other', 'paid': <String>[]};
    final wed = morningBrief(_input(DateTime(2026, 10, 7), [tutor, insurance])).body;
    expect(wed, allOf(contains('Сегодня к оплате:'), contains('Репетитор — 5 000 ₸'), contains('Страховка — 120 000 ₸')));
    // Во вторник — «завтра» репетитор, страховка ещё впереди.
    final tue = morningBrief(_input(DateTime(2026, 10, 6), [tutor, insurance])).body;
    expect(tue, contains('Репетитор'));
    // Отмечена оплатой этой недели (ключ — дата срока) и этого года — не напоминает.
    final paidTutor = {...tutor, 'paid': ['2026-10-07']};
    final paidInsurance = {...insurance, 'paid': ['2026']};
    final done = morningBrief(_input(DateTime(2026, 10, 7), [paidTutor, paidInsurance])).body;
    expect(done, isNot(contains('Репетитор')));
    expect(done, isNot(contains('Страховка')));
  });

  test('R04: погашенная рассрочка не требует оплаты в утренней сводке; активная — требует', () {
    final l = Ledger();
    applyLedgerCommand(l, {'type': 'addMoneyAccount', 'accountId': 'card'});
    applyLedgerCommand(l, {'type': 'opening', 'id': 'o', 'date': '2026-09-01', 'account': 'card', 'amount': '${kzt(100000)}'});
    applyLedgerCommand(l, {'type': 'openingDebt', 'id': 'd', 'date': '2026-09-01', 'debtId': 'phone', 'amount': '${kzt(50000)}'});
    const installment = {'name': 'Рассрочка', 'amount': '1000000', 'day': 5, 'category': 'other', 'paid': <String>[], 'debtId': 'phone'};
    BriefInput input() => BriefInput(ledger: l, today: DateTime(2026, 10, 5), profile: const {}, planned: const [installment], limits: const [], locale: 'ru');
    expect(morningBrief(input()).body, contains('Рассрочка'), reason: 'долг ещё есть');
    applyLedgerCommand(l, {'type': 'loanPayment', 'id': 'p', 'date': '2026-09-20', 'account': 'card', 'debtId': 'phone', 'principal': '${kzt(50000)}'});
    expect(morningBrief(input()).body, isNot(contains('Рассрочка')), reason: 'долг погашен');
    expect(eveningBrief(input()).body, isNot(contains('Рассрочка')));
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

void personDueBriefTests() {
  test('D133: срок возврата личного долга напоминает с остатком долга, а после возврата замолкает', () {
    final l = Ledger();
    applyLedgerCommand(l, {'type': 'addMoneyAccount', 'accountId': 'card'});
    applyLedgerCommand(l, {'type': 'opening', 'id': 'o', 'date': '2026-09-01', 'account': 'card', 'amount': '${kzt(100000)}'});
    applyLedgerCommand(l, {'type': 'borrow', 'id': 'b', 'date': '2026-10-02', 'account': 'card', 'person': 'Теща', 'amount': '${kzt(80000)}'});
    const due = {'name': 'Теща', 'amount': '8000000', 'day': 1, 'category': 'other', 'paid': <String>[], 'person': 'Теща', 'onDate': '2026-10-20'};
    BriefInput input(DateTime day) => BriefInput(ledger: l, today: day, profile: const {}, planned: const [due], limits: const [], locale: 'ru');
    final body = morningBrief(input(DateTime(2026, 10, 20))).body;
    expect(body, allOf(contains('Долг: Теща'), contains('80 000 ₸')));
    // Часть вернули — в напоминании остаток.
    applyLedgerCommand(l, {'type': 'repaymentMade', 'id': 'r', 'date': '2026-10-10', 'account': 'card', 'person': 'Теща', 'principal': '${kzt(30000)}'});
    expect(morningBrief(input(DateTime(2026, 10, 20))).body, contains('50 000 ₸'));
    // Вернули всё — напоминания нет.
    applyLedgerCommand(l, {'type': 'repaymentMade', 'id': 'r2', 'date': '2026-10-12', 'account': 'card', 'person': 'Теща', 'principal': '${kzt(50000)}'});
    expect(morningBrief(input(DateTime(2026, 10, 20))).body, isNot(contains('Теща')));
  });

  test('N01: части к сроку вычитаются так же, как в приложении — по общему расчёту ядра', () {
    final l = Ledger();
    applyLedgerCommand(l, {'type': 'addMoneyAccount', 'accountId': 'card'});
    applyLedgerCommand(l, {'type': 'opening', 'id': 'o', 'date': '2026-09-01', 'account': 'card', 'amount': '${kzt(200000)}'});
    // Договорились вернуть 80 000 к 20.10, потом заняли ещё 20 000 без срока.
    applyLedgerCommand(l, {'type': 'borrow', 'id': 'b', 'date': '2026-10-02', 'account': 'card', 'person': 'Брат', 'amount': '${kzt(80000)}'});
    applyLedgerCommand(l, {'type': 'borrow', 'id': 'b2', 'date': '2026-10-03', 'account': 'card', 'person': 'Брат', 'amount': '${kzt(20000)}'});
    const due = {'id': 'pd:1', 'name': 'Брат', 'amount': '8000000', 'day': 1, 'category': 'other', 'paid': <String>[], 'person': 'Брат', 'onDate': '2026-10-20'};
    BriefInput input() => BriefInput(ledger: l, today: DateTime(2026, 10, 20), profile: const {}, planned: const [due], limits: const [], locale: 'ru');
    applyLedgerCommand(l, {
      'type': 'repaymentMade', 'id': 'p1', 'date': '2026-10-10', 'account': 'card', 'person': 'Брат', 'principal': '${kzt(30000)}',
      'meta': {'planned': 'pd:1', 'period': '2026-10-20', 'part': true},
    });
    expect(morningBrief(input()).body, allOf(contains('Долг: Брат'), contains('50 000 ₸')), reason: 'к сроку осталось 80 000 − 30 000, хотя долг 70 000');
    applyLedgerCommand(l, {
      'type': 'repaymentMade', 'id': 'p2', 'date': '2026-10-11', 'account': 'card', 'person': 'Брат', 'principal': '${kzt(50000)}',
      'meta': {'planned': 'pd:1', 'period': '2026-10-20', 'part': true},
    });
    expect(morningBrief(input()).body, isNot(contains('Брат')), reason: 'договорённость исполнена частями, долг 20 000 без срока');
  });

  test('CS03: последний платёж рассрочки в сводке — остаток, как в приложении (RU/KK); кредит — остаток плюс проценты месяца', () {
    Ledger debtOf(int balance) {
      final l = Ledger();
      applyLedgerCommand(l, {'type': 'addMoneyAccount', 'accountId': 'card'});
      applyLedgerCommand(l, {'type': 'opening', 'id': 'o', 'date': '2026-09-01', 'account': 'card', 'amount': '${kzt(100000)}'});
      applyLedgerCommand(l, {'type': 'openingDebt', 'id': 'd', 'date': '2026-09-01', 'debtId': 'red', 'amount': '${kzt(balance)}'});
      return l;
    }
    final phone = {'id': 'pl', 'name': 'Телефон', 'amount': '${kzt(50000)}', 'day': 10, 'category': 'other', 'debtId': 'red', 'paid': ['2026-09'], 'start': '2026-09-01'};
    String brief(Ledger l, Map<String, dynamic> debt, String locale) => morningBrief(BriefInput(
          ledger: l, today: DateTime(2026, 10, 10), profile: const {}, planned: [phone], limits: const [], locale: locale,
          debts: {'red': debt},
        )).body;
    for (final locale in ['ru', 'kk']) {
      final body = brief(debtOf(10000), {'name': 'Телефон', 'kind': 'installment', 'rate': 0}, locale);
      expect(body, contains('10 000 ₸'), reason: locale);
      expect(body, isNot(contains('50 000 ₸')), reason: locale);
    }
    // Кредит под 24 %: остаток 10 000 + проценты 200 — проценты из платежа не выпадают.
    expect(brief(debtOf(10000), {'name': 'Телефон', 'kind': 'loan', 'rate': 24}, 'ru'), contains('10 200 ₸'));
    // Обычный месяц — обычный платёж.
    expect(brief(debtOf(300000), {'name': 'Телефон', 'kind': 'loan', 'rate': 24}, 'ru'), contains('50 000 ₸'));
  });
}
