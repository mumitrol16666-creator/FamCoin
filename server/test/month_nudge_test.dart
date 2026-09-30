import 'package:famcoin_core/famcoin_core.dart';
import 'package:famcoin_server/briefs.dart';
import 'package:test/test.dart';

void main() {
  test('previousMonth: январь даёт декабрь прошлого года, ключ месяца — ГГГГ-ММ', () {
    expect(previousMonth(DateTime(2026, 10, 1)), DateTime(2026, 9, 1));
    expect(previousMonth(DateTime(2026, 1, 15)), DateTime(2025, 12, 1));
    expect(monthKey(DateTime(2026, 9, 1)), '2026-09');
    expect(monthKey(previousMonth(DateTime(2027, 1, 3))), '2026-12');
  });

  test('названия месяцев: ru и kk, все двенадцать', () {
    expect(monthName(9, 'ru'), 'сентябрь');
    expect(monthName(9, 'kk'), 'қыркүйек');
    for (var m = 1; m <= 12; m++) {
      expect(monthName(m, 'ru'), isNotEmpty);
      expect(monthName(m, 'kk'), isNotEmpty);
    }
  });

  test('напоминание закрыть месяц: заголовок с названием месяца, в тексте итоги', () {
    final ru = monthNudge(month: DateTime(2026, 9, 1), income: kzt(300000), expense: kzt(245000), locale: 'ru');
    expect(ru.title, 'Сверьте сентябрь');
    expect(ru.body, contains('300 000 ₸'));
    expect(ru.body, contains('245 000 ₸'));
    expect(ru.body, contains('закройте месяц'));

    final kk = monthNudge(month: DateTime(2026, 9, 1), income: kzt(300000), expense: kzt(245000), locale: 'kk');
    expect(kk.title, contains('қыркүйек'));
    expect(kk.body, contains('300 000 ₸'));
    expect(kk.body, contains('245 000 ₸'));
  });
}
