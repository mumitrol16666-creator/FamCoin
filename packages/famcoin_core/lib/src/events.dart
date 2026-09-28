/// Пользовательские события O01–O24 как готовые наборы проводок.
///
/// Каждый метод строит сбалансированную операцию и проводит её. Имена
/// технических счетов: `expense:<категория>`, `income:<источник>`,
/// `receivable:<человек>`, `liability:<долг>`, `asset:<актив>`, `equity:*`.
library;

import 'ledger.dart';

String expenseAccount(String category) => 'expense:$category';
String incomeAccount(String source) => 'income:$source';
String receivableAccount(String person) => 'receivable:$person';
String liabilityAccount(String debtId) => 'liability:$debtId';
String otherAssetAccount(String assetId) => 'asset:$assetId';

const equityOpening = 'equity:opening';
const equityAdjustment = 'equity:adjustment';
const equityRevaluation = 'equity:revaluation';

const categoryInterest = 'interest';
const categoryFees = 'fees';
const sourceCashback = 'cashback';
const sourceInterest = 'interest';

extension LedgerEvents on Ledger {
  String _exp(String category) {
    ensure(expenseAccount(category), LedgerKind.expense);
    return expenseAccount(category);
  }

  String _inc(String source) {
    ensure(incomeAccount(source), LedgerKind.income);
    return incomeAccount(source);
  }

  String _recv(String person) {
    ensure(receivableAccount(person), LedgerKind.asset,
        assetClass: AssetClass.receivable);
    return receivableAccount(person);
  }

  String _liab(String debtId) {
    ensure(liabilityAccount(debtId), LedgerKind.liability);
    return liabilityAccount(debtId);
  }

  String _asset(String assetId) {
    ensure(otherAssetAccount(assetId), LedgerKind.asset,
        assetClass: AssetClass.other);
    return otherAssetAccount(assetId);
  }

  String _equity(String id) {
    ensure(id, LedgerKind.equity);
    return id;
  }

  Transaction _post(Transaction tx) {
    post(tx);
    return tx;
  }

  static void _positive(int amount, String what) {
    if (amount <= 0) throw LedgerException('$what должна быть > 0', code: 'amountNotPositive');
    if (amount > maxAmount) throw LedgerException('$what слишком большая', code: 'amountTooBig');
  }

  /// Каждая часть покупки положительна: отрицательная часть — это возврат,
  /// и он проводится отдельным событием.
  static void _checkSplits(Map<String, int> splits) {
    if (splits.isEmpty) throw LedgerException('Нет категорий', code: 'noCategories');
    for (final v in splits.values) {
      _positive(v, 'Сумма части покупки');
    }
  }

  String _money(String id) {
    requireActiveMoney(id);
    return id;
  }

  // ------------------------------------------------------ O20 начальные

  /// Начальный остаток денежного счёта на дату начала учёта.
  Transaction openingBalance({
    required String id,
    required DateTime date,
    required String account,
    required int amount,
  }) =>
      _post(Transaction(
        id: id,
        date: date,
        type: EventType.opening,
        postings: [Posting(_money(account), amount), Posting(_equity(equityOpening), amount)],
      ));

  /// Уже существующий долг на дату начала учёта — без фиктивного дохода.
  Transaction openingDebt({
    required String id,
    required DateTime date,
    required String debtId,
    required int amount,
  }) {
    _positive(amount, 'Сумма долга');
    return _post(Transaction(
      id: id,
      date: date,
      type: EventType.opening,
      postings: [Posting(_liab(debtId), amount), Posting(_equity(equityOpening), -amount)],
    ));
  }

  /// Уже существующее требование «мне должны» на дату начала учёта.
  Transaction openingReceivable({
    required String id,
    required DateTime date,
    required String person,
    required int amount,
  }) {
    _positive(amount, 'Сумма требования');
    return _post(Transaction(
      id: id,
      date: date,
      type: EventType.opening,
      postings: [Posting(_recv(person), amount), Posting(_equity(equityOpening), amount)],
    ));
  }

  // ---------------------------------------------------------- O01 / O02

