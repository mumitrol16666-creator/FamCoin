/// Дневной лимит повседневных трат: сколько потрачено и сколько доступно.
///
/// Лимит задаёт сам владелец (D48). Неизрасходованное может переноситься на
/// следующие дни (D64, D70) по истории сумм лимита (D71). Доступное не больше
/// денег на счетах без отложенного на цели (D73); предстоящие платежи его не
/// уменьшают (D81). Расчёт один для приложения, сводок и бота — число на
/// главном экране и в Telegram всегда совпадает.
library;

import '../ledger.dart';
import '../serialization.dart';

/// День, к которому относится трата. Возврат уменьшает траты того дня, когда
/// была покупка, а не дня возврата: вернули вчерашний кофе — вчерашние расходы
/// уменьшились, сегодняшний лимит не тронут. `null` — возврат по удалённой
/// покупке: в дневные траты не входит (деньги на счёте он всё равно учитывает).
DateTime? spendDay(Ledger l, Transaction t) {
  if (t.type == EventType.refund) {
    final of = t.meta['refundOf'];
    if (of is String) return l.currentVersion(of)?.date;
  }
  return t.date;
}

/// Трата вне дневного лимита: оплата планового платежа (раздел 9.3, T33),
/// покупка, которую владелец отметил как запланированную (D74), или
/// непредвиденная трата (D101). То же для возврата по такой покупке. Деньги со
/// счёта такая трата тратит как обычно — она не входит только в дневной лимит
/// и в разборы привычек. Имя функции историческое: «запланированная» здесь
/// значит «не из дневных мелочей».
bool isPlannedSpend(Ledger l, Transaction t) => _flagged(l, t, (m) => m['planned'] != null || m['plannedPurchase'] == true || m['unexpected'] == true);

/// Непредвиденная трата (D101): владелец отметил её так в диалоге «Крупная
/// покупка» или в карточке операции. Вне дневного лимита, как запланированная,
/// но считается отдельно — чтобы было видно, сколько за месяц ушло на внезапное.
bool isUnexpectedSpend(Ledger l, Transaction t) => _flagged(l, t, (m) => m['unexpected'] == true);

bool _flagged(Ledger l, Transaction t, bool Function(Map<String, dynamic>) test) {
  if (test(t.meta)) return true;
  final of = t.meta['refundOf'];
  if (t.type != EventType.refund || of is! String) return false;
  final original = l.currentVersion(of) ?? l.byId(of);
  return original != null && test(original.meta);
}

class DaySpend {
  const DaySpend(this.everyday, this.planned, this.byCategory, {this.unexpected = 0});

  /// Повседневные траты — те, что идут в дневной лимит. Не меньше нуля.
  final int everyday;

  /// Запланированные траты — вне лимита. Не меньше нуля.
  final int planned;

  /// Непредвиденные траты (D101) — тоже вне лимита, отдельно от
  /// запланированных. Не меньше нуля.
  final int unexpected;

  /// Всё, что не вошло в дневной лимит.
  int get outside => planned + unexpected;

  /// Повседневные траты по категориям (id категории → сумма больше нуля).
  final Map<String, int> byCategory;
}

/// Траты за дни [from]–[to] включительно: покупки минус возвраты по покупкам
/// этих дней (возврат считается по дню покупки — см. [spendDay]).
DaySpend spendBetween(Ledger l, DateTime from, DateTime to) {
  var everyday = 0;
  var planned = 0;
  var unexpected = 0;
  final byCategory = <String, int>{};
  for (final tx in l.transactions) {
    if ((tx.type != EventType.expense && tx.type != EventType.refund) || l.isReversed(tx.id)) continue;
    final day = spendDay(l, tx); // возврат по удалённой покупке даёт null и сюда не попадает
    if (day == null || day.isBefore(from) || day.isAfter(to)) continue;
    final sudden = isUnexpectedSpend(l, tx);
    final outside = sudden || isPlannedSpend(l, tx);
    for (final p in tx.postings) {
      if (l.account(p.accountId).kind != LedgerKind.expense) continue;
      if (sudden) {
        unexpected += p.amount;
      } else if (outside) {
        planned += p.amount;
      } else {
        everyday += p.amount;
        byCategory.update(p.accountId.substring(p.accountId.indexOf(':') + 1), (s) => s + p.amount, ifAbsent: () => p.amount);
      }
    }
  }
  return DaySpend(everyday < 0 ? 0 : everyday, planned < 0 ? 0 : planned, byCategory..removeWhere((_, s) => s <= 0), unexpected: unexpected < 0 ? 0 : unexpected);
}

/// Сумма лимита, действующая с даты [from] до следующей записи.
typedef LimitPeriod = ({DateTime from, int amount});

