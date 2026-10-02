import 'package:famcoin_server/ai_check.dart';
import 'package:test/test.dart';

const _context = <String, dynamic>{
  'today': '2026-10-02',
  'period': {'todayDay': 2, 'daysInMonth': 31},
  'dailyLimit': {'perDay': 5000, 'overspentOnPreviousDays': 293, 'spentToday': 3180, 'availableToday': 1527},
  'bankDebts': {'totalDebt': 1236828, 'monthlyPayments': 80000},
  'monthEndBalanceForecast': {'estimate': -264090, 'rangeLow': -297741, 'rangeHigh': -230439},
  'expenseByCategory': [
    {'name': 'Продукты', 'amount': 65000},
    {'name': 'Кафе', 'amount': 13000},
    {'name': 'Транспорт', 'amount': 9000},
  ],
  'plannedPurchases': [
    {'name': 'Зимние колёса', 'amount': 100000, 'toSavePerMonth': 16700},
  ],
  'goals': null,
  'operationsEarlier': [
    {'date': '2026-09-12', 'amount': 4707.5, 'note': 'Ремонт 30000, стартер'},
  ],
};

List<String> _check(String answer, {List<String> texts = const [], Map<String, String> calc = const {}}) =>
    unverifiedAmounts(answer, context: _context, texts: texts, numbers: [for (final e in calc.entries) DeclaredNumber(e.key, e.value)]);

double? _eval(String calc, {List<double> extra = const []}) => evaluateCalc(calc, _context, extra: extra);

