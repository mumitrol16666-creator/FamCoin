/// Расчётные формулы раздела 9: дневной ориентир, лимиты, цели, кредиты,
/// стратегии долгов. Включает T15, T16, T22, T23.
library;

import 'package:famcoin_core/famcoin_core.dart';
import 'package:test/test.dart';

void main() {
  group('Дневной ориентир', () {
    test('T22 100 000 на 10 дней, потрачено 2 000 → остаток дня 8 000', () {
      final g = dailyGuide(
        liquid: kzt(100000),
        reserves: 0,
        obligations: 0,
        savingsPlan: 0,
        days: 10,
        spentToday: kzt(2000),
      );
      expect(g.dailyBudget, kzt(10000));
      expect(g.remainingToday, kzt(8000));
      expect(g.deficit, isFalse);
    });

    test('обязательства и резервы вычитаются по одному разу', () {
      final g = dailyGuide(
        liquid: kzt(486300),
        reserves: kzt(60000),
        obligations: kzt(185000),
        savingsPlan: kzt(50000),
        days: 13,
      );
      expect(g.base, kzt(191300));
      expect(g.dailyBudget, kzt(14715), reason: '191 300 / 13 = 14 715,38 → вниз до тенге');
    });

    test('дефицит показывается, а не отрицательный бюджет; дней не меньше 1', () {
      final g = dailyGuide(liquid: kzt(10000), reserves: 0, obligations: kzt(15000), savingsPlan: 0, days: 0);
      expect(g.deficit, isTrue);
      expect(g.dailyBudget, 0);
      expect(g.days, 1);
    });

    test('маленький аванс завтра не освобождает деньги на аренду послезавтра', () {
      // 100 000 свободно, горизонт 10 дней; аванс +20 000 на 2-й день,
      // аренда −110 000 на 3-й день. Без аренды было бы 12 000/день.
      final r = constantDailyBudget(
        freeLiquid: kzt(100000),
        horizonDays: 10,
        flows: [PlannedFlow(2, kzt(20000)), PlannedFlow(3, -kzt(110000))],
      );
      // После аренды остаётся 10 000 на весь горизонт из 10 дней → 1 000/день;
      // ограничивает последняя точка, а не день аванса.
      expect(r.dailyBudget, kzt(1000));
      expect(r.bindingDay, 10);
      expect(r.deficitDay, isNull);
    });

    test('дефицит фиксируется с датой', () {
      final r = constantDailyBudget(
        freeLiquid: kzt(50000),
        horizonDays: 10,
        flows: [PlannedFlow(4, -kzt(80000)), PlannedFlow(4, kzt(20000))],
      );
      expect(r.deficitDay, 4);
      expect(r.dailyBudget, 0);
    });
  });

  group('Лимиты', () {
    test('80% и прогноз', () {
      final s = limitStatus(spent: kzt(24900), limit: kzt(30000), elapsedFullDays: 21, periodDays: 30);
      expect(s.usedPercent, closeTo(83, 0.01));
      expect(s.warn80, isTrue);
      expect(s.exceeded, isFalse);
      expect(s.linearForecast, kzt(35571), reason: '24 900 / 21 × 30 = 35 571,43 → до тенге');
      expect(s.forecastExceeds, isTrue);
      expect(s.remainingPerDay, kzt(566), reason: '5 100 / 9 = 566,67 → вниз до тенге');
    });

    test('T23 нулевой лимит: без деления на ноль, любая трата — предупреждение', () {
      final s = limitStatus(spent: kzt(1), limit: 0, elapsedFullDays: 0, periodDays: 30);
      expect(s.usedPercent, isNull);
      expect(s.linearForecast, isNull, reason: 'нет полных прошедших дней');
      expect(s.warn80, isTrue);
      expect(s.exceeded, isTrue);
    });

    test('отрицательный расход после возврата показывается явно', () {
      final s = limitStatus(spent: -kzt(3000), limit: kzt(30000), elapsedFullDays: 5, periodDays: 30);
      expect(s.remaining, kzt(33000));
      expect(s.warn80, isFalse);
    });
  });

  group('Цели', () {
    test('прогресс, остаток, требуемый взнос', () {
      final g = goalStatus(saved: kzt(300000), target: kzt(600000), plannedContributionsLeft: 9, avgMonthlyNetContribution: kzt(42000));
      expect(g.progressPercent, 50);
      expect(g.remaining, kzt(300000));
      expect(g.requiredContribution, kzt(33334), reason: '300 000 / 9 = 33 333,33 → вверх до тенге');
      expect(g.monthsToGoal, 8);
    });

    test('T23 нулевая цель и отсутствие взносов: null вместо NaN', () {
      final g = goalStatus(saved: kzt(10), target: 0);
      expect(g.progressPercent, isNull);
      expect(g.remaining, 0);
      expect(g.requiredContribution, isNull);
      expect(g.monthsToGoal, 0);
      final h = goalStatus(saved: 0, target: kzt(1000), avgMonthlyNetContribution: 0);
      expect(h.monthsToGoal, isNull);
    });

    test('прогресс больше 100%, остаток не меньше нуля', () {
      final g = goalStatus(saved: kzt(700000), target: kzt(600000));
      expect(g.progressPercent, closeTo(116.67, 0.01));
      expect(g.remaining, 0);
      expect(g.reached, isTrue);
    });

    test('копилка округления', () {
      expect(roundUpSaving(kzt(1230), kzt(100)), kzt(70));
      expect(roundUpSaving(kzt(1200), kzt(100)), 0);
      expect(roundUpSaving(kzt(1230), kzt(500)), kzt(270));
    });
  });

  group('Кредиты', () {
    test('T15 120 000 под 0% на 12 месяцев: по 10 000, без деления на ноль', () {
      expect(annuityPayment(principal: kzt(120000), annualRatePercent: 0, months: 12), kzt(10000));
      final s = buildSchedule(principal: kzt(120000), annualRatePercent: 0, months: 12)!;
      expect(s.months, 12);
      expect(s.rows.every((r) => r.payment == kzt(10000)), isTrue);
      expect(s.totalInterest, 0);
      expect(s.rows.last.balanceAfter, 0);
    });

    test('T16 остаток 100 000, 0%, платёж 10 000, досрочно 20 000 → 80 000 и восемь платежей', () {
      final e = earlyRepayment(balance: kzt(100000), annualRatePercent: 0, payment: kzt(10000), extra: kzt(20000));
      expect(e.balanceAfter, kzt(80000));
      expect(e.shortenTerm!.months, 8);
      expect(e.shortenTerm!.payment, kzt(10000));
      expect(e.reducePayment!.months, 10);
      expect(e.reducePayment!.payment, kzt(8000));
    });

    test('аннуитет 1 000 000 под 12% на 12 месяцев ≈ 88 849', () {
      final a = annuityPayment(principal: kzt(1000000), annualRatePercent: 12, months: 12);
      expect(a, closeTo(kzt(88849), kzt(1)));
      final s = buildSchedule(principal: kzt(1000000), annualRatePercent: 12, months: 12)!;
      expect(s.months, 12);
      expect(s.rows.last.balanceAfter, 0);
      expect(s.totalPaid - kzt(1000000), s.totalInterest);
      expect(s.totalInterest, closeTo(kzt(66186), kzt(30)));
    });

    test('платёж меньше процентов: причина вместо числа', () {
      final e = earlyRepayment(balance: kzt(1000000), annualRatePercent: 24, payment: kzt(10000), extra: 0);
      expect(e.shortenTerm, isNull);
      expect(e.reason, isNotNull);
    });

    test('досрочно: сокращение срока экономит больше процентов, чем уменьшение платежа', () {
      final e = earlyRepayment(balance: kzt(220000), annualRatePercent: 22, payment: kzt(20600), extra: kzt(100000));
      expect(e.shortenTerm!.months, lessThan(e.reducePayment!.months));
      expect(e.shortenTerm!.interestSaved, greaterThan(e.reducePayment!.interestSaved));
      expect(e.shortenTerm!.interestSaved, greaterThan(0));
    });
  });

  group('Стратегии долгов', () {
    final debts = [
      DebtInput(id: 'red', balance: kzt(220000), annualRatePercent: 22, minPayment: kzt(25000)),
      DebtInput(id: 'daniyar', balance: kzt(15000), annualRatePercent: 0, minPayment: kzt(5000)),
      DebtInput(id: 'iphone', balance: kzt(200000), annualRatePercent: 0, minPayment: kzt(20000)),
    ];

    test('лавина — по ставке, снежный ком — по остатку', () {
      final a = simulateDebtStrategy(debts: debts, monthlyBudget: kzt(60000), strategy: DebtStrategy.avalanche);
      final s = simulateDebtStrategy(debts: debts, monthlyBudget: kzt(60000), strategy: DebtStrategy.snowball);
      expect(a.order, ['red', 'daniyar', 'iphone']);
      expect(s.order, ['daniyar', 'iphone', 'red']);
      expect(a.feasible, isTrue);
      expect(a.totalInterest, lessThanOrEqualTo(s.totalInterest));
      expect(a.months, lessThanOrEqualTo(s.months));
    });

    test('бюджет меньше минимальных платежей — причина, не расчёт', () {
      final r = simulateDebtStrategy(debts: debts, monthlyBudget: kzt(40000), strategy: DebtStrategy.avalanche);
      expect(r.feasible, isFalse);
      expect(r.reason, contains('минимальных'));
    });
  });
}
