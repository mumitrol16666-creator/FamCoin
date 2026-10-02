/// План записи выписки в журнал (D94): какие строки новые, какие уже
/// записаны, чем станет каждая новая и что будет с остатком счёта.
///
/// План только читает журнал и ничего не пишет — его показывают человеку до
/// подтверждения и строят заново при нажатии «Записать».
library;

import 'package:famcoin_core/famcoin_core.dart';

import 'chat_entry.dart';
import 'ledger_service.dart';
import 'statement.dart';

/// Id операций импорта выдаются по номеру строки выписки: повторная запись
/// того же импорта не создаёт вторую операцию.
String importRowId(String importId, int n) => 'i$importId-$n';
String importOpeningId(String importId) => 'i$importId-open';
String importLevelId(String importId) => 'i$importId-level';

/// Отмена импорта помечает свои отменяющие записи этим началом id — так
/// «импорт отменили» отличается от «человек сам удалил операцию».
String importUndoId(String importId, Object what) => 'iu$importId-$what';

final _importedRow = RegExp(r'^i[0-9a-f]{12}-\d+$');
final _importedOpening = RegExp(r'^i[0-9a-f]{12}-open$');

/// Чем становится строка выписки.
enum PlanGroup {
  /// Расход: покупка.
  purchase,

  /// Расход: перевод другому человеку.
  transferOut,

  /// Расход: снятие наличных, когда счёт наличных не ведётся.
  withdrawal,

  /// Расход: комиссии и прочее.
  otherExpense,

  /// Расход: плановый платёж — его срок отмечается оплаченным.
  planned,
  income,

  /// Возврат покупки или перевода.
  refund,

  /// Перевод между своими счетами, которые оба ведутся в приложении.
  move,

  /// Уточнение остатка (O21): деньги ушли на свой счёт (или пришли с него),
  /// которого в приложении нет, либо зачислен кредит. Не расход и не доход.
  adjust,
}

/// Срок планового платежа: вид справочника, id платежа и период `ГГГГ-ММ`.
typedef DueMark = ({String kind, String id, String period});

class PlannedOp {
  const PlannedOp(this.n, this.amount, this.group, this.command, this.label, {this.mark});

  /// Номер строки выписки.
  final int n;

  /// Сумма строки в тиынах со знаком — на столько меняется остаток счёта.
  final int amount;
  final PlanGroup group;

  /// Команда журнала без `commandId`.
  final Map<String, dynamic> command;

  /// Категория, источник дохода или счёт — подпись в списке.
  final String label;

  /// Срок планового платежа, который эта операция оплачивает.
  final DueMark? mark;
}

class ImportPlan {
  ImportPlan({
    required this.ops,
    required this.written,
    required this.present,
    required this.removed,
    required this.beforeStart,
    required this.loans,
    required this.oldOpenings,
    required this.newOpening,
    required this.restartCarry,
    required this.balanceAfter,
    required this.balanceAtEnd,
    required this.gap,
    required this.piggyHeld,
    required this.startDate,
  });

  /// Новые операции — по порядку выписки, от старых к новым.
  final List<PlannedOp> ops;

  /// Строки, уже записанные этим же импортом (повтор после сбоя).
  final List<int> written;

  /// Строки, которые уже есть в журнале: записаны вручную или прошлым импортом.
  final List<int> present;

  /// Строки прошлого импорта, которые человек сам удалил, — не возвращаются.
  final List<int> removed;

  /// Строки раньше начала учёта счёта: они уже учтены в начальном остатке.
  final List<int> beforeStart;

  /// Строки, похожие на платёж по кредиту из плановых платежей: не пишутся —
  /// такой платёж делится на долг и проценты, и эту разбивку знает только
  /// человек (она в приложении банка).
  final List<({int n, String name})> loans;

  /// Начальный остаток заменяется: прежние записи отменяются, новая ставится
  /// на первый день выписки. Пустой список и `null` — остаток не трогаем.
  final List<Transaction> oldOpenings;
  final int? newOpening;

  bool get changesOpening => newOpening != null;

  /// Перенос дневного лимита начинается заново: траты прошлых дней из
  /// выписки не должны задним числом превращаться в перерасход.
  final bool restartCarry;

