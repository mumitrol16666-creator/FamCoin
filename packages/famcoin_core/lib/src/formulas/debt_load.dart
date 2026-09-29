/// Долговая нагрузка (раздел 9.10): сколько всего должны банкам, какая доля
/// дохода уходит на платежи, когда долг будет погашен при текущем темпе и
/// при дополнительных взносах.
library;

import 'debt_strategy.dart';

class DebtLoadInput {
  const DebtLoadInput({
    required this.id,
    required this.currentBalance,
    required this.monthlyPayment,
    required this.annualRatePercent,
    this.initialBalance,
  });
  final String id;
  final int currentBalance;
  final int monthlyPayment;
  final double annualRatePercent;

  /// Остаток на момент открытия долга; `null` — доля погашения не считается
  /// (например, кредитная карта: баланс растёт от новых покупок, «доля
  /// погашения» для неё не имеет смысла).
  final int? initialBalance;
}

class DebtLoadStatus {
  const DebtLoadStatus({
    required this.totalDebt,
    required this.monthlyPayments,
    this.incomeSharePercent,
    this.paidPercent,
  });
  final int totalDebt;
  final int monthlyPayments;

  /// `null` — доход неизвестен или равен нулю.
  final double? incomeSharePercent;

  /// Средневзвешенная (по сумме) доля уже погашенного среди долгов, где
  /// известен исходный остаток; `null`, если такого долга нет.
  final double? paidPercent;
}

DebtLoadStatus debtLoad(List<DebtLoadInput> debts, {int? monthlyIncome}) {
  final totalDebt = debts.fold(0, (s, d) => s + d.currentBalance);
  final monthlyPayments = debts.fold(0, (s, d) => s + d.monthlyPayment);
  var paidBase = 0, paidNow = 0;
  for (final d in debts) {
    final initial = d.initialBalance;
    if (initial == null || initial <= 0) continue;
    paidBase += initial;
    paidNow += (initial - d.currentBalance).clamp(0, initial);
  }
  return DebtLoadStatus(
    totalDebt: totalDebt,
    monthlyPayments: monthlyPayments,
    incomeSharePercent: (monthlyIncome ?? 0) > 0 ? monthlyPayments * 100 / monthlyIncome! : null,
    paidPercent: paidBase > 0 ? paidNow * 100 / paidBase : null,
  );
}

/// Сколько месяцев до полного погашения при заданном месячном бюджете на
/// платежи (минимальные платежи плюс остаток — первому долгу по лавине).
/// `null`, если долгов нет или погашение не укладывается в разумный срок.
int? monthsToPayoff(List<DebtLoadInput> debts, {required int monthlyBudget}) {
  if (debts.isEmpty) return 0;
  final r = simulateDebtStrategy(
    debts: [for (final d in debts) DebtInput(id: d.id, balance: d.currentBalance, annualRatePercent: d.annualRatePercent, minPayment: d.monthlyPayment)],
    monthlyBudget: monthlyBudget,
    strategy: DebtStrategy.avalanche,
  );
  return r.feasible ? r.months : null;
}