void main() {
  group('число подтверждено, если оно есть в данных ровно таким', () {
    test('поля сводки, числа из заметок, вопроса и прошлых реплик', () {
      expect(_check('Считается так: 5 000 ₸ лимит − 293 ₸ перерасход − 3 180 ₸ сегодня = 1 527 ₸.'), isEmpty);
      expect(_check('По данным к концу месяца не хватит 264 090 ₸; сценарии — от 230 439 до 297 741 ₸.'), isEmpty);
      expect(_check('На ремонт ушло 30 000 ₸ — так написано в заметке.'), isEmpty);
      expect(_check('Операция на 4 708 ₸ была 12 сентября, это 0 ₸ сверх плана.'), isEmpty, reason: 'копейки округлены');
      expect(_check('Телефон за 250 000 ₸.', texts: ['Хочу купить телефон за 250 тысяч']), isEmpty);
      expect(_check('Телефон за 250 000 ₸.'), ['250 000 ₸']);
    });

    test('приблизительные суммы и суммы словами', () {
      expect(_check('Долг по банкам — около 1,2 млн ₸, платёж — 80 тыс. ₸ в месяц.'), isEmpty);
      expect(_check('Долг по банкам — 5 млн ₸.'), ['5 млн ₸']);
    });

    test('проценты, даты, годы и количества — не суммы', () {
      expect(_check('Это 1 350 % от дохода, 28 сентября 2026 года было 3 операции, прошло 15 дней.'), isEmpty);
    });
  });

  group('совпадение с суммой двух чужих чисел больше не проходит', () {
    test('круглое число без объяснения — не подтверждено, даже если его можно «собрать» из данных', () {
      // 35 000 = 30 000 (из заметки) + 5 000 (лимит): раньше проверка это пропускала.
      expect(_check('В неделю выходит 35 000 ₸.'), ['35 000 ₸']);
      expect(_check('Без этих 293 ₸ было бы 1 820 ₸.'), ['1 820 ₸'], reason: 'сумму двух полей тоже нужно объяснить');
      expect(_check('Все три категории вместе — 87 000 ₸.'), ['87 000 ₸']);
    });

    test('с объяснением, которое сервер пересчитал сам, — подтверждено', () {
      expect(_check('Без этих 293 ₸ было бы 1 820 ₸.', calc: {'1 820 ₸': 'dailyLimit.availableToday + dailyLimit.overspentOnPreviousDays'}), isEmpty);
      expect(_check('Все три категории вместе — 87 000 ₸.', calc: {'87 000 ₸': 'sum(expenseByCategory.amount)'}), isEmpty);
      expect(_check('За 3 месяца накопится 50 100 ₸.', calc: {'50 100 ₸': 'plannedPurchases[name=Зимние колёса].toSavePerMonth * 3'}), isEmpty);
      expect(_check('На продукты осталось 25 000 ₸ из 90 000 ₸.', texts: ['лимит на продукты 90 000'], calc: {'25 000 ₸': '90000 - expenseByCategory[name=Продукты].amount'}), isEmpty);
    });

    test('объяснение не сходится с написанным — не подтверждено', () {
      expect(_check('За 3 месяца накопится 51 000 ₸.', calc: {'51 000 ₸': 'plannedPurchases[0].toSavePerMonth * 3'}), ['51 000 ₸'], reason: 'ошибка в арифметике модели');
      expect(_check('Вы потратили 12 345 ₸ на кафе.', calc: {'12 345 ₸': 'expenseByCategory[name=Кафе].amount'}), ['12 345 ₸'], reason: 'в поле другое число');
      expect(_check('Вы потратили 12 345 ₸.', calc: {'12 345 ₸': '12345'}), ['12 345 ₸'], reason: 'число, которого нет в данных, нельзя «объяснить» им самим');
      expect(_check('В неделю выходит 35 000 ₸.', calc: {'35 000 ₸': '100 * 350'}), ['35 000 ₸'], reason: 'расчёт без единого числа из данных');
      expect(_check('Цели — 40 000 ₸.', calc: {'40 000 ₸': 'goals[0].saved'}), ['40 000 ₸'], reason: 'поля нет');
    });
  });

  group('выражения', () {
    test('пути, списки, выбор по названию и номеру', () {
      expect(_eval('dailyLimit.availableToday'), 1527);
      expect(_eval('expenseByCategory[1].amount'), 13000);
      expect(_eval('expenseByCategory[name=кафе].amount'), 13000, reason: 'название без учёта регистра');
      expect(_eval('expenseByCategory[name="Продукты"].amount'), 65000);
      expect(_eval('expenseByCategory[category=Продукты].amount'), 65000, reason: 'поле названо иначе — ищем название в любом текстовом поле');
      expect(_eval('expenseByCategory[Кафе].amount'), 13000, reason: 'можно и без имени поля');
      expect(evaluateCalc('budget[name=Кафе].left', const {'budget': {'usedPercent': 71, 'limits': [{'name': 'Кафе', 'left': 7000}]}}), 7000, reason: 'список на уровень глубже и он один');
      expect(_eval('sum(expenseByCategory.amount)'), 87000);
      expect(_eval('monthEndBalanceForecast.estimate'), -264090);
    });

    test('арифметика: порядок действий, скобки, разные знаки, деньги в записи', () {
      expect(_eval('dailyLimit.perDay - dailyLimit.overspentOnPreviousDays - dailyLimit.spentToday'), 1527);
      expect(_eval('(dailyLimit.perDay − dailyLimit.spentToday) × 2'), 3640);
      expect(_eval('bankDebts.monthlyPayments * 12 / 4'), 240000);
      expect(_eval('5 000 ₸ - 293 ₸'), 4707, reason: 'числа из данных можно писать и напрямую');
      expect(_eval('plannedPurchases[0].amount / period.daysInMonth')!.round(), 3226);
      expect(_eval('250000 - plannedPurchases[0].amount', extra: [250000]), 150000, reason: 'число из вопроса');
    });

    test('чего нельзя: выдуманные числа, пустые поля, мусор', () {
      expect(_eval('250000 - plannedPurchases[0].amount'), isNull, reason: 'числа 250 000 нет ни в данных, ни в вопросе');
      expect(_eval('100 * 350'), isNull, reason: 'нет ни одного числа из данных');
      expect(_eval('goals[0].saved'), isNull);
      expect(_eval('expenseByCategory[name=Одежда].amount'), isNull);
      expect(_eval('expenseByCategory[7].amount'), isNull);
      expect(_eval('expenseByCategory.amount'), isNull, reason: 'список без sum — не число');
      expect(_eval('dailyLimit.perDay / (dailyLimit.perDay - 5000)'), isNull, reason: 'деление на ноль');
      expect(_eval('dailyLimit.perDay +'), isNull);
      expect(_eval('system("rm -rf")'), isNull);
      expect(_eval(''), isNull);
    });
  });
}
