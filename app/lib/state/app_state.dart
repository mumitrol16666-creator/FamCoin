/// Данные владельца: журнал, справочники, профиль.
///
/// Источник правды — сервер. Команда сначала принимается сервером, затем
/// та же команда применяется к локальному журналу функцией из
/// `famcoin_core`, поэтому числа на экране совпадают с сервером.
/// Расчёты — только в ядре.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';

import 'api_client.dart';
import 'models.dart';

class AppState extends ChangeNotifier {
  AppState({required this.api, required this.token, DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final ApiClient api;
  final String token;
  final DateTime Function() _clock;

  Timer? _dayTimer;
  DateTime? _observedDay;

  /// В открытом приложении дата сама по себе не вызывает перерисовку.
  /// Следим за местной полуночью, чтобы «сегодня» и текущий месяц обновились
  /// даже без операций и сети. Запускается один раз при создании сессии.
  void startDayUpdates() {
    _observedDay ??= today;
    checkDayChange();
  }

  /// Вызывается также при возвращении из фона: телефон мог усыпить таймер,
  /// а человек — сменить часовой пояс. Прошлый перенос не сбрасываем:
  /// формулы просто пересчитываются на новую календарную дату.
  void checkDayChange() {
    if (_observedDay == null) return;
    final now = _clock();
    final day = DateTime(now.year, now.month, now.day);
    final changed = day != _observedDay;
    _observedDay = day;
    _dayTimer?.cancel();
    final midnight = DateTime(now.year, now.month, now.day + 1);
    _dayTimer = Timer(midnight.difference(now), checkDayChange);
    if (changed) notifyListeners();
  }

  @override
  void dispose() {
    _dayTimer?.cancel();
    _observedDay = null;
    super.dispose();
  }

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

  /// Переносить ли остаток дневного лимита на следующий день (D70). Пока
  /// владелец не включил переключатель — выключено.
  bool get dailyLimitCarryOn => profile['dailyLimitCarry'] == true;

  /// Включение начинает перенос с сегодняшнего дня: старый накопленный
  /// плюс или минус не «оживает» после выключения и повторного включения.
  Future<void> setDailyLimitCarryOn(bool on) {
    final limit = dailyLimit;
    return send({
      'type': 'updateProfile',
      'profile': {
        'dailyLimitCarry': on,
        if (on) 'dailyLimitSince': _date(today),
        if (on && limit != null) 'dailyLimitHistory': _historyJson([(from: today, amount: limit)]),
      },
    });
  }

  /// История суммы лимита по датам (D71): каждая запись действует со своей
  /// даты до следующей. Поэтому смена суммы не пересчитывает прошлые дни по
  /// новой ставке: без истории переход с 5 000 на 8 000 ₸ на десятый день
  /// переноса добавил бы 30 000 ₸, которых никто не выдавал.
  List<({DateTime from, int amount})> get dailyLimitHistory => dailyLimitHistoryOf(profile);

  List<Map<String, String>> _historyJson(List<({DateTime from, int amount})> h) =>
      [for (final e in h) {'from': _date(e.from), 'amount': e.amount.toString()}];

  /// Записи, целиком лежащие до начала переноса, не нужны — кроме той,
  /// что действовала в его первый день.
  static List<({DateTime from, int amount})> _pruned(List<({DateTime from, int amount})> h, DateTime since) {
    final inEffect = h.lastIndexWhere((e) => !e.from.isAfter(since));
    return inEffect <= 0 ? h : h.sublist(inEffect);
  }

  /// Меняет сумму лимита с сегодняшнего дня. Включение лимита (был не задан)
  /// запускает перенос с сегодняшнего дня; выключение — снимает перенос совсем.
  Future<void> setDailyLimit(int? minor) {
    if (minor == null) {
      return send({
        'type': 'updateProfile',
        'profile': {'dailyLimit': null, 'dailyLimitSince': null, 'dailyLimitHistory': null},
      });
    }
    final old = dailyLimit;
    final since = dailyLimitSince ?? today;
    var h = [...dailyLimitHistory];
    // Профили до D71 истории не хранят: все прошлые дни шли по прежней сумме.
    if (h.isEmpty && old != null) h = [(from: since.isAfter(today) ? today : since, amount: old)];
    h.removeWhere((e) => e.from == today); // повторная правка в тот же день заменяет прежнюю
    if (h.isEmpty || h.last.amount != minor) h.add((from: today, amount: minor));
    return send({
      'type': 'updateProfile',
      'profile': {
        'dailyLimit': minor.toString(),
        if (old == null) 'dailyLimitSince': _date(today),
        'dailyLimitHistory': _historyJson(_pruned(h, dailyLimitSince ?? today)),
      },
    });
  }

  /// Обнулить перенос: начать копить заново с сегодняшнего дня, сумму
  /// лимита не трогая. Для «слишком большой минус, хочу начать с нуля».
  Future<void> resetDailyLimitCarry() => _restartCarry();

  Future<void> _restartCarry() {
    final limit = dailyLimit;
    return send({
      'type': 'updateProfile',
      'profile': {
        'dailyLimitSince': _date(today),
        if (limit != null) 'dailyLimitHistory': _historyJson([(from: today, amount: limit)]),
      },
    });
  }

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

  /// Счета, остаток которых сейчас меньше нуля (D87).
  List<AccountInfo> get accountsInMinus => activeAccounts.where((a) => ledger.balance(a.id) < 0).toList();

  /// Пояснение владельца, почему счёт в минусе (D87). Действует, пока счёт
  /// остаётся в минусе с дня пояснения: вышел в плюс и ушёл в минус снова —
  /// это уже другая история, старое пояснение к ней не относится.
  String? minusNote(String accountId) {
    final meta = _kind('account')[accountId] ?? const {};
    final note = '${meta['minusNote'] ?? ''}'.trim();
    if (note.isEmpty || meta['minusNoteAt'] == null || ledger.balance(accountId) >= 0) return null;
    var day = dateFromJson(meta['minusNoteAt']);
    final oldest = today.subtract(const Duration(days: 90));
    if (day.isBefore(oldest)) day = oldest;
    for (; !day.isAfter(today); day = DateTime(day.year, day.month, day.day + 1)) {
      if (ledger.balance(accountId, asOf: day) >= 0) return null;
    }
    return note;
  }

  Future<void> setMinusNote(String accountId, String note) {
    final data = Map<String, dynamic>.from(_kind('account')[accountId] ?? const {})
      ..remove('minusNote')
      ..remove('minusNoteAt');
    final text = note.trim();
    if (text.isNotEmpty) {
      data['minusNote'] = text.length > 200 ? text.substring(0, 200) : text;
      data['minusNoteAt'] = _date(today);
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
  /// Плановые платежи и разовые покупки (D88) — одним списком: у них общие
  /// сроки, календарь и оплата. Разовая покупка отличается полем `once`.
  List<PlannedInfo> get planned => [
        for (final e in _kind('planned').entries) PlannedInfo.fromJson(e.key, e.value),
        for (final e in _kind('purchase').entries)
          if (RegExp(r'^\d{4}-\d{2}$').hasMatch('${e.value['once']}')) PlannedInfo.fromJson(e.key, e.value),
      ];

  /// Разовые покупки, которые ещё впереди (не куплены).
  List<PlannedInfo> get purchases => planned.where((p) => p.once != null && !p.paid.contains(p.once)).toList()..sort((a, b) => a.once!.compareTo(b.once!));

  /// Копилка, в которую откладывают на покупку (D90); `null` — не копят или
  /// копилку уже закрыли.
  GoalInfo? purchaseGoal(PlannedInfo p) => p.goalId == null ? null : goals.where((g) => g.id == p.goalId).firstOrNull;

  /// Сколько уже отложено на покупку в её копилке.
  int purchaseSaved(PlannedInfo p) {
    final goal = purchaseGoal(p);
    return goal == null ? 0 : goalSaved(goal);
  }

  /// Сколько откладывать в месяц, чтобы к месяцу покупки набралась вся сумма:
  /// то, чего ещё не хватает, поровну на месяцы до покупки. Считается той же
  /// формулой, что «нужно в месяц» у цели, — у покупки с копилкой и на
  /// карточке её цели число одно и то же. `0` — уже накоплено.
  int purchaseMonthly(PlannedInfo p) {
    final m = p.onceMonth!;
    final months = (m.year - today.year) * 12 + (m.month - today.month);
    return goalStatus(saved: purchaseSaved(p), target: p.amount, plannedContributionsLeft: months < 1 ? 1 : months).requiredContribution ?? 0;
  }

  /// Завести копилку под покупку: цель с тем же названием, суммой и сроком —
  /// деньги в ней перестают быть свободными и не попадают в дневной лимит.
  Future<void> startSavingFor(PlannedInfo p) {
    final m = p.onceMonth!;
    final goal = newGoalCommands(name: p.name, target: p.amount, deadline: DateTime(m.year, m.month + 1, 0));
    return sendBatch([
      ...goal,
      {'type': 'upsertEntity', 'kind': p.entityKind, 'entityId': p.id, 'data': p.toJson(goal: goal.last['entityId'] as String)},
    ]);
  }

  /// Новая разовая покупка на месяц [month]. Срок — последний день месяца:
  /// «в марте» не значит «первого числа», просрочки до конца месяца нет.
  Future<void> addPurchase({required String name, required int amount, required DateTime month, required String category}) {
    final id = newId();
    return upsert('purchase', id, PlannedInfo(id, name, amount, 31, category, null, const {}, once: _period(month)).toJson());
  }
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

  /// День, к которому относится трата, и признак «запланированная» — общие
  /// с ботом и сводками правила из ядра (`formulas/daily_limit.dart`).
  DateTime? _spendDay(Transaction t) => spendDay(ledger, t);
  bool _isPlannedSpend(Transaction t) => isPlannedSpend(ledger, t);

  /// Повседневные траты из дневного бюджета за [from]–[to] включительно:
  /// покупки минус возвраты по покупкам этих дней (возврат считается по дню
  /// покупки, не по дню самого возврата). Запланированные траты сюда не входят.
  int spentBetween(DateTime from, DateTime to) => spendBetween(ledger, from, to).everyday;

  /// Запланированные траты за те же дни — вне лимита; для пояснения «что не
  /// вошло в лимит», в расчёт доступного не идут.
  int spentPlannedBetween(DateTime from, DateTime to) => spendBetween(ledger, from, to).planned;

  /// Непредвиденные траты (D101) за те же дни — вне лимита, отдельной строкой
  /// в аналитике, сверке и у консультанта.
  int spentUnexpectedBetween(DateTime from, DateTime to) => spendBetween(ledger, from, to).unexpected;

  /// Непредвиденные траты за месяц [monthStart].
  int unexpectedFor(DateTime monthStart) => spentUnexpectedBetween(monthStart, DateTime(monthStart.year, monthStart.month + 1, 0));

  /// Крупная покупка (D74): от половины дневного лимита. Такую покупку
  /// программа предлагает отметить запланированной — дневной лимит нужен для
  /// потребительских мелочей, а не для крупных трат.
  bool isBigPurchase(int amount) {
    final limit = dailyLimit;
    return limit != null && limit > 0 && amount * 2 >= limit;
  }

  /// Сегодняшние повседневные траты из дневного бюджета.
  int spentToday() => spentBetween(today, today);

  /// Дневной лимит на сегодня: расчёт — в ядре, один для приложения и бота.
  DailyLimitState get _limitState => dailyLimitState(ledger, profile, today);

  /// Сколько доступно сегодня по лимиту и переносу (D64), без оглядки на деньги.
  int? get dailyLimitPlanned => _limitState.planned;

  /// Свободные деньги сейчас (D73): ликвидные минус отложенное на цели минус
  /// ещё не оплаченные платежи до следующего дохода. Отрицательные — платежи
  /// нечем покрыть.
  int get freeMoney => ledger.freeLiquid() - obligationsUntilIncome;

  /// Доступно на свободные траты сегодня (D73, D81): по лимиту и переносу, но
  /// не больше денег, которые есть сейчас (без отложенного на цели).
  /// Предстоящие платежи доступное не уменьшают — о нехватке карточка
  /// предупреждает отдельно. Перерасход остаётся отрицательным.
  int? get dailyLimitAvailable => _limitState.available;

  /// Разбор «доступно сегодня» для экрана «Как посчитано» (D73):
  /// деньги → свободно → ориентир → лимит и перенос → доступно.
  LimitExplain get limitExplain {
    final until = nextIncomeDate;
    final due = dueItems(until.subtract(const Duration(days: 1)));
    final unpaid = due.fold<int>(0, (sum, d) => sum + d.planned.amount);
    return LimitExplain(
      liquid: ledger.liquid(),
      reserves: liquidReserves,
      obligations: unpaid,
      overdue: due.where((d) => d.date.isBefore(today)).fold<int>(0, (sum, d) => sum + d.planned.amount),
      days: daysToIncome < 1 ? 1 : daysToIncome,
      until: until,
      byMonthEnd: !hasPayDay,
      guideDaily: guide.dailyBudget,
      spent: spentToday(),
      outside: spentPlannedBetween(today, today),
      limit: dailyLimit,
      carry: dailyLimitCarry,
      planned: dailyLimitPlanned,
      available: dailyLimitAvailable,
      today: today,
    );
  }

  /// Вклад прошлых дней в сегодняшнее доступное: положительный — прошлые
  /// дни сэкономили и добавили сегодня, отрицательный — прошлый перерасход
  /// уменьшил сегодняшнюю сумму. `0` в первый день лимита или без переноса.
  int get dailyLimitCarry => _limitState.carry;

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
      if (!_plannedDebtActive(p)) continue; // долг уже закрыт (F10)
      // Разовая покупка — один срок в своём месяце (и просрочка после него).
      final from = p.onceMonth ?? p.start ?? monthStart;
      // Не раньше 10 лет назад и не дальше двух месяцев вперёд.
      final startIdx = (from.year * 12 + from.month - 1).clamp(todayIdx - 120, todayIdx + 2);
      for (var i = startIdx; i <= todayIdx + 2; i++) {
        final date = _onDay(i ~/ 12, i % 12 + 1, p.day);
        if (date.isAfter(until)) break;
        if (p.start != null && date.isBefore(p.start!)) continue;
        final period = _period(date);
        if (p.once != null && period != p.once) continue;
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

  /// Траты по категории в прошлом месяце — к такому же дню и за весь месяц
  /// (D95). Это замена линейному «прогнозу к концу месяца», который просто
  /// умножал первые дни на их число. `null` — прошлый месяц в приложении не
  /// вёлся, сравнивать не с чем, и ничего не показывается.
  ({int toDay, int total})? lastMonthSpent(String category) {
    final prev = monthOf(-1);
    if (!hasActivityIn(prev)) return null;
    final acc = expenseAccount(category);
    final sameDay = DateTime(prev.year, prev.month, today.day + 1);
    final end = sameDay.isAfter(monthStart) ? monthStart : sameDay;
    final toDay = ledger.expenseByCategory(prev, end)[acc] ?? 0;
    // Ноль к этому дню — чаще всего учёт начался позже, а не «ничего не
    // тратил»: сравнение с нулём ничего не говорит, лучше промолчать.
    if (toDay <= 0) return null;
    return (toDay: toDay, total: ledger.expenseByCategory(prev, monthStart)[acc] ?? 0);
  }

  /// Лимит стоит показать на главной: он почти исчерпан или траты идут
  /// быстрее, чем к этому же дню прошлого месяца.
  bool limitAtRisk(LimitInfo def, LimitStatus st) {
    if (st.warn80) return true;
    final last = lastMonthSpent(def.category);
    return last != null && st.spent > last.toDay;
  }

  /// Список лимитов считает расходы одним проходом по журналу, даже если
  /// категорий десятки. Подробности одного лимита используют тот же расчёт.
  List<({LimitInfo def, LimitStatus status})> get currentLimitStatuses {
    final spent = ledger.expenseByCategory(monthStart, monthEnd);
    return [for (final def in limits) (def: def, status: _limitStatus(def, spent[expenseAccount(def.category)] ?? 0))];
  }

  LimitStatus limitStatusFor(LimitInfo def) => _limitStatus(def, spentInCategory(def.category));

  LimitStatus _limitStatus(LimitInfo def, int spent) => limitStatus(
        spent: spent,
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

  // -------------------------------------------------- доход → цели (D96)

  /// Предлагать ли после записи дохода отложить часть в копилки целей.
  /// По умолчанию да; выключается ссылкой в самом листе или в настройках.
  bool get offerGoalsOnIncome => profile['offerGoalsOnIncome'] != false;
  Future<void> setOfferGoalsOnIncome(bool on) => send({'type': 'updateProfile', 'profile': {'offerGoalsOnIncome': on}});

  /// Доход от этой суммы считается заметным: на кэшбэк в 300 ₸ вопрос
  /// «отложить на цели?» не нужен.
  static const incomeOfferMin = 5000 * minorPerUnit;

  /// Цели, на которые есть смысл откладывать: с копилкой и ещё не достигнутые.
  List<GoalInfo> get openGoals => [
        for (final g in goals)
          if (g.account != null && ledger.hasAccount(g.account!) && !goalStatusFor(g).reached) g,
      ];

  /// Показывать ли после дохода [amount] лист «Отложить часть на цели?».
  bool shouldOfferGoals(int amount) => offerGoalsOnIncome && amount >= incomeOfferMin && openGoals.isNotEmpty;

  /// Сколько отложено в копилку цели за месяц, в который попадает [day]:
  /// переводы в копилку минус переводы из неё, не меньше нуля; отменённые
  /// записи не считаются.
  int goalDepositedInMonth(GoalInfo g, DateTime day) {
    final acc = g.account;
    if (acc == null) return 0;
    final from = DateTime(day.year, day.month, 1);
    final to = DateTime(day.year, day.month + 1, 1);
    var sum = 0;
    for (final tx in ledger.transactions) {
      if (tx.type != EventType.transfer || ledger.isReversed(tx.id)) continue;
      if (tx.date.isBefore(from) || !tx.date.isBefore(to)) continue;
      sum += tx.amountOn(acc);
    }
    return math.max(0, sum);
  }

  /// Подсказка взноса с дохода от [date]: «нужно в месяц» (та же формула,
  /// что на карточке цели) за вычетом уже отложенного в этом месяце, не
  /// больше остатка до цели. `null` — у цели нет срока, считать не от чего.
  int? goalSuggestedDeposit(GoalInfo g, {required DateTime date}) {
    final st = goalStatusFor(g);
    final need = st.requiredContribution;
    if (need == null) return null;
    return math.max(0, math.min(need - goalDepositedInMonth(g, date), st.remaining));
  }

  /// Подсказки по открытым целям для дохода [amount]: по порядку целей, пока
  /// хватает дохода, — сумма подсказок не превышает сам доход. Цели без
  /// подсказки в ответ не попадают (поле остаётся пустым).
  Map<String, int> incomeGoalSuggestions(int amount, {required DateTime date}) {
    var left = amount;
    final out = <String, int>{};
    for (final g in openGoals) {
      final s = goalSuggestedDeposit(g, date: date);
      if (s == null || s <= 0) continue;
      final v = math.min(s, left);
      if (v <= 0) break;
      out[g.id] = v;
      left -= v;
    }
    return out;
  }

  /// Отложить с дохода на несколько целей: одна пачка переводов датой дохода
  /// со счёта, куда пришёл доход. [commandId] лист создаёт один раз на
  /// попытку — повтор после обрыва связи не задвоит переводы.
  Future<void> allocateToGoals(Map<GoalInfo, int> amounts, {required String from, required DateTime date, String? commandId}) =>
      sendBatch([
        for (final e in amounts.entries)
          if (e.value > 0) {'type': 'transfer', 'id': newId(), 'date': _date(date), 'from': from, 'to': e.key.account!, 'amount': e.value.toString()},
      ], commandId: commandId);

  // ------------------------------------------------------------- периоды

  /// Первый день месяца со сдвигом от текущего: 0 — этот, −1 — прошлый.
  DateTime monthOf(int offset) => DateTime(today.year, today.month + offset, 1);

  PeriodReport reportFor(DateTime monthStart) =>
      ledger.report(monthStart, DateTime(monthStart.year, monthStart.month + 1, 1));

  /// Расход по категориям месяца: id категории → сумма, по убыванию.
  List<MapEntry<String, int>> categoriesFor(DateTime monthStart) {
    final end = DateTime(monthStart.year, monthStart.month + 1, 1);
    final raw = ledger.expenseByCategory(monthStart, end);
    // Платежи по долгам — строкой рядом с категориями (D98): так «куда ушло
    // больше всего» честно показывает кредит, если он больше всего.
    final debts = ledger.debtPaymentsBetween(monthStart, end);
    final list = [
      for (final e in raw.entries)
        if (e.value != 0) MapEntry(e.key.substring(8), e.value),
      if (debts > 0) MapEntry(debtsCategory, debts),
    ]..sort((a, b) => b.value.compareTo(a.value));
    return list;
  }

  /// Расход по дням месяца: индекс 0 — первое число. Возврат обычно считается
  /// по дню покупки (`_spendDay`); если покупка была в ДРУГОМ месяце, для
  /// этого графика он всё же встаёт на свою дату — иначе сумма столбиков
  /// разошлась бы с месячным отчётом и категориями, которые всегда считают
  /// возврат по его собственной дате (F03).
  /// День, под которым операция показывается на графике по дням и в его
  /// детализации: у возврата в границах своего месяца — день покупки (тот
  /// же, что учитывает дневной лимит через `_spendDay`), у возврата, который
  /// пересёк границу месяца, и у всех остальных операций — собственная дата.
  /// Общая функция для `dailyExpense()` и `transactionsOnDay()` — столбик
  /// графика и список операций под ним всегда должны показывать одно и то
  /// же (повторный аудит, F05).
  DateTime? _chartDay(Transaction t) {
    if (t.type != EventType.refund) return t.date;
    final spendDay = _spendDay(t); // возврат по удалённой покупке — null, не входит
    if (spendDay == null) return null;
    if (spendDay.year != t.date.year || spendDay.month != t.date.month) return t.date;
    return spendDay;
  }

  List<int> dailyExpense(DateTime monthStart) {
    final days = DateTime(monthStart.year, monthStart.month + 1, 0).day;
    final out = List<int>.filled(days, 0);
    final end = DateTime(monthStart.year, monthStart.month + 1, 1);
    for (final tx in ledger.transactions) {
      if (ledger.isReversed(tx.id) || tx.type == EventType.reversal) continue;
      final day = _chartDay(tx);
      if (day == null || day.isBefore(monthStart) || !day.isBefore(end)) continue;
      for (final p in tx.postings) {
        if (ledger.account(p.accountId).kind == LedgerKind.expense) out[day.day - 1] += p.amount;
      }
    }
    // Та же база, что у report.total и categoriesFor: проценты уже попали
    // через расходные проводки. Добавляем только тело учтённых платежей;
    // рассрочки с записанной покупкой ядро исключает во избежание дубля.
    for (final tx in ledger.debtPaymentsIn(monthStart, end)) {
      for (final posting in tx.postings) {
        if (ledger.account(posting.accountId).kind == LedgerKind.liability) {
          out[tx.date.day - 1] -= posting.amount;
        }
      }
    }
    return out;
  }

  /// Доход месяца по дням — для графика «доход/расход по дням» (индекс 0 —
  /// первое число). По проводкам дохода, а не по виду события (F04): доход
  /// может прийти и не через `EventType.income` (например, проценты по долгу).
  List<int> dailyIncome(DateTime monthStart) {
    final days = DateTime(monthStart.year, monthStart.month + 1, 0).day;
    final out = List<int>.filled(days, 0);
    final end = DateTime(monthStart.year, monthStart.month + 1, 1);
    for (final tx in ledger.transactions) {
      if (ledger.isReversed(tx.id) || tx.type == EventType.reversal) continue;
      if (tx.date.isBefore(monthStart) || !tx.date.isBefore(end)) continue;
      for (final p in tx.postings) {
        if (ledger.account(p.accountId).kind == LedgerKind.income) out[tx.date.day - 1] += p.amount;
      }
    }
    return out;
  }

  /// Расход месяца по отметке «для кого» — считает и возвраты (F04), иначе
  /// покупка с возвратом в одном месяце завышает расход члена семьи.
  Map<String, int> expenseByWho(DateTime monthStart) {
    final end = DateTime(monthStart.year, monthStart.month + 1, 1);
    final out = <String, int>{};
    for (final tx in userTransactions) {
      if ((tx.type != EventType.expense && tx.type != EventType.refund) || tx.date.isBefore(monthStart) || !tx.date.isBefore(end)) continue;
      final sum = tx.postings.where((p) => ledger.account(p.accountId).kind == LedgerKind.expense).fold(0, (s, p) => s + p.amount);
      out.update(_whoFor(tx), (v) => v + sum, ifAbsent: () => sum);
    }
    return out;
  }

  /// «Для кого» операции: собственный `meta.who`, а у возврата без него
  /// (старые записи до того, как `refund()` начал сохранять `who`) — «для
  /// кого» была связанная покупка через `refundOf` (повторный аудит, F10).
  String _whoFor(Transaction t) {
    final own = t.meta['who'] as String?;
    if (own != null) return own;
    if (t.type == EventType.refund) {
      final of = t.meta['refundOf'];
      if (of is String) {
        final purchaseWho = (ledger.currentVersion(of) ?? ledger.byId(of))?.meta['who'] as String?;
        if (purchaseWho != null) return purchaseWho;
      }
    }
    return 'me';
  }

  /// Операции месяца, затронувшие категорию расхода.
  List<Transaction> categoryTransactions(String category, DateTime monthStart) {
    final end = DateTime(monthStart.year, monthStart.month + 1, 1);
    if (category == debtsCategory) {
      final ids = {for (final t in ledger.debtPaymentsIn(monthStart, end)) t.id};
      return userTransactions.where((t) => ids.contains(t.id)).toList();
    }
    final acc = expenseAccount(category);
    return userTransactions
        .where((t) => !t.date.isBefore(monthStart) && t.date.isBefore(end) && t.postings.any((p) => p.accountId == acc))
        .toList();
  }

  /// Операции конкретного дня графика по дням — тем же правилом дня, что и
  /// столбик (`_chartDay`), а не по собственной дате операции: иначе список
  /// под графиком не совпадал бы со значением столбика для возврата внутри
  /// месяца (повторный аудит, F05).
  List<Transaction> transactionsOnDay(DateTime day) => userTransactions.where((t) => _chartDay(t) == day).toList();

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
  /// [plannedPurchase] и [unexpected] (D74, D101) — трата вне дневного лимита;
  /// одновременно оба не ставятся.
  Future<void> addExpense({required int amount, required String category, required String account, required DateTime date, String who = 'me', String note = '', String? time, bool plannedPurchase = false, bool unexpected = false, String? id, String? commandId}) =>
      send({'type': 'expense', 'id': id ?? newId(), 'date': _date(date), 'account': account, 'splits': {category: amount.toString()}, 'meta': {'who': who, if (note.isNotEmpty) 'note': note, if (time != null) 'time': time, if (plannedPurchase && !unexpected) 'plannedPurchase': true, if (unexpected) 'unexpected': true}}, commandId: commandId);

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
    // Покупка из копилки (D90): накопленное возвращается на счёт оплаты,
    // копилка закрывается — и расход проводится уже с этого счёта.
    final goal = p.once == null ? null : purchaseGoal(p);
    return sendBatch([
      if (goal != null) ...closeGoalCommands(goal, returnTo: account),
      fact,
      {'type': 'upsertEntity', 'kind': p.entityKind, 'entityId': p.id, 'data': p.toJson(paid: {...p.paid, due.period}, keepGoal: goal == null)},
    ], commandId: commandId);
  }

  /// Исправление покупки: старая версия отменяется, новая проводится —
  /// одной командой, история сохраняется (F032).
  Future<void> editExpense(Transaction old, {required Map<String, int> splits, required String account, required DateTime date, required String who, required String note, String? time, bool? plannedPurchase, bool? unexpected}) =>
      sendBatch([
        {'type': 'reverse', 'txId': old.id, 'id': newId()},
        {
          'type': 'expense',
          'id': newId(),
          'date': _date(date),
          'account': account,
          'splits': {for (final e in splits.entries) e.key: e.value.toString()},
          'meta': {
            ...old.meta,
            'who': who,
            'note': note,
            if (time != null) 'time': time,
            'edited': old.id,
            if (plannedPurchase != null) 'plannedPurchase': plannedPurchase ? true : null,
            if (unexpected != null) 'unexpected': unexpected ? true : null,
          }..removeWhere((k, v) => v == null || v == ''),
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
  /// Наследует «для кого» от покупки (F04) — иначе возврат по чужой покупке
  /// считался бы за «меня» в семейной разбивке.
  Future<void> refund(Transaction purchase, {required String category, required int amount, required String account, DateTime? date, String? commandId}) =>
      send({'type': 'refund', 'id': newId(), 'date': _date(date ?? today), 'category': category, 'amount': amount.toString(), 'toAccount': account, 'meta': {'refundOf': ledger.purchaseRoot(purchase.id), 'who': purchase.meta['who'] ?? 'me'}}, commandId: commandId);

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

  // ---------------------------------------------- закрытие месяца (D75)

  /// В первые дни месяца прошлый предлагается закрыть; позже карточка на
  /// главной уходит, но месяц можно закрыть из «Ещё → Сверка месяца».
  static const closeWindowDays = 15;

  /// Закрытые месяцы `ГГГГ-ММ` (профиль `closedMonths`).
  Set<String> get closedMonths => {...((profile['closedMonths'] as List?) ?? const []).cast<String>()};

  bool isMonthClosed(DateTime month) => closedMonths.contains(_period(month));

  /// В месяце внесены операции (расход или доход) — есть что сверять.
  bool hasActivityIn(DateTime month) {
    final start = DateTime(month.year, month.month, 1);
    final end = DateTime(month.year, month.month + 1, 1);
    return ledger.transactions.any((t) => (t.type == EventType.expense || t.type == EventType.income) && !t.date.isBefore(start) && t.date.isBefore(end));
  }

  /// Прошлый месяц, если его пора закрыть: идут первые дни нового, он не
  /// закрыт и в нём вёлся учёт. Иначе `null` — карточка на главной не нужна.
  DateTime? get monthToClose {
    if (today.day > closeWindowDays) return null;
    final prev = monthOf(-1);
    return !isMonthClosed(prev) && hasActivityIn(prev) ? prev : null;
  }

  /// Отметить месяц закрытым. Закрытие ничего не блокирует: записи по-прежнему
  /// можно вносить и править, отметка нужна для порядка и напоминаний.
  Future<void> closeMonth(DateTime month) {
    final all = {...closedMonths, _period(month)}.toList()..sort();
    // Последние 60 месяцев — профиль не должен расти бесконечно.
    final kept = all.length > 60 ? all.sublist(all.length - 60) : all;
    return send({'type': 'updateProfile', 'profile': {'closedMonths': kept}});
  }

  /// Сколько месяцев подряд закрыто, считая от [month] назад.
  int closedStreakFrom(DateTime month) {
    var n = 0;
    var m = DateTime(month.year, month.month, 1);
    while (isMonthClosed(m) && n < 60) {
      n++;
      m = DateTime(m.year, m.month - 1, 1);
    }
    return n;
  }

  /// Платёж уже оплачен — внесён обычным расходом или вне приложения: срок
  /// отмечается оплаченным без новой операции.
  Future<void> markDuePaid(DueItem due) =>
      send({'type': 'upsertEntity', 'kind': due.planned.entityKind, 'entityId': due.planned.id, 'data': due.planned.toJson(paid: {...due.planned.paid, due.period})});

  /// Итоги месяца для сверки: доходы, расходы, куда ушло больше всего, платежи,
  /// расхождения остатков и средний расход в день из дневного лимита.
  MonthSummary monthSummary(DateTime month) {
    final start = DateTime(month.year, month.month, 1);
    final end = DateTime(month.year, month.month + 1, 1);
    final r = reportFor(start);
    final pr = reportFor(DateTime(month.year, month.month - 1, 1));
    final current = start == monthStart;
    final days = current ? today.day : end.difference(start).inDays;
    var total = 0, paid = 0;
    for (final p in planned) {
      if (!_plannedDebtActive(p)) continue;
      final date = _onDay(start.year, start.month, p.day);
      if (p.start != null && date.isBefore(p.start!)) continue;
      if (p.once != null && p.once != _period(start)) continue;
      total++;
      if (p.paid.contains(_period(start))) paid++;
    }
    return MonthSummary(
      month: start,
      current: current,
      income: r.income,
      // «Расходы» сверки — всё, что ушло, включая кредиты и долги (D98).
      expense: r.total,
      debtPayments: r.debtPayments,
      prevIncome: pr.income,
      prevExpense: pr.total,
      top: categoriesFor(start).take(3).toList(),
      adjustments: adjustmentsFor(start),
      unexpected: unexpectedFor(start),
      paymentsPaid: paid,
      paymentsTotal: total,
      days: days,
      // До целого тенге, как остальные расчётные суммы (D19): «1 433,33 ₸ в день» — лишняя точность.
      avgDaily: days <= 0 ? 0 : roundHalfUp(spentBetween(start, current ? today : end.subtract(const Duration(days: 1))) / days / minorPerUnit) * minorPerUnit,
    );
  }

  // ------------------------------------------------------- аналитика (D66)

  /// Тип расхода категории: выбор владельца для своей категории (F12) —
  /// приоритетнее запасного назначения по id из ядра (свободные по умолчанию).
  ExpenseType expenseTypeFor(String categoryId) => customCategories[categoryId]?.expenseType ?? expenseTypeOf(categoryId);

  /// Расход месяца по трём типам вместо десятков категорий (раздел 9.8):
  /// обязательные (аренда, коммуналка, связь, кредиты), обычные (еда,
  /// транспорт, бытовое) и свободные (кафе, развлечения, подарки). Своя
  /// категория — свободные по умолчанию, если владелец не указал иное.
  ExpenseTypeSplit expenseTypeSplit(DateTime monthStart) =>
      splitExpenseTypes({for (final e in categoriesFor(monthStart)) e.key: e.value}, classify: expenseTypeFor);

  /// Чистый капитал на конец каждого из последних [months] месяцев, самый
  /// новый — сегодня (месяц ещё не закончился). Ничего не хранится отдельно:
  /// журнал уже весь на устройстве (D63), это просто снимок на разные даты.
  /// Точек меньше [months], если учёт начат позже (F08): капитал «до того,
  /// как завели приложение» не показываем нулём — это не то же самое, что
  /// «денег правда не было».
  List<NetWorth> netWorthHistory(int months) {
    final firstMonth = _firstActivityMonth;
    var n = months;
    if (firstMonth != null) {
      final elapsed = (today.year - firstMonth.year) * 12 + (today.month - firstMonth.month) + 1;
      n = n.clamp(1, elapsed);
    } else {
      n = 1; // журнал пуст — есть только «сейчас»
    }
    return [for (var k = n - 1; k >= 0; k--) ledger.netWorth(asOf: k == 0 ? today : monthOf(1 - k).subtract(const Duration(days: 1)))];
  }

  /// Первый месяц, за который в журнале вообще есть операции; `null` —
  /// журнал пуст. Отличает «дохода не было» от «истории ещё не было» (F08):
  /// месяцы до начала учёта не должны считаться нулевыми при усреднении.
  /// Отменённые записи не считаются (повторный аудит, F03): случайно
  /// внесённая и тут же удалённая старая операция не должна отодвигать
  /// начало учёта назад.
  DateTime? get _firstActivityMonth {
    DateTime? earliest;
    for (final tx in ledger.transactions) {
      if (tx.type == EventType.reversal || ledger.isReversed(tx.id)) continue;
      if (earliest == null || tx.date.isBefore(earliest)) earliest = tx.date;
    }
    return earliest == null ? null : DateTime(earliest.year, earliest.month, 1);
  }

  /// Долг, по которому сейчас может быть платёж: остаток больше нуля.
  /// Пересчитывается заново каждый раз по журналу — револьверный долг
  /// (кредитка) сам «оживает» новой покупкой, отдельного признака «вида
  /// долга» здесь не нужно (повторный аудит, F02: раньше кредитка считалась
  /// «актуальной» всегда, даже без баланса и новых начислений — платёж
  /// требовался без причины).
  bool _debtStillOwed(DebtInfo d) => debtBalance(d.id) > 0;

  /// Плановый платёж ещё актуален: не привязан к долгу либо привязанный долг
  /// ещё не закрыт.
  bool _plannedDebtActive(PlannedInfo p) {
    if (p.debtId == null) return true;
    final debt = bankDebt(p.debtId!);
    return debt != null && _debtStillOwed(debt);
  }

  /// Действующие плановые платежи — без привязанных к уже погашенным долгам
  /// (F10). Строки списка и его сумма должны показывать одно и то же
  /// (повторный аудит, F01): `recurringMonthly` — это сумма именно этого
  /// списка, не всех `planned` без разбора.
  List<PlannedInfo> get activePlanned => planned.where((p) => p.once == null && _plannedDebtActive(p)).toList();

  /// Постоянные ежемесячные обязательства (раздел 9.11): плановые платежи,
  /// включая платежи по кредитам — они заводятся как планы со ссылкой на долг.
  int get recurringMonthly => activePlanned.fold(0, (s, p) => s + p.amount);

  /// Средний доход за последние [months] уже закончившихся месяцев (без
  /// текущего — он не закончился), но не раньше начала учёта: месяц без
  /// операций из-за того, что учёт тогда ещё не велся, не считается нулевым
  /// доходом (F08). `0`, если ни один из запрошенных месяцев не подходит.
  int avgMonthlyIncome({int months = 3}) {
    if (months <= 0) return 0;
    final firstMonth = _firstActivityMonth;
    var sum = 0;
    var counted = 0;
    for (var k = 1; k <= months; k++) {
      final m = monthOf(-k);
      if (firstMonth != null && m.isBefore(firstMonth)) continue;
      sum += reportFor(m).income;
      counted++;
    }
    return counted == 0 ? 0 : sum ~/ counted;
  }

  /// Постоянных платежей в месяц больше, чем записано доходов (D92): доля от
  /// дохода тогда не показатель, а признак того, что доходы внесены не все.
  /// Вместо «1 350 % дохода» приложение говорит об этом прямо.
  bool get incomeLooksIncomplete => recurringMonthly > 0 && avgMonthlyIncome() > 0 && recurringMonthly > avgMonthlyIncome();

  /// Доля постоянных обязательств от среднего дохода; `null` — доход неизвестен.
  double? get recurringShareOfIncome {
    final income = avgMonthlyIncome();
    return income > 0 ? recurringMonthly * 100 / income : null;
  }

  /// Прогноз остатка до конца календарного месяца (раздел 9.9; не до
  /// зарплаты — дата дохода из продукта убрана, D50). Точка отсчёта —
  /// свободные деньги сейчас минус ещё не оплаченные обязательства и
  /// ожидаемые повседневные траты по уже сложившемуся среднему, плюс
  /// ожидаемый остаток дохода месяца.
  MonthForecast get monthEndForecast {
    final remaining = dueItems(monthEnd.subtract(const Duration(days: 1))).fold(0, (s, d) => s + d.planned.amount);
    final elapsed = today.day;
    final avgDaily = elapsed <= 0 ? 0 : spentBetween(monthStart, today) ~/ elapsed;
    final daysLeft = monthEnd.difference(today).inDays - 1;
    final expectedIncome = avgMonthlyIncome() - monthReport.income;
    return forecastMonthEnd(
      current: ledger.freeLiquid(),
      remainingObligations: remaining,
      avgDailySpend: avgDaily,
      daysLeft: daysLeft < 0 ? 0 : daysLeft,
      expectedIncome: expectedIncome < 0 ? 0 : expectedIncome,
    );
  }

  /// Использовано от суммы всех лимитов, %; `null` — лимитов нет или их сумма 0.
  double? get budgetUsedPercent {
    final totalLimit = limits.fold(0, (s, l) => s + l.amount);
    if (totalLimit == 0) return null;
    final totalSpent = limits.fold(0, (s, l) => s + spentInCategory(l.category));
    return totalSpent * 100 / totalLimit;
  }

  double get monthElapsedPercent => today.day * 100 / daysInMonth;

  /// Долговая нагрузка по банковским долгам (раздел 9.10). Личные долги сюда
  /// не входят — это не регулярный ежемесячный платёж. Полностью выплаченные
  /// займы/рассрочки исключены (F10) — они больше не нагрузка.
  DebtLoadStatus get debtLoadStatus {
    final income = avgMonthlyIncome();
    return debtLoad(
      [for (final d in bankDebts.where(_debtStillOwed)) _debtLoadInput(d)],
      monthlyIncome: income > 0 ? income : null,
    );
  }

  DebtLoadInput _debtLoadInput(DebtInfo d) => DebtLoadInput(
        id: d.id,
        currentBalance: debtBalance(d.id),
        monthlyPayment: plannedForDebt(d.id)?.amount ?? 0,
        annualRatePercent: d.rate,
        // Кредитка — револьверный долг: баланс растёт от новых покупок,
        // «доля погашения» для неё не имеет смысла.
        initialBalance: d.kind == 'creditCard' ? null : _debtInitialBalance(d.id),
      );

  /// Месяцев до полного погашения всех банковских долгов при сумме
  /// минимальных платежей плюс [extraPerMonth] (сценарий «а если платить
  /// больше»); `0` без долгов, `null` — не укладывается в разумный срок.
  int? monthsToPayoffAt({int extraPerMonth = 0}) {
    final inputs = [for (final d in bankDebts.where(_debtStillOwed)) _debtLoadInput(d)];
    if (inputs.isEmpty) return 0;
    final budget = inputs.fold(0, (s, d) => s + d.monthlyPayment) + extraPerMonth;
    return monthsToPayoff(inputs, monthlyBudget: budget);
  }

  /// Остаток долга на дату его открытия — ищет самую первую запись,
  /// затронувшую этот долг (`openingDebt` использует тот же `EventType.opening`,
  /// что и начальный остаток денежного счёта).
  int? _debtInitialBalance(String debtId) {
    final acc = liabilityAccount(debtId);
    for (final tx in ledger.transactions) {
      if (tx.type != EventType.opening) continue;
      for (final p in tx.postings) {
        if (p.accountId == acc) return p.amount;
      }
    }
    return null;
  }

  /// Час операции из `meta.time` («09:14» → 9); `null`, если время не указано.
  int? _hourOf(Transaction t) {
    final m = RegExp(r'^(\d{1,2}):').firstMatch('${t.meta['time']}');
    return m == null ? null : int.tryParse(m[1]!);
  }

  /// Доля свободных трат после 20:00 среди операций с указанным временем
  /// (раздел 9.12); `null`, если время указано меньше чем у двух таких
  /// операций — единственная операция дала бы 0% или 100% и выглядела бы
  /// как измерение, хотя на самом деле почти ничего не известно (F13).
  double? eveningDiscretionaryShare(DateTime monthStart) {
    final end = DateTime(monthStart.year, monthStart.month + 1, 1);
    var total = 0, evening = 0, known = 0;
    for (final tx in ledger.transactions) {
      if (tx.type != EventType.expense || ledger.isReversed(tx.id) || _isPlannedSpend(tx)) continue;
      if (tx.date.isBefore(monthStart) || !tx.date.isBefore(end)) continue;
      final hour = _hourOf(tx);
      if (hour == null) continue;
      var counted = false;
      for (final p in tx.postings) {
        if (ledger.account(p.accountId).kind != LedgerKind.expense) continue;
        if (expenseTypeFor(p.accountId.substring(8)) != ExpenseType.discretionary) continue;
        total += p.amount;
        if (hour >= 20) evening += p.amount;
        counted = true;
      }
      if (counted) known++;
    }
    return total == 0 || known < 2 ? null : evening * 100 / total;
  }

  /// Крупные покупки в категориях без лимита — «не было в плане месяца»:
  /// лимит на категорию и есть тот самый план (раздел 9.12). Оплата планового
  /// платежа сюда не попадает — она и так известна заранее (F11); порог
  /// сравнивается с суммой всей покупки, а не с долей одной части разделённого
  /// чека, иначе крупную покупку можно «спрятать», разбив её на категории.
  List<Transaction> unplannedLargeExpenses(DateTime monthStart, {int threshold = 2000000}) {
    final end = DateTime(monthStart.year, monthStart.month + 1, 1);
    final plannedCats = {for (final l in limits) l.category};
    return userTransactions.where((t) {
      if (t.type != EventType.expense || t.date.isBefore(monthStart) || !t.date.isBefore(end) || _isPlannedSpend(t)) return false;
      final expenseParts = t.postings.where((p) => ledger.account(p.accountId).kind == LedgerKind.expense);
      final total = expenseParts.fold(0, (s, p) => s + p.amount);
      if (total < threshold) return false;
      return expenseParts.any((p) => !plannedCats.contains(p.accountId.substring(8)));
    }).toList();
  }

  /// Во сколько раз траты в дни поступления дохода выше обычных за последние
  /// [months] месяцев (не раньше начала учёта — см. `_firstActivityMonth`,
  /// F08); `null` без доходных дней или без дней для сравнения. Знаменатель —
  /// все наблюдаемые дни соответствующего типа, а не только те, где что-то
  /// потрачено (F13): иначе дни дохода без покупок молча выпадают и меняют
  /// смысл показателя.
  double? paydaySpendRatio({int months = 3}) {
    final requestedStart = monthOf(-(months - 1));
    final firstMonth = _firstActivityMonth;
    final start = firstMonth != null && firstMonth.isAfter(requestedStart) ? firstMonth : requestedStart;
    // До сегодня включительно, не до конца месяца (повторный аудит, F04):
    // будущие дни ещё не наступили и не могут быть «обычными днями без
    // трат» — они просто не наблюдались.
    final end = today.add(const Duration(days: 1));
    final incomeDays = <DateTime>{};
    final spendByDay = <DateTime, int>{};
    for (final tx in ledger.transactions) {
      if (ledger.isReversed(tx.id)) continue;
      if (tx.date.isBefore(start) || !tx.date.isBefore(end)) continue;
      if (tx.type == EventType.income) incomeDays.add(tx.date);
      if (tx.type == EventType.expense && !_isPlannedSpend(tx)) {
        final amt = tx.postings.where((p) => ledger.account(p.accountId).kind == LedgerKind.expense).fold(0, (s, p) => s + p.amount);
        spendByDay.update(tx.date, (v) => v + amt, ifAbsent: () => amt);
      }
    }
    if (incomeDays.isEmpty) return null;
    var onIncome = 0, onIncomeDays = 0, other = 0, otherDays = 0;
    for (var d = start; d.isBefore(end); d = d.add(const Duration(days: 1))) {
      final v = spendByDay[d] ?? 0;
      if (incomeDays.contains(d)) {
        onIncome += v;
        onIncomeDays++;
      } else {
        other += v;
        otherDays++;
      }
    }
    if (onIncomeDays == 0 || otherDays == 0) return null;
    final avgIncome = onIncome / onIncomeDays;
    final avgOther = other / otherDays;
    return avgOther == 0 ? null : avgIncome / avgOther;
  }

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
          {'type': 'upsertEntity', 'kind': p.entityKind, 'entityId': p.id, 'data': p.toJson(paid: {...p.paid}..remove(period))},
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
          {'type': 'upsertEntity', 'kind': p.entityKind, 'entityId': p.id, 'data': p.toJson(paid: {...p.paid, period})},
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
  Future<void> closeGoal(GoalInfo g, {required String returnTo}) => sendBatch(closeGoalCommands(g, returnTo: returnTo));

  /// «Реализовать цель» (D98): накопленное возвращается на счёт [account], с
  /// него той же командой проводится расход [amount] в категорию [category]
  /// (вне дневного лимита, как запланированная покупка), цель закрывается.
  /// Сумма может быть и больше накопленного — разницу доплатит счёт.
  Future<void> realizeGoal(GoalInfo g, {required int amount, required String category, required String account}) => sendBatch([
        ...closeGoalCommands(g, returnTo: account),
        {
          'type': 'expense',
          'id': newId(),
          'date': _date(today),
          'account': account,
          'splits': {category: amount.toString()},
          'meta': {'who': 'shared', 'note': g.name, 'plannedPurchase': true, 'goal': g.id},
        },
      ]);

  List<Map<String, dynamic>> closeGoalCommands(GoalInfo g, {required String returnTo}) {
    final acc = g.account;
    final balance = acc != null && ledger.hasAccount(acc) ? ledger.balance(acc) : 0;
    return [
      if (acc != null && balance > 0) {'type': 'transfer', 'id': newId(), 'date': _date(today), 'from': acc, 'to': returnTo, 'amount': balance.toString()},
      for (final r in ledger.reservations.where((r) => r.goalId == g.id))
        {'type': 'release', 'goalId': g.id, 'accountId': r.accountId, 'amount': r.amount.toString()},
      if (acc != null && ledger.hasAccount(acc)) {'type': 'archiveAccount', 'accountId': acc},
      {'type': 'deleteEntity', 'kind': 'goal', 'entityId': g.id},
    ];
  }

  // ---------------------------------------------------------- категории

  List<CategoryDef> get ownCategories => customCategories.values.toList();

  /// Категория используется в журнале — удалять нельзя, иначе история потеряет подпись.
  bool categoryInUse(String id) => ledger.hasAccount(expenseAccount(id)) || ledger.hasAccount(incomeAccount(id));

  Future<String> addCategory({required String name, required int iconIndex, required bool income, ExpenseType? expenseType}) async {
    final id = 'c${newId().substring(0, 12)}';
    await upsert('category', id, {'name': name, 'icon': iconIndex, 'income': income, if (expenseType != null) 'expenseType': expenseType.name});
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
