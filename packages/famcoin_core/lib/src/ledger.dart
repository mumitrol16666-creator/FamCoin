/// Журнал двойной записи FamCoin (раздел 7 карты продукта).
library;

/// Вид учётного счёта. Актив и расход растут по дебету, остальные — по кредиту.
enum LedgerKind { asset, liability, income, expense, equity }

/// Класс актива: деньги, требования «мне должны», прочие активы.
enum AssetClass { money, receivable, other }

/// Пользовательские типы событий (раздел 8, O01–O24).
enum EventType {
  opening, // O20 начальные остатки денег, долгов, активов
  expense, // O01 покупка за свои деньги (в т.ч. разделённый чек)
  income, // O02 доход
  transfer, // O03 перевод между своими счетами
  fxExchange, // O04 обмен валюты
  lendOut, // O07 дать в долг
  borrow, // O08 взять личный долг
  repaymentReceived, // O09 получить возврат долга
  repaymentMade, // O10 вернуть личный долг
  creditReceived, // O11 получить кредит деньгами
  loanPayment, // O12 / O14 платёж по кредиту, рассрочке, кредитке
  creditPurchase, // O13 покупка в рассрочку / кредитной картой
  refund, // O15 возврат покупки
  cashback, // O16 денежный кешбэк
  depositInterest, // O19 проценты по депозиту
  adjustment, // O21 сверка и корректировка
  fee, // O22 комиссия
  assetPurchase, // O23 покупка учитываемого актива
  revaluation, // O24 переоценка актива
  reversal, // отменяющая запись при исправлении
}

class LedgerAccount {
  const LedgerAccount({
    required this.id,
    required this.kind,
    this.assetClass,
    this.liquid = false,
    this.currency = 'KZT',
    this.archived = false,
  });

  final String id;
  final LedgerKind kind;
  final AssetClass? assetClass;

  /// Для денежных счетов: доступны ли деньги для повседневных трат.
  final bool liquid;
  final String currency;
  final bool archived;

  bool get isDebitNatural =>
      kind == LedgerKind.asset || kind == LedgerKind.expense;
  bool get isMoney =>
      kind == LedgerKind.asset && assetClass == AssetClass.money;
}

/// Изменение остатка счёта в его естественном направлении:
/// `+` — счёт растёт, `−` — уменьшается.
class Posting {
  const Posting(this.accountId, this.amount);
  final String accountId;
  final int amount;

  @override
  bool operator ==(Object other) =>
      other is Posting && other.accountId == accountId && other.amount == amount;
  @override
  int get hashCode => Object.hash(accountId, amount);
}

class Transaction {
  Transaction({
    required this.id,
    required this.date,
    required this.type,
    required List<Posting> postings,
    Map<String, Object?> meta = const {},
    this.reverses,
  })  : postings = List.unmodifiable(postings),
        meta = Map.unmodifiable(meta);

  final String id;
  final DateTime date;
  final EventType type;
  final List<Posting> postings;
  final Map<String, Object?> meta;

  /// Id операции, которую отменяет эта запись (для `EventType.reversal`).
  final String? reverses;

  int amountOn(String accountId) => postings
      .where((p) => p.accountId == accountId)
      .fold(0, (sum, p) => sum + p.amount);
}

/// Предел одной суммы: 10 трлн ₸ в тиынах. Защищает от переполнения.
const maxAmount = 1000000000000000;

/// Предел длины идентификатора счёта, операции, цели.
const maxIdLength = 100;

class LedgerException implements Exception {
  LedgerException(this.message, {this.code = 'invalid'});

  /// Пояснение по-русски — запасной текст, если приложение не знает [code].
  final String message;

  /// Машинный код: приложение показывает по нему текст на языке пользователя,
  /// сервер передаёт его в ответе как `code`.
  final String code;
  @override
  String toString() => 'LedgerException: $message';
}

/// Резерв денег под цель: назначение уже существующих денег, не актив.
class Reservation {
  Reservation({required this.goalId, required this.accountId, this.amount = 0});
  final String goalId;
  final String accountId;
  int amount;
}

class NetWorth {
  const NetWorth({
    required this.money,
    required this.receivables,
    required this.otherAssets,
    required this.liabilities,
  });
  final int money;
  final int receivables;
  final int otherAssets;
  final int liabilities;
  int get assets => money + receivables + otherAssets;
  int get capital => assets - liabilities;
}

