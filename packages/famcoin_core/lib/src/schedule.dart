/// Расписание планового платежа: раз в месяц, раз в неделю или раз в год.
///
/// Одно описание сроков для приложения, утренней сводки бота и сопоставления
/// выписки: иначе недельный платёж везде считался бы ежемесячным. Ключ срока
/// ([Occurrence.period]) — то, что хранится в списке «оплачено»: для месяца
/// `ГГГГ-ММ` (как всегда было), для недели — дата срока `ГГГГ-ММ-ДД`, для
/// года — `ГГГГ`.
library;

import 'events.dart' show liabilityAccount;
import 'formulas/loans.dart' show monthlyRate;
import 'ledger.dart';
import 'money.dart' show roundHalfUp;
import 'serialization.dart';

/// Один срок платежа: дата и ключ для отметки «оплачено».
class Occurrence {
  const Occurrence(this.date, this.period);
  final DateTime date;
  final String period;

  @override
  String toString() => '$period@${dateToJson(date)}';
}

const everyMonth = 'month';
const everyWeek = 'week';
const everyYear = 'year';

/// День месяца с поправкой на короткий месяц: 31-е в апреле — 30-е.
DateTime dayOfMonth(int year, int month, int day) {
  final last = DateTime(year, month + 1, 0).day;
  return DateTime(year, month, day.clamp(1, last));
}

class PaySchedule {
  const PaySchedule({this.every = everyMonth, this.day = 1, this.weekday, this.monthOfYear, this.once, this.start, this.previous, this.onDate});

  /// Читает поля записи справочника (`planned` / `purchase`): `every`, `day`,
  /// `weekday`, `monthOfYear`, `once`, `start`. Старые записи без `every` —
  /// ежемесячные.
  factory PaySchedule.fromJson(Map<String, dynamic> d) {
    final every = d['every'];
    return PaySchedule(
      every: every == everyWeek || every == everyYear ? every as String : everyMonth,
      day: (d['day'] as num?)?.toInt() ?? 1,
      weekday: (d['weekday'] as num?)?.toInt(),
      monthOfYear: (d['monthOfYear'] as num?)?.toInt(),
      once: d['once'] as String?,
      start: d['start'] is String ? dateFromJson(d['start']) : null,
      previous: d['prev'] is Map ? PaySchedule.fromJson((d['prev'] as Map).cast<String, dynamic>()) : null,
      onDate: d['onDate'] is String ? dateFromJson(d['onDate']) : null,
    );
  }

  /// Запись справочника для сохранения: только поля расписания, без пустых.
  Map<String, Object?> toJson() => {
        if (every != everyMonth) 'every': every,
        'day': day,
        if (every == everyWeek && weekday != null) 'weekday': weekday,
        if (every == everyYear && monthOfYear != null) 'monthOfYear': monthOfYear,
        if (once != null) 'once': once,
        if (start != null) 'start': dateToJson(start!),
        if (previous != null) 'prev': previous!.toJson(),
        if (onDate != null) 'onDate': dateToJson(onDate!),
      };

  /// [everyMonth], [everyWeek] или [everyYear]; у разовой покупки — месяц.
  final String every;

  /// Число месяца, 1–31.
  final int day;

  /// День недели 1–7 (понедельник — 1) для недельного платежа.
  final int? weekday;

  /// Месяц года 1–12 для годового платежа.
  final int? monthOfYear;

  /// Разовая покупка: единственный месяц `ГГГГ-ММ`.
  final String? once;

  /// С какой даты сроки считаются; более ранние не бывают просроченными.
  /// У версии с [previous] — дата, с которой действуют эти правила.
  final DateTime? start;

  /// Один срок в точную дату — срок возврата личного долга: ключ `ГГГГ-ММ-ДД`.
  /// Просрочка остаётся, пока долг не погашен.
  final DateTime? onDate;

  /// Прежняя версия расписания (R03): смена дня или частоты платежа не должна
  /// заново создавать сроки в оплаченном прошлом. Прежние правила действуют до
  /// дня перед [start] этой версии, их ключи «оплачено» остаются верными.
  final PaySchedule? previous;

