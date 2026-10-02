/// Разбор выписки на случайных раскладках (D94): сотни выписок с разным
/// числом строк в ячейках, разными колонками, выравниванием и разбивкой по
/// страницам — разобранное должно совпасть с тем, что было «напечатано».
/// Случайность с постоянным зерном: тест каждый раз проверяет одно и то же.
library;

import 'dart:io';
import 'dart:math';

import 'package:famcoin_core/famcoin_core.dart';
import 'package:famcoin_server/statement.dart';
import 'package:test/test.dart';

import 'statement_layout.dart';

const _operations = <(String, RowKind)>[
  ('Покупка', RowKind.purchase),
  ('Перевод', RowKind.transfer),
  ('Пополнение', RowKind.topup),
  ('Снятие', RowKind.withdrawal),
  ('Разное', RowKind.other),
  ('Перевод на свой\nсчет', RowKind.ownOut),
  ('Поступление со\nсвоего счета', RowKind.ownIn),
  ('Зачисление\nкредита', RowKind.credit),
];

/// Слова деталей — в том числе похожие на дату, сумму и название операции.
const _words = ['MAGNUM', 'AF51', 'Айгуль', 'К.', 'ИП', 'НУРЛАНОВ', 'Покупка', 'Перевод', '01.09.26', '1 500,00', '₸', 'Kaspi', 'Депозит', '*CHATGPT', 'ТОО', '№5', 'счет', 'С', 'На', '(тест)', '2', '+', '-'];

String _money(int minor) {
  final digits = (minor.abs() ~/ 100).toString();
  final grouped = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    grouped.write(digits[i]);
    if ((digits.length - i) % 3 == 1 && i != digits.length - 1) grouped.write(' ');
  }
  return '${minor < 0 ? '-' : '+'} $grouped,${(minor.abs() % 100).toString().padLeft(2, '0')} ₸';
}

void main() {
  test('случайные выписки разбираются в точности', () {
    // Больше выписок — переменной окружения: STATEMENT_SEEDS=5000 dart test …
    final seeds = int.parse(Platform.environment['STATEMENT_SEEDS'] ?? '300');
    for (var seed = 0; seed < seeds; seed++) {
      final r = Random(seed);
      final centered = r.nextBool();
      final repeatHeader = r.nextBool();
      final x = [40.0, 100.0 + r.nextInt(25), 215.0 + r.nextInt(30), 345.0 + r.nextInt(40)];
      // Заголовок таблицы иногда стоит не над левым краем ячеек (по центру колонки).
      final headerAt = r.nextInt(3) == 0 ? [x[0] + r.nextInt(8), x[1] + r.nextInt(30), x[2] + r.nextInt(40), x[3] + 10 + r.nextInt(60)] : x;
      final height = 8.0 + r.nextInt(5);
      final pitch = height + 1 + r.nextInt(4);
      final padding = 3.0 + r.nextInt(8);
      final count = 1 + r.nextInt(45);
      final ascending = r.nextInt(4) == 0;

      // Операции от новых к старым — как печатает банк (иногда наоборот).
      final expected = <(String, int, RowKind, String)>[];
      final printed = <List<String>>[];
      var day = 30;
      for (var i = 0; i < count; i++) {
        if (day > 1 && r.nextInt(3) == 0) day--;
        final (operation, kind) = _operations[r.nextInt(_operations.length)];
        var amount = (1 + r.nextInt(5000000)) * (r.nextInt(10) == 0 ? 100 : 1);
        final negative = switch (kind) { RowKind.topup || RowKind.ownIn || RowKind.credit => false, RowKind.purchase => r.nextInt(8) != 0, _ => true };
        if (negative) amount = -amount;
        final lines = [
          for (var k = 0; k < 1 + (r.nextInt(3) == 0 ? 1 + r.nextInt(3) : 0); k++) [for (var w = 0; w < 1 + r.nextInt(4); w++) _words[r.nextInt(_words.length)]].join(' '),
        ];
        final foreign = kind == RowKind.purchase && r.nextInt(6) == 0;
        final date = '${day.toString().padLeft(2, '0')}.09.26';
        printed.add([date, _money(amount) + (foreign ? '\n(- 23,20 USD)' : ''), operation, lines.join('\n')]);
        final details = lines.join(' ').split(' ').where((w) => w.isNotEmpty).join(' ');
        expected.add(('2026-09-${day.toString().padLeft(2, '0')}', amount, kind, foreign ? '$details (23,20 USD)' : details));
      }
      final total = expected.fold<int>(0, (s, e) => s + e.$2);
      final opening = r.nextInt(100000000);

      final s = Sheet(centered: centered, x: x, height: height, pitch: pitch, padding: padding)
        ..line('ВЫПИСКА')
        ..line('по Kaspi Gold за период с 01.09.26 по 30.09.26')
        ..gap()
        ..pair('Доступно на 01.09.26', _money(opening))
        ..pair('Пополнения', '+ 1 000,00 ₸')
        ..pair('Доступно на 30.09.26', _money(opening + total))
        ..line('Лимит на снятие наличных без комиссии: 300 000,00 ₸')
        ..gap(20)
        ..header(at: headerAt);
      for (final row in ascending ? printed.reversed : printed) {
        final lines = row.map((c) => c.split('\n').length).reduce(max);
        if (s.y + lines * pitch > 790) {
          s.gap(5 * height); // подвал стоит заметно ниже последней строки таблицы
          s.line('АО «Kaspi Bank», www.kaspi.kz', at: x[2]);
          s.newPage();
          if (repeatHeader) s.header(at: headerAt);
        }
        s.row(row[0], row[1], row[2], row[3]);
      }

      final BankStatement st;
      try {
        st = parseStatement(s.words);
      } on StatementError catch (e) {
        fail('зерно $seed (по середине: $centered, строк: $count): $e');
      }
      final got = [for (final row in st.rows) (dateToJson(row.date), row.amount, row.kind, row.details)];
      final want = ascending ? expected.reversed.toList() : expected.reversed.toList();
      // Порядок внутри дня зависит от порядка печати — сравниваем по дням.
      expect(got.length, want.length, reason: 'зерно $seed');
      String key((String, int, RowKind, String) e) => '${e.$1}|${e.$2}|${e.$3.name}|${e.$4}';
      expect(got.map(key).toList()..sort(), want.map(key).toList()..sort(), reason: 'зерно $seed (по середине: $centered, колонки: $x, заголовок: $headerAt, высота $height, шаг $pitch, отступ $padding)');
      expect([for (final row in st.rows) row.date], [...st.rows.map((row) => row.date)]..sort(), reason: 'зерно $seed: по возрастанию дат');
      expect((st.opening, st.closing), (opening, opening + total), reason: 'зерно $seed');
    }
  });
}
