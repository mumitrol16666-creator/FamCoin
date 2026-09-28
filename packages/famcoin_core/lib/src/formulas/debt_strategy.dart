/// Стратегии погашения долгов: лавина и снежный ком (раздел 9.7).
library;

import '../money.dart';
import 'loans.dart';

enum DebtStrategy { avalanche, snowball }

class DebtInput {
  const DebtInput({
    required this.id,
    required this.balance,
    required this.annualRatePercent,
    required this.minPayment,
  });
  final String id;
  final int balance;
  final double annualRatePercent;
  final int minPayment;
}

class DebtStrategyResult {
  const DebtStrategyResult({
    required this.strategy,
    required this.order,
    required this.months,
    required this.totalInterest,
    this.reason,
  });
  final DebtStrategy strategy;

  /// Очередь дополнительных выплат.
  final List<String> order;
  final int months;
  final int totalInterest;
  final String? reason;

  bool get feasible => reason == null;
}

/// Симуляция при одинаковом месячном бюджете выплат: минимальные платежи
/// по всем долгам, остаток бюджета — первому долгу очереди.
DebtStrategyResult simulateDebtStrategy({
  required List<DebtInput> debts,
  required int monthlyBudget,
  required DebtStrategy strategy,
  int maxMonths = 600,
}) {
  final minTotal = debts.fold(0, (s, d) => s + d.minPayment);
  final ordered = [...debts];
  switch (strategy) {
    case DebtStrategy.avalanche:
      ordered.sort((a, b) {
        final byRate = b.annualRatePercent.compareTo(a.annualRatePercent);
        return byRate != 0 ? byRate : a.balance.compareTo(b.balance);
      });
    case DebtStrategy.snowball:
      ordered.sort((a, b) {
        final byBalance = a.balance.compareTo(b.balance);
        return byBalance != 0 ? byBalance : b.annualRatePercent.compareTo(a.annualRatePercent);
      });
  }
  final order = [for (final d in ordered) d.id];
  if (monthlyBudget < minTotal) {
    return DebtStrategyResult(
      strategy: strategy,
      order: order,
      months: 0,
      totalInterest: 0,
      reason: 'Бюджет $monthlyBudget меньше суммы минимальных платежей $minTotal',
    );
  }

  final balances = {for (final d in ordered) d.id: d.balance};
  var months = 0;
  var totalInterest = 0;
  while (balances.values.any((b) => b > 0)) {
    months++;
    if (months > maxMonths) {
      return DebtStrategyResult(
        strategy: strategy,
        order: order,
        months: months,
        totalInterest: totalInterest,
        reason: 'Долги не гасятся за $maxMonths месяцев',
      );
    }
    var budget = monthlyBudget;
    for (final d in ordered) {
      final b = balances[d.id]!;
      if (b <= 0) continue;
      final interest = roundHalfUp(b * monthlyRate(d.annualRatePercent));
      totalInterest += interest;
      final withInterest = b + interest;
      final pay = withInterest < d.minPayment ? withInterest : d.minPayment;
      balances[d.id] = withInterest - pay;
      budget -= pay;
    }
    for (final d in ordered) {
      if (budget <= 0) break;
      final b = balances[d.id]!;
      if (b <= 0) continue;
      final pay = b < budget ? b : budget;
      balances[d.id] = b - pay;
      budget -= pay;
    }
  }
  return DebtStrategyResult(
    strategy: strategy,
    order: order,
    months: months,
    totalInterest: totalInterest,
  );
}
