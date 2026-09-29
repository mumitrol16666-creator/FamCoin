/// Новые формулы аналитики (раздел 9.8–9.10): типы расходов, прогноз месяца,
/// долговая нагрузка.
library;

import 'package:famcoin_core/famcoin_core.dart';
import 'package:test/test.dart';

void main() {
  group('expenseTypeOf / splitExpenseTypes', () {
    test('встроенные категории распределены по трём типам', () {
      expect(expenseTypeOf('home'), ExpenseType.mandatory);
      expect(expenseTypeOf('utilities'), ExpenseType.mandatory);
      expect(expenseTypeOf('food'), ExpenseType.regular);
      expect(expenseTypeOf('cafe'), ExpenseType.discretionary);
    });

    test('своя категория — свободные по умолчанию', () {
      expect(expenseTypeOf('c_my_custom_id'), ExpenseType.discretionary);
    });

    test('сумма по трём типам не теряет и не дублирует', () {
      final split = splitExpenseTypes({'home': kzt(100000), 'food': kzt(60000), 'cafe': kzt(20000)});
      expect(split.mandatory, kzt(100000));
      expect(split.regular, kzt(60000));
      expect(split.discretionary, kzt(20000));
      expect(split.total, kzt(180000));
    });
  });

  group('forecastMonthEnd', () {
    test('точка и диапазон считаются по формуле, доход увеличивает остаток', () {
      final f = forecastMonthEnd(current: kzt(214000), remainingObligations: kzt(93000), avgDailySpend: kzt(7200), daysLeft: 10, expectedIncome: kzt(120000));
      expect(f.expectedRegularSpend, kzt(72000));
      expect(f.estimate, kzt(214000 - 93000 - 72000 + 120000));
      expect(f.rangeLow, lessThan(f.estimate));
      expect(f.rangeHigh, greaterThan(f.estimate));
      expect(f.rangeHigh - f.estimate, f.estimate - f.rangeLow);
    });

    test('оценка и диапазон округляются до целого тенге — дробные тиыны не просачиваются в прогноз', () {
      // Средний расход в день — не круглое число тиынов (типичный итог
      // целочисленного деления суммы на число прошедших дней).
      final f = forecastMonthEnd(current: 1090000, remainingObligations: 3000000, avgDailySpend: 234825, daysLeft: 10, expectedIncome: 0);
      for (final v in [f.estimate, f.rangeLow, f.rangeHigh, f.expectedRegularSpend, f.expectedIncome]) {
        expect(v % minorPerUnit, 0, reason: 'значение $v должно быть целым числом тенге');
      }
    });

    test('нулевые дни до конца месяца — трат больше не прогнозируется', () {
      final f = forecastMonthEnd(current: kzt(50000), remainingObligations: 0, avgDailySpend: kzt(5000), daysLeft: 0, expectedIncome: 0);
      expect(f.expectedRegularSpend, 0);
      expect(f.estimate, kzt(50000));
      expect(f.rangeLow, f.estimate);
      expect(f.rangeHigh, f.estimate);
    });
  });

  group('debtLoad / monthsToPayoff', () {
    test('общий долг и платежи суммируются, доля дохода считается верно', () {
      final status = debtLoad([
        const DebtLoadInput(id: 'a', currentBalance: 150000000, monthlyPayment: 15000000, annualRatePercent: 20, initialBalance: 300000000),
        const DebtLoadInput(id: 'b', currentBalance: 30000000, monthlyPayment: 3000000, annualRatePercent: 25),
      ], monthlyIncome: 74000000);
      expect(status.totalDebt, 180000000);
      expect(status.monthlyPayments, 18000000);
      expect(status.incomeSharePercent, closeTo(18000000 * 100 / 74000000, 0.001));
      // Доля погашения — только по долгу с известным исходным остатком.
      expect(status.paidPercent, closeTo(50, 0.001));
    });

    test('без исходных остатков доля погашения неизвестна, без дохода — доля дохода неизвестна', () {
      final status = debtLoad([const DebtLoadInput(id: 'c', currentBalance: 100, monthlyPayment: 10, annualRatePercent: 10)]);
      expect(status.paidPercent, isNull);
      expect(status.incomeSharePercent, isNull);
    });

    test('месяцев до погашения растёт при меньшем бюджете и падает при большем', () {
      final debts = [DebtLoadInput(id: 'a', currentBalance: kzt(500000), monthlyPayment: kzt(20000), annualRatePercent: 20)];
      final atMin = monthsToPayoff(debts, monthlyBudget: kzt(20000));
      final withExtra = monthsToPayoff(debts, monthlyBudget: kzt(40000));
      expect(atMin, isNotNull);
      expect(withExtra, isNotNull);
      expect(withExtra!, lessThan(atMin!));
    });

    test('без долгов — ноль месяцев', () {
      expect(monthsToPayoff(const [], monthlyBudget: kzt(1000)), 0);
    });
  });
}