/// История суммы лимита по датам (D71) из профиля владельца, по возрастанию
/// дат. Смена суммы не пересчитывает прошлые дни по новой ставке: без истории
/// переход с 5 000 на 8 000 ₸ на десятый день переноса добавил бы 30 000 ₸,
/// которых никто не выдавал.
List<LimitPeriod> dailyLimitHistoryOf(Map<String, dynamic> profile) {
  final raw = profile['dailyLimitHistory'];
  if (raw is! List) return const [];
  return <LimitPeriod>[
    for (final e in raw)
      if (e is Map && e['from'] != null && e['amount'] != null) (from: dateFromJson(e['from']), amount: parseMinor(e['amount'])),
  ]..sort((a, b) => a.from.compareTo(b.from));
}

/// Число суток между двумя датами (по календарю, без сдвигов часовых поясов).
int daysBetween(DateTime a, DateTime b) => DateTime.utc(b.year, b.month, b.day).difference(DateTime.utc(a.year, a.month, a.day)).inDays;

/// Сколько лимита выдано за дни [from]–[to] включительно по истории сумм [h];
/// без истории (профиль до D71) — по текущей сумме [currentLimit].
int limitGranted(List<LimitPeriod> h, DateTime from, DateTime to, int currentLimit) {
  if (h.isEmpty) return currentLimit * (daysBetween(from, to) + 1);
  var sum = 0;
  if (h.first.from.isAfter(from)) {
    // дни до первой записи истории — по её сумме (действующей раньше нет)
    final end = h.first.from.isAfter(to) ? to : h.first.from.subtract(const Duration(days: 1));
    final days = daysBetween(from, end) + 1;
    if (days > 0) sum += h.first.amount * days;
  }
  for (var i = 0; i < h.length; i++) {
    final segStart = h[i].from.isAfter(from) ? h[i].from : from;
    final next = i + 1 < h.length ? DateTime(h[i + 1].from.year, h[i + 1].from.month, h[i + 1].from.day - 1) : to;
    final segEnd = next.isAfter(to) ? to : next;
    final days = daysBetween(segStart, segEnd) + 1;
    if (days > 0) sum += h[i].amount * days;
  }
  return sum;
}

/// Дневной лимит на сегодня — всё, что показывает карточка на главной.
class DailyLimitState {
  const DailyLimitState({
    required this.limit,
    required this.carryOn,
    required this.since,
    required this.spentToday,
    required this.outsideToday,
    required this.planned,
    required this.available,
  });

  /// Лимит на день; `null` — не задан.
  final int? limit;

  /// Переносится ли остаток на следующий день (D70).
  final bool carryOn;

  /// С какого дня копится перенос (D64).
  final DateTime? since;

  /// Сегодняшние повседневные траты.
  final int spentToday;

  /// Сегодняшние запланированные и непредвиденные траты — в лимит не вошли (D74, D101).
  final int outsideToday;

  /// Доступно по лимиту и переносу, без оглядки на деньги. За каждый день с
  /// начала копления лимит либо остаётся неизрасходован и добавляется к
  /// завтрашнему, либо превышен — и настолько же уменьшает доступное на
  /// будущее: «выдано лимитов за N дней минус потрачено за N дней».
  final int? planned;

  /// Доступно сегодня: [planned], но не больше денег на счетах без отложенного
  /// на цели. Перерасход остаётся отрицательным — ограничение срезает только плюс.
  final int? available;

  /// Вклад прошлых дней: положительный — прошлые дни сэкономили и добавили
  /// сегодня, отрицательный — прошлый перерасход уменьшил сегодняшнюю сумму.
  /// `0` в первый день лимита или без переноса.
  int get carry => limit == null || planned == null ? 0 : planned! - (limit! - spentToday);

  /// Доступное срезано деньгами на счетах.
  bool get capped => planned != null && available != null && planned! > available!;
}

/// Состояние дневного лимита на день [today] по журналу и профилю владельца
/// (`dailyLimit`, `dailyLimitCarry`, `dailyLimitSince`, `dailyLimitHistory`).
DailyLimitState dailyLimitState(Ledger l, Map<String, dynamic> profile, DateTime today) {
  final limit = profile['dailyLimit'] == null ? null : parseMinor(profile['dailyLimit']);
  final carryOn = profile['dailyLimitCarry'] == true;
  final since = profile['dailyLimitSince'] == null ? null : dateFromJson(profile['dailyLimitSince']);
  final day = spendBetween(l, today, today);

  int? planned;
  if (limit != null) {
    if (!carryOn) {
      planned = limit - day.everyday;
    } else {
      final start = since == null || since.isAfter(today) ? today : since;
      planned = limitGranted(dailyLimitHistoryOf(profile), start, today, limit) - spendBetween(l, start, today).everyday;
    }
  }
  int? available;
  if (planned != null) {
    final money = l.freeLiquid();
    final cap = money < 0 ? 0 : money;
    available = planned > cap ? cap : planned;
  }
  return DailyLimitState(
    limit: limit,
    carryOn: carryOn,
    since: since,
    spentToday: day.everyday,
    outsideToday: day.outside,
    planned: planned,
    available: available,
  );
}
