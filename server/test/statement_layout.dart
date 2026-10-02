/// Раскладка «как в PDF» для тестов разбора выписки: слова с рамками, как их
/// отдаёт `pdftotext -bbox`. Настоящая выписка — таблица «Дата · Сумма ·
/// Операция · Детали» с блоком итогов над ней.
library;

import 'dart:math';

import 'package:famcoin_server/pdf_words.dart';

class Sheet {
  Sheet({this.centered = false, this.x = const [40, 110, 230, 360], this.height = 9, this.pitch = 12, this.padding = 6});

  /// Ячейки выровнены по середине строки таблицы, а не по её верху.
  final bool centered;

  /// Левые края колонок: дата, сумма, операция, детали.
  final List<double> x;

  final words = <PdfWord>[];

  /// Куски текста, как их рисует PDF: строка целиком с позиции (страница, x, y).
  final runs = <(int, double, double, String)>[];
  var page = 0;
  var y = 60.0;

  /// Высота слова, шаг строк внутри ячейки и отступ между строками таблицы.
  final double height;
  final double pitch;
  final double padding;
  static const charWidth = 5.0;

  /// Текст с позиции [at]; пробел разделяет слова.
  void text(double at, String s, {double? onY}) {
    runs.add((page, at, onY ?? y, s));
    var pos = at;
    for (final w in s.split(' ')) {
      if (w.isNotEmpty) words.add(PdfWord(page, pos, onY ?? y, pos + w.length * charWidth, (onY ?? y) + height, w));
      pos += (w.length + 1) * charWidth;
    }
  }

  void line(String s, {double at = 40}) {
    text(at, s);
    y += pitch;
  }

  /// Строка блока итогов: название слева, сумма справа.
  void pair(String label, String amount) {
    text(40, label);
    text(300, amount);
    y += pitch;
  }

  void gap([double by = 10]) => y += by;

  void header({List<String> titles = const ['Дата', 'Сумма', 'Операция', 'Детали'], List<double>? at}) {
    for (var i = 0; i < 4; i++) {
      text((at ?? x)[i], titles[i]);
    }
    y += pitch + padding;
  }

  /// Строка таблицы; ячейка из нескольких строк — через `\n`.
  void row(String date, String amount, String operation, String details) {
    final cells = [date, amount, operation, details].map((c) => c.split('\n')).toList();
    final lines = cells.map((c) => c.length).reduce(max);
    for (var c = 0; c < 4; c++) {
      final shift = centered ? (lines - cells[c].length) / 2 * pitch : 0.0;
      for (var i = 0; i < cells[c].length; i++) {
        text(x[c], cells[c][i], onY: y + shift + i * pitch);
      }
    }
    y += lines * pitch + padding;
  }

  void newPage() {
    page++;
    y = 40;
  }
}

/// Шапка выписки за сентябрь 2026: остаток 100 000 ₸ на начало.
Sheet statementHead({bool centered = false, String closing = '+ 94 279,92 ₸', List<double> x = const [40, 110, 230, 360]}) {
  final s = Sheet(centered: centered, x: x);
  s.line('ВЫПИСКА');
  s.line('по Kaspi Gold за период с 01.09.26 по 30.09.26');
  s.gap();
  s.line('Иванов Иван Иванович');
  s.line('Номер карты: *1234');
  s.line('Номер счета: KZ12722C000012345678');
  s.gap();
  s.line('Краткое содержание операций по карте:');
  s.pair('Доступно на 01.09.26', '+ 100 000,00 ₸');
  s.pair('Пополнения', '+ 50 000,00 ₸');
  s.pair('Переводы', '- 20 000,00 ₸');
  s.pair('Покупки', '- 10 470,08 ₸');
  s.pair('Доступно на 30.09.26', closing);
  s.gap();
  s.line('Лимит на снятие наличных без комиссии: 300 000,00 ₸');
  s.gap(20);
  return s;
}

