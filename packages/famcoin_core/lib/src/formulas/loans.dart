/// Кредиты: аннуитет, график, досрочное погашение (раздел 9.7).
///
/// Модель равных месячных периодов с фиксированной номинальной ставкой.
/// Введённый банковский график приоритетнее модельного.
library;

import 'dart:math' as math;

import '../money.dart';

/// Месячная ставка в долях из годовой в процентах: 22 → 0.22 / 12.
double monthlyRate(double annualRatePercent) => annualRatePercent / 100 / 12;

/// Аннуитетный платёж. При нулевой ставке — равные доли тела (T15).
int annuityPayment({
  required int principal,
  required double annualRatePercent,
  required int months,
}) {
  if (months <= 0) throw ArgumentError('months должно быть > 0');
  if (principal <= 0) return 0;
  final r = monthlyRate(annualRatePercent);
  if (r == 0) return roundHalfUp(principal / months);
  final a = principal * r / (1 - math.pow(1 + r, -months));
  return roundHalfUp(a);
}

class ScheduleRow {
  const ScheduleRow({
    required this.index,
    required this.payment,
    required this.interest,
    required this.principal,
    required this.balanceAfter,
  });
  final int index;
  final int payment;
  final int interest;
  final int principal;
  final int balanceAfter;
}

class Schedule {
  const Schedule(this.rows);
  final List<ScheduleRow> rows;
  int get months => rows.length;
  int get totalInterest => rows.fold(0, (s, r) => s + r.interest);
  int get totalPaid => rows.fold(0, (s, r) => s + r.payment);
}

/// Строит график: проценты на остаток, тело = платёж − проценты,
/// последний платёж закрывает остаток с учётом округлений.
/// Если платёж не покрывает проценты, возвращает `null` — долг не гасится.
Schedule? buildSchedule({
  required int principal,
  required double annualRatePercent,
  int? payment,
  int? months,
  int maxMonths = 600,
}) {
  if (principal <= 0) return const Schedule([]);
  if (payment == null && months == null) {
    throw ArgumentError('Нужен payment или months');
  }
  final r = monthlyRate(annualRatePercent);
  final a = payment ??
      annuityPayment(
          principal: principal, annualRatePercent: annualRatePercent, months: months!);
  final rows = <ScheduleRow>[];
  var balance = principal;
  var i = 0;
  while (balance > 0) {
    i++;
    if (i > maxMonths) return null;
    final interest = roundHalfUp(balance * r);
    if (a <= interest && balance > 0) return null;
    var body = a - interest;
    var pay = a;
    if (body >= balance) {
      body = balance;
      pay = body + interest;
    }
    balance -= body;
    rows.add(ScheduleRow(
      index: i,
      payment: pay,
      interest: interest,
      principal: body,
      balanceAfter: balance,
    ));
  }
  return Schedule(rows);
}

class EarlyRepaymentOption {
  const EarlyRepaymentOption({
    required this.months,
    required this.payment,
    required this.totalInterest,
    required this.interestSaved,
  });
  final int months;
  final int payment;
  final int totalInterest;

  /// Экономия сравнивает будущие проценты двух графиков; внесённое тело
  /// не является экономией.
  final int interestSaved;
}

class EarlyRepayment {
  const EarlyRepayment({
    required this.balanceAfter,
    required this.baseline,
    this.shortenTerm,
    this.reducePayment,
    this.reason,
  });
  final int balanceAfter;
  final Schedule baseline;
  final EarlyRepaymentOption? shortenTerm;
  final EarlyRepaymentOption? reducePayment;
  final String? reason;
}

/// Сравнение сценариев досрочного погашения: сохранить платёж (короче срок)
/// или сохранить срок (меньше платёж).
EarlyRepayment earlyRepayment({
  required int balance,
  required double annualRatePercent,
  required int payment,
  required int extra,
}) {
  if (extra < 0 || extra > balance) {
    throw ArgumentError('extra должно быть в пределах остатка');
  }
  final baseline = buildSchedule(
      principal: balance, annualRatePercent: annualRatePercent, payment: payment);
  if (baseline == null) {
    return EarlyRepayment(
      balanceAfter: balance,
      baseline: const Schedule([]),
      reason: 'Платёж не покрывает проценты периода: долг не гасится',
    );
  }
  final b = balance - extra;
  if (b == 0) {
    return EarlyRepayment(
      balanceAfter: 0,
      baseline: baseline,
      shortenTerm: EarlyRepaymentOption(
          months: 0, payment: 0, totalInterest: 0, interestSaved: baseline.totalInterest),
      reducePayment: EarlyRepaymentOption(
          months: 0, payment: 0, totalInterest: 0, interestSaved: baseline.totalInterest),
    );
  }
  final shorter =
      buildSchedule(principal: b, annualRatePercent: annualRatePercent, payment: payment)!;
  final newPayment = annuityPayment(
      principal: b, annualRatePercent: annualRatePercent, months: baseline.months);
  final sameTerm = buildSchedule(
          principal: b, annualRatePercent: annualRatePercent, payment: newPayment) ??
      shorter;
  return EarlyRepayment(
    balanceAfter: b,
    baseline: baseline,
    shortenTerm: EarlyRepaymentOption(
      months: shorter.months,
      payment: payment,
      totalInterest: shorter.totalInterest,
      interestSaved: baseline.totalInterest - shorter.totalInterest,
    ),
    reducePayment: EarlyRepaymentOption(
      months: sameTerm.months,
      payment: newPayment,
      totalInterest: sameTerm.totalInterest,
      interestSaved: baseline.totalInterest - sameTerm.totalInterest,
    ),
  );
}
