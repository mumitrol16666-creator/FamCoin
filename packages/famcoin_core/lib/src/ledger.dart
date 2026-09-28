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
  LedgerException(this.message);
  final String message;
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
  });
  final int income;
  final int expense;

  /// Чистый денежный поток через границу денежных счетов.
  final int cashFlow;
  int get result => income - expense;
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
      throw LedgerException('Некорректный идентификатор счёта');
    }
    if (_accounts.containsKey(account.id)) {
      throw LedgerException('Счёт ${account.id} уже существует');
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
      _accounts[id] ?? (throw LedgerException('Счёт $id не найден'));

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
    if (!a.isMoney) throw LedgerException('$id — не денежный счёт');
    if (a.archived) throw LedgerException('Счёт $id в архиве');
    return a;
  }

  /// Возвращает технический счёт, создавая его при первом обращении.
  LedgerAccount ensure(String id, LedgerKind kind,
      {AssetClass? assetClass, String currency = 'KZT'}) {
    if (id.isEmpty || id.length > maxIdLength) {
      throw LedgerException('Некорректный идентификатор');
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
    if (tx.postings.isEmpty) throw LedgerException('Нет проводок');
    if (tx.id.isEmpty || tx.id.length > maxIdLength) {
      throw LedgerException('Некорректный идентификатор операции');
    }
    var debit = 0;
    var credit = 0;
    for (final p in tx.postings) {
      if (p.amount.abs() > maxAmount) throw LedgerException('Слишком большая сумма');
      final acc = account(p.accountId);
      if (acc.isDebitNatural) {
        debit += p.amount;
      } else {
        credit += p.amount;
      }
    }
    if (debit != credit) {
      throw LedgerException(
          'Операция ${tx.id} не сбалансирована: дебет $debit ≠ кредит $credit');
    }
  }

  /// Проводит операцию. Повтор того же `id` с тем же содержимым возвращает
  /// `false` и ничего не меняет; тот же `id` с другим содержимым — ошибка.
  bool post(Transaction tx) {
    final existing = _byId[tx.id];
    if (existing != null) {
      if (_samePostings(existing, tx)) return false;
      throw LedgerException(
          'Команда ${tx.id} уже проведена с другим содержимым');
    }
    validate(tx);
    if (tx.reverses != null) {
      if (!_byId.containsKey(tx.reverses)) {
        throw LedgerException('Нет операции ${tx.reverses}');
      }
      if (_reversed.contains(tx.reverses)) {
        throw LedgerException('Операция ${tx.reverses} уже отменена');
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

  /// Исправление через отменяющую запись: исходная операция остаётся в
  /// истории, её эффект снимается. Повторная отмена — ошибка.
  Transaction reverse(String txId, {required String newId, DateTime? date}) {
    final original = byId(txId) ?? (throw LedgerException('Нет операции $txId'));
    if (_reversed.contains(txId)) {
      throw LedgerException('Операция $txId уже отменена');
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

  /// Сумма проводок по счетам, отобранным `where`, за полуинтервал [from, to).
  /// `skipOpening` исключает начальные остатки: они не являются потоком периода.
  int sumPostings(bool Function(LedgerAccount) where,
      {DateTime? from, DateTime? to, bool skipOpening = false}) {
    var sum = 0;
    for (final tx in _transactions) {
      if (from != null && tx.date.isBefore(from)) continue;
      if (to != null && !tx.date.isBefore(to)) continue;
      if (skipOpening && tx.type == EventType.opening) continue;
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
        cashFlow: sumPostings((a) => a.isMoney,
            from: from, to: to, skipOpening: true),
      );

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
    if (amount <= 0 || amount > maxAmount) throw LedgerException('Сумма резерва должна быть > 0');
    if (goalId.isEmpty || goalId.length > maxIdLength) throw LedgerException('Некорректная цель');
    requireActiveMoney(accountId);
    final available = balance(accountId) - reserved(accountId: accountId);
    if (amount > available) {
      throw LedgerException(
          'Дефицит резерва: доступно $available, запрошено $amount');
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
      throw LedgerException('Резерв меньше запрошенной суммы');
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
      throw LedgerException('Резерв цели $goalId меньше $amount');
    }
    final posted = post(tx);
    if (posted) release(goalId: goalId, accountId: accountId, amount: amount);
    return posted;
  }
}
