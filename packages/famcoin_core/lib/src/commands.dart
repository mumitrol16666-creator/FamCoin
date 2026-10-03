/// Команды журнала: одно и то же описание события применяется в приложении
/// и на сервере одной функцией, поэтому результат совпадает до тиына.
library;

import 'events.dart';
import 'ledger.dart';
import 'serialization.dart';

/// Поля профиля, которые сервер принимает в команде `updateProfile`. Список
/// общий для сервера и для заглушки сервера в тестах приложения: если
/// приложение начнёт писать новое поле, а здесь его нет, тесты упадут, а не
/// боевой сервер ответит отказом (так было бы с `closedMonths`).
const profileKeys = {
  'mode',
  'onboarded',
  'incomeDay',
  'budgetMethod',
  'hiddenCategories',
  'dailyLimit',
  'dailyLimitSince',
  'dailyLimitCarry',
  'dailyLimitHistory',
  'closedMonths',
  'firstName',
  'lastName',
  'birthDate',
  'offerGoalsOnIncome',
};

/// Типы команд, которые меняют журнал.
const ledgerCommandTypes = {
  'addMoneyAccount',
  'archiveAccount',
  'opening',
  'openingDebt',
  'openingReceivable',
  'expense',
  'income',
  'transfer',
  'lendOut',
  'borrow',
  'repaymentReceived',
  'repaymentMade',
  'creditReceived',
  'loanPayment',
  'creditPurchase',
  'refund',
  'adjustment',
  'reverse',
  'restore',
  'reserve',
  'release',
};

/// Применяет команду к журналу. Бросает [LedgerException], если команда
/// нарушает правила учёта; журнал при этом не меняется.
void applyLedgerCommand(Ledger l, Map<String, dynamic> c) {
  String s(String k) {
    final v = c[k];
    if (v is! String || v.isEmpty || v.length > maxIdLength) {
      throw LedgerException('Поле $k не заполнено', code: 'fieldMissing');
    }
    return v;
  }

  String? so(String k) => c[k] == null ? null : s(k);
  int m(String k) => parseMinor(c[k]);
  int mo(String k) => c[k] == null ? 0 : parseMinor(c[k]);
  DateTime date() => dateFromJson(c['date']);
  Map<String, int> splits() {
    final raw = c['splits'];
    if (raw is! Map || raw.isEmpty) throw LedgerException('Нет категорий', code: 'noCategories');
    return {
      for (final e in raw.entries) '${e.key}': parseMinor(e.value),
    };
  }

  Map<String, Object?> meta() {
    final raw = c['meta'];
    if (raw == null) return const {};
    if (raw is! Map) throw LedgerException('Некорректные данные операции', code: 'invalidData');
    return raw.cast<String, Object?>();
  }

  switch (c['type']) {
    case 'addMoneyAccount':
      l.addMoneyAccount(s('accountId'), liquid: c['liquid'] != false, currency: so('currency') ?? 'KZT');
    case 'archiveAccount':
      l.requireActiveMoney(s('accountId'));
      l.archiveAccount(s('accountId'), archived: c['archived'] != false);
    case 'opening':
      l.openingBalance(id: s('id'), date: date(), account: s('account'), amount: m('amount'), meta: meta());
    case 'openingDebt':
      l.openingDebt(id: s('id'), date: date(), debtId: s('debtId'), amount: m('amount'));
    case 'openingReceivable':
      l.openingReceivable(id: s('id'), date: date(), person: s('person'), amount: m('amount'));
    case 'expense':
      l.expense(id: s('id'), date: date(), account: s('account'), splits: splits(), meta: meta());
    case 'income':
      l.income(id: s('id'), date: date(), account: s('account'), source: s('source'), amount: m('amount'), meta: meta());
    case 'transfer':
      l.transfer(id: s('id'), date: date(), from: s('from'), to: s('to'), amount: m('amount'), fee: mo('fee'), meta: meta());
    case 'lendOut':
      l.lendOut(id: s('id'), date: date(), account: s('account'), person: s('person'), amount: m('amount'), meta: meta());
    case 'borrow':
      l.borrow(id: s('id'), date: date(), account: s('account'), person: s('person'), amount: m('amount'), meta: meta());
    case 'repaymentReceived':
      l.repaymentReceived(id: s('id'), date: date(), account: s('account'), person: s('person'), principal: m('principal'), interest: mo('interest'), meta: meta());
    case 'repaymentMade':
      l.repaymentMade(id: s('id'), date: date(), account: s('account'), person: s('person'), principal: m('principal'), interest: mo('interest'), fees: mo('fees'), meta: meta());
    case 'creditReceived':
      l.creditReceived(id: s('id'), date: date(), account: s('account'), debtId: s('debtId'), amount: m('amount'));
    case 'loanPayment':
      l.loanPayment(id: s('id'), date: date(), account: s('account'), debtId: s('debtId'), principal: m('principal'), interest: mo('interest'), fees: mo('fees'), meta: meta());
    case 'creditPurchase':
      l.creditPurchase(id: s('id'), date: date(), debtId: s('debtId'), splits: splits(), downPaymentAccount: so('downPaymentAccount'), downPayment: mo('downPayment'));
    case 'restore':
      l.restore(s('txId'), newId: s('id'));
    case 'refund':
      l.refund(id: s('id'), date: date(), category: s('category'), amount: m('amount'), toAccount: so('toAccount'), reduceDebtId: so('reduceDebtId'), meta: meta());
    case 'adjustment':
      final reason = c['reason'];
      if (reason is! String || reason.trim().isEmpty || reason.length > 200) {
        throw LedgerException('Укажите причину корректировки', code: 'adjustmentReason');
      }
      l.adjustment(id: s('id'), date: date(), account: s('account'), delta: m('delta'), reason: reason.trim());
    case 'reverse':
      l.reverse(s('txId'), newId: s('id'));
    case 'reserve':
      l.reserve(goalId: s('goalId'), accountId: s('accountId'), amount: m('amount'));
    case 'release':
      l.release(goalId: s('goalId'), accountId: s('accountId'), amount: m('amount'));
    default:
      throw LedgerException('Неизвестная команда ${c['type']}');
  }
}