  /// Сколько прошлых недель неоплаченного недельного платежа ещё показывается:
  /// иначе забытый на полгода платёж «раз в неделю» завалил бы список.
  static const weekLookbackDays = 56;

  /// С какой даты просматривать сроки: запись обычно не смотрит дальше.
  DateTime scanFrom(DateTime today) {
    final own = _ownScanFrom(today);
    final prev = previous?.scanFrom(today);
    return prev != null && prev.isBefore(own) ? prev : own;
  }

  DateTime _ownScanFrom(DateTime today) {
    if (onDate != null) return onDate!;
    final onceMonth = once == null ? null : DateTime(int.parse(once!.substring(0, 4)), int.parse(once!.substring(5, 7)), 1);
    final base = onceMonth ?? start ?? DateTime(today.year, today.month, 1);
    final floor = switch (every) {
      everyWeek => today.subtract(const Duration(days: weekLookbackDays)),
      everyYear => DateTime(today.year - 2, 1, 1),
      _ => DateTime(today.year, today.month - 120, 1),
    };
    return base.isBefore(floor) ? floor : base;
  }

  /// Сроки в промежутке [from, to] включительно, по возрастанию дат. Срок
  /// раньше [start] не считается.
  List<Occurrence> occurrences(DateTime from, DateTime to) {
    final prev = previous;
    final out = <Occurrence>[];
    if (prev != null && start != null) {
      // Прежняя версия действует до дня перед началом этой.
      final until = start!.subtract(const Duration(days: 1));
      if (!from.isAfter(until)) out.addAll(prev.occurrences(from, to.isBefore(until) ? to : until));
    }
    out.addAll(_own(from, to));
    return out;
  }

  List<Occurrence> _own(DateTime from, DateTime to) {
    final out = <Occurrence>[];
    if (onDate != null) {
      if (!onDate!.isBefore(from) && !onDate!.isAfter(to)) out.add(Occurrence(onDate!, dateToJson(onDate!)));
      return out;
    }
    void add(DateTime date, String period) {
      if (date.isBefore(from) || date.isAfter(to)) return;
      if (start != null && date.isBefore(start!)) return;
      out.add(Occurrence(date, period));
    }

    if (once != null) {
      final year = int.parse(once!.substring(0, 4)), month = int.parse(once!.substring(5, 7));
      add(dayOfMonth(year, month, day), once!);
      return out;
    }
    switch (every) {
      case everyWeek:
        final w = (weekday ?? 1).clamp(1, 7);
        var d = DateTime(from.year, from.month, from.day);
        d = d.add(Duration(days: (w - d.weekday + 7) % 7));
        for (; !d.isAfter(to); d = DateTime(d.year, d.month, d.day + 7)) {
          add(d, dateToJson(d));
        }
      case everyYear:
        for (var y = from.year; y <= to.year; y++) {
          add(dayOfMonth(y, (monthOfYear ?? 1).clamp(1, 12), day), '$y');
        }
      default:
        for (var m = DateTime(from.year, from.month); !m.isAfter(to); m = DateTime(m.year, m.month + 1)) {
          final d = dayOfMonth(m.year, m.month, day);
          add(d, '${d.year}-${d.month.toString().padLeft(2, '0')}');
        }
    }
    return out;
  }
}

/// Платёж по кредиту действует, пока долг не погашен (R04). Одно правило для
/// приложения, календаря, утренней сводки и сопоставления выписки; оплаченные
/// сроки прошлого остаются в истории, будущие после погашения не требуются.
bool plannedDebtActive(Ledger l, String? debtId, {String? person}) {
  // Срок возврата личного долга действует, пока человеку что-то должен я.
  final id = person ?? debtId;
  return id == null || (l.hasAccount(liabilityAccount(id)) && l.balance(liabilityAccount(id)) > 0);
}

/// Виды справочника с отметками сроков: условия и исполнение в одной записи.
const paidMarkKinds = {'planned', 'purchase'};