/// Три раздельных отчёта периода (раздел 9.2).
class PeriodReport {
  const PeriodReport({
    required this.income,
    required this.expense,
    required this.cashFlow,
    this.debtPayments = 0,
    this.borrowed = 0,
  });
  final int income;

  /// Получено в долг за период деньгами на счёт: личные долги и кредиты
  /// (D102). В [income] не входит — это не заработок, деньги придётся вернуть;
  /// показывается рядом с «в т.ч. кредиты и долги», чтобы месяц читался честно.
  final int borrowed;

  /// Расход по категориям — без платежей по долгам.
  final int expense;

  /// Платежи по кредитам и долгам за период: тело, без процентов (проценты и
  /// так в [expense]). См. [Ledger.debtPaymentsBetween].
  final int debtPayments;

  /// Всё, что ушло: расходы плюс платежи по долгам. Это то, что человек
  /// называет «расходами за месяц» (D98); в отчётах показывается как «Расходы».
  int get total => expense + debtPayments;

  /// Чистый денежный поток через границу денежных счетов.
  final int cashFlow;
  int get result => income - total;
}

class Ledger {
  final Map<String, LedgerAccount> _accounts = {};
  final List<Transaction> _transactions = [];
  final Map<String, Transaction> _byId = {};
  final Map<String, Reservation> _reservations = {};
  final Set<String> _reversed = {};

  /// Бонусные баллы — отдельно от денег, не входят в капитал (O17/O18).
  final Map<String, int> bonusWallets = {};

  Iterable<LedgerAccount> get accounts => _accounts.values;
  List<Transaction> get transactions => List.unmodifiable(_transactions);
  Iterable<Reservation> get reservations => _reservations.values;

  // ---------------------------------------------------------------- счета

  void addAccount(LedgerAccount account) {
    if (account.id.isEmpty || account.id.length > maxIdLength) {
      throw LedgerException('Некорректный идентификатор счёта', code: 'invalidId');
    }
    if (_accounts.containsKey(account.id)) {
      throw LedgerException('Счёт ${account.id} уже существует', code: 'accountExists');
    }
    _accounts[account.id] = account;
  }

  /// Денежный счёт пользователя: карта, наличные, депозит.
  void addMoneyAccount(String id, {bool liquid = true, String currency = 'KZT'}) {
    addAccount(LedgerAccount(
      id: id,
      kind: LedgerKind.asset,
      assetClass: AssetClass.money,
      liquid: liquid,
      currency: currency,
    ));
  }

  LedgerAccount account(String id) =>
      _accounts[id] ?? (throw LedgerException('Счёт $id не найден', code: 'accountNotFound'));

  bool hasAccount(String id) => _accounts.containsKey(id);

  /// Архивный счёт сохраняет историю и остаток, но не участвует в новых
  /// операциях и ликвидности.
  void archiveAccount(String id, {bool archived = true}) {
    final a = account(id);
    _accounts[id] = LedgerAccount(
      id: a.id,
      kind: a.kind,
      assetClass: a.assetClass,
      liquid: a.liquid,
      currency: a.currency,
      archived: archived,
    );
  }

  /// Денежный счёт для новой операции: существует, денежный, не в архиве.
  LedgerAccount requireActiveMoney(String id) {
    final a = account(id);
    if (!a.isMoney) throw LedgerException('$id — не денежный счёт', code: 'accountNotMoney');
    if (a.archived) throw LedgerException('Счёт $id в архиве', code: 'accountArchived');
    return a;
  }

  /// Возвращает технический счёт, создавая его при первом обращении.
  LedgerAccount ensure(String id, LedgerKind kind,
      {AssetClass? assetClass, String currency = 'KZT'}) {
    if (id.isEmpty || id.length > maxIdLength) {
      throw LedgerException('Некорректный идентификатор', code: 'invalidId');
    }
    return _accounts.putIfAbsent(
      id,
      () => LedgerAccount(
          id: id, kind: kind, assetClass: assetClass, currency: currency),
    );
  }

  // ------------------------------------------------------------ проведение

