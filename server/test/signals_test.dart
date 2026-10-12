/// D167, часть 2: сигналы сразу после записи — лимит категории на 80 % и
/// превышен, дневной лимит исчерпан. Ключи сигналов, тексты RU/KK, какие
/// команды дают пересчёт.
library;

import 'package:famcoin_core/famcoin_core.dart';
import 'package:famcoin_server/signals.dart';
import 'package:test/test.dart';

Ledger _ledger() {
  final l = Ledger();
  applyLedgerCommand(l, {'type': 'addMoneyAccount', 'accountId': 'card'});
  applyLedgerCommand(l, {'type': 'opening', 'id': 'o', 'date': '2026-09-01', 'account': 'card', 'amount': '${kzt(100000)}'});
  return l;
}

void _spend(Ledger l, String id, String date, String cat, int amount, {bool planned = false}) =>
    applyLedgerCommand(l, {'type': 'expense', 'id': id, 'date': date, 'account': 'card', 'splits': {cat: '${kzt(amount)}'}, if (planned) 'meta': {'plannedPurchase': true}});

void main() {
  const limits = [{'category': 'cafe', 'amount': '1000000'}];
  final today = DateTime(2026, 10, 12);

  test('лимит категории: тишина до 80 %, затем «80 %», затем «превышен» — у каждого свой ключ на месяц', () {
    final l = _ledger();
    SignalInput input() => SignalInput(ledger: l, today: today, profile: const {}, limits: limits, locale: 'ru');
    _spend(l, 'a', '2026-10-05', 'cafe', 7000);
    expect(currentSignals(input()), isEmpty);
    _spend(l, 'b', '2026-10-12', 'cafe', 1500);
    final warn = currentSignals(input()).single;
    expect(warn.key, 'limit80:cafe:2026-10');
    expect(warn.title, 'Лимит «Кафе»: 85 %');
    expect(warn.body, '8 500 ₸ из 10 000 ₸, осталось 1 500 ₸ на 19 дней.');
    _spend(l, 'c', '2026-10-12', 'cafe', 2000);
    final over = currentSignals(input()).single;
    expect(over.key, 'limit100:cafe:2026-10');
    expect(over.title, 'Лимит «Кафе» превышен');
    expect(over.body, '10 500 ₸ из 10 000 ₸, до конца месяца 19 дней.');
    // Ровно лимит — уже превышение, как в приложении (exceeded при spent >= limit).
    final kk = currentSignals(SignalInput(ledger: l, today: today, profile: const {}, limits: limits, locale: 'kk')).single;
    expect(kk.title, '«Кафе» лимиті асып кетті');
    expect(kk.body, contains('ай соңына дейін 19 күн'));
  });

  test('дневной лимит: сигнал, когда повседневные траты дня добрали лимит; запланированные не считаются', () {
    final l = _ledger();
    SignalInput input({bool carry = false}) => SignalInput(ledger: l, today: today, profile: {'dailyLimit': '500000', if (carry) 'dailyLimitCarry': true}, limits: const [], locale: 'ru');
    _spend(l, 'a', '2026-10-12', 'home', 20000, planned: true);
    _spend(l, 'b', '2026-10-12', 'food', 4000);
    expect(currentSignals(input()), isEmpty, reason: '4 000 из 5 000 — лимит ещё есть');
    _spend(l, 'c', '2026-10-12', 'food', 1200);
    final s = currentSignals(input()).single;
    expect(s.key, 'daily:2026-10-12');
    expect(s.title, 'Дневной лимит исчерпан');
    expect(s.body, 'Сегодня повседневных трат 5 200 ₸ при лимите 5 000 ₸. Завтра снова 5 000 ₸.');
    expect(currentSignals(input(carry: true)).single.body, endsWith('Перерасход уменьшит завтрашний лимит.'));
    expect(currentSignals(SignalInput(ledger: l, today: today, profile: const {}, limits: const [], locale: 'ru')), isEmpty, reason: 'без дневного лимита сигнала нет');
    final kk = currentSignals(SignalInput(ledger: l, today: today, profile: const {'dailyLimit': '500000'}, limits: const [], locale: 'kk')).single;
    expect(kk.title, 'Күндік лимит таусылды');
  });

  test('склонение дней в тексте', () {
    final l = _ledger();
    _spend(l, 'a', '2026-10-30', 'cafe', 9000);
    expect(currentSignals(SignalInput(ledger: l, today: DateTime(2026, 10, 30), profile: const {}, limits: limits, locale: 'ru')).single.body, endsWith('на 1 день.'));
    expect(currentSignals(SignalInput(ledger: l, today: DateTime(2026, 10, 28), profile: const {}, limits: limits, locale: 'ru')).single.body, endsWith('на 3 дня.'));
  });

  test('пересчёт только после расхода: своего, восстановленного или внутри пачки', () {
    expect(commandTouchesExpense({'type': 'expense'}), isTrue);
    expect(commandTouchesExpense({'type': 'restore', 'txId': 'x'}), isTrue);
    expect(commandTouchesExpense({'type': 'batch', 'commands': [{'type': 'upsertEntity'}, {'type': 'expense'}]}), isTrue);
    expect(commandTouchesExpense({'type': 'batch', 'commands': [{'type': 'transfer'}]}), isFalse);
    expect(commandTouchesExpense({'type': 'upsertEntity', 'kind': 'limit'}), isFalse);
    expect(commandTouchesExpense({'type': 'income'}), isFalse);
  });
}
