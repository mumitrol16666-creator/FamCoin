/// Расписание платежей: месяц, неделя, год и разовая покупка.
library;

import 'package:famcoin_core/famcoin_core.dart';
import 'package:test/test.dart';

void main() {
  List<String> p(PaySchedule s, DateTime a, DateTime b) => [for (final o in s.occurrences(a, b)) o.toString()];

  test('ежемесячный: ключ ГГГГ-ММ, 31-е в коротком месяце — последний день', () {
    const s = PaySchedule(day: 31);
    expect(p(s, DateTime(2026, 1, 15), DateTime(2026, 4, 30)), ['2026-01@2026-01-31', '2026-02@2026-02-28', '2026-03@2026-03-31', '2026-04@2026-04-30']);
  });

  test('ежемесячный: границы включительно, срок раньше start не считается', () {
    final s = PaySchedule(day: 10, start: DateTime(2026, 9, 20));
    expect(p(s, DateTime(2026, 9, 1), DateTime(2026, 11, 10)), ['2026-10@2026-10-10', '2026-11@2026-11-10']);
  });

  test('недельный: каждый нужный день недели, ключ — дата срока', () {
    // 2026-09-28 — понедельник; платёж по средам (3).
    const s = PaySchedule(every: everyWeek, weekday: 3);
    expect(p(s, DateTime(2026, 9, 28), DateTime(2026, 10, 14)), ['2026-09-30@2026-09-30', '2026-10-07@2026-10-07', '2026-10-14@2026-10-14']);
    // Сам первый день окна — тоже срок, если совпал.
    expect(p(s, DateTime(2026, 9, 30), DateTime(2026, 9, 30)), ['2026-09-30@2026-09-30']);
  });

  test('недельный через границу года и воскресенье (7)', () {
    const s = PaySchedule(every: everyWeek, weekday: 7);
    expect(p(s, DateTime(2026, 12, 25), DateTime(2027, 1, 10)), ['2026-12-27@2026-12-27', '2027-01-03@2027-01-03', '2027-01-10@2027-01-10']);
  });

  test('годовой: ключ ГГГГ, 29 февраля в невисокосный год — 28-е', () {
    const s = PaySchedule(every: everyYear, day: 29, monthOfYear: 2);
    expect(p(s, DateTime(2027, 1, 1), DateTime(2028, 12, 31)), ['2027@2027-02-28', '2028@2028-02-29']);
  });

  test('годовой не попадает в окно, где срока нет', () {
    const s = PaySchedule(every: everyYear, day: 15, monthOfYear: 11);
    expect(p(s, DateTime(2026, 9, 1), DateTime(2026, 10, 31)), isEmpty);
    expect(p(s, DateTime(2026, 9, 1), DateTime(2026, 11, 30)), ['2026@2026-11-15']);
  });

  test('разовая покупка — один срок в своём месяце, как раньше', () {
    const s = PaySchedule(day: 31, once: '2027-03');
    expect(p(s, DateTime(2026, 9, 1), DateTime(2027, 12, 31)), ['2027-03@2027-03-31']);
    expect(p(s, DateTime(2027, 4, 1), DateTime(2027, 12, 31)), isEmpty);
  });

  test('fromJson: запись без every — ежемесячная; странное значение — тоже', () {
    expect(PaySchedule.fromJson({'day': 5}).every, everyMonth);
    expect(PaySchedule.fromJson({'day': 5, 'every': 'daily'}).every, everyMonth);
    final w = PaySchedule.fromJson({'every': 'week', 'weekday': 5, 'start': '2026-09-01'});
    expect(w.every, everyWeek);
    expect(w.weekday, 5);
    expect(w.start, DateTime(2026, 9, 1));
  });

  test('scanFrom: недельный не уходит глубже восьми недель, ежемесячный — начало месяца', () {
    final today = DateTime(2026, 10, 5);
    expect(PaySchedule(every: everyWeek, weekday: 1, start: DateTime(2025, 1, 1)).scanFrom(today), today.subtract(const Duration(days: 56)));
    expect(const PaySchedule(day: 10).scanFrom(today), DateTime(2026, 10, 1));
    expect(PaySchedule(day: 10, start: DateTime(2026, 8, 3)).scanFrom(today), DateTime(2026, 8, 3));
    expect(const PaySchedule(day: 10, once: '2027-03').scanFrom(today), DateTime(2027, 3, 1));
  });
}