  /// Остаток счёта после записи — сейчас и на последний день выписки.
  final int balanceAfter;
  final int balanceAtEnd;

  /// Остаток по выписке минус [balanceAtEnd]; `null` — сверить нельзя.
  final int? gap;

  /// Сколько с этого счёта отложено в копилки целей на последний день
  /// выписки — переводами, которых в самой выписке нет. Копилка в приложении
  /// — отдельный счёт, а в банке эти деньги могут лежать на той же карте:
  /// тогда остаток в банке больше остатка счёта ровно на эту сумму.
  final int piggyHeld;

  /// С какого дня ведётся счёт (дата начального остатка), если это мешает
  /// записать часть строк.
  final DateTime? startDate;

  int count(PlanGroup g) => ops.where((o) => o.group == g).length;
  int total(PlanGroup g) => ops.where((o) => o.group == g).fold(0, (s, o) => s + o.amount);
}

// -------------------------------------------------------------- словари

/// Начало слова в названии магазина → категория. Ключ с пробелом на конце —
/// только целое слово («pub », чтобы не сработать на PUBG).
const _merchants = <String, String>{
  // продукты
  'magnum': 'food', 'small': 'food', 'galmart': 'food', 'toimart': 'food', 'metro cash': 'food', 'anvar': 'food', 'анвар': 'food',
  'ramstor': 'food', 'рамстор': 'food', 'svetofor': 'food', 'светофор': 'food', 'arzan': 'food', 'арзан': 'food', 'arbuz': 'food',
  'airba fresh': 'food', 'supermarket': 'food', 'супермаркет': 'food', 'minimarket': 'food', 'минимаркет': 'food', 'гипермаркет': 'food',
  'продукт': 'food', 'продмаг': 'food', 'grocery': 'food', 'магазин': 'food', 'дүкен': 'food', 'market': 'food', 'маркет': 'food',
  'пекарн': 'food', 'bakery': 'food', 'мясн': 'food', 'фрукт': 'food', 'овощ': 'food',
  // кафе и доставка еды
  'cafe': 'cafe', 'кафе': 'cafe', 'coffee': 'cafe', 'кофе': 'cafe', 'restaurant': 'cafe', 'ресторан': 'cafe', 'pizza': 'cafe', 'пицц': 'cafe',
  'burger': 'cafe', 'бургер': 'cafe', 'doner': 'cafe', 'донер': 'cafe', 'kfc ': 'cafe', 'mcdonald': 'cafe', 'hardee': 'cafe', 'popeyes': 'cafe',
  'dodo': 'cafe', 'starbucks': 'cafe', 'bahandi': 'cafe', 'salam bro': 'cafe', 'sushi': 'cafe', 'суши': 'cafe', 'столов': 'cafe', 'асхана': 'cafe',
  'дәмхана': 'cafe', 'мейрамхана': 'cafe', 'lounge': 'cafe', 'pub ': 'cafe', 'паб ': 'cafe', 'bistro': 'cafe', 'бистро': 'cafe', 'chocofood': 'cafe',
  'wolt': 'cafe', 'glovo': 'cafe', 'yandex eda': 'cafe', 'шашлы': 'cafe', 'чайхан': 'cafe', 'кулинар': 'cafe',
  // транспорт и топливо
  'taxi': 'transport', 'такси': 'transport', 'yandex go': 'transport', 'yandex taxi': 'transport', 'uber': 'transport', 'indrive': 'transport',
  'onay': 'transport', 'автобус': 'transport', 'парков': 'transport', 'parking': 'transport', 'паркинг': 'transport', 'азс ': 'transport',
  'sinooil': 'transport', 'qazaq oil': 'transport', 'helios': 'transport', 'kazmunaygas': 'transport', 'gazprom': 'transport', 'газпром': 'transport',
  'royal petrol': 'transport', 'petrol': 'transport', 'oil ': 'transport', 'автомойк': 'transport', 'carwash': 'transport', 'шиномонтаж': 'transport',
  'автозапчаст': 'transport', 'air astana': 'transport', 'flyarystan': 'transport', 'fly arystan': 'transport', 'aviata': 'transport',
  'chocotravel': 'transport', 'railways': 'transport',
  // здоровье
  'аптек': 'health', 'apteka': 'health', 'pharmacy': 'health', 'pharm': 'health', 'europharma': 'health', 'biosfera': 'health', 'биосфера': 'health',
  'sadyhan': 'health', 'садыхан': 'health', 'clinic': 'health', 'клиник': 'health', 'stomat': 'health', 'стомат': 'health', 'dental': 'health',
  'medical': 'health', 'медцентр': 'health', 'invivo': 'health', 'инвиво': 'health', 'лаборатор': 'health', 'оптика': 'health', 'optika': 'health',
  'дәріхана': 'health', 'емхана': 'health', 'hospital': 'health', 'больниц': 'health',
  // дети
  'детск': 'kids', 'kids': 'kids', 'baby': 'kids', 'toys': 'kids', 'игрушк': 'kids', 'балалар': 'kids',
  // коммунальные и связь
  'алсеко': 'utilities', 'alseco': 'utilities', 'ерц ': 'utilities', 'erc ': 'utilities', 'энергосбыт': 'utilities', 'energosbyt': 'utilities',
  'водоканал': 'utilities', 'су арнасы': 'utilities', 'теплосет': 'utilities', 'теплотранзит': 'utilities', 'коммунал': 'utilities',
  'qazaqgaz': 'utilities', 'казтрансгаз': 'utilities',
  'beeline': 'phone', 'билайн': 'phone', 'kcell': 'phone', 'activ': 'phone', 'tele2': 'phone', 'altel': 'phone', 'izi ': 'phone',
  'kazakhtelecom': 'phone', 'казахтелеком': 'phone', 'alma tv': 'phone', 'almatv': 'phone', 'megaline': 'phone',
  // быт, техника, маркетплейсы
  'sulpak': 'household', 'technodom': 'household', 'mechta': 'household', 'alser': 'household', 'fix price': 'household', 'leroy': 'household',
  'хозтовар': 'household', 'хозяйствен': 'household', 'ozon': 'household', 'aliexpress': 'household', 'temu': 'household',
  'kaspi магазин': 'household', 'kaspi magazin': 'household', 'jysk': 'household', 'строймарт': 'household', 'стройматериал': 'household',
  'мебел': 'household', 'dns ': 'household',
  // развлечения
  'kino': 'fun', 'кино': 'fun', 'cinema': 'fun', 'chaplin': 'fun', 'ticketon': 'fun', 'steam': 'fun', 'playstation': 'fun', 'xbox': 'fun',
  'game': 'fun', 'боулинг': 'fun', 'bowling': 'fun', 'театр': 'fun', 'concert': 'fun', 'концерт': 'fun', 'караоке': 'fun',
  // одежда
  'wildberries': 'clothes', 'lamoda': 'clothes', 'zara': 'clothes', 'waikiki': 'clothes', 'defacto': 'clothes', 'adidas': 'clothes',
  'nike': 'clothes', 'sportmaster': 'clothes', 'спортмастер': 'clothes', 'koton': 'clothes', 'ostin': 'clothes', 'gloria jeans': 'clothes',
  'intertop': 'clothes', 'одежд': 'clothes', 'обув': 'clothes',
  // образование
  'school': 'education', 'университет': 'education', 'university': 'education', 'coursera': 'education', 'udemy': 'education',
  'skillbox': 'education', 'книжн': 'education', 'meloman': 'education', 'меломан': 'education',
  // подписки
  'netflix': 'subscriptions', 'spotify': 'subscriptions', 'youtube': 'subscriptions', 'google': 'subscriptions', 'apple': 'subscriptions',
  'itunes': 'subscriptions', 'icloud': 'subscriptions', 'openai': 'subscriptions', 'chatgpt': 'subscriptions', 'anthropic': 'subscriptions',
  'claude': 'subscriptions', 'yandex plus': 'subscriptions', 'kinopoisk': 'subscriptions', 'кинопоиск': 'subscriptions', 'ivi ': 'subscriptions',
  'telegram': 'subscriptions', 'adobe': 'subscriptions', 'microsoft': 'subscriptions', 'notion': 'subscriptions', 'github': 'subscriptions',
  'jetbrains': 'subscriptions', 'discord': 'subscriptions', 'canva': 'subscriptions', 'figma': 'subscriptions', 'zoom': 'subscriptions',
  // подарки
  'цветы': 'gifts', 'flowers': 'gifts', 'flower': 'gifts', 'gift': 'gifts', 'подарк': 'gifts',
};

