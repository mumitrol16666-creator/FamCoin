/// Расписание планового платежа: раз в месяц, раз в неделю или раз в год.
///
/// Одно описание сроков для приложения, утренней сводки бота и сопоставления
/// выписки: иначе недельный платёж везде считался бы ежемесячным. Ключ срока
/// ([Occurrence.period]) — то, что хранится в списке «оплачено»: для месяца
/// `ГГГГ-ММ` (как всегда было), для недели — дата срока `ГГГГ-ММ-ДД`, для
/// года — `ГГГГ`.
library;

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
  const PaySchedule({this.every = everyMonth, this.day = 1, this.weekday, this.monthOfYear, this.once, this.start});

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
    );
  }

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
  final DateTime? start;

  /// Сколько прошлых недель неоплаченного недельного платежа ещё показывается:
  /// иначе забытый на полгода платёж «раз в неделю» завалил бы список.
  static const weekLookbackDays = 56;

  /// С какой даты просматривать сроки: запись обычно не смотрит дальше.
  DateTime scanFrom(DateTime today) {
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