  /// Проверяет операцию, ничего не меняя.
  void validate(Transaction tx) {
    if (tx.postings.isEmpty) throw LedgerException('Нет проводок', code: 'noPostings');
    if (tx.id.isEmpty || tx.id.length > maxIdLength) {
      throw LedgerException('Некорректный идентификатор операции', code: 'invalidId');
    }
    var debit = 0;
    var credit = 0;
    for (final p in tx.postings) {
      if (p.amount.abs() > maxAmount) throw LedgerException('Слишком большая сумма', code: 'amountTooBig');
      final acc = account(p.accountId);
      if (acc.isDebitNatural) {
        debit += p.amount;
      } else {
        credit += p.amount;
      }
    }
    if (debit != credit) {
      throw LedgerException(
          'Операция ${tx.id} не сбалансирована: дебет $debit ≠ кредит $credit', code: 'unbalanced');
    }
  }

  /// Проводит операцию. Повтор того же `id` с тем же содержимым возвращает
  /// `false` и ничего не меняет; тот же `id` с другим содержимым — ошибка.
  bool post(Transaction tx) {
    final existing = _byId[tx.id];
    if (existing != null) {
      if (_samePostings(existing, tx)) return false;
      throw LedgerException(
          'Команда ${tx.id} уже проведена с другим содержимым', code: 'duplicateDifferent');
    }
    validate(tx);
    if (tx.reverses != null) {
      if (!_byId.containsKey(tx.reverses)) {
        throw LedgerException('Нет операции ${tx.reverses}', code: 'noSuchTransaction');
      }
      if (_reversed.contains(tx.reverses)) {
        throw LedgerException('Операция ${tx.reverses} уже отменена', code: 'alreadyReversed');
      }
    }
    _transactions.add(tx);
    _byId[tx.id] = tx;
    if (tx.reverses != null) _reversed.add(tx.reverses!);
    return true;
  }

  static bool _samePostings(Transaction a, Transaction b) {
    if (a.postings.length != b.postings.length) return false;
    for (var i = 0; i < a.postings.length; i++) {
      if (a.postings[i] != b.postings[i]) return false;
    }
    return true;
  }

  Transaction? byId(String id) => _byId[id];
  bool isReversed(String id) => _reversed.contains(id);

  /// Исходная версия покупки. Правка отменяет старую запись и создаёт новую
  /// с `meta.edited` → id старой; возвраты и лимит возврата считаются по
  /// всей цепочке версий, поэтому не теряются после правки.
  String purchaseRoot(String txId) {
    var id = txId;
    for (var i = 0; i < 1000; i++) {
      final prev = _byId[id]?.meta['edited'];
      if (prev is! String || prev.isEmpty || !_byId.containsKey(prev)) break;
      id = prev;
    }
    return id;
  }

  /// Действующая (не отменённая) версия покупки из цепочки правок [txId].
  Transaction? currentVersion(String txId) {
    final root = purchaseRoot(txId);
    for (final t in _transactions.reversed) {
      if (t.type == EventType.reversal || t.type == EventType.refund || _reversed.contains(t.id)) continue;
      if (purchaseRoot(t.id) == root) return t;
    }
    return null;
  }

  /// Сколько по покупке уже возвращено по счёту категории [expenseAccountId]
  /// — по всем версиям покупки, отменённые возвраты не считаются.
  int refundedFor(String purchaseId, String expenseAccountId) {
    final root = purchaseRoot(purchaseId);
    var sum = 0;
    for (final t in _transactions) {
      if (t.type != EventType.refund || _reversed.contains(t.id)) continue;
      final of = t.meta['refundOf'];
      if (of is! String || purchaseRoot(of) != root) continue;
      sum -= t.amountOn(expenseAccountId);
    }
    return sum;
  }

  /// Исправление через отменяющую запись: исходная операция остаётся в
  /// истории, её эффект снимается. Повторная отмена — ошибка.
  Transaction reverse(String txId, {required String newId, DateTime? date}) {
    final original = byId(txId) ?? (throw LedgerException('Нет операции $txId', code: 'noSuchTransaction'));
    if (_reversed.contains(txId)) {
      throw LedgerException('Операция $txId уже отменена', code: 'alreadyReversed');
    }
    final tx = Transaction(
      id: newId,
      date: date ?? original.date,
      type: EventType.reversal,
      postings: [for (final p in original.postings) Posting(p.accountId, -p.amount)],
      reverses: txId,
    );
    post(tx);
    return tx;
  }

