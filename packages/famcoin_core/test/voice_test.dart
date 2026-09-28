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

  test('копейки и «к»: «12,5к»', () {
    expect(p('одежда 12,5к').amount, kzt(12500));
  });
}
