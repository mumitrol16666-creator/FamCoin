/// Расписание платежей: месяц, неделя, год и разовая покупка.
library;

import 'package:famcoin_core/famcoin_core.dart';
import 'package:test/test.dart';

void main() {
  onDateTests();
  scheduleVersionTests();
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

void scheduleVersionTests() {
  group('R03 версии расписания', () {
    List<String> keys(PaySchedule s, DateTime a, DateTime b) => [for (final o in s.occurrences(a, b)) o.period];

    test('смена дня недели со сегодняшней даты не создаёт сроки в оплаченном прошлом', () {
      const monday = PaySchedule(every: everyWeek, weekday: 1);
      final old = PaySchedule(every: everyWeek, weekday: 1, start: DateTime(2026, 9, 1));
      final next = PaySchedule(every: everyWeek, weekday: 2, start: DateTime(2026, 9, 28), previous: old);
      expect(monday.every, everyWeek);
      // Сентябрьские понедельники остались прежними, новые сроки — вторники.
      expect(keys(next, DateTime(2026, 9, 1), DateTime(2026, 10, 13)),
          ['2026-09-07', '2026-09-14', '2026-09-21', '2026-09-29', '2026-10-06', '2026-10-13']);
    });

    test('смена периодичности месяц → неделя: оплаченные месяцы сохраняют ключи ГГГГ-ММ', () {
      final old = PaySchedule(day: 10, start: DateTime(2026, 8, 1));
      final next = PaySchedule(every: everyWeek, weekday: 3, start: DateTime(2026, 10, 1), previous: old);
      expect(keys(next, DateTime(2026, 8, 1), DateTime(2026, 10, 14)), ['2026-08', '2026-09', '2026-10-07', '2026-10-14']);
    });

    test('toJson / fromJson сохраняют цепочку версий', () {
      final v1 = PaySchedule(day: 5, start: DateTime(2026, 1, 1));
      final v2 = PaySchedule(day: 20, start: DateTime(2026, 6, 1), previous: v1);
      final back = PaySchedule.fromJson(v2.toJson().cast<String, dynamic>());
      expect(back.previous?.day, 5);
      expect(back.start, DateTime(2026, 6, 1));
      expect(keys(back, DateTime(2026, 5, 1), DateTime(2026, 7, 31)), ['2026-05', '2026-06', '2026-07']);
      expect(back.occurrences(DateTime(2026, 5, 1), DateTime(2026, 7, 31)).map((o) => o.date.day), [5, 20, 20]);
    });

    test('scanFrom учитывает прежнюю версию', () {
      final v1 = PaySchedule(day: 5, start: DateTime(2026, 3, 1));
      final v2 = PaySchedule(day: 20, start: DateTime(2026, 6, 1), previous: v1);
      expect(v2.scanFrom(DateTime(2026, 10, 5)), DateTime(2026, 3, 1));
    });
  });
}

void onDateTests() {
  group('срок возврата личного долга (onDate)', () {
    final s = PaySchedule(onDate: DateTime(2026, 10, 20));
    test('один срок в точную дату, ключ — дата; вне промежутка срока нет', () {
      expect([for (final o in s.occurrences(DateTime(2026, 10, 1), DateTime(2026, 10, 31))) o.toString()], ['2026-10-20@2026-10-20']);
      expect(s.occurrences(DateTime(2026, 11, 1), DateTime(2026, 11, 30)), isEmpty);
      expect(s.occurrences(DateTime(2026, 10, 20), DateTime(2026, 10, 20)), hasLength(1), reason: 'границы включительно');
    });

    test('просрочка видна в обзоре, пока срок не оплачен: scanFrom начинается со срока', () {
      expect(s.scanFrom(DateTime(2026, 12, 1)), DateTime(2026, 10, 20));
    });

    test('toJson / fromJson сохраняют дату', () {
      final back = PaySchedule.fromJson(s.toJson().cast<String, dynamic>());
      expect(back.onDate, DateTime(2026, 10, 20));
    });

    test('plannedDebtActive: пока должен я — срок действует, после погашения — нет', () {
      final l = Ledger()
        ..addMoneyAccount('cash')
        ..openingBalance(id: 'o', date: DateTime(2026, 10, 1), account: 'cash', amount: kzt(100000));
      l.borrow(id: 'b', date: DateTime(2026, 10, 2), account: 'cash', person: 'Теща', amount: kzt(80000));
      expect(plannedDebtActive(l, null, person: 'Теща'), isTrue);
      expect(plannedDebtActive(l, null, person: 'Другой'), isFalse, reason: 'долга нет');
      l.repaymentMade(id: 'r', date: DateTime(2026, 10, 10), account: 'cash', person: 'Теща', principal: kzt(80000));
      expect(plannedDebtActive(l, null, person: 'Теща'), isFalse);
      expect(plannedDebtActive(l, null), isTrue, reason: 'платёж без долга всегда действует');
    });
  });
}