  /// Покупка за свои деньги. `splits` — категория → сумма; одна покупка с
  /// несколькими категориями остаётся одной операцией (T24).
  /// `bonusPoints` — использованные баллы: расход равен денежной части (T13).
  Transaction expense({
    required String id,
    required DateTime date,
    required String account,
    required Map<String, int> splits,
    int bonusPoints = 0,
    String? bonusWallet,
    Map<String, Object?> meta = const {},
  }) {
    _checkSplits(splits);
    final total = splits.values.fold(0, (a, b) => a + b);
    _positive(total, 'Сумма покупки');
    if (bonusPoints > 0) {
      final wallet = bonusWallet ?? (throw LedgerException('Не указан бонусный кошелёк', code: 'noBonusWallet'));
      final have = bonusWallets[wallet] ?? 0;
      if (have < bonusPoints) throw LedgerException('Недостаточно бонусов', code: 'notEnoughBonus');
      bonusWallets[wallet] = have - bonusPoints;
    }
    return _post(Transaction(
      id: id,
      date: date,
      type: EventType.expense,
      postings: [
        for (final e in splits.entries) Posting(_exp(e.key), e.value),
        Posting(_money(account), -total),
      ],
      meta: {...meta, if (bonusPoints > 0) 'bonusPoints': bonusPoints},
    ));
  }

  Transaction income({
    required String id,
    required DateTime date,
    required String account,
    required String source,
    required int amount,
    Map<String, Object?> meta = const {},
  }) {
    _positive(amount, 'Сумма дохода');
    return _post(Transaction(
      id: id,
      date: date,
      type: EventType.income,
      postings: [Posting(_money(account), amount), Posting(_inc(source), amount)],
      meta: meta,
    ));
  }

  // --------------------------------------------------------------- O03

  /// Перевод между своими счетами. Не расход; комиссия — отдельная проводка.
  Transaction transfer({
    required String id,
    required DateTime date,
    required String from,
    required String to,
    required int amount,
    int fee = 0,
    Map<String, Object?> meta = const {},
  }) {
    _positive(amount, 'Сумма перевода');
    if (from == to) throw LedgerException('Счета перевода совпадают', code: 'sameAccounts');
    _money(from);
    _money(to);
    if (account(from).currency != account(to).currency) {
      throw LedgerException('Для разных валют используйте fxExchange', code: 'currencyMismatch');
    }
    return _post(Transaction(
      id: id,
      date: date,
      type: EventType.transfer,
      postings: [
        Posting(from, -amount - fee),
        Posting(to, amount),
        if (fee > 0) Posting(_exp(categoryFees), fee),
      ],
      meta: meta,
    ));
  }

  // --------------------------------------------------------------- O04

  /// Обмен валюты: две фактические суммы в двух валютах. Курсовой результат
  /// считается отдельно по средневзвешенной стоимости (`FxPosition`).
  Transaction fxExchange({
    required String id,
    required DateTime date,
    required String from,
    required int fromAmount,
    required String to,
    required int toAmount,
    required int toAmountInReporting,
    int fee = 0,
  }) {
    _positive(fromAmount, 'Сумма продажи');
    _positive(toAmount, 'Сумма покупки');
    // Проводки в валюте отчёта: списание fromAmount, зачисление оценки
    // toAmountInReporting; разница — реализованный курсовой результат.
    final diff = fromAmount + fee - toAmountInReporting;
    return _post(Transaction(
      id: id,
      date: date,
      type: EventType.fxExchange,
      postings: [
        Posting(from, -fromAmount - fee),
        Posting(to, toAmountInReporting),
        if (fee > 0) Posting(_exp(categoryFees), fee),
        if (diff - fee != 0) Posting(_equity(equityRevaluation), -(diff - fee)),
      ],
      meta: {'toAmountForeign': toAmount, 'toCurrency': account(to).currency},
    ));
  }

  // ------------------------------------------------------- O07–O10 люди

  Transaction lendOut({
    required String id,
    required DateTime date,
    required String account,
    required String person,
    required int amount,
    Map<String, Object?> meta = const {},
  }) {
    _positive(amount, 'Сумма долга');
    return _post(Transaction(
      id: id,
      date: date,
      type: EventType.lendOut,
      postings: [Posting(_recv(person), amount), Posting(_money(account), -amount)],
      meta: meta,
    ));
  }

  Transaction borrow({
    required String id,
    required DateTime date,
    required String account,
    required String person,
    required int amount,
    Map<String, Object?> meta = const {},
  }) {
    _positive(amount, 'Сумма долга');
    return _post(Transaction(
      id: id,
      date: date,
      type: EventType.borrow,
      postings: [Posting(_money(account), amount), Posting(_liab(person), amount)],
      meta: meta,
    ));
  }