String _plain(String s) => s.toLowerCase().replaceAll('ё', 'е').replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ').trim();

/// Категория покупки по названию магазина из выписки; `null` — не узнали.
String? merchantCategory(String details) {
  final text = ' ${_plain(details)} ';
  String? best;
  var bestLength = 0;
  for (final e in _merchants.entries) {
    if (e.key.length > bestLength && text.contains(' ${e.key}')) {
      best = e.value;
      bestLength = e.key.length;
    }
  }
  return best;
}

final _depositWords = RegExp(r'депозит|deposit|вклад|жинақ');
final _cashWords = RegExp(r'банкомат|терминал|наличн|қолма-қол|(?<![a-z])atm(?![a-z])|(?<![a-z])cash');
final _salaryWords = RegExp(r'зарплат|заработн|аванс|жалақы|salary|payroll');
final _cashbackWords = RegExp(r'кешбэк|кэшбек|кешбек|cashback|бонус');
final _interestWords = RegExp(r'вознагражден|сыйақы|процент|пайыз|interest');
final _feeWords = RegExp(r'комисси|commission|(?<![a-z])fee');

DateTime _day(DateTime d, int shift) => DateTime(d.year, d.month, d.day + shift);

/// Неоплаченный срок планового платежа.
class _Due {
  _Due(this.kind, this.id, this.data, this.amount, this.date, this.period);
  final String kind;
  final String id;
  final Map<String, dynamic> data;
  final int amount;
  final DateTime date;
  final String period;
  bool used = false;