/// Девять операций сентября — все виды, с переносами в ячейках. Сумма
/// операций −5 720,08 ₸: остаток на конец 94 279,92 ₸.
Sheet sampleStatement({bool centered = false, String closing = '+ 94 279,92 ₸'}) {
  final s = statementHead(centered: centered, closing: closing);
  s.header();
  s.row('30.09.26', '- 1 500,00 ₸', 'Покупка', 'MAGNUM AF51');
  s.row('29.09.26', '+ 50 000,00 ₸', 'Пополнение', 'Алексей А.');
  s.row('28.09.26', '- 20 000,00 ₸', 'Перевод', 'Айгуль К.');
  s.row('27.09.26', '- 30 000,00 ₸', 'Перевод на свой\nсчет', 'На Kaspi Депозит');
  s.row('26.09.26', '- 11 470,08 ₸\n(- 23,20 USD)', 'Покупка', 'OPENAI *CHATGPT SUBSCR');
  s.row('25.09.26', '- 10 000,00 ₸', 'Снятие', 'Банкомат Kaspi');
  s.row('24.09.26', '+ 15 000,00 ₸', 'Поступление со\nсвоего счета', 'С Kaspi Депозита');
  s.row('23.09.26', '- 250,00 ₸', 'Разное', 'Комиссия за перевод');
  s.row('22.09.26', '+ 2 500,00 ₸', 'Покупка', 'MAGNUM AF51');
  return s;
}

/// Настоящий PDF с тем же текстом на тех же местах — для проверки на живом
/// `pdftotext`. Шрифт встроенный (Helvetica), поэтому текст только латиницей.
List<int> sheetPdf(Sheet s, {double fontSize = 9}) {
  const pageHeight = 842.0;
  String escape(String t) => t.replaceAll(r'\', r'\\').replaceAll('(', r'\(').replaceAll(')', r'\)');
  final pages = s.runs.map((r) => r.$1).fold<int>(0, max) + 1;
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [${[for (var p = 0; p < pages; p++) '${4 + p * 2} 0 R'].join(' ')}] /Count $pages >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>',
  ];
  for (var p = 0; p < pages; p++) {
    final stream = [
      for (final r in s.runs.where((r) => r.$1 == p))
        'BT /F1 $fontSize Tf 1 0 0 1 ${r.$2.toStringAsFixed(2)} ${(pageHeight - r.$3 - fontSize * 0.8).toStringAsFixed(2)} Tm (${escape(r.$4)}) Tj ET',
    ].join('\n');
    objects
      ..add('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 $pageHeight] /Contents ${5 + p * 2} 0 R /Resources << /Font << /F1 3 0 R >> >> >>')
      ..add('<< /Length ${stream.length} >>\nstream\n$stream\nendstream');
  }
  final out = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(out.length);
    out.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = out.length;
  out.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final o in offsets) {
    out.write('${o.toString().padLeft(10, '0')} 00000 n \n');
  }
  out.write('trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n');
  return out.toString().codeUnits;
}

/// Выписка на английском, только латиницей — её можно превратить в настоящий
/// PDF. Те же девять операций, что в [sampleStatement].
Sheet latinStatement({bool centered = false}) {
  final s = Sheet(centered: centered);
  s.line('STATEMENT');
  s.line('for Kaspi Gold for the period from 01.09.26 to 30.09.26');
  s.gap();
  s.line('Ivanov Ivan');
  s.line('Card number: *1234');
  s.gap();
  s.pair('Available on 01.09.26', '+ 100 000,00 KZT');
  s.pair('Replenishments', '+ 50 000,00 KZT');
  s.pair('Purchases', '- 10 470,08 KZT');
  s.pair('Available on 30.09.26', '+ 94 279,92 KZT');
  s.gap(20);
  s.header(titles: ['Date', 'Amount', 'Transaction', 'Details']);
  s.row('30.09.26', '- 1 500,00 KZT', 'Purchase', 'MAGNUM AF51');
  s.row('29.09.26', '+ 50 000,00 KZT', 'Replenishment', 'Alexey A.');
  s.row('28.09.26', '- 20 000,00 KZT', 'Transfer', 'Aigul K.');
  s.row('27.09.26', '- 30 000,00 KZT', 'Transfer to own\naccount', 'To Kaspi Deposit');
  s.row('26.09.26', '- 11 470,08 KZT\n(- 23,20 USD)', 'Purchase', 'OPENAI *CHATGPT SUBSCR');
  s.row('25.09.26', '- 10 000,00 KZT', 'Withdrawal', 'Kaspi ATM');
  s.row('24.09.26', '+ 15 000,00 KZT', 'Transfer from own\naccount', 'From Kaspi Deposit');
  s.row('23.09.26', '- 250,00 KZT', 'Others', 'Transfer fee (commission)');
  s.newPage();
  s.header(titles: ['Date', 'Amount', 'Transaction', 'Details']);
  s.row('22.09.26', '+ 2 500,00 KZT', 'Purchase', 'MAGNUM AF51\nALMATY KZ');
  return s;
}