  /// Возврат мне: тело уменьшает требование, проценты — доход.
  Transaction repaymentReceived({
    required String id,
    required DateTime date,
    required String account,
    required String person,
    required int principal,
    int interest = 0,
    Map<String, Object?> meta = const {},
  }) {
    if (principal < 0 || interest < 0) {
      throw LedgerException('Части возврата не могут быть отрицательными', code: 'negativeParts');
    }
    _positive(principal + interest, 'Сумма возврата');
    final owed = balance(_recv(person));
    if (principal > owed) {
      throw LedgerException('Возврат $principal больше требования $owed', code: 'repaymentExceeds');
    }
    return _post(Transaction(
      id: id,
      date: date,
      type: EventType.repaymentReceived,
      postings: [
        Posting(_money(account), principal + interest),
        if (principal > 0) Posting(_recv(person), -principal),
        if (interest > 0) Posting(_inc(sourceInterest), interest),
      ],
      meta: meta,
    ));
  }

  /// Я возвращаю: тело уменьшает обязательство, проценты и комиссии — расход.
  Transaction repaymentMade({
    required String id,
    required DateTime date,
    required String account,
    required String person,
    required int principal,
    int interest = 0,
    int fees = 0,
    Map<String, Object?> meta = const {},
  }) =>
      loanPayment(
        id: id,
        date: date,
        account: account,
        debtId: person,
        principal: principal,
        interest: interest,
        fees: fees,
        type: EventType.repaymentMade,
        meta: meta,
      );

  // ------------------------------------------------------ O11–O14 банки

  Transaction creditReceived({
    required String id,
    required DateTime date,
    required String account,
    required String debtId,
    required int amount,
  }) {
    _positive(amount, 'Сумма кредита');
    return _post(Transaction(
      id: id,
      date: date,
      type: EventType.creditReceived,
      postings: [Posting(_money(account), amount), Posting(_liab(debtId), amount)],
    ));
  }

  /// Платёж по кредиту, рассрочке или кредитке (O12/O14).
  Transaction loanPayment({
    required String id,
    required DateTime date,
    required String account,
    required String debtId,
    required int principal,
    int interest = 0,
    int fees = 0,
    EventType type = EventType.loanPayment,
    Map<String, Object?> meta = const {},
  }) {
    if (principal < 0 || interest < 0 || fees < 0) {
      throw LedgerException('Части платежа не могут быть отрицательными', code: 'negativeParts');
    }
    final total = principal + interest + fees;
    _positive(total, 'Сумма платежа');
    final owed = balance(_liab(debtId));
    if (principal > owed) {
      throw LedgerException('Тело $principal больше остатка долга $owed', code: 'principalExceeds');
    }
    return _post(Transaction(
      id: id,
      date: date,
      type: type,
      postings: [
        Posting(_money(account), -total),
        if (principal > 0) Posting(_liab(debtId), -principal),
        if (interest > 0) Posting(_exp(categoryInterest), interest),
        if (fees > 0) Posting(_exp(categoryFees), fees),
      ],
      meta: meta,
    ));
  }

  /// Покупка в рассрочку или кредитной картой (O13): расход на полную
  /// потребительскую стоимость, обязательство на непогашенную часть.
  Transaction creditPurchase({
    required String id,
    required DateTime date,
    required String debtId,
    required Map<String, int> splits,
    String? downPaymentAccount,
    int downPayment = 0,
  }) {
    _checkSplits(splits);
    final total = splits.values.fold(0, (a, b) => a + b);
    _positive(total, 'Сумма покупки');
    if (downPayment < 0) throw LedgerException('Взнос не может быть отрицательным', code: 'downPaymentNegative');
    if (downPayment > total) throw LedgerException('Взнос больше суммы покупки', code: 'downPaymentExceeds');
    if (downPayment > 0 && downPaymentAccount == null) {
      throw LedgerException('Не указан счёт первоначального взноса', code: 'noDownPaymentAccount');
    }
    return _post(Transaction(
      id: id,
      date: date,
      type: EventType.creditPurchase,
      postings: [
        for (final e in splits.entries) Posting(_exp(e.key), e.value),
        if (total - downPayment > 0) Posting(_liab(debtId), total - downPayment),
        if (downPayment > 0) Posting(_money(downPaymentAccount!), -downPayment),
      ],
    ));
  }

  // --------------------------------------------------------------- O15