  String get name => '${data['name'] ?? ''}'.trim();
}

/// Строит план записи выписки [st] на счёт [accountId]. [today] — сегодняшний
/// день по времени Казахстана.
ImportPlan planImport(BankStatement st, LedgerView v, String accountId, String importId, DateTime today) {
  final l = v.ledger;
  final kk = v.locale == 'kk';
  final accounts = chatAccounts(v);
  final meta = v.of('account')[accountId] ?? const {};
  final who = v.profile['mode'] == 'family' ? meta['owner'] as String? ?? 'me' : 'me';
  final currency = l.account(accountId).currency;
  final others = accounts.where((a) => a.id != accountId && l.account(a.id).currency == currency).toList();
  final deposits = others.where((a) => a.type == 'deposit' || _depositWords.hasMatch(a.name.toLowerCase())).toList();
  final cash = others.where((a) => a.type == 'cash').toList();
  final expenseIds = {...chatCategories(v, income: false), 'fees'};
  final incomeIds = chatCategories(v, income: true).toSet();

  // ------------------------------------------------ что уже есть в журнале
  final ownIds = {for (var n = 0; n < st.rows.length; n++) importRowId(importId, n)};
  final openingId = importOpeningId(importId);
  final reversalOf = <String, String>{};
  for (final t in l.transactions) {
    if (t.reverses != null) reversalOf[t.reverses!] = t.id;
  }
  final live = <String, List<Transaction>>{};
  final deleted = <String, List<Transaction>>{};
  final openings = <Transaction>[];
  // Категория, которую человек уже выбирал для такой же заметки: исправил
  // один раз в приложении — следующая выписка запишет так же.
  final history = <String, String>{};
  // Оплаты плановых платежей, отмеченные в приложении: дата у них — день
  // отметки, а не день списания в банке.
  final paidPlanned = <Transaction>[];
  var earlier = false;
  for (final t in l.transactions) {
    if (t.type == EventType.reversal) continue;
    final amount = t.amountOn(accountId);
    final reversed = l.isReversed(t.id);
    if (!reversed && t.type == EventType.expense && t.meta['note'] is String) {
      final spent = t.postings.where((p) => p.accountId.startsWith('expense:')).toList();
      if (spent.length == 1) history[_plain(t.meta['note'] as String)] = spent.single.accountId.substring(8);
    }
    if (amount == 0) continue;
    if (t.type == EventType.opening) {
      if (!reversed && t.id != openingId) openings.add(t);
      continue;
    }
    if (ownIds.contains(t.id)) continue;
    final key = '${dateToJson(t.date)}|$amount';
    if (!reversed) {
      live.putIfAbsent(key, () => []).add(t);
      if (t.meta['planned'] != null) paidPlanned.add(t);
      if (t.date.isBefore(st.from)) earlier = true;
    } else if (_importedRow.hasMatch(t.id) && !(reversalOf[t.id] ?? '').startsWith('iu')) {
      deleted.putIfAbsent(key, () => []).add(t);
    }
  }

  final used = <String>{};
  bool take(Map<String, List<Transaction>> from, DateTime date, int amount) {
    final list = from['${dateToJson(date)}|$amount'];
    if (list == null || list.isEmpty) return false;
    used.add(list.removeLast().id);
    return true;
  }

  final written = <int>[];
  final present = <int>[];
  final removed = <int>[];
  final fresh = <int>[];
  for (var n = 0; n < st.rows.length; n++) {
    final r = st.rows[n];
    if (l.byId(importRowId(importId, n)) != null) {
      written.add(n);
    } else if (take(live, r.date, r.amount)) {
      present.add(n);
    } else if (take(deleted, r.date, r.amount)) {
      removed.add(n);
    } else {
      fresh.add(n);
    }
  }
  // Записанное вручную могло попасть на соседний день: банк ставит свою дату.
  fresh.removeWhere((n) {
    final r = st.rows[n];
    final found = take(live, _day(r.date, -1), r.amount) || take(live, _day(r.date, 1), r.amount);
    if (found) present.add(n);
    return found;
  });
  // Плановый платёж отмечают оплаченным когда вспомнят — запись может стоять
  // на недели позже списания. Ищем её по сумме, ближайшую по дате.
  fresh.removeWhere((n) {
    final r = st.rows[n];
    Transaction? nearest;
    var best = 36;
    for (final t in paidPlanned) {
      if (used.contains(t.id) || t.amountOn(accountId) != r.amount) continue;
      final days = daysBetween(r.date, t.date).abs();
      if (days < best) {
        best = days;
        nearest = t;
      }
    }
    if (nearest == null) return false;
    used.add(nearest.id);
    present.add(n);
    return true;
  });
  present.sort();

  // ------------------------------------------------------ начальный остаток
  // Выписка, сошедшаяся с банком, знает остаток на свой первый день. Если до
  // неё по счёту ничего не записано, начало учёта счёта переносится на этот
  // день: иначе операции выписки до прежнего начального остатка посчитались
  // бы дважды — они уже «сидят» в нём.
  final alreadyOpened = l.byId(openingId) != null;
  final startDate = openings.isEmpty ? null : openings.map((t) => t.date).reduce((a, b) => a.isAfter(b) ? a : b);
  final openingSum = openings.fold<int>(0, (s, t) => s + t.amountOn(accountId));
  final fromImport = openings.length == 1 && _importedOpening.hasMatch(openings.single.id);
  var canMove = alreadyOpened;
  if (!alreadyOpened && st.balanced && !earlier) {
    canMove = startDate == null ||
        (!startDate.isBefore(st.from) && !startDate.isAfter(st.to)) ||
        // Выписка кончается ровно накануне начала учёта и сходится с ним.
        (startDate == _day(st.to, 1) && openingSum == st.closing);
  }
  final sameOpening = openings.length == 1 && startDate == st.from && openingSum == st.opening;
  final changes = canMove && !alreadyOpened && !sameOpening && !(openings.isEmpty && st.opening == 0);

  final beforeStart = <int>[];
  if (!canMove && startDate != null) {
    // Начальный остаток, поставленный прошлой выпиской, — остаток на начало
    // дня; введённый вручную — на какой-то момент дня, поэтому его день
    // целиком считается уже учтённым.
    fresh.removeWhere((n) {
      final d = st.rows[n].date;
      final before = fromImport ? d.isBefore(startDate) : !d.isAfter(startDate);
      if (before) beforeStart.add(n);
      return before;
    });
  }

  // ------------------------------------------------- плановые платежи
  // Неоплаченные сроки рядом с периодом выписки. Списание на ту же сумму
  // около срока — это он: расход пишется в категорию платежа, срок
  // отмечается оплаченным, в дневной лимит такая трата не входит.
  final dues = <_Due>[];
  for (final kind in const ['planned', 'purchase']) {
    for (final e in v.of(kind).entries) {
      final data = e.value;
      final amount = int.tryParse('${data['amount']}') ?? 0;
      final debtId = data['debtId'] as String?;
      if (amount <= 0) continue;
      // Платёж по уже закрытому долгу не действует — как в приложении.
      if (debtId != null && !(v.of('debt').containsKey(debtId) && l.hasAccount(liabilityAccount(debtId)) && l.balance(liabilityAccount(debtId)) > 0)) continue;
      final paid = {...((data['paid'] as List?) ?? const []).cast<String>()};
      final start = data['start'] is String ? dateFromJson(data['start']) : null;
      final day = (data['day'] as num?)?.toInt() ?? 1;
      for (var m = DateTime(st.from.year, st.from.month - 1); !m.isAfter(DateTime(st.to.year, st.to.month + 1)); m = DateTime(m.year, m.month + 1)) {
        final lastDay = DateTime(m.year, m.month + 1, 0).day;
        final date = DateTime(m.year, m.month, day < 1 ? 1 : (day > lastDay ? lastDay : day));
        final period = dateToJson(date).substring(0, 7);
        if (start != null && date.isBefore(start)) continue;
        if (data['once'] != null && data['once'] != period) continue;
        if (paid.contains(period)) continue;
        dues.add(_Due(kind, e.key, data, amount, date, period));
      }
    }
  }

  _Due? dueFor(StatementRow r) {
    if (r.amount >= 0 || r.kind == RowKind.withdrawal || r.kind == RowKind.credit) return null;
    _Due? nearest;
    var best = 11;
    for (final d in dues) {
      if (d.used || d.amount != -r.amount) continue;
      final days = daysBetween(r.date, d.date).abs();
      if (days < best) {
        best = days;
        nearest = d;
      }
    }
    return nearest;
  }

  // ------------------------------------------------------- новые операции
  String clip(String s) => s.length > maxNoteLength ? s.substring(0, maxNoteLength) : s;
  String join(String title, String details) => details.isEmpty ? title : '$title: $details';

  PlannedOp plan(int n) {
    final r = st.rows[n];
    final id = importRowId(importId, n);
    final date = dateToJson(r.date);
    final abs = r.amount.abs().toString();
    final out = r.amount < 0;
    final low = '${r.operation} ${r.details}'.toLowerCase();

    PlannedOp expense(PlanGroup g, String category, String note) {
      final c = expenseIds.contains(history[_plain(note)]) ? history[_plain(note)]! : (expenseIds.contains(category) ? category : 'other');
      return PlannedOp(n, r.amount, g, {
        'type': 'expense',
        'id': id,
        'date': date,
        'account': accountId,
        'splits': {c: abs},
        'meta': {'who': who, if (note.isNotEmpty) 'note': clip(note), 'src': 'kaspi'},
      }, categoryName(c, v));
    }

    PlannedOp income(String note) {
      final guess = _salaryWords.hasMatch(low) ? 'salary' : (_cashbackWords.hasMatch(low) ? 'cashback' : (_interestWords.hasMatch(low) ? 'interestIncome' : 'otherIncome'));
      final source = incomeIds.contains(guess) ? guess : 'otherIncome';
      return PlannedOp(n, r.amount, PlanGroup.income, {
        'type': 'income',
        'id': id,
        'date': date,
        'account': accountId,
        'source': source,
        'amount': abs,
        'meta': {if (note.isNotEmpty) 'note': clip(note), 'src': 'kaspi'},
      }, categoryName(source, v));
    }

    PlannedOp refund(String category, String note) {
      final c = expenseIds.contains(history[_plain(note)]) ? history[_plain(note)]! : (expenseIds.contains(category) ? category : 'other');
      return PlannedOp(n, r.amount, PlanGroup.refund, {
        'type': 'refund',
        'id': id,
        'date': date,
        'category': c,
        'amount': abs,
        'toAccount': accountId,
        'meta': {'who': who, if (note.isNotEmpty) 'note': clip(note), 'src': 'kaspi'},
      }, categoryName(c, v));
    }

    PlannedOp move(ChatAccount other) => PlannedOp(n, r.amount, PlanGroup.move, {
          'type': 'transfer',
          'id': id,
          'date': date,
          'from': out ? accountId : other.id,
          'to': out ? other.id : accountId,
          'amount': abs,
          'meta': {'src': 'kaspi'},
        }, other.name);

    PlannedOp adjust(String reason) => PlannedOp(n, r.amount, PlanGroup.adjust, {
          'type': 'adjustment',
          'id': id,
          'date': date,
          'account': accountId,
          'delta': r.amount.toString(),
          'reason': clip(reason),
        }, kk ? 'Қалдықты нақтылау' : 'Уточнение остатка');

    PlannedOp own() {
      if (deposits.length == 1 && _depositWords.hasMatch(low)) return move(deposits.single);
      return adjust(
        out
            ? join(kk ? 'FamCoin-де жоқ өз шотыма аударым' : 'Перевод на свой счёт, которого нет в FamCoin', r.details)
            : join(kk ? 'FamCoin-де жоқ өз шотымнан түсім' : 'Поступление со своего счёта, которого нет в FamCoin', r.details),
      );
    }

    switch (r.kind) {
      case RowKind.purchase:
        final category = merchantCategory(r.details) ?? 'other';
        return out ? expense(PlanGroup.purchase, category, r.details) : refund(category, r.details);
      case RowKind.transfer:
        return out
            ? expense(PlanGroup.transferOut, 'other', join(kk ? 'Аударым' : 'Перевод', r.details))
            : refund('other', join(kk ? 'Аударым қайтарылды' : 'Возврат перевода', r.details));
      case RowKind.topup:
        if (!out && cash.length == 1 && _cashWords.hasMatch(low)) return move(cash.single);
        return out
            ? expense(PlanGroup.otherExpense, 'other', join(kk ? 'Толықтыру қайтарылды' : 'Отмена пополнения', r.details))
            : income(join(kk ? 'Толықтыру' : 'Пополнение', r.details));
      case RowKind.withdrawal:
        if (cash.length == 1) return move(cash.single);
        final note = join(kk ? 'Қолма-қол ақша алу' : 'Снятие наличных', r.details);
        return out ? expense(PlanGroup.withdrawal, 'other', note) : refund('other', note);
      case RowKind.ownOut || RowKind.ownIn:
        return own();
      case RowKind.credit:
        return adjust(join(kk ? 'Несие түсті (несие FamCoin-де есепке алынбаған)' : 'Зачисление кредита (кредит не учтён в FamCoin)', r.details));
      case RowKind.other:
        final note = r.details.isEmpty ? r.operation : r.details;
        return out ? expense(PlanGroup.otherExpense, _feeWords.hasMatch(low) ? 'fees' : 'other', note) : income(note);
      case RowKind.unknown:
        if (_depositWords.hasMatch(low)) return own();
        final note = join(r.operation, r.details);
        return out ? expense(PlanGroup.otherExpense, 'other', note) : income(note);
    }
  }

  PlannedOp payment(int n, _Due due) {
    final r = st.rows[n];
    final category = expenseIds.contains(due.data['category']) ? due.data['category'] as String : 'other';
    final mark = (kind: due.kind, id: due.id, period: due.period);
    // Та же запись, что делает «Оплатить» в приложении: заметка — название
    // платежа, связь со сроком — в `meta`.
    return PlannedOp(n, r.amount, PlanGroup.planned, {
      'type': 'expense',
      'id': importRowId(importId, n),
      'date': dateToJson(r.date),
      'account': accountId,
      'splits': {category: r.amount.abs().toString()},
      'meta': {'who': 'shared', 'note': clip(due.name), 'planned': due.id, 'period': due.period, 'src': 'kaspi'},
    }, categoryName(category, v), mark: mark);
  }

  final ops = <PlannedOp>[];
  final loans = <({int n, String name})>[];
  for (final n in fresh) {
    final due = dueFor(st.rows[n]);
    // Разовую покупку с копилкой оплачивают в приложении: там копилка
    // закрывается и деньги возвращаются на счёт.
    if (due == null || due.data['goal'] != null) {
      ops.add(plan(n));
      continue;
    }
    due.used = true;
    if (due.data['debtId'] != null) {
      loans.add((n: n, name: due.name));
    } else {
      ops.add(payment(n, due));
    }
  }

  // --------------------------------------------------------------- остатки
  final added = ops.fold<int>(0, (s, o) => s + o.amount);
  var shift = 0;
  var shiftAtEnd = 0;
  if (changes) {
    shift = st.opening! - openingSum;
    shiftAtEnd = st.opening! - openings.where((t) => !t.date.isAfter(st.to)).fold<int>(0, (s, t) => s + t.amountOn(accountId));
  }
  final balanceAtEnd = l.balance(accountId, asOf: st.to) + added + shiftAtEnd;

  final types = v.of('account');
  bool piggy(String id) => isPiggy(id) || types[id]?['type'] == 'piggy';
  var piggyHeld = 0;
  for (final t in l.transactions) {
    if (t.type != EventType.transfer || t.date.isAfter(st.to) || used.contains(t.id) || l.isReversed(t.id)) continue;
    if (t.postings.any((p) => p.accountId != accountId && piggy(p.accountId))) piggyHeld -= t.amountOn(accountId);
  }

  final limit = v.profile['dailyLimit'];
  final since = v.profile['dailyLimitSince'];
  final restartCarry = limit != null &&
      v.profile['dailyLimitCarry'] == true &&
      since is String &&
      // Плановые платежи в дневной лимит не входят — перенос они не трогают.
      ops.any((o) => o.command['type'] == 'expense' && o.mark == null && !st.rows[o.n].date.isBefore(dateFromJson(since)) && st.rows[o.n].date.isBefore(today));

  return ImportPlan(
    ops: ops,
    written: written,
    present: present,
    removed: removed,
    beforeStart: beforeStart,
    loans: loans,
    oldOpenings: changes ? openings : const [],
    newOpening: changes ? st.opening : null,
    restartCarry: restartCarry,
    balanceAfter: l.balance(accountId) + added + shift,
    balanceAtEnd: balanceAtEnd,
    // Пока часть строк не записана, остаток с банком сравнивать рано.
    gap: st.balanced && beforeStart.isEmpty && loans.isEmpty ? st.closing! - balanceAtEnd : null,
    piggyHeld: piggyHeld,
    startDate: startDate,
  );
}

