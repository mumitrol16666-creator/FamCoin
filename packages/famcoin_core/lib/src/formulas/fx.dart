/// Валютный остаток по средневзвешенной стоимости (раздел 9.8, T20–T21).
library;

import '../money.dart';

class FxSale {
  const FxSale({required this.costReleased, required this.realized});

  /// Часть стоимости, списанная вместе с проданной валютой.
  final int costReleased;

  /// Реализованный курсовой результат: выручка − списанная стоимость.
  final int realized;
}

/// Позиция в одной валюте: количество (минимальные единицы иностранной
/// валюты) и её стоимость в валюте отчёта.
class FxPosition {
  int units = 0;
  int cost = 0;

  /// Средняя стоимость одной единицы валюты в минимальных единицах отчёта.
  double get averageCost => units == 0 ? 0 : cost / units * minorPerUnit;

  void buy({required int units, required int cost}) {
    if (units <= 0 || cost < 0) throw ArgumentError('Некорректная покупка');
    this.units += units;
    this.cost += cost;
  }

  FxSale sell({required int units, required int proceeds}) {
    if (units <= 0 || units > this.units) {
      throw ArgumentError('Продажа $units при остатке ${this.units}');
    }
    final released = units == this.units
        ? cost
        : roundHalfUp(cost * units / this.units);
    this.units -= units;
    cost -= released;
    return FxSale(costReleased: released, realized: proceeds - released);
  }

  /// Перевод между своими валютными счетами переносит стоимость.
  void transferTo(FxPosition other, int units) {
    final released = sell(units: units, proceeds: 0).costReleased;
    other.buy(units: units, cost: released);
  }

  /// Оценка остатка по курсу отчёта (минимальные единицы отчёта за единицу).
  int valueAt(int rateMinorPerUnit) =>
      roundHalfUp(units * rateMinorPerUnit / minorPerUnit);

  int unrealizedAt(int rateMinorPerUnit) => valueAt(rateMinorPerUnit) - cost;
}
