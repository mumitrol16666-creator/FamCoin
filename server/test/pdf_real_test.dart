/// Настоящий PDF через настоящий `pdftotext` (D94): слова с рамками →
/// выписка. Нужен пакет poppler-utils; без него тесты пропускаются (в CI он
/// обязателен: `TEST_PDFTOTEXT_REQUIRED=1`).
library;

import 'dart:io';

import 'package:famcoin_core/famcoin_core.dart';
import 'package:famcoin_server/pdf_words.dart';
import 'package:famcoin_server/statement.dart';
import 'package:test/test.dart';

import 'statement_layout.dart';

void main() {
  final reader = PdfReader();
  var available = false;

  setUpAll(() async => available = await reader.probe());

  bool skip() {
    if (available) return false;
    if (Platform.environment['TEST_PDFTOTEXT_REQUIRED'] == '1') fail('TEST_PDFTOTEXT_REQUIRED=1, а pdftotext не найден');
    markTestSkipped('pdftotext не установлен');
    return true;
  }

  test('без разборщика чтение выключено и ничего не запускает', () async {
    final off = PdfReader();
    expect(off.enabled, isFalse);
    expect(await off.words(probePdf('FamCoin')), isNull);
  });

  test('выписка из настоящего PDF: ячейки по верху строки и по её середине', () async {
    if (skip()) return;
    for (final centered in [false, true]) {
      final words = await reader.words(sheetPdf(latinStatement(centered: centered)));
      expect(words, isNotNull, reason: 'по середине: $centered');
      final st = parseStatement(words!);
      expect(st.balanced, isTrue);
      expect((st.opening, st.closing), (kzt(100000), 9427992));
      expect(st.rows.map((r) => r.amount), [250000, -25000, 1500000, -1000000, -1147008, -3000000, -2000000, 5000000, -150000], reason: 'по середине: $centered');
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
        'MAGNUM AF51 ALMATY KZ',
        'Transfer fee (commission)',
        'From Kaspi Deposit',
        'Kaspi ATM',
        'OPENAI *CHATGPT SUBSCR (23,20 USD)',
        'To Kaspi Deposit',
        'Aigul K.',
        'Alexey A.',
        'MAGNUM AF51',
      ], reason: 'по середине: $centered');
      expect(st.rows[5].operation, 'Transfer to own account');
    }
  });

  test('не PDF и оборванный PDF — «не прочитал», без исключений', () async {
    if (skip()) return;
    expect(await reader.words('просто текст'.codeUnits), isNull);
    final pdf = sheetPdf(latinStatement());
    final broken = await reader.words(pdf.sublist(0, 200));
    expect(broken == null || broken.isEmpty, isTrue);
  });
}
