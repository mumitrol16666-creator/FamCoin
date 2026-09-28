/// Дневные итоги по счетам — восстановимая проекция журнала.
///
/// Обновляются при каждой проводке и могут быть полностью перестроены;
/// после перестройки обязаны совпасть с журналом до минимальной единицы (T31).
library;

import 'ledger.dart';

class DailyTotals {
  final Map<String, int> _totals = {};
  int revision = 0;

  static String key(DateTime date, String accountId) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}|$accountId';

  Map<String, int> get totals => Map.unmodifiable(_totals);

  int of(DateTime date, String accountId) => _totals[key(date, accountId)] ?? 0;

  /// Инкрементальное обновление после проводки.
  void apply(Transaction tx) {
    for (final p in tx.postings) {
      final k = key(tx.date, p.accountId);
      final v = (_totals[k] ?? 0) + p.amount;
      if (v == 0) {
        _totals.remove(k);
      } else {
        _totals[k] = v;
      }
    }
    revision++;
  }

  /// Полная перестройка по журналу.
  static DailyTotals rebuild(Ledger ledger) {
    final result = DailyTotals();
    for (final tx in ledger.transactions) {
      result.apply(tx);
    }
    return result;
  }

  bool sameAs(DailyTotals other) {
    if (_totals.length != other._totals.length) return false;
    for (final e in _totals.entries) {
      if (other._totals[e.key] != e.value) return false;
    }
    return true;
  }
}
