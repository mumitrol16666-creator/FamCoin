/// Лимиты категорий (раздел 9.4).
library;

import '../money.dart';

class LimitStatus {
  const LimitStatus({
    required this.spent,
    required this.limit,
    required this.remaining,
    this.usedPercent,
    this.linearForecast,
    this.remainingPerDay,
  });

  final int spent;
  final int limit;

  /// Может быть отрицательным при превышении.
  final int remaining;

  /// `null`, если лимит нулевой: тогда любая трата — предупреждение.
  final double? usedPercent;

  /// Линейный ориентир к концу периода; `null` без полных прошедших дней.
  final int? linearForecast;

  /// Сколько можно тратить в день до конца периода.
  final int? remainingPerDay;

  bool get warn80 => limit == 0 ? spent > 0 : spent * 5 >= limit * 4;
  bool get exceeded => limit == 0 ? spent > 0 : spent >= limit;
  bool get forecastExceeds => linearForecast != null && linearForecast! > limit;
}

LimitStatus limitStatus({
  required int spent,
  required int limit,
  required int elapsedFullDays,
  required int periodDays,
}) {
  if (limit < 0) throw ArgumentError('Лимит не может быть отрицательным');
  final remaining = limit - spent;
  final daysLeft = periodDays - elapsedFullDays;
  return LimitStatus(
    spent: spent,
    limit: limit,
    remaining: remaining,
    usedPercent: limit == 0 ? null : spent * 100 / limit,
    // Прогноз приблизительный, поэтому округляется до целой единицы валюты.
    linearForecast: elapsedFullDays <= 0 || periodDays <= 0
        ? null
        : roundHalfUp(spent / elapsedFullDays * periodDays / minorPerUnit) * minorPerUnit,
    remainingPerDay: daysLeft <= 0
        ? null
        : (remaining > 0 ? (remaining ~/ daysLeft) ~/ minorPerUnit * minorPerUnit : 0),
  );
}
