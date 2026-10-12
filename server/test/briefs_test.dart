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
    // Весь остаток распределён на июльский просроченный срок (D167: он виден
    // как просрочка), повторного требования тех же денег за сентябрь нет.
    final body = morningBrief(input).body;
    expect('Рассрочка —'.allMatches(body).length, 1);
    expect(body, contains('• Рассрочка — 10 000 ₸ (срок 30.07)'));
    expect(body, isNot(contains('Сегодня к оплате')));
  });

  personDueBriefTests();
  main167();
  const rent = {'name': 'Аренда', 'amount': '15000000', 'day': 31, 'category': 'home', 'paid': <String>[]};
  const tyres = {'name': 'Колёса', 'amount': '10000000', 'day': 31, 'category': 'transport', 'paid': <String>[], 'once': '2027-03'};

  test('утренняя сводка: разовая покупка напоминает о себе только в своём месяце', () {
    // 31 октября: ежемесячный платёж к оплате, покупка на март — нет.
    final october = morningBrief(_input(DateTime(2026, 10, 31), [rent, tyres])).body;
    expect(october, contains('Аренда'));
    expect(october, isNot(contains('Колёса')));

    // 29 марта: покупка — «в ближайшие 14 дней», 31-го — «сегодня к оплате».
    expect(morningBrief(_input(DateTime(2027, 3, 29), [tyres])).body, allOf(contains('В ближайшие 14 дней:'), contains('• Колёса — 100 000 ₸ (31.03)')));
    final march = morningBrief(_input(DateTime(2027, 3, 31), [rent, tyres])).body;
    expect(march, allOf(contains('Сегодня к оплате:'), contains('Колёса — 100 000 ₸'), contains('Аренда — 150 000 ₸')));

    // Куплена — больше не напоминает; не куплена — в апреле это просрочка (D167).
    final bought = {...tyres, 'paid': ['2027-03']};
    expect(morningBrief(_input(DateTime(2027, 3, 31), [bought])).body, isNot(contains('Колёса')));
    expect(morningBrief(_input(DateTime(2027, 4, 30), [bought])).body, isNot(contains('Колёса')));
    final april = morningBrief(_input(DateTime(2027, 4, 30), [tyres])).body;
    expect(april, contains('• Колёса — 100 000 ₸ (срок 31.03)'));
    expect(april, isNot(contains('Сегодня к оплате')));
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
    // Отмечена оплатой этой недели (ключ — дата срока) и этого года — сегодня
    // не требует; репетитор остаётся только как следующая среда в ближайших днях.
    final paidTutor = {...tutor, 'paid': ['2026-10-07']};
    final paidInsurance = {...insurance, 'paid': ['2026']};
    final done = morningBrief(_input(DateTime(2026, 10, 7), [paidTutor, paidInsurance])).body;
    expect(done, isNot(contains('Сегодня к оплате')));
    expect(done, contains('• Репетитор — 5 000 ₸ (14.10)'));
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
    expect(eveningBrief(input())?.body, isNot(contains('Рассрочка')));
  });

  test('утренняя сводка заканчивается советом дня (D97): на языке владельца, назавтра другой', () {
    final today = DateTime(2026, 10, 3);
    final ru = morningBrief(_input(today, const [])).body.split('\n').last;
    expect(ru, '💡 Совет: ${moneyTipOfDay(today).ru}');
    expect(morningBrief(_input(today.add(const Duration(days: 1)), const [])).body.split('\n').last, isNot(ru));

    final kkInput = BriefInput(ledger: Ledger(), today: today, profile: const {}, planned: const [], limits: const [], locale: 'kk');
    expect(morningBrief(kkInput).body.split('\n').last, '💡 Кеңес: ${moneyTipOfDay(today).kk}');
    // Вечерний отчёт без совета — один в день достаточно.
    expect(eveningBrief(_input(today, const []))?.body, isNot(contains('💡')));
  });

  test('вечерний отчёт: платёж по кредиту отдельно от расходов', () {
    final l = Ledger();
    applyLedgerCommand(l, {'type': 'addMoneyAccount', 'accountId': 'card'});
    applyLedgerCommand(l, {'type': 'opening', 'id': 'o', 'date': '2026-10-01', 'account': 'card', 'amount': '${kzt(300000)}'});
    applyLedgerCommand(l, {'type': 'openingDebt', 'id': 'd', 'date': '2026-10-01', 'debtId': 'red', 'amount': '${kzt(500000)}'});
    applyLedgerCommand(l, {'type': 'loanPayment', 'id': 'p1', 'date': '2026-10-02', 'account': 'card', 'debtId': 'red', 'principal': '${kzt(40000)}', 'interest': '${kzt(12000)}'});
    applyLedgerCommand(l, {'type': 'expense', 'id': 'e1', 'date': '2026-10-02', 'account': 'card', 'splits': {'food': '${kzt(2180)}'}});
    final body = eveningBrief(BriefInput(ledger: l, today: DateTime(2026, 10, 2), profile: const {}, planned: const [], limits: const [], locale: 'ru'))!.body;
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
    final body = eveningBrief(input)!.body;
    expect(body, allOf(contains('• Продукты: 2 180 ₸'), contains('• Собака: 1 300 ₸'), contains('Лимит «Продукты» превышен')));
    expect(body, isNot(contains('food')));
    expect(eveningBrief(BriefInput(ledger: l, today: DateTime(2026, 10, 2), profile: const {}, planned: const [], limits: const [], locale: 'kk'))!.body, contains('Азық-түлік'));
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

/// D167: сводки с содержанием — вчера против лимита, просрочка, ближайшие
/// платежи и кассовый разрыв утром; вечером без нулей, лимиты в день
/// превышения, пустой день с кнопками.
void main167() {
  Ledger ledger({int money = 100000}) {
    final l = Ledger();
    applyLedgerCommand(l, {'type': 'addMoneyAccount', 'accountId': 'card'});
    applyLedgerCommand(l, {'type': 'opening', 'id': 'o', 'date': '2026-09-01', 'account': 'card', 'amount': '${kzt(money)}'});
    return l;
  }
  void spend(Ledger l, String id, String date, String cat, int amount, {bool planned = false}) =>
      applyLedgerCommand(l, {'type': 'expense', 'id': id, 'date': date, 'account': 'card', 'splits': {cat: '${kzt(amount)}'}, if (planned) 'meta': {'plannedPurchase': true}});

  group('D167 утро', () {
    test('вчера против дневного лимита: уложились, превысили, без лимита, без записей', () {
      final l = ledger();
      spend(l, 'a', '2026-10-11', 'food', 3000);
      spend(l, 'b', '2026-10-11', 'home', 20000, planned: true); // запланированная — вне лимита
      final limited = BriefInput(ledger: l, today: DateTime(2026, 10, 12), profile: const {'dailyLimit': '500000'}, planned: const [], limits: const [], locale: 'ru');
      expect(morningBrief(limited).body, contains('Вчера: <b>3 000 ₸</b> при лимите 5 000 ₸ — уложились ✅'));
      spend(l, 'c', '2026-10-11', 'cafe', 4000);
      expect(morningBrief(limited).body, contains('Вчера: <b>7 000 ₸</b> при лимите 5 000 ₸ — на 2 000 ₸ больше ⚠'));
      final free = BriefInput(ledger: l, today: DateTime(2026, 10, 12), profile: const {}, planned: const [], limits: const [], locale: 'ru');
      expect(morningBrief(free).body, contains('Вчера потрачено: <b>7 000 ₸</b>.'));
      expect(morningBrief(BriefInput(ledger: l, today: DateTime(2026, 10, 13), profile: const {}, planned: const [], limits: const [], locale: 'ru')).body, contains('Вчера записей не было.'));
      expect(morningBrief(BriefInput(ledger: l, today: DateTime(2026, 10, 14), profile: const {}, planned: const [], limits: const [], locale: 'ru')).body, contains('Записей нет уже 2 дня.'));
      expect(morningBrief(limited).body, contains('Доступно сегодня: 5 000 ₸.'));
      final kk = BriefInput(ledger: l, today: DateTime(2026, 10, 12), profile: const {'dailyLimit': '500000'}, planned: const [], limits: const [], locale: 'kk');
      expect(morningBrief(kk).body, allOf(contains('Кеше: <b>7 000 ₸</b>'), contains('Бүгін қолжетімді: 5 000 ₸.')));
    });

    test('просрочка: один самый свежий срок на платёж, с датой; кассовый разрыв против свободных денег', () {
      const rent = {'id': 'rent', 'name': 'Аренда', 'amount': '15000000', 'day': 1, 'category': 'home', 'paid': <String>[], 'start': '2026-08-01'};
      const net = {'id': 'net', 'name': 'Интернет', 'amount': '500000', 'day': 20, 'category': 'home', 'paid': <String>[], 'start': '2026-08-01'};
      final poor = BriefInput(ledger: ledger(money: 20000), today: DateTime(2026, 10, 12), profile: const {}, planned: const [rent, net], limits: const [], locale: 'ru');
      final body = morningBrief(poor).body;
      expect(body, contains('⚠ Просрочено:'));
      expect('Аренда —'.allMatches(body).length, 1, reason: 'август и сентябрь не оплачены, но в просрочке только последний срок');
      expect(body, contains('• Аренда — 150 000 ₸ (срок 1.10)'));
      expect(body, contains('• Интернет — 5 000 ₸ (срок 20.09)'));
      expect(body, contains('В ближайшие 14 дней:'));
      expect(body, contains('• Интернет — 5 000 ₸ (20.10)'));
      expect(body, isNot(contains('1.11')), reason: 'ноябрьская аренда дальше 14 дней');
      expect(body, contains('❗ Не хватает 140 000 ₸ на платежи до 20.10: к оплате 160 000 ₸, свободно на счетах 20 000 ₸.'));

      final rich = BriefInput(ledger: ledger(money: 500000), today: DateTime(2026, 10, 12), profile: const {}, planned: const [net], limits: const [], locale: 'ru');
      expect(morningBrief(rich).body, contains('На платежи денег хватает ✅'));
      final nothing = BriefInput(ledger: ledger(), today: DateTime(2026, 10, 12), profile: const {}, planned: const [], limits: const [], locale: 'ru');
      expect(morningBrief(nothing).body, isNot(anyOf(contains('хватает'), contains('Просрочено'))));
      final kk = BriefInput(ledger: ledger(money: 20000), today: DateTime(2026, 10, 12), profile: const {}, planned: const [rent, net], limits: const [], locale: 'kk');
      expect(morningBrief(kk).body, allOf(contains('⚠ Мерзімі өткен:'), contains('жетпейді')));
    });
  });

  group('D167 тишина (часть 4)', () {
    BriefInput at(Ledger l, int day, {List<List<Map<String, String>>> buttons = const [], bool month = false}) =>
        BriefInput(ledger: l, today: DateTime(2026, 10, day), profile: const {}, planned: const [], limits: const [], locale: 'ru', quickButtons: buttons, monthRemindersEnabled: month);

    test('серия дней без записей: 2-й и 3-й вечер — сообщение со счётчиком и остатком, 4-й — тишина, 5-й и 7-й — снова, дальше раз в неделю', () {
      final l = ledger();
      spend(l, 'b', '2026-10-09', 'food', 500);
      spend(l, 'a', '2026-10-10', 'food', 1200);
      expect(quietDays(l, DateTime(2026, 10, 12)), 2);
      applyLedgerCommand(l, {'type': 'reverse', 'id': 'r', 'date': '2026-10-11', 'txId': 'a'}); // отмена — не запись
      expect(quietDays(l, DateTime(2026, 10, 12)), 3, reason: 'отменённая запись не считается: 10-е тоже пустое');
      expect(quietDays(Ledger(), DateTime(2026, 10, 12)), 1, reason: 'пустой журнал — один тихий день, не шестьдесят');
      final fresh = ledger();
      expect(quietDays(fresh, DateTime(2026, 9, 1)), 1, reason: 'день начального остатка');
      expect(quietDays(fresh, DateTime(2026, 9, 3)), 3, reason: 'раньше начального остатка не считаем');
      final buttons = [[{'text': 'Кофе · 1 590 ₸', 'callback_data': 'q:1'}]];
      final second = eveningBrief(at(l, 11, buttons: buttons))!;
      expect(second.title, '2 дня без записей');
      expect(second.body, allOf(contains('2 дня без записей, последняя — 9.10. На счетах 99 500 ₸ — сходится?'), contains('Если траты были, одно нажатие:')));
      expect(second.buttons, buttons);
      expect(eveningBrief(at(l, 12))!.title, '3 дня без записей');
      expect(eveningBrief(at(l, 13)), isNull, reason: '4-й день — молчим');
      expect(eveningBrief(at(l, 14))!.title, '5 дней без записей');
      expect(eveningBrief(at(l, 15)), isNull);
      expect(eveningBrief(at(l, 16))!.title, '7 дней без записей');
      expect(eveningBrief(at(l, 20)), isNull);
      expect(eveningBrief(at(l, 23))!.title, '14 дней без записей');
      expect(eveningBrief(at(l, 13), force: true)!.title, '4 дня без записей', reason: 'предпросмотр из приложения строится всегда');
      // Напоминание о сверке важнее тишины: 29.10 — за 3 дня до 1-го.
      expect(eveningBrief(at(l, 29, month: true))!.body, contains('Через 3 дня сверка месяца'));
      // Утро тоже считает серию.
      expect(morningBrief(at(l, 13)).body, contains('Записей нет уже 3 дня.'));
      expect(morningBrief(at(l, 11)).body, contains('Вчера записей не было.'));
    });

    test('первый пустой день остаётся «Сегодня без записей»; день с записью — обычный отчёт', () {
      final l = ledger();
      spend(l, 'a', '2026-10-10', 'food', 1200);
      expect(eveningBrief(at(l, 11))!.title, 'Сегодня без записей');
      expect(eveningBrief(at(l, 10))!.title, 'Вечерний отчёт');
      final kk = eveningBrief(BriefInput(ledger: l, today: DateTime(2026, 10, 12), profile: const {}, planned: const [], limits: const [], locale: 'kk'))!;
      expect(kk.title, '2 күн жазба жоқ');
    });
  });

  group('D167 вечер', () {
    test('нулевая категория не показывается', () {
      final l = ledger();
      spend(l, 'a', '2026-10-11', 'food', 1200);
      spend(l, 'b', '2026-10-11', 'cafe', 1790);
      applyLedgerCommand(l, {'type': 'reverse', 'id': 'r', 'date': '2026-10-11', 'txId': 'a'});
      final body = eveningBrief(BriefInput(ledger: l, today: DateTime(2026, 10, 11), profile: const {}, planned: const [], limits: const [], locale: 'ru'))!.body;
      expect(body, contains('• Кафе: 1 790 ₸'));
      expect(body, isNot(contains(': 0 ₸')), reason: 'отменённая запись в продуктах дала ноль — строки нет');
    });

    test('лимит категории: предупреждение в вечер превышения и по воскресеньям, а не каждый день', () {
      final l = ledger();
      const limits = [{'category': 'cafe', 'amount': '1000000'}];
      BriefInput at(int day) => BriefInput(ledger: l, today: DateTime(2026, 10, day), profile: const {}, planned: const [], limits: limits, locale: 'ru');
      spend(l, 'a', '2026-10-05', 'cafe', 8500); // понедельник: 85 % — порог 80 % пройден сегодня
      expect(eveningBrief(at(5))!.body, contains('Лимит «Кафе»: 85%.'));
      spend(l, 'b', '2026-10-06', 'cafe', 500); // 90 % — ничего нового
      expect(eveningBrief(at(6))!.body, isNot(contains('Лимит «Кафе»')));
      spend(l, 'c', '2026-10-07', 'cafe', 2000); // превышен сегодня
      expect(eveningBrief(at(7))!.body, contains('⚠ Лимит «Кафе» превышен: 11 000 ₸ из 10 000 ₸.'));
      spend(l, 'd', '2026-10-08', 'cafe', 300); // по-прежнему превышен — молчим
      expect(eveningBrief(at(8))!.body, isNot(contains('Лимит «Кафе»')));
      expect(eveningBrief(at(11))!.body, contains('⚠ Лимит «Кафе» превышен: 11 300 ₸ из 10 000 ₸.'), reason: 'воскресенье — недельная сводка');
    });

    test('пустой день: вопрос и кнопки быстрых операций; без плиток — подсказка про бота', () {
      final l = ledger();
      spend(l, 'a', '2026-10-10', 'food', 1200);
      final buttons = [[{'text': 'Кофе · 1 590 ₸', 'callback_data': 'q:1'}]];
      final b = eveningBrief(BriefInput(ledger: l, today: DateTime(2026, 10, 11), profile: const {}, planned: const [], limits: const [], locale: 'ru', quickButtons: buttons))!;
      expect(b.title, 'Сегодня без записей');
      expect(b.body, allOf(contains('Сегодня ничего не записано. Траты были?'), contains('Одно нажатие — и записано:'), contains('С начала месяца:')));
      expect(b.buttons, buttons);
      final plain = eveningBrief(BriefInput(ledger: l, today: DateTime(2026, 10, 11), profile: const {}, planned: const [], limits: const [], locale: 'ru'))!;
      expect(plain.body, contains('Напишите боту сообщением: «кофе 1500».'));
      expect(plain.buttons, isNull);
      // День с записью — обычный отчёт без кнопок.
      final usual = eveningBrief(BriefInput(ledger: l, today: DateTime(2026, 10, 10), profile: const {}, planned: const [], limits: const [], locale: 'ru', quickButtons: buttons))!;
      expect(usual.title, 'Вечерний отчёт');
      expect(usual.buttons, isNull);
      final kk = eveningBrief(BriefInput(ledger: l, today: DateTime(2026, 10, 11), profile: const {}, planned: const [], limits: const [], locale: 'kk', quickButtons: buttons))!;
      expect(kk.title, 'Бүгін жазба жоқ');
    });
  });
}
