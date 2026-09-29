/// Прогноз остатка до конца месяца (раздел 9.9).
///
/// Точка отсчёта — календарный конец месяца, не день зарплаты (D50: дата
/// дохода из продукта убрана). Прогноз — не гадание: вместо одного числа
/// «с точностью до тенге» — оценка и диапазон вокруг неё. Диапазон — простой
/// сценарий (±25% от ещё не потраченной части обычных трат), а не
/// статистический доверительный интервал: ширина не зависит от того,
/// насколько траты владельца скачут день ото дня.
library;

import 'dart:math' as math;

import '../money.dart';

class MonthForecast {
  const MonthForecast({
    required this.current,
    required this.remainingObligations,
    required this.expectedRegularSpend,
    required this.expectedIncome,
    required this.estimate,
    required this.rangeLow,
    required this.rangeHigh,
  });

  /// Свободные деньги сейчас.
  final int current;

  /// Ещё не оплаченные обязательные платежи до конца месяца (со знаком минус
  /// в прогнозе, здесь — положительная сумма).
  final int remainingObligations;

  /// Ожидаемые повседневные траты до конца месяца (регулярные + свободные).
  final int expectedRegularSpend;

  /// Ожидаемый доход до конца месяца.
  final int expectedIncome;

  /// Точечная оценка остатка на конец месяца.
  final int estimate;

  /// Нижняя и верхняя граница разумного диапазона.
  final int rangeLow;
  final int rangeHigh;
}

/// [current] — свободные деньги сейчас (уже учитывает всё, что произошло
/// сегодня); [remainingObligations] — сумма ещё не оплаченных обязательных
/// платежей до конца месяца; [avgDailySpend] — средний дневной расход на
/// обычное и свободное по уже прошедшим дням месяца; [daysLeft] — сколько
/// ПОЛНЫХ дней осталось до конца месяца, НЕ считая сегодня (сегодняшние траты
/// и доходы уже отражены в [current] и должны не задваиваться); [expectedIncome] —
/// ожидаемый доход до конца месяца (например, среднее за прошлые месяцы за
/// вычетом уже полученного).
///
/// Диапазон — ±25% от ещё не потраченной части обычных трат: сама точка
/// отсчёта («средний день») куда точнее известна, чем то, сколько дней ещё
/// останется такими же.
MonthForecast forecastMonthEnd({
  required int current,
  required int remainingObligations,
  required int avgDailySpend,
  required int daysLeft,
  required int expectedIncome,
}) {
  final d = math.max(0, daysLeft);
  // Оценка — округляется до целой единицы валюты: дробные тиыны в прогнозе
  // создают ложное ощущение точности (тот же принцип, что у dailyGuide).
  int round(int v) => roundHalfUp(v / minorPerUnit) * minorPerUnit;
  final expectedSpend = round(avgDailySpend * d);
  final estimate = round(current - remainingObligations - expectedSpend + expectedIncome);
  final margin = round((expectedSpend * 0.25).round());
  return MonthForecast(
    current: current,
    remainingObligations: remainingObligations,
    expectedRegularSpend: expectedSpend,
    expectedIncome: round(expectedIncome),
    estimate: estimate,
    rangeLow: estimate - margin,
    rangeHigh: estimate + margin,
  );
}