  /// Удалённая операция уже восстановлена действующей копией.
  bool isRestored(String txId) =>
      _transactions.any((t) => t.meta['restoredFrom'] == txId && !_reversed.contains(t.id));

  /// `true`, если [txId] отменена не настоящим удалением, а как шаг правки:
  /// где-то есть более новая версия с `meta.edited == txId`. Такую старую
  /// версию нельзя показывать в корзине и восстанавливать как независимую
  /// операцию — иначе правка «10 000 → 12 000» плюс восстановление старой
  /// версии дают задвоенные 22 000 вместо одной покупки на 12 000 (повторный
  /// аудит, F01).
  bool _supersededByEdit(String txId) => _transactions.any((t) => t.meta['edited'] == txId);

  /// В корзине: удалена и ещё не восстановлена (сами отмены и старые версии
  /// правок не считаются).
  bool isDeleted(String txId) {
    final t = _byId[txId];
    return t != null && t.type != EventType.reversal && _reversed.contains(txId) && !isRestored(txId) && !_supersededByEdit(txId);
  }

  /// Восстановление удалённой операции: новая запись с теми же проводками и
  /// `meta.restoredFrom`; исходная и отменяющая записи остаются в истории.
  /// Ограничения исходного события проверяются заново (F02 повторного
  /// аудита) — с момента удаления состояние могло измениться (например,
  /// добавился ещё один возврат или долг успели погасить), а сбалансированные
  /// проводки сами по себе не значат, что операция сейчас допустима.
  Transaction restore(String txId, {required String newId}) {
    final original = byId(txId) ?? (throw LedgerException('Нет операции $txId', code: 'noSuchTransaction'));
    if (!_reversed.contains(txId) || original.type == EventType.reversal) {
      throw LedgerException('Восстановить можно только удалённую операцию', code: 'restoreNotReversed');
    }
    if (isRestored(txId)) {
      throw LedgerException('Операция уже восстановлена', code: 'alreadyRestored');
    }
    if (_supersededByEdit(txId)) {
      throw LedgerException('Эта версия операции заменена более новой правкой', code: 'restoreSuperseded');
    }
    _revalidateForRestore(original);
    final tx = Transaction(
      id: newId,
      date: original.date,
      type: original.type,
      postings: original.postings,
      meta: {...original.meta, 'restoredFrom': txId},
    );
    post(tx);
    return tx;
  }

  /// Заново проверяет то же самое, что проверяет создание такой операции:
  /// восстановление копирует старые проводки напрямую, минуя доменные
  /// конструкторы из `events.dart` и их проверки.
  void _revalidateForRestore(Transaction original) {
    switch (original.type) {
      case EventType.refund:
        final of = original.meta['refundOf'];
        if (of is! String) return;
        final purchase = currentVersion(of);
        if (purchase == null) {
          throw LedgerException('Покупка отменена — возврат по ней невозможен', code: 'purchaseCancelled');
        }
        for (final p in original.postings) {
          if (_accounts[p.accountId]?.kind != LedgerKind.expense) continue;
          final amount = -p.amount; // возврат хранит отрицательную проводку по категории
          final bought = purchase.amountOn(p.accountId);
          final already = refundedFor(of, p.accountId);
          if (amount + already > bought) {
            throw LedgerException('Возврат больше суммы покупки в этой категории', code: 'refundExceeds');
          }
        }
      case EventType.loanPayment:
      case EventType.repaymentMade:
        for (final p in original.postings) {
          if (_accounts[p.accountId]?.kind != LedgerKind.liability) continue;
          final principal = -p.amount; // платёж уменьшает долг
          final owed = balance(p.accountId);
          if (principal > owed) {
            throw LedgerException('Тело $principal больше остатка долга $owed', code: 'principalExceeds');
          }
        }
      default:
        break;
    }
  }

  // -------------------------------------------------------------- остатки

  int balance(String accountId, {DateTime? asOf}) {
    account(accountId);
    var sum = 0;
    for (final tx in _transactions) {
      if (asOf != null && tx.date.isAfter(asOf)) continue;
      sum += tx.amountOn(accountId);
    }
    return sum;
  }

