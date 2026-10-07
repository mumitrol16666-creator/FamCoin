/// Разбор голосовых фраз (раздел 10.2 карты продукта).
library;

import 'package:famcoin_core/famcoin_core.dart';
import 'package:test/test.dart';

const accounts = [
  VoiceAccount('kaspi', ['Kaspi Gold', 'каспи', 'kaspi']),
  VoiceAccount('halyk', ['Halyk', 'халык', 'народный']),
  VoiceAccount('cash', ['наличные', 'нал', 'қолма-қол']),
  VoiceAccount('dep', ['депозит', 'вклад']),
];

void main() {
  VoiceDraft p(String s) => parseVoice(s, accounts: accounts, people: ['Асхат', 'Данияр']);

  test('«Кофе 1 200» — расход, кафе, 1 200, сегодня', () {
    final d = p('Кофе 1 200');
    expect(d.kind, VoiceKind.expense);
    expect(d.amount, kzt(1200));
    expect(d.category, 'cafe');
    expect(d.date, isNull);
    expect(d.complete, isTrue);
  });

  test('«Вчера такси 1800 с Kaspi» — транспорт, вчера, счёт Kaspi', () {
    final d = p('Вчера такси 1800 с Kaspi');
    expect(d.category, 'transport');
    expect(d.date, -1);
    expect(d.accountId, 'kaspi');
    expect(d.amount, kzt(1800));
  });

  test('«Зарплата 450 тысяч на Halyk» — доход', () {
    final d = p('Зарплата 450 тысяч на Halyk');
    expect(d.kind, VoiceKind.income);
    expect(d.category, 'salary');
    expect(d.amount, kzt(450000));
    expect(d.accountId, 'halyk');
  });

  test('«Перевёл 20 тысяч с Kaspi на депозит» — перевод с двумя счетами', () {
    final d = p('Перевёл 20 тысяч с Kaspi на депозит');
    expect(d.kind, VoiceKind.transfer);
    expect(d.amount, kzt(20000));
    expect(d.accountId, 'kaspi');
    expect(d.toAccountId, 'dep');
  });

  test('«Дал Асхату 30 тысяч в долг» — выдача долга', () {
    final d = p('Дал Асхату 30 тысяч в долг');
    expect(d.kind, VoiceKind.lendOut);
    expect(d.person, 'Асхат');
    expect(d.amount, kzt(30000));
  });

  test('«Асхат вернул десять тысяч» — возврат мне, число словами', () {
    final d = p('Асхат вернул мне десять тысяч');
    expect(d.kind, VoiceKind.repaymentReceived);
    expect(d.person, 'Асхат');
    expect(d.amount, kzt(10000));
  });

  test('числа словами: «двести пятьдесят», «полторы тысячи»', () {
    expect(p('такси двести пятьдесят').amount, kzt(250));
    expect(p('обед полторы тысячи').amount, kzt(1500));
    // Разговорные формы: «тыщи», «тыщу», «тысячу», «1,5 тыщи».
    expect(p('такси полторы тыщи').amount, kzt(1500));
    expect(p('такси полторы тыщи').category, 'transport');
    expect(p('кофе две тыщи').amount, kzt(2000));
    expect(p('продукты тысячу').amount, kzt(1000));
    expect(p('такси 1,5 тыщи').amount, kzt(1500));
    expect(p('такси 3 тысячи').amount, kzt(3000));
    // Слово-тысяча плюс цифры: «тыща 590» = 1 590.
    expect(p('кофе тыща 590').amount, kzt(1590));
    expect(p('кофе тыща 590').category, 'cafe');
    expect(p('такси две тыщи 300').amount, kzt(2300));
    expect(p('обед полторы тыщи 200').amount, kzt(1700));
    expect(p('продукты две тысячи триста').amount, kzt(2300));
  });

  test('«молоко 800, хлеб 250» — одна покупка из позиций', () {
    final d = p('молоко 800, хлеб 250');
    expect(d.amount, kzt(1050));
    expect(d.items.length, 2);
    expect(d.category, 'food');
    expect(d.note, contains('молоко 800'));
  });

  test('казахский: «Кеше таксиге 1 800 теңге төледім»', () {
    final d = p('Кеше таксиге 1 800 теңге төледім');
    expect(d.kind, VoiceKind.expense);
    expect(d.category, 'transport');
    expect(d.date, -1);
    expect(d.amount, kzt(1800));
  });

  test('казахский: «Айлық түсті, 450 мың теңге» и «Асхатқа 30 мың теңге қарыз бердім»', () {
    final s = p('Айлық түсті, 450 мың теңге');
    expect(s.kind, VoiceKind.income);
    expect(s.amount, kzt(450000));
    final l = p('Асхатқа 30 мың теңге қарыз бердім');
    expect(l.kind, VoiceKind.lendOut);
    expect(l.person, 'Асхат');
    expect(l.amount, kzt(30000));
  });

  test('«Данияр пять тысяч» — сумма есть, тип и категория не угаданы: нужно подтверждение', () {
    final d = p('Данияр пять тысяч');
    expect(d.amount, kzt(5000));
    expect(d.kind, VoiceKind.expense);
    expect(d.category, isNull);
    expect(d.warnings, contains('no_category'));
  });

  test('без суммы — черновик неполный', () {
    final d = p('купил продукты');
    expect(d.complete, isFalse);
    expect(d.warnings, contains('no_amount'));
    expect(d.category, 'food');
  });

  test('личный словарь важнее общего', () {
    final d = parseVoice('бар 3000', accounts: accounts, userWords: {'бар': 'cafe'});
    expect(d.category, 'cafe');
  });

  group('названия счетов', () {
    // Так счета передаёт приложение: название целиком и каждое его слово.
    const mine = [
      VoiceAccount('gold', ['Kaspi Gold', 'Kaspi', 'Gold']),
      VoiceAccount('second', ['Kaspi 2', 'Kaspi', '2']),
      VoiceAccount('card', ['Карта для покупок', 'Карта', 'для', 'покупок']),
      VoiceAccount('cash', ['Наличные']),
      VoiceAccount('jusan', ['Jusan']),
    ];
    VoiceDraft q(String s) => parseVoice(s, accounts: mine);

    test('цифра или слог из названия счёта не портят сумму и не выбирают счёт', () {
      final d = parseVoice('кофе 1500', accounts: const [VoiceAccount('zero', ['Счёт 0', 'Счёт', '0'])]);
      expect(d.amount, kzt(1500));
      expect(d.accountId, isNull);
      expect(q('такси 2000').accountId, isNull, reason: '«2» из «Kaspi 2» — не название');
      expect(q('такси 2000').amount, kzt(2000));
      expect(q('подарок для мамы 5000').accountId, isNull, reason: '«для» — служебное слово');
      expect(parseVoice('налог 5000', accounts: const [VoiceAccount('cash', ['нал'])]).accountId, isNull, reason: 'короткое название — только целым словом');
      expect(parseVoice('хлеб 300 нал', accounts: const [VoiceAccount('cash', ['нал'])]).accountId, 'cash');
    });

    test('латинское название узнаётся в русской записи — так его отдаёт распознавание речи', () {
      expect(q('такси 2000 с каспи').accountId, 'gold');
      expect(q('такси 2000 с каспи').note, 'Такси');
      expect(q('Вчера такси 2000 с Каспи Голд.').accountId, 'gold');
      expect(q('продукты 5000 с жусана').accountId, 'jusan');
      expect(q('продукты 5000 с Jusan').accountId, 'jusan');
    });

    test('русское название узнаётся в другом падеже', () {
      expect(q('хлеб 300 наличными').accountId, 'cash');
      expect(q('хлеб 300 из наличных').accountId, 'cash');
      expect(q('хлеб 300 наличными').note, 'Хлеб');
      expect(q('хлеб 300 с карты').accountId, isNull, reason: 'короткое слово не склоняем: «карта» ≠ «картошка»');
      expect(q('картошка 300').accountId, isNull);
      expect(q('хлеб 300 карта').accountId, 'card');
    });

    test('перевод между счетами: откуда и куда', () {
      final d = q('перевёл 20000 с каспи на жусан');
      expect(d.kind, VoiceKind.transfer);
      expect((d.accountId, d.toAccountId), ('gold', 'jusan'));
      expect(d.amount, kzt(20000));
    });
  });

  test('имя в долге пишут и с маленькой буквы; глагол в начале фразы — не имя', () {
    VoiceDraft q(String s) => parseVoice(s, accounts: accounts);
    expect(q('одолжил марату 10000').person, 'Марату');
    expect(q('Одолжил Марату 10000').person, 'Марату');
    expect(q('дал в долг асхату 5000 с каспи').person, 'Асхату');
    expect(q('дал в долг асхату 5000 с каспи').accountId, 'kaspi');
    expect(q('взял в долг у данияра 20 тысяч').person, 'Данияра');
    expect(q('взял в долг у данияра 20 тысяч').kind, VoiceKind.borrow, reason: '«взял в долг» — не выдача');
    expect(q('заняла у мамы 50000').kind, VoiceKind.borrow);
    expect(q('занял ему 5000').kind, VoiceKind.lendOut);
    expect(q('взял в долг 20 тысяч').person, isNull);
    expect(q('взял в долг 20 тысяч').warnings, contains('no_person'));
    // Имя, записанное раньше в другом падеже, узнаётся по основе.
    expect(parseVoice('асхат вернул мне 5000', people: ['Асхату']).person, 'Асхату');
  });

  test('копейки и «к»: «12,5к»', () {
    expect(p('одежда 12,5к').amount, kzt(12500));
  });

  group('аудит разбора фраз (D138)', () {
    int? amountOf(String phrase) => parseVoice(phrase).amount;

    test('направление долга: «взял в долг у», «одолжил у» — это я взял', () {
      expect(parseVoice('взял 5000 в долг у Марата').kind, VoiceKind.borrow);
      expect(parseVoice('одолжил у Марата 5000').kind, VoiceKind.borrow);
      expect(parseVoice('занял у Марата 5000').kind, VoiceKind.borrow);
      // Выдача не меняется.
      expect(parseVoice('дал Асхату 30 тысяч в долг').kind, VoiceKind.lendOut);
      expect(parseVoice('одолжил Марату 5000').kind, VoiceKind.lendOut);
      expect(parseVoice('занял ему 5000 в долг').kind, VoiceKind.lendOut);
    });

    test('слова-подстроки не меняют тип операции', () {
      expect(parseVoice('заказал такси 1500').kind, VoiceKind.expense);
      expect(parseVoice('пришлось заплатить 3000 за такси').kind, VoiceKind.expense);
      expect(parseVoice('вернулся домой купил хлеб 300').kind, VoiceKind.expense);
      expect(parseVoice('доклад 500').kind, VoiceKind.expense);
      // Настоящие доходы и возвраты остаются.
      expect(parseVoice('пришла зарплата 300 тысяч').kind, VoiceKind.income);
      expect(parseVoice('получил заказ 50000').kind, VoiceKind.income);
      expect(parseVoice('вернул Марату 5000').kind, VoiceKind.repaymentMade);
    });

    test('категории не ищутся внутри чужих слов', () {
      expect(parseVoice('суп 700').category, 'cafe');
      expect(parseVoice('суши 3500').category, 'cafe');
      expect(parseVoice('сумка 15000').category, isNot('utilities'));
      expect(parseVoice('цветы 5000').category, isNot('food'));
      expect(parseVoice('газета 200').category, isNot('utilities'));
      expect(parseVoice('детали 900').category, isNot('kids'));
      // Окончания и настоящие слова работают.
      expect(parseVoice('детям 5000').category, 'kids');
      expect(parseVoice('купил газ 3000').category, 'utilities');
      expect(parseVoice('в баре 4000').category, 'fun');
      expect(parseVoice('кофейня 1500').category, 'cafe');
    });

    test('«к» после числа — тысяча только вплотную или в конце фразы', () {
      expect(amountOf('такси 1500 к дому'), kzt(1500));
      expect(amountOf('потратил 500 к обеду'), kzt(500));
      expect(amountOf('хлеб 300 к ужину'), kzt(300));
      expect(amountOf('кофе 2,5к'), kzt(2500));
      expect(amountOf('аренда 150к'), kzt(150000));
      expect(amountOf('кофе 5 к'), kzt(5000));
    });

    test('количество, время и единицы не становятся позициями и суммой', () {
      expect(amountOf('купил 2 кофе за 700'), kzt(700));
      expect(amountOf('потратил 3000 на 2 пиццы'), kzt(3000));
      expect(amountOf('кофе 350 тенге 5 раз'), kzt(350));
      expect(amountOf('такси 1500 в 5 утра'), kzt(1500));
      expect(amountOf('кофе 1500 в 14:30'), kzt(1500));
      expect(amountOf('вчера в 15:00 кофе 1200'), kzt(1200));
      expect(amountOf('такси 2 км 1200'), kzt(1200));
      expect(amountOf('такси 15 минут 1800'), kzt(1800));
      expect(amountOf('кофе 2500 и 3 пончика'), kzt(2500));
      // Список покупок работает, как раньше.
      expect(amountOf('молоко 800 хлеб 250 яйца 120'), kzt(1170));
      expect(amountOf('купил молоко 800 хлеб 250'), kzt(1050));
    });

    test('суммы: «10 тысяч 500», «миллион двести тысяч», разделитель тысяч, даты', () {
      expect(amountOf('бензин 10 тысяч 500'), kzt(10500));
      expect(amountOf('потратил 5 тысяч 500 на продукты'), kzt(5500));
      expect(parseVoice('потратил 5 тысяч 500 на продукты').category, 'food');
      expect(amountOf('кофе 2 тысячи 500'), kzt(2500));
      expect(amountOf('миллион двести тысяч аренда'), kzt(1200000));
      expect(amountOf('кофе 1.500'), kzt(1500));
      expect(amountOf('кофе 12,500'), kzt(12500));
      expect(amountOf('кофе 1.234.567'), kzt(1234567));
      expect(amountOf('25 октября кофе 500'), kzt(500));
      // Десятичные остаются десятичными.
      expect(amountOf('кофе 350,5'), 35050);
    });
  });
}