/// Команды замены начального остатка: прежние записи отменяются, новая
/// помечается как их правка — в корзине прежние не появляются.
List<Map<String, dynamic>> openingCommands(ImportPlan plan, BankStatement st, String accountId, String importId) => [
      for (var k = 0; k < plan.oldOpenings.length; k++) {'type': 'reverse', 'txId': plan.oldOpenings[k].id, 'id': 'i$importId-openrev$k'},
      if (plan.changesOpening && plan.newOpening != 0)
        {
          'type': 'opening',
          'id': importOpeningId(importId),
          'date': dateToJson(st.from),
          'account': accountId,
          'amount': plan.newOpening.toString(),
          'meta': {if (plan.oldOpenings.isNotEmpty) 'edited': plan.oldOpenings.last.id, 'src': 'kaspi'},
        },
    ];

/// Отметка сроков оплаченными: справочник платежа с дополненным списком
/// `paid`. [paidSoFar] копит периоды по платежам — у платежа может быть
/// несколько сроков в одной выписке.
Map<String, dynamic> markCommand(DueMark mark, LedgerView v, Map<String, Set<String>> paidSoFar) {
  final data = v.of(mark.kind)[mark.id] ?? const <String, dynamic>{};
  final paid = paidSoFar.putIfAbsent('${mark.kind}|${mark.id}', () => {...((data['paid'] as List?) ?? const []).cast<String>()})..add(mark.period);
  return {
    'type': 'upsertEntity',
    'kind': mark.kind,
    'entityId': mark.id,
    'data': {...data, 'paid': paid.toList()..sort()},
  };
}