  /// `true`, если [tx] сама — начальный остаток, либо отменяет начальный
  /// остаток: обе стороны такой пары не являются потоком периода (F02).
  bool _isOpeningLike(Transaction tx) =>
      tx.type == EventType.opening ||
      (tx.type == EventType.reversal && tx.reverses != null && _byId[tx.reverses]?.type == EventType.opening);

  /// Сумма проводок по счетам, отобранным `where`, за полуинтервал [from, to).
  /// `skipOpening` исключает начальные остатки: они не являются потоком периода.
  int sumPostings(bool Function(LedgerAccount) where,
      {DateTime? from, DateTime? to, bool skipOpening = false}) {
    var sum = 0;
    for (final tx in _transactions) {
      if (from != null && tx.date.isBefore(from)) continue;
      if (to != null && !tx.date.isBefore(to)) continue;
      if (skipOpening && _isOpeningLike(tx)) continue;
      for (final p in tx.postings) {
        if (where(_accounts[p.accountId]!)) sum += p.amount;
      }
    }
    return sum;
  }

  /// Ликвидные собственные деньги: положительные остатки ликвидных счетов.
  int liquid() {
    var sum = 0;
    for (final acc in _accounts.values) {
      if (!acc.isMoney || !acc.liquid || acc.archived) continue;
      final b = balance(acc.id);
      if (b > 0) sum += b;
    }
    return sum;
  }

  int reserved({String? goalId, String? accountId}) {
    var sum = 0;
    for (final r in _reservations.values) {
      if (goalId != null && r.goalId != goalId) continue;
      if (accountId != null && r.accountId != accountId) continue;
      sum += r.amount;
    }
    return sum;
  }

  /// Свободные ликвидные = ликвидные − резервы на ликвидных счетах.
  int freeLiquid() {
    var reservedLiquid = 0;
    for (final r in _reservations.values) {
      if (account(r.accountId).liquid) reservedLiquid += r.amount;
    }
    return liquid() - reservedLiquid;
  }

  NetWorth netWorth({DateTime? asOf}) {
    var money = 0, receivables = 0, other = 0, liabilities = 0;
    for (final acc in _accounts.values) {
      final b = balance(acc.id, asOf: asOf);
      switch (acc.kind) {
        case LedgerKind.asset:
          switch (acc.assetClass) {
            case AssetClass.money:
              money += b;
            case AssetClass.receivable:
              receivables += b;
            case AssetClass.other:
              other += b;
            case null:
              other += b;
          }
        case LedgerKind.liability:
          liabilities += b;
        default:
          break;
      }
    }
    return NetWorth(
      money: money,
      receivables: receivables,
      otherAssets: other,
      liabilities: liabilities,
    );
  }

  PeriodReport report(DateTime from, DateTime to) => PeriodReport(
        income: sumPostings((a) => a.kind == LedgerKind.income, from: from, to: to),
        expense:
            sumPostings((a) => a.kind == LedgerKind.expense, from: from, to: to),
        debtPayments: debtPaymentsBetween(from, to),
        borrowed: borrowedBetween(from, to),
        cashFlow: sumPostings((a) => a.isMoney,
            from: from, to: to, skipOpening: true),
      );

  /// Сколько получено в долг деньгами за период (D102): «взял в долг» у
  /// человека и кредит деньгами. Старые долги, записанные без движения по
  /// счёту (`openingDebt`), сюда не входят — денег тогда не приходило.
  int borrowedBetween(DateTime from, DateTime to) {
    var sum = 0;
    for (final tx in _transactions) {
      if ((tx.type != EventType.borrow && tx.type != EventType.creditReceived) || _reversed.contains(tx.id)) continue;
      if (tx.date.isBefore(from) || !tx.date.isBefore(to)) continue;
      for (final p in tx.postings) {
        if (_accounts[p.accountId]!.kind == LedgerKind.liability) sum += p.amount;
      }
    }
    return sum;
  }