/// Сохранение записи платежа или разовой покупки (N03): условия — из команды,
/// исполнение (`paid`) — из уже сохранённой записи. Форма, открытая до чужой
/// оплаты (или её отмены), не возвращает прежние отметки: отметки меняет
/// только `setPaid`. Версия условий — поле `rev`: команда с `rev`, отличным от
/// сохранённого, построена по устаревшей записи — условия уже поменяли на
/// другом устройстве, отказ `entityChanged` вместо молчаливой замены чужой
/// правки. Команда без `rev` (старое приложение) не проверяется. Новая запись
/// получает `rev: 1`, каждое сохранение — следующий номер. Общая для сервера,
/// приложения и тестовой заглушки сервера; [check] `false` — только слить
/// (приложение после ответа сервера).
Map<String, dynamic> mergePlannedUpsert(Map<String, dynamic>? stored, Map<String, dynamic> incoming, {bool check = true}) {
  if (stored == null) return {...incoming, 'rev': 1};
  final rev = (stored['rev'] as num?)?.toInt() ?? 0;
  final base = incoming['rev'];
  if (check && base is num && base.toInt() != rev) {
    throw LedgerException('Этот платёж уже изменили на другом устройстве', code: 'entityChanged');
  }
  return {...incoming, 'paid': stored['paid'] ?? const <String>[], 'rev': rev + 1};
}

/// Сумма срока планового платежа по банковскому долгу (CS03) — одна для
/// приложения, календаря, прогноза и сводок бота. Беспроцентная рассрочка
/// (`kind: installment`): не больше остатка — последний платёж бывает меньше
/// обычного. Кредит с процентами: не больше остатка плюс проценты за месяц
/// (как в графике `buildSchedule`) — последний платёж меньше, но проценты из
/// него не выпадают. Остаток не известен или нулевой — сумма платежа.
int debtDueAmount(Ledger l, {required int amount, required String debtId, required String kind, double rate = 0}) {
  final account = liabilityAccount(debtId);
  final left = l.hasAccount(account) ? l.balance(account) : 0;
  if (left <= 0 || amount <= 0) return amount;
  final interest = kind == 'installment' ? 0 : roundHalfUp(left * monthlyRate(rate));
  final cap = left + interest;
  return cap < amount ? cap : amount;
}

/// Сколько осталось внести к сроку возврата личного долга (N01): договорённая
/// сумма [amount] минус части к этому сроку (`meta.part` записей с этим
/// `meta.planned` и `meta.period`), но не больше долга человеку сейчас. Общая
/// для приложения, сводок бота и консультанта; `amount <= 0` — весь долг.
int personDueLeft(Ledger l, {required String planId, required String person, required int amount, required String period}) {
  final account = liabilityAccount(person);
  final owed = l.hasAccount(account) ? l.balance(account) : 0;
  if (amount <= 0) return owed;
  var parts = 0;
  for (final t in l.transactions) {
    if (t.type != EventType.repaymentMade || l.isReversed(t.id)) continue;
    if (t.meta['planned'] == planId && t.meta['period'] == period && t.meta['part'] == true) parts += -t.amountOn(account);
  }
  final left = amount - parts;
  return owed < left ? owed : left;
}

/// Команда справочника «отметить срок» (R01): добавляет или снимает один ключ
/// в списке `paid` записи платежа, не трогая остальные отметки. Полная замена
/// записи устаревшей копией с другого устройства теряла чужие отметки.
const setPaidCommand = 'setPaid';

/// Запись платежа с одной изменённой отметкой срока; [clearGoal] снимает
/// связь с копилкой (покупка совершена, копилка закрыта). Общая для приложения,
/// сервера и тестовой заглушки сервера.
Map<String, dynamic> withPaidMark(Map<String, dynamic> data, String period, {required bool paid, bool clearGoal = false}) {
  final keys = {...((data['paid'] as List?) ?? const []).cast<String>()};
  if (paid) {
    keys.add(period);
  } else {
    keys.remove(period);
  }
  final out = {...data, 'paid': keys.toList()..sort()};
  if (clearGoal) out.remove('goal');
  return out;
}
