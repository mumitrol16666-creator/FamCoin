/// Разбор выписки Kaspi Gold из слов PDF (D94): таблица собирается по
/// координатам, переносы в ячейках возвращаются в свою операцию, а итог
/// сверяется с остатками самой выписки.
library;

import 'package:famcoin_core/famcoin_core.dart';
import 'package:famcoin_server/pdf_words.dart';
import 'package:famcoin_server/statement.dart';
import 'package:test/test.dart';

import 'statement_layout.dart';

Matcher fails(String code) => throwsA(isA<StatementError>().having((e) => e.code, 'code', code));

void main() {
  group('вывод pdftotext -bbox', () {
    test('слова с рамками и страницами; служебные знаки возвращаются', () {
      final words = parseBboxWords('''
<html><body><doc>
  <page width="595.000000" height="842.000000">
    <word xMin="40.000000" yMin="60.500000" xMax="80.000000" yMax="69.500000">10.01.26</word>
    <word xMin="110.000000" yMin="60.500000" xMax="115.000000" yMax="69.500000">-</word>
    <word xMin="360.000000" yMin="60.500000" xMax="400.000000" yMax="69.500000">H&amp;M</word>
  </page>
  <page width="595.000000" height="842.000000">
    <word xMin="40,000000" yMin="20,000000" xMax="60,000000" yMax="29,000000">&#8376;</word>
  </page>
</doc></body></html>''');
      expect(words.map((w) => w.text), ['10.01.26', '-', 'H&M', '₸']);
      expect(words.map((w) => w.page), [0, 0, 0, 1]);
      expect(words.first.x0, 40);
      expect(words.first.yMid, 65);
      expect(words.last.x0, 40, reason: 'запятая вместо точки в числе — тоже число');
    });

    test('проверочный PDF собирается с верной таблицей ссылок', () {
      final pdf = String.fromCharCodes(probePdf('FamCoin'));
      expect(pdf, startsWith('%PDF-1.4'));
      final xref = int.parse(RegExp(r'startxref\n(\d+)').firstMatch(pdf)![1]!);
      expect(pdf.substring(xref), startsWith('xref'));
      final offsets = RegExp(r'(\d{10}) 00000 n').allMatches(pdf).map((m) => int.parse(m[1]!)).toList();
      for (var i = 0; i < offsets.length; i++) {
        expect(pdf.substring(offsets[i]), startsWith('${i + 1} 0 obj'));
      }
    });
  });

  group('таблица операций', () {
    void expectSample(BankStatement st) {
      expect(st.balanced, isTrue);
      expect(st.opening, kzt(100000));
      expect(st.closing, 9427992);
      expect(dateToJson(st.from), '2026-09-01');
      expect(dateToJson(st.to), '2026-09-30');
      expect(st.language, 'ru');
      expect(st.rows.map((r) => dateToJson(r.date)), ['2026-09-22', '2026-09-23', '2026-09-24', '2026-09-25', '2026-09-26', '2026-09-27', '2026-09-28', '2026-09-29', '2026-09-30'],
          reason: 'банк печатает новые сверху, в журнал — от старых к новым');
      expect(st.rows.map((r) => r.amount), [250000, -25000, 1500000, -1000000, -1147008, -3000000, -2000000, 5000000, -150000]);
      expect(st.rows.map((r) => r.kind), [
        RowKind.purchase,
        RowKind.other,
        RowKind.ownIn,
        RowKind.withdrawal,
        RowKind.purchase,
        RowKind.ownOut,
        RowKind.transfer,
        RowKind.topup,
        RowKind.purchase,
      ]);
      expect(st.rows.map((r) => r.details), [
        'MAGNUM AF51',
        'Комиссия за перевод',
        'С Kaspi Депозита',
        'Банкомат Kaspi',
        'OPENAI *CHATGPT SUBSCR (23,20 USD)',
        'На Kaspi Депозит',
        'Айгуль К.',
        'Алексей А.',
        'MAGNUM AF51',
      ]);
      expect(st.rows[5].operation, 'Перевод на свой счет', reason: 'название операции, перенесённое на вторую строку, собрано целиком');
      expect(st.rows[2].operation, 'Поступление со своего счета');
    }

    test('ячейки выровнены по верху: перенос уходит на строки ниже', () {
      expectSample(parseStatement(sampleStatement().words));
    });

    test('ячейки выровнены по середине: перенос расходится вверх и вниз от даты', () {
      expectSample(parseStatement(sampleStatement(centered: true).words));
    });

    test('длинные детали в три строки остаются у своей операции', () {
      for (final centered in [false, true]) {
        final s = statementHead(centered: centered, closing: '+ 91 000,00 ₸');
        s.header();
        s.row('03.09.26', '- 4 000,00 ₸', 'Покупка', 'ИП НУРЛАНОВ\nМАГАЗИН У ДОМА\nАЛМАТЫ');
        s.row('02.09.26', '- 2 000,00 ₸', 'Покупка', 'COFFEE BOOM');
        s.row('02.09.26', '- 3 000,00 ₸', 'Перевод', 'Айгуль К.');
        final st = parseStatement(s.words);
        // Две операции одного дня: нижняя в выписке была раньше.
        expect(st.rows.map((r) => r.details), ['Айгуль К.', 'COFFEE BOOM', 'ИП НУРЛАНОВ МАГАЗИН У ДОМА АЛМАТЫ'], reason: 'по середине: $centered');
        expect(st.rows.map((r) => r.amount), [-300000, -200000, -400000]);
      }
    });

    test('вторая страница без заголовка и подвал банка: подвал в операции не попадает', () {
      final s = statementHead(closing: '+ 97 000,00 ₸');
      s.header();
      s.row('03.09.26', '- 1 000,00 ₸', 'Покупка', 'SMALL');
      s.gap(40);
      s.line('АО «Kaspi Bank», БИК CASPKZKA, www.kaspi.kz', at: 230);
      s.newPage();
      s.row('02.09.26', '- 1 500,00 ₸', 'Покупка', 'GALMART\nЕСЕНТАЙ');
      s.row('01.09.26', '- 500,00 ₸', 'Разное', 'Комиссия');
      s.gap(40);
      s.line('Выписка сформирована 01.10.26', at: 230);
      final st = parseStatement(s.words);
      expect(st.rows.map((r) => r.details), ['Комиссия', 'GALMART ЕСЕНТАЙ', 'SMALL']);
      expect(st.balanced, isTrue);
    });

    test('заголовок повторяется на каждой странице', () {
      final s = statementHead(closing: '+ 98 500,00 ₸');
      s.header();
      s.row('03.09.26', '- 1 000,00 ₸', 'Покупка', 'SMALL');
      s.newPage();
      s.line('ВЫПИСКА по Kaspi Gold', at: 230);
      s.gap();
      s.header();
      s.row('02.09.26', '- 500,00 ₸', 'Покупка', 'GALMART');
      final st = parseStatement(s.words);
      expect(st.rows.map((r) => r.details), ['GALMART', 'SMALL']);
    });

    test('заголовок таблицы стоит по центру колонок, а ячейки — по левому краю', () {
      final s = statementHead(closing: '+ 77 000,00 ₸');
      s.header(at: [48, 150, 262, 420]);
      s.row('05.09.26', '- 1 000,00 ₸', 'Покупка', 'SMALL');
      s.row('04.09.26', '- 2 000,00 ₸', 'Перевод', 'Айгуль К.');
      s.row('03.09.26', '- 20 000,00 ₸', 'Перевод на свой\nсчет', 'На Kaspi Депозит');
      final st = parseStatement(s.words);
      expect(st.rows.map((r) => (r.kind, r.details)), [(RowKind.ownOut, 'На Kaspi Депозит'), (RowKind.transfer, 'Айгуль К.'), (RowKind.purchase, 'SMALL')]);
    });

    test('знак валюты прочитался буквой или не прочитался вовсе', () {
      for (final sign in ['T', '', '¤']) {
        final s = statementHead(closing: '+ 97 000,00 ₸');
        s.header();
        s.row('03.09.26', '- 1 000,00 $sign'.trim(), 'Покупка', 'SMALL');
        s.row('02.09.26', '- 2 000,00 $sign'.trim(), 'Перевод', 'Айгуль К.');
        final st = parseStatement(s.words);
        expect(st.rows.map((r) => (r.amount, r.kind, r.details)), [(-200000, RowKind.transfer, 'Айгуль К.'), (-100000, RowKind.purchase, 'SMALL')], reason: 'знак «$sign»');
      }
    });

    test('сумма без знака: расход или приход — по виду операции', () {
      final s = statementHead(closing: '+ 104 000,00 ₸');
      s.header();
      s.row('03.09.26', '1 000,00 ₸', 'Покупка', 'SMALL');
      s.row('02.09.26', '5 000,00 ₸', 'Пополнение', 'Алексей А.');
      final st = parseStatement(s.words);
      expect(st.rows.map((r) => r.amount), [500000, -100000]);
    });

    test('выписка на казахском и английском: таблица читается, незнакомое название операции — «не узнано»', () {
      final kk = Sheet()
        ..line('Kaspi Gold бойынша ҮЗІНДІ 01.09.26 - 30.09.26')
        ..pair('01.09.26 қолжетімді', '+ 10 000,00 ₸')
        ..pair('30.09.26 қолжетімді', '+ 8 000,00 ₸')
        ..gap()
        ..header(titles: ['Күні', 'Сомасы', 'Операция', 'Толығырақ'])
        ..row('05.09.26', '- 1 500,00 ₸', 'Сатып алу', 'MAGNUM')
        ..row('04.09.26', '- 500,00 ₸', 'Жаңа операция', 'Kaspi Депозитке');
      final a = parseStatement(kk.words);
      expect(a.language, 'kk');
      expect(a.balanced, isTrue);
      expect(a.rows.map((r) => (r.kind, r.operation, r.details)), [(RowKind.unknown, 'Жаңа операция', 'Kaspi Депозитке'), (RowKind.purchase, 'Сатып алу', 'MAGNUM')]);

      final en = Sheet()
        ..line('STATEMENT for Kaspi Gold from 01.09.26 to 30.09.26')
        ..gap()
        ..header(titles: ['Date', 'Amount', 'Transaction', 'Details'])
        ..row('05.09.26', '- 1 500,00 ₸', 'Purchase', 'MAGNUM')
        ..row('04.09.26', '+ 500,00 ₸', 'Replenishment', 'John D.');
      final b = parseStatement(en.words);
      expect(b.language, 'en');
      expect(b.balanced, isFalse, reason: 'остатков в шапке нет — сверить не с чем');
      expect(b.rows.map((r) => r.kind), [RowKind.topup, RowKind.purchase]);
      expect(dateToJson(b.from), '2026-09-01');
      expect(dateToJson(b.to), '2026-09-30');
    });

    test('неразрывные пробелы и типографский минус в суммах', () {
      final s = statementHead(closing: '+\u00a098\u00a0500,00\u00a0₸');
      s.header();
      s.words.addAll([
        PdfWord(0, 40, s.y, 80, s.y + 9, '03.09.26'),
        PdfWord(0, 110, s.y, 180, s.y + 9, '\u2212\u00a01\u00a0500,00\u00a0₸'),
        PdfWord(0, 230, s.y, 265, s.y + 9, 'Покупка'),
        PdfWord(0, 360, s.y, 385, s.y + 9, 'SMALL'),
      ]);
      // вторая строка — чтобы начала колонок определились по данным
      s.y += 18;
      s.row('02.09.26', '- 0,00 ₸', 'Разное', 'Проверка карты');
      final st = parseStatement(s.words);
      expect(st.rows.single.amount, -150000, reason: 'нулевая операция пропущена');
      expect(st.balanced, isTrue);
    });
  });

  group('сверка с итогами выписки', () {
    test('операции не сошлись с остатками — выписка не принимается', () {
      expect(() => parseStatement(sampleStatement(closing: '+ 94 000,00 ₸').words), fails('mismatch'));
    });

    test('строка с датой, но без суммы: без итогов выписка не принимается, а потерянная операция не сходится с итогами', () {
      final loose = Sheet()
        ..line('ВЫПИСКА по Kaspi Gold за период с 01.09.26 по 30.09.26')
        ..gap()
        ..header()
        ..row('03.09.26', '- 1 000,00 ₸', 'Покупка', 'SMALL')
        ..row('02.09.26', 'нет суммы', 'Покупка', 'GALMART');
      expect(() => parseStatement(loose.words), fails('badRows'));

      // По итогам должно было уйти 2 000 ₸, прочиталась одна операция на 1 000.
      final lost = statementHead(closing: '+ 98 000,00 ₸');
      lost.header();
      lost.row('03.09.26', '- 1 000,00 ₸', 'Покупка', 'SMALL');
      lost.row('02.09.26', 'нет суммы', 'Покупка', 'GALMART');
      expect(() => parseStatement(lost.words), fails('mismatch'));
    });

    test('справка о счёте в том же файле и подпись с датой под таблицей не мешают', () {
      // Справка — первой страницей, выписка — второй.
      final before = Sheet()
        ..line('СПРАВКА о наличии счета')
        ..line('02.10.26')
        ..line('Иванов Иван Иванович имеет счет KZ12722C000012345678')
        ..line('Остаток на 30.09.26 составляет 97 000,00 ₸')
        ..newPage()
        ..line('ВЫПИСКА по Kaspi Gold за период с 01.09.26 по 30.09.26')
        ..pair('Доступно на 01.09.26', '+ 100 000,00 ₸')
        ..pair('Доступно на 30.09.26', '+ 97 000,00 ₸')
        ..gap()
        ..header()
        ..row('03.09.26', '- 1 000,00 ₸', 'Покупка', 'SMALL')
        ..row('02.09.26', '- 2 000,00 ₸', 'Перевод на свой\nсчет', 'На Kaspi Депозит')
        ..gap(4)
        ..line('02.10.26 14:35 Kaspi.kz');
      final a = parseStatement(before.words);
      expect(a.balanced, isTrue);
      expect(a.rows.map((r) => (r.amount, r.kind, r.details)), [(-200000, RowKind.ownOut, 'На Kaspi Депозит'), (-100000, RowKind.purchase, 'SMALL')]);

      // Справка — последней страницей.
      final after = statementHead(closing: '+ 97 000,00 ₸');
      after.header();
      after.row('03.09.26', '- 1 000,00 ₸', 'Покупка', 'SMALL');
      after.row('02.09.26', '- 2 000,00 ₸', 'Перевод на свой\nсчет', 'На Kaspi Депозит');
      after
        ..newPage()
        ..line('СПРАВКА о наличии счета')
        ..line('02.10.26')
        ..line('Остаток на 30.09.26 составляет 97 000,00 ₸', at: 230);
      final b = parseStatement(after.words);
      expect(b.rows.map((r) => (r.amount, r.kind, r.details)), [(-200000, RowKind.ownOut, 'На Kaspi Депозит'), (-100000, RowKind.purchase, 'SMALL')]);
    });

    test('остатков в шапке нет — выписка принимается без сверки', () {
      final s = Sheet()
        ..line('ВЫПИСКА по Kaspi Gold за период с 01.09.26 по 30.09.26')
        ..gap()
        ..header()
        ..row('03.09.26', '- 1 000,00 ₸', 'Покупка', 'SMALL');
      final st = parseStatement(s.words);
      expect(st.balanced, isFalse);
      expect(st.opening, isNull);
      expect(st.rows.single.amount, -100000);
    });

    test('в шапке есть другие суммы с датами — остатки находятся по сходимости', () {
      final s = Sheet()
        ..line('ВЫПИСКА по Kaspi Gold за период с 01.09.26 по 30.09.26')
        ..pair('Лимит действует до 01.10.26', '300 000,00 ₸')
        ..pair('Доступно на 30.09.26', '+ 9 000,00 ₸')
        ..pair('Доступно на 01.09.26', '+ 10 000,00 ₸')
        ..gap()
        ..header()
        ..row('03.09.26', '- 1 000,00 ₸', 'Покупка', 'SMALL');
      final st = parseStatement(s.words);
      expect((st.opening, st.closing), (kzt(10000), kzt(9000)));
    });

    test('выписка по счёту не в тенге не принимается: её суммы нельзя записать как тенге', () {
      for (final sign in [r'$', 'USD', '€']) {
        final s = Sheet()
          ..line('ВЫПИСКА по Kaspi Gold за период с 01.09.26 по 30.09.26')
          ..gap()
          ..header()
          ..row('03.09.26', '- 10,00 $sign', 'Покупка', 'AMAZON')
          ..row('02.09.26', '- 25,50 $sign', 'Покупка', 'APPLE.COM/BILL');
        expect(() => parseStatement(s.words), fails('currency'), reason: 'знак «$sign»');
      }
    });

    test('это не выписка: таблицы нет; таблица пуста; операций слишком много', () {
      expect(() => parseStatement((Sheet()..line('Справка о наличии счёта')..line('Дата выдачи 01.09.26')).words), fails('noTable'));
      expect(() => parseStatement((statementHead()..header()).words), fails('noRows'));
      final many = statementHead()..header();
      for (var i = 0; i < 12; i++) {
        many.row('03.09.26', '- 1 000,00 ₸', 'Покупка', 'SMALL');
      }
      expect(() => parseStatement(many.words, maxRows: 10), fails('tooMany'));
    });
  });

  test('выписка переживает сохранение в базу и обратно', () {
    final st = parseStatement(sampleStatement().words);
    final back = BankStatement.fromJson(st.toJson());
    expect(back.rows.map((r) => r.toJson()), st.rows.map((r) => r.toJson()));
    expect((back.opening, back.closing, back.from, back.to, back.language), (st.opening, st.closing, st.from, st.to, st.language));
  });

  test('строение файла для журнала не содержит ни имён, ни сумм, ни номеров', () {
    final layout = maskedLayout(sampleStatement().words);
    expect(layout, contains('Дата'));
    expect(layout, contains('Покупка'));
    expect(layout, isNot(contains('Иванов')));
    expect(layout, isNot(contains('Айгуль')));
    expect(layout, isNot(contains('MAGNUM')));
    expect(layout, isNot(contains('KZ12722')));
    expect(layout, isNot(contains('94 279')));
    expect(RegExp(r'\d').allMatches(layout.replaceAll(RegExp(r'p\d+ y\d+ h\d+ \||\d+:'), '').replaceAll('9', '')), isEmpty, reason: 'из цифр остаются только координаты');
  });
}