  /// Платежи по долгам за период, которые считаются расходом (D98): тело
  /// кредита и возврат личных долгов. Проценты не входят — они уже расход по
  /// категории «Проценты». Долги, покупки по которым записаны в приложении
  /// (`creditPurchase`), не считаются: та покупка уже была расходом, и платёж
  /// по ней был бы учтён второй раз.
  List<Transaction> debtPaymentsIn(DateTime from, DateTime to) {
    final purchased = <String>{};
    for (final tx in _transactions) {
      if (tx.type != EventType.creditPurchase || _reversed.contains(tx.id)) continue;
      for (final p in tx.postings) {
        if (_accounts[p.accountId]!.kind == LedgerKind.liability) purchased.add(p.accountId);
      }
    }
    return [
      for (final tx in _transactions)
        if ((tx.type == EventType.loanPayment || tx.type == EventType.repaymentMade) &&
            !_reversed.contains(tx.id) &&
            !tx.date.isBefore(from) &&
            tx.date.isBefore(to) &&
            tx.postings.any((p) => _accounts[p.accountId]!.kind == LedgerKind.liability && !purchased.contains(p.accountId)))
          tx,
    ];
  }

  /// Сумма [debtPaymentsIn]: сколько ушло на долги за период, без процентов.
  int debtPaymentsBetween(DateTime from, DateTime to) {
    var sum = 0;
    for (final tx in debtPaymentsIn(from, to)) {
      for (final p in tx.postings) {
        if (_accounts[p.accountId]!.kind == LedgerKind.liability) sum -= p.amount;
      }
    }
    return sum;
  }

  /// Корректировки остатков за период (O21): меняют капитал, но не доход и
  /// не расход, поэтому показываются в отчёте отдельной строкой.
  int adjustmentsFor(DateTime from, DateTime to) =>
      sumPostings((a) => a.id == 'equity:adjustment', from: from, to: to);

  /// Расход по категориям за период; возвраты уменьшают свою категорию.
  Map<String, int> expenseByCategory(DateTime from, DateTime to) {
    final result = <String, int>{};
    for (final tx in _transactions) {
      if (tx.date.isBefore(from) || !tx.date.isBefore(to)) continue;
      for (final p in tx.postings) {
        if (_accounts[p.accountId]!.kind == LedgerKind.expense) {
          result.update(p.accountId, (v) => v + p.amount, ifAbsent: () => p.amount);
        }
      }
    }
    return result;
  }

  // -------------------------------------------------------------- резервы

  String _rkey(String goalId, String accountId) => '$goalId|$accountId';

  /// Зарезервировать деньги счёта под цель (O05). Резерв не может превышать
  /// доступный положительный остаток счёта.
  void reserve({required String goalId, required String accountId, required int amount}) {
    if (amount <= 0 || amount > maxAmount) throw LedgerException('Сумма резерва должна быть > 0', code: 'invalidAmount');
    if (goalId.isEmpty || goalId.length > maxIdLength) throw LedgerException('Некорректная цель', code: 'invalidGoal');
    requireActiveMoney(accountId);
    final available = balance(accountId) - reserved(accountId: accountId);
    if (amount > available) {
      throw LedgerException(
          'Дефицит резерва: доступно $available, запрошено $amount', code: 'reserveExceedsFree');
    }
    _reservations
        .putIfAbsent(_rkey(goalId, accountId),
            () => Reservation(goalId: goalId, accountId: accountId))
        .amount += amount;
  }

  /// Восстановление сохранённого резерва без проверок остатка.
  void restoreReservation(String goalId, String accountId, int amount) {
    if (amount <= 0) return;
    _reservations[_rkey(goalId, accountId)] =
        Reservation(goalId: goalId, accountId: accountId, amount: amount);
  }

  /// Освободить резерв (O06). Не создаёт дохода и не меняет баланс.
  void release({required String goalId, required String accountId, required int amount}) {
    final r = _reservations[_rkey(goalId, accountId)];
    if (r == null || r.amount < amount) {
      throw LedgerException('Резерв меньше запрошенной суммы', code: 'reserveTooSmall');
    }
    r.amount -= amount;
    if (r.amount == 0) _reservations.remove(_rkey(goalId, accountId));
  }

  /// Потратить деньги цели: операция проводится и резерв уменьшается
  /// вместе — либо оба изменения, либо ни одного.
  bool postFromReservation(Transaction tx,
      {required String goalId, required String accountId, required int amount}) {
    validate(tx);
    final r = _reservations[_rkey(goalId, accountId)];
    if (r == null || r.amount < amount) {
      throw LedgerException('Резерв цели $goalId меньше $amount', code: 'reserveTooSmall');
    }
    final posted = post(tx);
    if (posted) release(goalId: goalId, accountId: accountId, amount: amount);
    return posted;
  }
}
