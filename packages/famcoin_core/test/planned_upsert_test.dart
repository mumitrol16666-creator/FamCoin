/// Сохранение условий платежа отдельно от его исполнения (аудит 08.10, N03).
library;

import 'package:famcoin_core/famcoin_core.dart';
import 'package:test/test.dart';

void main() {
  final stored = {'name': 'Аренда', 'amount': '1000000', 'day': 10, 'paid': ['2026-09'], 'rev': 3};

  test('отметки сроков — из сохранённой записи, условия — из команды, версия +1', () {
    final next = mergePlannedUpsert(stored, {'name': 'Квартира', 'amount': '1200000', 'day': 10, 'paid': <String>[], 'rev': 3});
    expect(next, {'name': 'Квартира', 'amount': '1200000', 'day': 10, 'paid': ['2026-09'], 'rev': 4});
  });

  test('команда по устаревшей версии условий — отказ entityChanged; без rev (старое приложение) — без проверки', () {
    expect(
      () => mergePlannedUpsert(stored, {'name': 'Квартира', 'paid': <String>[], 'rev': 2}),
      throwsA(isA<LedgerException>().having((e) => e.code, 'code', 'entityChanged')),
    );
    expect(mergePlannedUpsert(stored, {'name': 'Квартира', 'paid': <String>[]})['paid'], ['2026-09']);
    expect(mergePlannedUpsert(stored, {'name': 'X', 'rev': 2}, check: false)['rev'], 4, reason: 'приложение после ответа сервера только сливает');
  });

  test('новая запись принимает свои отметки и получает rev 1; запись без rev считается версией 0', () {
    expect(mergePlannedUpsert(null, {'name': 'Аренда', 'paid': ['2026-08']}), {'name': 'Аренда', 'paid': ['2026-08'], 'rev': 1});
    expect(mergePlannedUpsert({'name': 'Аренда', 'paid': ['2026-09']}, {'name': 'Б', 'paid': <String>[], 'rev': 0})['rev'], 1);
  });
}
