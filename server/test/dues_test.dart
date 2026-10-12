/// D167, часть 3: напоминания о платежах — полдень и вечер, просрочка раз в
/// три дня, кнопка «Оплатил» только там, где платёж закрывается одним нажатием.
library;

import 'package:famcoin_core/famcoin_core.dart';
import 'package:famcoin_server/briefs.dart';
import 'package:famcoin_server/chat_entry.dart';
import 'package:famcoin_server/dues.dart';
import 'package:test/test.dart';

const _card = ChatAccount('card', 'Kaspi Gold', 'card', true, null);
const _cash = ChatAccount('cash', 'Наличные', 'cash', true, null);

Ledger _ledger({int money = 100000}) {
  final l = Ledger();
  applyLedgerCommand(l, {'type': 'addMoneyAccount', 'accountId': 'card'});
  applyLedgerCommand(l, {'type': 'addMoneyAccount', 'accountId': 'cash'});
  applyLedgerCommand(l, {'type': 'opening', 'id': 'o', 'date': '2026-09-01', 'account': 'card', 'amount': '${kzt(money)}'});
  applyLedgerCommand(l, {'type': 'opening', 'id': 'o2', 'date': '2026-09-01', 'account': 'cash', 'amount': '${kzt(3000)}'});
  return l;
}

BriefInput _input(Ledger l, DateTime today, List<Map<String, dynamic>> planned, {String locale = 'ru', Map<String, Map<String, dynamic>> debts = const {}}) =>
    BriefInput(ledger: l, today: today, profile: const {}, planned: planned, limits: const [], locale: locale, debts: debts);

const net = {'id': 'net', 'name': 'Интернет', 'amount': '500000', 'day': 12, 'category': 'home', 'paid': <String>[], 'start': '2026-09-01'};
const rent = {'id': 'rent', 'name': 'Аренда', 'amount': '15000000', 'day': 1, 'category': 'home', 'paid': <String>[], 'start': '2026-09-01'};