  /// Возврат покупки: уменьшает расход категории в дату возврата.
  /// Деньги либо зачисляются на счёт, либо уменьшают кредитный долг (T19).
  Transaction refund({
    required String id,
    required DateTime date,
    required String category,
    required int amount,
    String? toAccount,
    String? reduceDebtId,
    Map<String, Object?> meta = const {},
  }) {
    _positive(amount, 'Сумма возврата');
    if ((toAccount == null) == (reduceDebtId == null)) {
      throw LedgerException('Укажите ровно один способ возврата', code: 'refundMethod');
    }
    // Возврат привязан к покупке (meta.refundOf): нельзя вернуть больше, чем
    // потрачено в категории, с учётом прежних возвратов и правок покупки.
    final of = meta['refundOf'];
    if (of is String && byId(of) != null) {
      final purchase = currentVersion(of);
      if (purchase == null) throw LedgerException('Покупка отменена — возврат по ней невозможен', code: 'purchaseCancelled');
      final bought = purchase.amountOn(_exp(category));
      final already = refundedFor(of, _exp(category));
      if (amount + already > bought) {
        throw LedgerException('Возврат больше суммы покупки в этой категории', code: 'refundExceeds');
      }
    }
    return _post(Transaction(
      id: id,
      date: date,
      type: EventType.refund,
      postings: [
        Posting(_exp(category), -amount),
        if (toAccount != null) Posting(_money(toAccount), amount),
        if (reduceDebtId != null) Posting(_liab(reduceDebtId), -amount),
      ],
      meta: meta,
    ));
  }

  // ------------------------------------------------------ O16, O17, O19

  Transaction cashback({
    required String id,
    required DateTime date,
    required String account,
    required int amount,
  }) =>
      income(id: id, date: date, account: account, source: sourceCashback, amount: amount);

  /// Начисление бонусов — не деньги и не доход (O17).
  void accrueBonus(String wallet, int points) {
    _positive(points, 'Баллы');
    bonusWallets.update(wallet, (v) => v + points, ifAbsent: () => points);
  }

  Transaction depositInterest({
    required String id,
    required DateTime date,
    required String account,
    required int amount,
  }) =>
      income(id: id, date: date, account: account, source: sourceInterest, amount: amount);

  // --------------------------------------------------------- O21 / O22

  /// Сверка: разница проводится отдельной строкой с причиной, не как доход.
  Transaction adjustment({
    required String id,
    required DateTime date,
    required String account,
    required int delta,
    required String reason,
  }) {
    if (delta == 0) throw LedgerException('Нулевая корректировка', code: 'zeroAdjustment');
    return _post(Transaction(
      id: id,
      date: date,
      type: EventType.adjustment,
      postings: [Posting(_money(account), delta), Posting(_equity(equityAdjustment), delta)],
      meta: {'reason': reason},
    ));
  }

  Transaction fee({
    required String id,
    required DateTime date,
    required String account,
    required int amount,
  }) =>
      expense(id: id, date: date, account: account, splits: {categoryFees: amount});

  // --------------------------------------------------------- O23 / O24

  /// Покупка учитываемого актива — не потребительский расход (T32).
  Transaction assetPurchase({
    required String id,
    required DateTime date,
    required String assetId,
    required int amount,
    String? fromAccount,
    String? viaDebtId,
    int downPayment = 0,
  }) {
    _positive(amount, 'Стоимость актива');
    if (viaDebtId == null && fromAccount == null) {
      throw LedgerException('Укажите счёт оплаты или кредит', code: 'noPaymentSource');
    }
    final financed = viaDebtId == null ? 0 : amount - downPayment;
    final paid = amount - financed;
    if (paid > 0 && fromAccount == null) {
      throw LedgerException('Не указан счёт оплаты', code: 'noPaymentAccount');
    }
    return _post(Transaction(
      id: id,
      date: date,
      type: EventType.assetPurchase,
      postings: [
        Posting(_asset(assetId), amount),
        if (financed > 0) Posting(_liab(viaDebtId!), financed),
        if (paid > 0) Posting(_money(fromAccount!), -paid),
      ],
    ));
  }

  /// Переоценка актива: меняет капитал без движения денег.
  Transaction revaluation({
    required String id,
    required DateTime date,
    required String assetId,
    required int delta,
  }) {
    if (delta == 0) throw LedgerException('Нулевая переоценка', code: 'zeroRevaluation');
    return _post(Transaction(
      id: id,
      date: date,
      type: EventType.revaluation,
      postings: [Posting(_asset(assetId), delta), Posting(_equity(equityRevaluation), delta)],
    ));
  }
}
