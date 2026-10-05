/// Расписание планового платежа: раз в месяц, раз в неделю или раз в год.
///
/// Одно описание сроков для приложения, утренней сводки бота и сопоставления
/// выписки: иначе недельный платёж везде считался бы ежемесячным. Ключ срока
/// ([Occurrence.period]) — то, что хранится в списке «оплачено»: для месяца
/// `ГГГГ-ММ` (как всегда было), для недели — дата срока `ГГГГ-ММ-ДД`, для
/// года — `ГГГГ`.
library;

import 'events.dart' show liabilityAccount;
import 'ledger.dart';
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
  const PaySchedule({this.every = everyMonth, this.day = 1, this.weekday, this.monthOfYear, this.once, this.start, this.previous});

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
bool plannedDebtActive(Ledger l, String? debtId) =>
    debtId == null || (l.hasAccount(liabilityAccount(debtId)) && l.balance(liabilityAccount(debtId)) > 0);

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