void main() {
  final today = DateTime(2026, 10, 12);

  test('полдень: сегодняшний срок с кнопкой «Оплатил» и счётом; вечер — «не отмечен»; без сроков — null', () {
    final l = _ledger();
    final noon = dueReminder(_input(l, today, const [net]), const [_card, _cash], stage: 'noon')!;
    expect(noon.title, 'Сегодня платёж: Интернет — 5 000 ₸');
    expect(noon.body, allOf(contains('• Интернет — 5 000 ₸ · со счёта Kaspi Gold'), contains('Нажмите «Оплатил»')));
    expect(noon.buttons, [[{'text': '✅ Оплатил: Интернет', 'callback_data': 'p:net:2026-10'}]]);
    final evening = dueReminder(_input(l, today, const [net]), const [_card], stage: 'evening')!;
    expect(evening.title, 'Платёж не отмечен: Интернет');
    expect(evening.body, startsWith('Срок сегодня, оплата ещё не отмечена:'));
    expect(dueReminder(_input(l, DateTime(2026, 10, 11), const [net]), const [_card], stage: 'noon'), isNull, reason: 'срок завтра — напоминать рано');
    expect(dueReminder(_input(l, DateTime(2026, 10, 13), const [net]), const [_card], stage: 'noon')!.title, 'Просроченный платёж: Интернет — 5 000 ₸', reason: 'день после срока без отметки — просрочка');
    final paid = {...net, 'paid': ['2026-10']};
    expect(dueReminder(_input(l, today, [paid]), const [_card], stage: 'evening'), isNull, reason: 'отмечен — вечером молчим');
    final kk = dueReminder(_input(l, today, const [net], locale: 'kk'), const [_card], stage: 'noon')!;
    expect(kk.title, 'Бүгін төлем: Интернет — 5 000 ₸');
    expect(kk.buttons!.single.single['text'], '✅ Төледім: Интернет');
  });

  test('несколько сроков в день — счётчик и сумма в заголовке', () {
    final l = _ledger();
    const tax = {'id': 'tax', 'name': 'Налог', 'amount': '2200000', 'day': 12, 'category': 'other', 'paid': <String>[], 'start': '2026-09-01'};
    final b = dueReminder(_input(l, today, const [net, tax]), const [_card], stage: 'noon')!;
    expect(b.title, 'Сегодня платежей: 2 на 27 000 ₸');
    expect(b.buttons!.length, 2);
  });

  test('просрочка: на 1-й, 4-й, 7-й день после срока, только в полдень, один срок на платёж', () {
    final l = _ledger();
    Brief? at(int day, {String stage = 'noon'}) => dueReminder(_input(l, DateTime(2026, 10, day), const [rent]), const [_card], stage: stage);
    expect(at(2)!.title, 'Просроченный платёж: Аренда — 150 000 ₸');
    expect(at(2)!.body, contains('• Аренда — 150 000 ₸ (срок 1.10) · на счёте «Kaspi Gold» не хватает'));
    expect(at(2)!.buttons, isNull, reason: 'денег нет — кнопки нет');
    expect(at(3), isNull);
    expect(at(4), isNull);
    expect(at(5), isNotNull);
    expect(at(6), isNull);
    expect(at(8), isNotNull);
    expect(at(5, stage: 'evening'), isNull, reason: 'вечером только сегодняшние сроки');
    expect('Аренда —'.allMatches(at(2)!.body).length, 1, reason: 'сентябрьский срок тоже не оплачен, но напоминаем о последнем');
  });

  test('одним нажатием нельзя: разовая покупка, кредит с процентами, нет денег; рассрочка — можно', () {
    final l = _ledger();
    applyLedgerCommand(l, {'type': 'openingDebt', 'id': 'd1', 'date': '2026-09-01', 'debtId': 'phone', 'amount': '${kzt(60000)}'});
    applyLedgerCommand(l, {'type': 'openingDebt', 'id': 'd2', 'date': '2026-09-01', 'debtId': 'loan', 'amount': '${kzt(500000)}'});
    const tyres = {'id': 'tyres', 'name': 'Колёса', 'amount': '1000000', 'day': 12, 'category': 'transport', 'paid': <String>[], 'once': '2026-10'};
    const phone = {'id': 'phone-pay', 'name': 'Телефон', 'amount': '1000000', 'day': 12, 'category': 'other', 'paid': <String>[], 'debtId': 'phone', 'start': '2026-09-01'};
    const loan = {'id': 'loan-pay', 'name': 'Кредит', 'amount': '2000000', 'day': 12, 'category': 'other', 'paid': <String>[], 'debtId': 'loan', 'start': '2026-09-01'};
    final debts = {'phone': {'kind': 'installment', 'rate': 0}, 'loan': {'kind': 'loan', 'rate': 20}};
    final b = dueReminder(_input(l, today, const [tyres, phone, loan], debts: debts), const [_card], stage: 'noon')!;
    expect(b.body, contains('• Колёса — 10 000 ₸ · в приложении'));
    expect(b.body, contains('• Телефон — 10 000 ₸ · со счёта Kaspi Gold'));
    expect(b.body, contains('• Кредит — '));
    expect(b.body, contains('· в приложении (кредит с процентами)'));
    expect(b.buttons, [[{'text': '✅ Оплатил: Телефон', 'callback_data': 'p:phone-pay:2026-10'}]]);
  });

  test('счёт оплаты — тот, с которого платёж уже платили; иначе первый ликвидный', () {
    final l = _ledger();
    expect(payAccountFor(l, 'net', const [_card, _cash])!.id, 'card');
    applyLedgerCommand(l, {'type': 'expense', 'id': 'e', 'date': '2026-09-12', 'account': 'cash', 'splits': {'home': '${kzt(500)}'}, 'meta': {'planned': 'net', 'period': '2026-09'}});
    expect(payAccountFor(l, 'net', const [_card, _cash])!.id, 'cash');
    final b = dueReminder(_input(l, today, const [net]), const [_card, _cash], stage: 'noon')!;
    expect(b.body, contains('· на счёте «Наличные» не хватает'), reason: 'на наличных 2 500, нужно 5 000 — одним нажатием нельзя');
  });

  test('слишком длинный ключ платежа — без кнопки, но в тексте есть', () {
    final l = _ledger();
    final long = {...net, 'id': 'pd:${'Ооооооооооооооооооооооооооооо'}'};
    final b = dueReminder(_input(l, today, [long]), const [_card], stage: 'noon')!;
    expect(b.body, contains('Интернет'));
    expect(b.buttons, isNull);
  });
}
