/// Цели и копилки (раздел 9.6).
library;

import 'dart:math' as math;

import '../money.dart';

class GoalStatus {
  const GoalStatus({
    required this.saved,
    required this.target,
    required this.remaining,
    this.progressPercent,
    this.requiredContribution,
    this.monthsToGoal,
  });

  final int saved;
  final int target;

  /// Не меньше нуля.
  final int remaining;

  /// Может быть больше 100; `null` при нулевой цели.
  final double? progressPercent;

  /// `null`, если запланированных дат пополнения нет.
  final int? requiredContribution;

  /// `null`, если среднее пополнение ≤ 0 и цель не достигнута.
  final int? monthsToGoal;

  bool get reached => remaining == 0;
}

GoalStatus goalStatus({
  required int saved,
  required int target,
  int plannedContributionsLeft = 0,
  int avgMonthlyNetContribution = 0,
}) {
  final remaining = math.max(0, target - saved);
  return GoalStatus(
    saved: saved,
    target: target,
    remaining: remaining,
    progressPercent: target > 0 ? saved * 100 / target : null,
    // Взнос округляется вверх до целой единицы валюты.
    requiredContribution: plannedContributionsLeft > 0
        ? (remaining / plannedContributionsLeft / minorPerUnit).ceil() * minorPerUnit
        : null,
    monthsToGoal: remaining == 0
        ? 0
        : (avgMonthlyNetContribution > 0
            ? (remaining / avgMonthlyNetContribution).ceil()
            : null),
  );
}

/// Копилка округления: `ceil(Сумма / Шаг) × Шаг − Сумма`.
int roundUpSaving(int amount, int step) {
  if (step <= 0) throw ArgumentError('Шаг должен быть > 0');
  if (amount <= 0) return 0;
  final rem = amount % step;
  return rem == 0 ? 0 : step - rem;
}
