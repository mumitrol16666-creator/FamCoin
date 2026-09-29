/// Данные владельца: журнал, справочники, профиль.
///
/// Источник правды — сервер. Команда сначала принимается сервером, затем
/// та же команда применяется к локальному журналу функцией из
/// `famcoin_core`, поэтому числа на экране совпадают с сервером.
/// Расчёты — только в ядре.
library;

import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';

import 'api_client.dart';
import 'models.dart';

class AppState extends ChangeNotifier {
  AppState({required this.api, required this.token, DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final ApiClient api;
  final String token;
  final DateTime Function() _clock;

  Ledger ledger = Ledger();
  String plan = 'free';

  /// До какого момента действует оплаченный Pro; пусто — бессрочно или тариф обычный.
  DateTime? proUntil;
  String email = '';

  /// Имя из Telegram; у обычных аккаунтов пусто.
  String? name;

  // Анкета «О вас» (D50): имя, фамилия, дата рождения — в профиле.
  String get firstName => profile['firstName'] as String? ?? '';
  String get lastName => profile['lastName'] as String? ?? '';
  /// Дата рождения — не дата операции: правило «не раньше 2000 года» из
  /// ядра к ней не относится, иначе экран настроек падал у всех, кто
  /// родился раньше.
  DateTime? get birthDate {
    final v = profile['birthDate'];
    if (v is! String) return null;
    final d = DateTime.tryParse(v);
    return d == null ? null : DateTime(d.year, d.month, d.day);
  }

  Future<void> setAbout({required String firstName, required String lastName, DateTime? birthDate}) => send({
        'type': 'updateProfile',
        'profile': {'firstName': firstName, 'lastName': lastName, 'birthDate': birthDate == null ? null : dateToJson(birthDate)},
      });

  /// Что показывать как «кто вошёл»: имя из анкеты, иначе из Telegram, иначе email.
  String get displayName {
    final full = '$firstName $lastName'.trim();
    if (full.isNotEmpty) return full;
    return name?.isNotEmpty == true ? name! : email;
  }
  Map<String, dynamic> profile = {};
  int revision = 0;
  final Map<String, Map<String, Map<String, dynamic>>> _entities = {};

  bool loaded = false;
  Object? loadError;

  DateTime get today {
    final n = _clock();
    return DateTime(n.year, n.month, n.day);
  }

  bool get pro => plan == 'pro';
  bool get familyMode => profile['mode'] == 'family';
  bool get onboarded => profile['onboarded'] == true;

  /// Как показывать ориентир на главной: `daily` — доля на сегодня (по
  /// умолчанию), `total` — вся сумма, свободная до зарплаты/конца месяца.
  /// Хранится в уже заведённом на сервере ключе `budgetMethod`.
  String get guideView => profile['budgetMethod'] as String? ?? 'daily';
  Future<void> setGuideView(String v) => send({'type': 'updateProfile', 'profile': {'budgetMethod': v}});

  /// Дневной лимит повседневных трат, тиыны; задаёт сам владелец (D48).
  /// `null` — не задан. Расчёт по формуле 9.3 — только подсказка.
  int? get dailyLimit => profile['dailyLimit'] == null ? null : parseMinor(profile['dailyLimit']);

  /// С какого дня копится перенос неизрасходованного лимита (D64). Задаётся
  /// один раз при включении лимита и не двигается при смене суммы — так
  /// перенос не сбрасывается, если владелец просто поправил число.
  DateTime? get dailyLimitSince => profile['dailyLimitSince'] == null ? null : dateFromJson(profile['dailyLimitSince']);

  /// Меняет сумму лимита. Включение лимита (был не задан) запускает перенос
  /// с сегодняшнего дня; выключение — снимает перенос совсем.
  Future<void> setDailyLimit(int? minor) => send({
        'type': 'updateProfile',
        'profile': {
          'dailyLimit': minor?.toString(),
          if (minor == null) 'dailyLimitSince': null else if (dailyLimit == null) 'dailyLimitSince': _date(today),
        },
      });

  /// Обнулить перенос: начать копить заново с сегодняшнего дня, сумму
  /// лимита не трогая. Для «слишком большой минус, хочу начать с нуля».
  Future<void> resetDailyLimitCarry() => send({'type': 'updateProfile', 'profile': {'dailyLimitSince': _date(today)}});

  /// Встроенные категории, скрытые из выбора (свои удаляются иначе — см. D41).
  Set<String> get hiddenCategories => {...((profile['hiddenCategories'] as List?) ?? const []).cast<String>()};

  Future<void> setCategoryHidden(String id, bool hidden) {
    if (id == 'other' || id == 'otherIncome') return Future.value();
    final ids = {...hiddenCategories};
    hidden ? ids.add(id) : ids.remove(id);
    return send({'type': 'updateProfile', 'profile': {'hiddenCategories': ids.toList()..sort()}});
  }

  /// Категории для выбора: свои — всегда, встроенные — без скрытых.
  List<CategoryDef> get visibleExpenseCategories => expenseCategories.where((c) => c.isCustom || !hiddenCategories.contains(c.id)).toList();
  List<CategoryDef> get visibleIncomeCategories => incomeCategories.where((c) => c.isCustom || !hiddenCategories.contains(c.id)).toList();

  // ------------------------------------------------------------ загрузка

  Future<void> load() async {
    try {
      applySnapshot(await api.state(token));
      loadError = null;
    } catch (e) {
      loadError = e;
    }
    loaded = true;
    notifyListeners();
  }

  void applySnapshot(Map<String, dynamic> s) {
    ledger = ledgerFromSnapshot(
      accounts: (s['accounts'] as List).cast(),
      transactions: (s['transactions'] as List).cast(),
      reservations: (s['reservations'] as List).cast(),
    );
    plan = s['plan'] as String? ?? 'free';
    proUntil = s['proUntil'] == null ? null : DateTime.parse(s['proUntil'] as String).toLocal();
    email = s['email'] as String? ?? '';
    name = s['name'] as String?;
    profile = Map<String, dynamic>.from(s['profile'] as Map? ?? const {});
    revision = s['revision'] as int? ?? 0;
    _entities.clear();
    for (final e in (s['entities'] as List).cast<Map<String, dynamic>>()) {
      _entities.putIfAbsent(e['kind'] as String, () => {})[e['id'] as String] = Map<String, dynamic>.from(e['data'] as Map);
    }
    _syncCategories();
  }

  void _syncCategories() {
    customCategories
      ..clear()
      ..addEntries([for (final e in _kind('category').entries) MapEntry(e.key, customCategoryFromJson(e.key, e.value))]);
  }

  /// Команд отправлено, ответа сервера ещё нет.
  int _ahead = 0;

  /// Есть запрос в полёте — для полоски загрузки.
  bool get busy => _ahead > 0;

  /// Сервер — источник правды (D24): команда сначала принимается сервером
  /// и только потом применяется к локальному журналу. Без ответа сервера
  /// экран не меняется — при обрыве связи не появляется «призрачный»
  /// остаток. [commandId] задаёт форма и повторяет при повторной отправке:
  /// сервер не применит команду дважды, а клиент перечитает состояние.
  Future<void> send(Map<String, dynamic> command, {String? commandId}) async {
    _ahead++;
    notifyListeners();
    try {
      final r = await api.command(token, {...command, 'commandId': commandId ?? newId()});
      if (r.repeated || r.revision != revision + 1) {
        // Повтор уже принятой команды или изменения с другого устройства —
        // берём состояние сервера целиком.
        await _reload();
      } else {
        try {
          _applyLocal(command);
          revision = r.revision;
        } catch (_) {
          await _reload();
        }
      }
    } finally {
      _ahead--;
      notifyListeners();
    }
  }

  Future<void> sendBatch(List<Map<String, dynamic>> commands, {String? commandId}) =>
      send({'type': 'batch', 'commands': commands}, commandId: commandId);

  Future<void> _reload() async => applySnapshot(await api.state(token));

  void _applyLocal(Map<String, dynamic> c) {
    switch (c['type']) {
      case 'batch':
        for (final item in (c['commands'] as List).cast<Map<String, dynamic>>()) {
          _applyLocal(item);
        }
      case 'upsertEntity':
        _entities.putIfAbsent(c['kind'] as String, () => {})[c['entityId'] as String] = Map<String, dynamic>.from(c['data'] as Map);
        if (c['kind'] == 'category') _syncCategories();
      case 'deleteEntity':
        _entities[c['kind']]?.remove(c['entityId']);
        if (c['kind'] == 'category') _syncCategories();
      case 'updateProfile':
        profile = {...profile, ...(c['profile'] as Map).cast<String, dynamic>()};
      default:
        applyLedgerCommand(ledger, c);
    }
  }

  /// Перечитать состояние с сервера (после оплаты Pro и т.п.).
  Future<void> refresh() async {
    await _reload();
    notifyListeners();
  }

  // ---------------------------------------------------------- справочники

  Map<String, Map<String, dynamic>> _kind(String k) => _entities[k] ?? const {};

  List<AccountInfo> get moneyAccounts {
    final list = <AccountInfo>[];
    var i = 0;
    for (final a in ledger.accounts) {
      if (!a.isMoney) continue;
      final meta = _kind('account')[a.id] ?? const {};
      list.add(AccountInfo(
        id: a.id,
        name: meta['name'] as String? ?? a.id,
        type: meta['type'] as String? ?? 'card',
        color: Color((meta['color'] as num?)?.toInt() ?? accountPalette[i % accountPalette.length]),
        liquid: a.liquid,
        archived: a.archived,
        owner: meta['owner'] as String?,
      ));
      i++;
    }
    return list;
  }

  /// Кому принадлежит счёт (D08 продолжение): `me`, `shared` или id члена
  /// семьи; `null` снимает привязку. Форма операции подставляет «для кого»
  /// по счёту, чтобы не задавать одно и то же дважды.
  Future<void> setAccountOwner(String accountId, String? owner) {
    final data = Map<String, dynamic>.from(_kind('account')[accountId] ?? const {});
    if (owner == null) {
      data.remove('owner');
    } else {
      data['owner'] = owner;
    }
    return upsert('account', accountId, data);
  }

  /// Счета для трат и переводов — без архивных и без копилок целей.
  List<AccountInfo> get activeAccounts => moneyAccounts.where((a) => !a.archived && a.type != piggyType).toList();

  /// Копилки целей: пополняются переводом, в дневной лимит не входят.
  List<AccountInfo> get piggyAccounts => moneyAccounts.where((a) => !a.archived && a.type == piggyType).toList();

  AccountInfo? accountInfo(String id) => moneyAccounts.where((a) => a.id == id).firstOrNull;

  List<Member> get members => [for (final e in _kind('member').entries) Member.fromJson(e.key, e.value)];
  List<LimitInfo> get limits => [for (final e in _kind('limit').entries) LimitInfo.fromJson(e.key, e.value)];
  List<GoalInfo> get goals => [for (final e in _kind('goal').entries) GoalInfo.fromJson(e.key, e.value)];
  List<PlannedInfo> get planned => [for (final e in _kind('planned').entries) PlannedInfo.fromJson(e.key, e.value)];
  List<DebtInfo> get bankDebts => [for (final e in _kind('debt').entries) DebtInfo.fromJson(e.key, e.value)];
  List<QuickAction> get quickActions => [for (final e in _kind('quick').entries) QuickAction.fromJson(e.key, e.value)];

  DebtInfo? bankDebt(String id) => bankDebts.where((d) => d.id == id).firstOrNull;

  /// Личные долги: требования и обязательства, не относящиеся к банкам.
  List<PersonDebt> get personDebts {
    final banks = {for (final d in bankDebts) d.id};
    final list = <PersonDebt>[];
    for (final a in ledger.accounts) {
      final isRecv = a.assetClass == AssetClass.receivable;
      final isLiab = a.kind == LedgerKind.liability;
      if (!isRecv && !isLiab) continue;
      final name = a.id.substring(a.id.indexOf(':') + 1);
      if (isLiab && banks.contains(name)) continue;
      final b = ledger.balance(a.id);
      if (b != 0) list.add(PersonDebt(name, isRecv, b));
    }
    return list;
  }

  List<String> get knownPeople => {for (final d in personDebts) d.person}.toList();

  int debtBalance(String debtId) {
    final id = liabilityAccount(debtId);
    return ledger.hasAccount(id) ? ledger.balance(id) : 0;
  }

  int get totalBankDebt => bankDebts.fold(0, (s, d) => s + debtBalance(d.id));

  // ---------------------------------------------------------------- запросы

  DateTime get monthStart => DateTime(today.year, today.month, 1);
  DateTime get monthEnd => DateTime(today.year, today.month + 1, 1);
  int get daysInMonth => monthEnd.difference(monthStart).inDays;

  List<Transaction> get userTransactions {
    final txs = ledger.transactions;
    final index = {for (var i = 0; i < txs.length; i++) txs[i].id: i};
    final list = txs
        .where((t) => t.type != EventType.reversal && !ledger.isReversed(t.id) && !(t.type == EventType.opening && t.postings.every((p) => !ledger.account(p.accountId).isMoney)))
        .toList()
      ..sort((a, b) {
        final byDate = b.date.compareTo(a.date);
        return byDate != 0 ? byDate : index[b.id]!.compareTo(index[a.id]!);
      });
    return list;
  }

  /// Полная история: все записи, включая отменённые и отменяющие.
  /// Для аудита — пользователь видит, что и когда было исправлено.
  List<Transaction> get fullHistory {
    final txs = ledger.transactions;
    final index = {for (var i = 0; i < txs.length; i++) txs[i].id: i};
    return txs.where((t) => !(t.type == EventType.opening && t.postings.every((p) => !ledger.account(p.accountId).isMoney))).toList()
      ..sort((a, b) {
        final byDate = b.date.compareTo(a.date);
        return byDate != 0 ? byDate : index[b.id]!.compareTo(index[a.id]!);
      });
  }

  PeriodReport get monthReport => ledger.report(monthStart, monthEnd);

  int get monthDebtPayouts {
    var sum = 0;
    for (final tx in ledger.transactions) {
      if (tx.date.isBefore(monthStart) || !tx.date.isBefore(monthEnd)) continue;
      if (tx.type != EventType.loanPayment && tx.type != EventType.repaymentMade) continue;
      if (ledger.isReversed(tx.id)) continue;
      for (final p in tx.postings) {
        if (ledger.account(p.accountId).kind == LedgerKind.liability) sum -= p.amount;
      }
    }
    return sum;
  }

  /// День, к которому относится трата. Возврат уменьшает траты того дня,
  /// когда была покупка, а не дня возврата: вернули вчерашний кофе —
  /// вчерашние расходы уменьшились, сегодняшний лимит не тронут.
  /// `null` — возврат по удалённой покупке: в дневные траты не входит
  /// (деньги на счёте он всё равно учитывает).
  DateTime? _spendDay(Transaction t) {
    if (t.type == EventType.refund) {
      final of = t.meta['refundOf'];
      if (of is String) return ledger.currentVersion(of)?.date;
    }
    return t.date;
  }

  /// Покупка — оплата планового платежа (или возврат по ней): в дневной
  /// бюджет не входит, обязательство уже учтено отдельно (раздел 9.3, T33).
  bool _isPlannedSpend(Transaction t) {
    if (t.meta['planned'] != null) return true;
    final of = t.meta['refundOf'];
    return t.type == EventType.refund && of is String && (ledger.currentVersion(of) ?? ledger.byId(of))?.meta['planned'] != null;
  }

  /// Повседневные траты из дневного бюджета за [from]–[to] включительно:
  /// покупки минус возвраты по покупкам этих дней (возврат считается по дню
  /// покупки, не по дню самого возврата — см. `_spendDay`).
  int spentBetween(DateTime from, DateTime to) {
    var sum = 0;
    for (final tx in ledger.transactions) {
      if ((tx.type != EventType.expense && tx.type != EventType.refund) || ledger.isReversed(tx.id)) continue;
      final day = _spendDay(tx); // возврат по удалённой покупке даёт null и сюда не попадает
      if (day == null || day.isBefore(from) || day.isAfter(to) || _isPlannedSpend(tx)) continue;
      for (final p in tx.postings) {
        if (ledger.account(p.accountId).kind == LedgerKind.expense) sum += p.amount;
      }
    }
    return sum < 0 ? 0 : sum;
  }

  /// Сегодняшние повседневные траты из дневного бюджета.
  int spentToday() => spentBetween(today, today);

  /// Сколько доступно сегодня с учётом переноса (D64): за каждый день с
  /// начала копления (`dailyLimitSince`) лимит либо остаётся неизрасходован
  /// и добавляется к завтрашнему дню, либо превышен — и настолько же
  /// уменьшает доступное на будущее. Эквивалентно «выдано лимитов за N дней
  /// минус потрачено за N дней»; ежедневно ничего не сохраняется отдельно —
  /// значение всегда считается заново по журналу.
  int? get dailyLimitAvailable {
    final limit = dailyLimit;
    if (limit == null) return null;
    final since = dailyLimitSince ?? today;
    final days = today.difference(since.isAfter(today) ? today : since).inDays + 1;
    return limit * days - spentBetween(since, today);
  }

  /// Вклад прошлых дней в сегодняшнее доступное: положительный — прошлые
  /// дни сэкономили и добавили сегодня, отрицательный — прошлый перерасход
  /// уменьшил сегодняшнюю сумму. `0` в первый день лимита или без переноса.
  int get dailyLimitCarry {
    final limit = dailyLimit;
    final available = dailyLimitAvailable;
    if (limit == null || available == null) return 0;
    return available - (limit - spentToday());
  }

  static DateTime _onDay(int year, int month, int day) {
    final last = DateTime(year, month + 1, 0).day;
    return DateTime(year, month, day.clamp(1, last));
  }

  static String _period(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}';

  /// Дата следующего основного дохода. Без даты — первое число следующего месяца.
  DateTime get nextIncomeDate {
    final day = (profile['incomeDay'] as num?)?.toInt();
    if (day == null) return monthEnd;
    final thisMonth = _onDay(today.year, today.month, day);
    return thisMonth.isAfter(today) ? thisMonth : _onDay(today.year, today.month + 1, day);
  }

  int get daysToIncome => nextIncomeDate.difference(today).inDays;

  bool get hasPayDay => profile['incomeDay'] != null;

  /// Неоплаченные сроки: все прошлые с даты добавления платежа (просрочка не
  /// исчезает при смене месяца, пока срок не оплачен или не отмечен) и
  /// будущие до [until].
  List<DueItem> dueItems(DateTime until) {
    final items = <DueItem>[];
    final todayIdx = today.year * 12 + today.month - 1;
    for (final p in planned) {
      final from = p.start ?? monthStart;
      // Не раньше 10 лет назад и не дальше двух месяцев вперёд.
      final startIdx = (from.year * 12 + from.month - 1).clamp(todayIdx - 120, todayIdx + 2);
      for (var i = startIdx; i <= todayIdx + 2; i++) {
        final date = _onDay(i ~/ 12, i % 12 + 1, p.day);
        if (date.isAfter(until)) break;
        if (p.start != null && date.isBefore(p.start!)) continue;
        final period = _period(date);
        if (p.paid.contains(period)) continue;
        items.add(DueItem(p, date, period));
      }
    }
    items.sort((a, b) => a.date.compareTo(b.date));
    return items;
  }

  List<DueItem> get upcoming => dueItems(today.add(const Duration(days: 31)));

  /// C0: обязательства до следующего дохода, ещё не оплаченные.
  int get obligationsUntilIncome =>
      dueItems(nextIncomeDate.subtract(const Duration(days: 1))).fold(0, (s, d) => s + d.planned.amount);

  int get liquidReserves {
    var sum = 0;
    for (final r in ledger.reservations) {
      if (ledger.account(r.accountId).liquid) sum += r.amount;
    }
    return sum;
  }

  /// L0 — ликвидные деньги на начало дня: сегодняшние траты возвращаются
  /// в базу, иначе дневная норма уменьшалась бы после каждой покупки (T22).
  int get liquidAtDayStart => ledger.liquid() + spentToday();

  DailyGuide get guide => dailyGuide(
        liquid: liquidAtDayStart,
        reserves: liquidReserves,
        obligations: obligationsUntilIncome,
        savingsPlan: 0,
        days: daysToIncome,
        spentToday: spentToday(),
      );

  int spentInCategory(String category) =>
      ledger.expenseByCategory(monthStart, monthEnd)[expenseAccount(category)] ?? 0;

  LimitStatus limitStatusFor(LimitInfo def) => limitStatus(
        spent: spentInCategory(def.category),
        limit: def.amount,
        elapsedFullDays: today.day - 1,
        periodDays: daysInMonth,
      );

  /// Накоплено по цели: остаток копилки плюс старые резервы.
  int goalSaved(GoalInfo g) =>
      (g.account != null && ledger.hasAccount(g.account!) ? ledger.balance(g.account!) : 0) + ledger.reserved(goalId: g.id);

  GoalStatus goalStatusFor(GoalInfo g) {
    int? months;
    if (g.deadline != null) {
      final d = g.deadline!;
      months = (d.year - today.year) * 12 + d.month - today.month;
      if (months < 1) months = 1;
    }
    return goalStatus(
      saved: goalSaved(g),
      target: g.target,
      plannedContributionsLeft: months ?? 0,
    );
  }

  // ------------------------------------------------------------- периоды

  /// Первый день месяца со сдвигом от текущего: 0 — этот, −1 — прошлый.
  DateTime monthOf(int offset) => DateTime(today.year, today.month + offset, 1);

  PeriodReport reportFor(DateTime monthStart) =>
      ledger.report(monthStart, DateTime(monthStart.year, monthStart.month + 1, 1));

  /// Расход по категориям месяца: id категории → сумма, по убыванию.
  List<MapEntry<String, int>> categoriesFor(DateTime monthStart) {
    final raw = ledger.expenseByCategory(monthStart, DateTime(monthStart.year, monthStart.month + 1, 1));
    final list = [for (final e in raw.entries) if (e.value != 0) MapEntry(e.key.substring(8), e.value)]
      ..sort((a, b) => b.value.compareTo(a.value));
    return list;
  }

  /// Расход по дням месяца: индекс 0 — первое число.
  List<int> dailyExpense(DateTime monthStart) {
    final days = DateTime(monthStart.year, monthStart.month + 1, 0).day;
    final out = List<int>.filled(days, 0);
    final end = DateTime(monthStart.year, monthStart.month + 1, 1);
    for (final tx in ledger.transactions) {
      if (ledger.isReversed(tx.id) || tx.type == EventType.reversal) continue;
      final day = _spendDay(tx); // возврат — к дню покупки
      if (day == null || day.isBefore(monthStart) || !day.isBefore(end)) continue;
      for (final p in tx.postings) {
        if (ledger.account(p.accountId).kind == LedgerKind.expense) out[day.day - 1] += p.amount;
      }
    }
    return out;
  }

  /// Расход месяца по отметке «для кого».
  Map<String, int> expenseByWho(DateTime monthStart) {
    final end = DateTime(monthStart.year, monthStart.month + 1, 1);
    final out = <String, int>{};
    for (final tx in userTransactions) {
      if (tx.type != EventType.expense || tx.date.isBefore(monthStart) || !tx.date.isBefore(end)) continue;
      final who = tx.meta['who'] as String? ?? 'me';
      final sum = tx.postings.where((p) => ledger.account(p.accountId).kind == LedgerKind.expense).fold(0, (s, p) => s + p.amount);
      out.update(who, (v) => v + sum, ifAbsent: () => sum);
    }
    return out;
  }

  /// Операции месяца, затронувшие категорию расхода.
  List<Transaction> categoryTransactions(String category, DateTime monthStart) {
    final end = DateTime(monthStart.year, monthStart.month + 1, 1);
    final acc = expenseAccount(category);
    return userTransactions
        .where((t) => !t.date.isBefore(monthStart) && t.date.isBefore(end) && t.postings.any((p) => p.accountId == acc))
        .toList();
  }

  /// Операции по долгу: банковскому (`debtId`) или человеку.
  List<Transaction> debtTransactions(String accountId) =>
      userTransactions.where((t) => t.postings.any((p) => p.accountId == accountId)).toList();

  /// Плановый платёж, привязанный к кредиту.
  PlannedInfo? plannedForDebt(String debtId) => planned.where((p) => p.debtId == debtId).firstOrNull;

  // ------------------------------------------------------------- команды

  String _date(DateTime d) => dateToJson(d);

  /// [time] — часы:минуты «HH:mm», когда операция произошла на самом деле;
  /// на дневной бюджет и отчёты не влияет, только показывается и правится.
  /// [id] и [commandId] форма создаёт один раз на попытку сохранения и
  /// повторяет при ошибке сети — повтор не создаёт вторую запись.
  Future<void> addExpense({required int amount, required String category, required String account, required DateTime date, String who = 'me', String note = '', String? time, String? id, String? commandId}) =>
      send({'type': 'expense', 'id': id ?? newId(), 'date': _date(date), 'account': account, 'splits': {category: amount.toString()}, 'meta': {'who': who, if (note.isNotEmpty) 'note': note, if (time != null) 'time': time}}, commandId: commandId);

  Future<void> addIncome({required int amount, required String source, required String account, required DateTime date, String note = '', String? time, String? id, String? commandId}) =>
      send({'type': 'income', 'id': id ?? newId(), 'date': _date(date), 'account': account, 'source': source, 'amount': amount.toString(), 'meta': {if (note.isNotEmpty) 'note': note, if (time != null) 'time': time}}, commandId: commandId);

  Future<void> addTransfer({required int amount, required String from, required String to, required DateTime date, String? time, String? id, String? commandId}) =>
      send({'type': 'transfer', 'id': id ?? newId(), 'date': _date(date), 'from': from, 'to': to, 'amount': amount.toString(), if (time != null) 'meta': {'time': time}}, commandId: commandId);

  /// `kind`: lendOut, borrow, repaymentReceived, repaymentMade.
  Future<void> addPersonDebt({required String kind, required int amount, required String person, required String account, required DateTime date, String? time, String? id, String? commandId}) {
    final isRepayment = kind == 'repaymentReceived' || kind == 'repaymentMade';
    return send({
      'type': kind,
      'id': id ?? newId(),
      'date': _date(date),
      'account': account,
      'person': person,
      if (isRepayment) 'principal': amount.toString() else 'amount': amount.toString(),
      if (time != null) 'meta': {'time': time},
    }, commandId: commandId);
  }

  Future<void> payDebt({required String debtId, required String account, required int principal, int interest = 0, DateTime? date}) =>
      send({'type': 'loanPayment', 'id': newId(), 'date': _date(date ?? today), 'account': account, 'debtId': debtId, 'principal': principal.toString(), 'interest': interest.toString()});

  /// Оплата срока планового платежа: факт и отметка «оплачено» — одной
  /// командой. Запись помнит платёж и период (`meta.planned`, `meta.period`),
  /// чтобы её удаление снова открыло срок.
  Future<void> payDue(DueItem due, {required String account, required int amount, int interest = 0, DateTime? date, String? commandId}) {
    final p = due.planned;
    final d = _date(date ?? today);
    final link = {'planned': p.id, 'period': due.period};
    final fact = p.debtId != null
        ? {'type': 'loanPayment', 'id': newId(), 'date': d, 'account': account, 'debtId': p.debtId, 'principal': (amount - interest).toString(), 'interest': interest.toString(), 'meta': link}
        : {'type': 'expense', 'id': newId(), 'date': d, 'account': account, 'splits': {p.category: amount.toString()}, 'meta': {'who': 'shared', 'note': p.name, ...link}};
    return sendBatch([
      fact,
      {'type': 'upsertEntity', 'kind': 'planned', 'entityId': p.id, 'data': p.toJson(paid: {...p.paid, due.period})},
    ], commandId: commandId);
  }

  /// Исправление покупки: старая версия отменяется, новая проводится —
  /// одной командой, история сохраняется (F032).
  Future<void> editExpense(Transaction old, {required Map<String, int> splits, required String account, required DateTime date, required String who, required String note, String? time}) =>
      sendBatch([
        {'type': 'reverse', 'txId': old.id, 'id': newId()},
        {
          'type': 'expense',
          'id': newId(),
          'date': _date(date),
          'account': account,
          'splits': {for (final e in splits.entries) e.key: e.value.toString()},
          'meta': {...old.meta, 'who': who, 'note': note, if (time != null) 'time': time, 'edited': old.id}..removeWhere((k, v) => v == null || v == ''),
        },
      ]);

  Future<void> editIncome(Transaction old, {required int amount, required String source, required String account, required DateTime date, required String note, String? time}) =>
      sendBatch([
        {'type': 'reverse', 'txId': old.id, 'id': newId()},
        {'type': 'income', 'id': newId(), 'date': _date(date), 'account': account, 'source': source, 'amount': amount.toString(), 'meta': {if (note.isNotEmpty) 'note': note, if (time != null) 'time': time, 'edited': old.id}},
      ]);

  /// Возврат покупки на счёт (F028): уменьшает расход категории в дату
  /// возврата. Привязывается к исходной версии покупки, поэтому правка
  /// покупки не открывает возврат заново; лимит проверяет ядро и сервер.
  Future<void> refund(Transaction purchase, {required String category, required int amount, required String account, DateTime? date, String? commandId}) =>
      send({'type': 'refund', 'id': newId(), 'date': _date(date ?? today), 'category': category, 'amount': amount.toString(), 'toAccount': account, 'meta': {'refundOf': ledger.purchaseRoot(purchase.id)}}, commandId: commandId);

  /// Сколько по покупке уже возвращено в категории — по всем версиям покупки.
  int refundedFor(String purchaseId, String category) => ledger.refundedFor(purchaseId, expenseAccount(category));

  /// Сверка остатка (O21): разница между фактическим остатком и остатком в
  /// приложении проводится отдельной записью с причиной.
  Future<void> adjustBalance({required String account, required int actualBalance, required String reason, DateTime? date}) {
    final delta = actualBalance - ledger.balance(account);
    if (delta == 0) return Future.value();
    return send({'type': 'adjustment', 'id': newId(), 'date': _date(date ?? today), 'account': account, 'delta': delta.toString(), 'reason': reason});
  }

  int adjustmentsFor(DateTime monthStart) => ledger.adjustmentsFor(monthStart, DateTime(monthStart.year, monthStart.month + 1, 1));
  int get monthAdjustments => adjustmentsFor(monthStart);

  Future<void> changePassword(String current, String next) => api.changePassword(token, current, next);

  /// Удаление — отменяющая запись, история сохраняется. Если удаляется
  /// оплата планового платежа, её срок снова становится неоплаченным.
  Future<void> deleteTransaction(String txId, {String? commandId}) {
    final reverse = {'type': 'reverse', 'txId': txId, 'id': newId()};
    final tx = ledger.byId(txId);
    // Покупку с действующим возвратом удалять нельзя: деньги вернулись бы
    // дважды. Сначала удаляется возврат.
    if (tx != null && tx.type == EventType.expense && tx.postings.any((p) => p.accountId.startsWith('expense:') && ledger.refundedFor(txId, p.accountId) > 0)) {
      return Future.error(LedgerException('Сначала удалите возврат по этой покупке', code: 'hasRefunds'));
    }
    final plannedId = tx?.meta['planned'];
    if (tx != null && plannedId is String) {
      final p = planned.where((p) => p.id == plannedId).firstOrNull;
      final period = tx.meta['period'] as String? ?? _period(tx.date);
      if (p != null && p.paid.contains(period)) {
        return sendBatch([
          reverse,
          {'type': 'upsertEntity', 'kind': 'planned', 'entityId': p.id, 'data': p.toJson(paid: {...p.paid}..remove(period))},
        ], commandId: commandId);
      }
    }
    return send(reverse, commandId: commandId);
  }

  /// Восстановление удалённой операции (корзина): та же запись заново, с
  /// пометкой `restoredFrom`. Оплата планового платежа снова отмечает срок.
  Future<void> restoreTransaction(String txId, {String? commandId}) {
    final restore = {'type': 'restore', 'txId': txId, 'id': newId()};
    final tx = ledger.byId(txId);
    final plannedId = tx?.meta['planned'];
    if (tx != null && plannedId is String) {
      final p = planned.where((p) => p.id == plannedId).firstOrNull;
      final period = tx.meta['period'] as String? ?? _period(tx.date);
      if (p != null && !p.paid.contains(period)) {
        return sendBatch([
          restore,
          {'type': 'upsertEntity', 'kind': 'planned', 'entityId': p.id, 'data': p.toJson(paid: {...p.paid, period})},
        ], commandId: commandId);
      }
    }
    return send(restore, commandId: commandId);
  }

  /// Удалённые операции (корзина): отменённые и ещё не восстановленные.
  List<Transaction> get deletedTransactions => fullHistory.where((t) => ledger.isDeleted(t.id)).toList();

  Future<void> reserve(String goalId, String account, int amount) =>
      send({'type': 'reserve', 'goalId': goalId, 'accountId': account, 'amount': amount.toString()});

  Future<void> release(String goalId, String account, int amount) =>
      send({'type': 'release', 'goalId': goalId, 'accountId': account, 'amount': amount.toString()});

  /// Команды новой цели: копилка (отдельный счёт) плюс описание цели.
  List<Map<String, dynamic>> newGoalCommands({required String name, required int target, DateTime? deadline}) {
    final id = newId();
    final acc = 'piggy$id';
    return [
      {'type': 'addMoneyAccount', 'accountId': acc, 'liquid': false},
      {'type': 'upsertEntity', 'kind': 'account', 'entityId': acc, 'data': {'name': name, 'type': piggyType, 'goalId': id, 'color': 0xFFE0A43A}},
      {'type': 'upsertEntity', 'kind': 'goal', 'entityId': id, 'data': GoalInfo(id, name, target, deadline, account: acc).toJson()},
    ];
  }

  /// Отложить в копилку: обычный перевод со своего счёта.
  Future<void> depositToGoal(GoalInfo g, {required String from, required int amount, DateTime? date}) =>
      send({'type': 'transfer', 'id': newId(), 'date': _date(date ?? today), 'from': from, 'to': g.account!, 'amount': amount.toString()});

  /// Забрать из копилки обратно на счёт.
  Future<void> withdrawFromGoal(GoalInfo g, {required String to, required int amount, DateTime? date}) =>
      send({'type': 'transfer', 'id': newId(), 'date': _date(date ?? today), 'from': g.account!, 'to': to, 'amount': amount.toString()});

  /// Закрыть цель: деньги из копилки возвращаются на счёт, копилка в архив.
  Future<void> closeGoal(GoalInfo g, {required String returnTo}) {
    final acc = g.account;
    final balance = acc != null && ledger.hasAccount(acc) ? ledger.balance(acc) : 0;
    return sendBatch([
      if (acc != null && balance > 0) {'type': 'transfer', 'id': newId(), 'date': _date(today), 'from': acc, 'to': returnTo, 'amount': balance.toString()},
      for (final r in ledger.reservations.where((r) => r.goalId == g.id))
        {'type': 'release', 'goalId': g.id, 'accountId': r.accountId, 'amount': r.amount.toString()},
      if (acc != null && ledger.hasAccount(acc)) {'type': 'archiveAccount', 'accountId': acc},
      {'type': 'deleteEntity', 'kind': 'goal', 'entityId': g.id},
    ]);
  }

  // ---------------------------------------------------------- категории

  List<CategoryDef> get ownCategories => customCategories.values.toList();

  /// Категория используется в журнале — удалять нельзя, иначе история потеряет подпись.
  bool categoryInUse(String id) => ledger.hasAccount(expenseAccount(id)) || ledger.hasAccount(incomeAccount(id));

  Future<String> addCategory({required String name, required int iconIndex, required bool income}) async {
    final id = 'c${newId().substring(0, 12)}';
    await upsert('category', id, {'name': name, 'icon': iconIndex, 'income': income});
    return id;
  }

  Future<void> releaseAllAndDeleteGoal(String goalId) => sendBatch([
        for (final r in ledger.reservations.where((r) => r.goalId == goalId))
          {'type': 'release', 'goalId': goalId, 'accountId': r.accountId, 'amount': r.amount.toString()},
        {'type': 'deleteEntity', 'kind': 'goal', 'entityId': goalId},
      ]);

  Future<void> upsert(String kind, String id, Map<String, Object?> data) =>
      send({'type': 'upsertEntity', 'kind': kind, 'entityId': id, 'data': data});

  Future<void> delete(String kind, String id) => send({'type': 'deleteEntity', 'kind': kind, 'entityId': id});

  Future<void> setFamilyMode(bool family) => send({'type': 'updateProfile', 'profile': {'mode': family ? 'family' : 'personal'}});

  Future<void> setIncomeDay(int? day) => send({'type': 'updateProfile', 'profile': {'incomeDay': day}});

  /// Команды нового денежного счёта с начальным остатком.
  List<Map<String, dynamic>> newAccountCommands({required String name, required String type, required int balance, int? color, String? owner}) {
    final id = newId();
    return [
      {'type': 'addMoneyAccount', 'accountId': id, 'liquid': type != 'deposit'},
      {
        'type': 'upsertEntity',
        'kind': 'account',
        'entityId': id,
        'data': {'name': name, 'type': type, 'color': color ?? accountPalette[moneyAccounts.length % accountPalette.length], if (owner != null) 'owner': owner},
      },
      if (balance != 0) {'type': 'opening', 'id': newId(), 'date': _date(today), 'account': id, 'amount': balance.toString()},
    ];
  }

  /// С какой даты считать сроки нового платежа. Если дата в этом месяце уже
  /// прошла и платёж ещё не сделан — с начала месяца, чтобы срок был виден.
  DateTime plannedStart(int day, {required bool paidThisMonth}) =>
      day < today.day && !paidThisMonth ? monthStart : today;

  /// Команды существующего кредита: условия, остаток и плановый платёж.
  List<Map<String, dynamic>> newBankDebtCommands({required String name, required String kind, required int balance, required int payment, required int day, double rate = 0, bool paidThisMonth = true}) {
    final id = newId();
    return [
      {'type': 'upsertEntity', 'kind': 'debt', 'entityId': id, 'data': DebtInfo(id, name, kind, rate).toJson()},
      if (balance > 0) {'type': 'openingDebt', 'id': newId(), 'date': _date(today), 'debtId': id, 'amount': balance.toString()},
      if (payment > 0)
        {'type': 'upsertEntity', 'kind': 'planned', 'entityId': newId(), 'data': PlannedInfo('', name, payment, day, 'other', id, const {}, start: plannedStart(day, paidThisMonth: paidThisMonth)).toJson()},
    ];
  }
}
