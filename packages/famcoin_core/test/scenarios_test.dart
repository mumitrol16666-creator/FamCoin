/// Контрольные сценарии раздела 16 карты продукта (T01–T35).
/// Суммы в тенге через `kzt()`, внутри — тиыны.
library;

import 'package:famcoin_core/famcoin_core.dart';
import 'package:test/test.dart';

final d0 = DateTime(2026, 9, 1);
final d1 = DateTime(2026, 9, 10);
final d2 = DateTime(2026, 9, 20);
final periodFrom = DateTime(2026, 9, 1);
final periodTo = DateTime(2026, 10, 1);

/// Журнал с одним ликвидным счётом «kaspi» и начальным остатком 100 000 ₸.
Ledger seed({int opening = 100000}) {
  final l = Ledger()..addMoneyAccount('kaspi');
  if (opening > 0) {
    l.openingBalance(id: 'open', date: d0, account: 'kaspi', amount: kzt(opening));
  }
  return l;
}

void main() {
  group('Балансы и доходы', () {
    test('T01 начальный остаток: баланс 100 000, доход периода 0', () {
      final l = seed();
      expect(l.balance('kaspi'), kzt(100000));
      expect(l.report(periodFrom, periodTo).income, 0);
    });

    test('T02 зарплата 450 000: баланс 550 000, доход 450 000', () {
      final l = seed()
        ..income(id: 's', date: d1, account: 'kaspi', source: 'salary', amount: kzt(450000));
      expect(l.balance('kaspi'), kzt(550000));
      expect(l.report(periodFrom, periodTo).income, kzt(450000));
    });

    test('T03 расход 8 400: баланс 541 600, расход 8 400', () {
      final l = seed()
        ..income(id: 's', date: d1, account: 'kaspi', source: 'salary', amount: kzt(450000))
        ..expense(id: 'e', date: d2, account: 'kaspi', splits: {'food': kzt(8400)});
      expect(l.balance('kaspi'), kzt(541600));
      expect(l.report(periodFrom, periodTo).expense, kzt(8400));
    });

    test('T04 перевод 20 000: остатки 80 000 и 20 000, расход 0, активы 100 000', () {
      final l = seed()
        ..addMoneyAccount('halyk')
        ..transfer(id: 't', date: d1, from: 'kaspi', to: 'halyk', amount: kzt(20000));
      expect(l.balance('kaspi'), kzt(80000));
      expect(l.balance('halyk'), kzt(20000));
      expect(l.report(periodFrom, periodTo).expense, 0);
      expect(l.report(periodFrom, periodTo).cashFlow, 0);
      expect(l.netWorth().assets, kzt(100000));
    });
  });

  group('Цели и резервы', () {
    test('T05 резерв 20 000: деньги и активы 100 000, свободно 80 000', () {
      final l = seed()..reserve(goalId: 'trip', accountId: 'kaspi', amount: kzt(20000));
      expect(l.balance('kaspi'), kzt(100000));
      expect(l.netWorth().assets, kzt(100000));
      expect(l.freeLiquid(), kzt(80000));
    });

    test('T06 трата 5 000 из цели: деньги 95 000, резерв 15 000, свободно 80 000, расход 5 000', () {
      final l = seed()..reserve(goalId: 'trip', accountId: 'kaspi', amount: kzt(20000));
      l.ensure(expenseAccount('travel'), LedgerKind.expense);
      final tx = Transaction(
        id: 'e',
        date: d1,
        type: EventType.expense,
        postings: [Posting(expenseAccount('travel'), kzt(5000)), Posting('kaspi', -kzt(5000))],
      );
      l.postFromReservation(tx, goalId: 'trip', accountId: 'kaspi', amount: kzt(5000));
      expect(l.balance('kaspi'), kzt(95000));
      expect(l.reserved(goalId: 'trip'), kzt(15000));
      expect(l.freeLiquid(), kzt(80000));
      expect(l.report(periodFrom, periodTo).expense, kzt(5000));
    });

    test('C06/T16 трата из цели с отрицательной суммой: операции нет, резерв и деньги прежние', () {
      final l = seed()..reserve(goalId: 'trip', accountId: 'kaspi', amount: kzt(20000));
      l.ensure(expenseAccount('travel'), LedgerKind.expense);
      final tx = Transaction(
        id: 'e',
        date: d1,
        type: EventType.expense,
        postings: [Posting(expenseAccount('travel'), kzt(5000)), Posting('kaspi', -kzt(5000))],
      );
      for (final bad in [-kzt(5000), 0]) {
        expect(
          () => l.postFromReservation(tx, goalId: 'trip', accountId: 'kaspi', amount: bad),
          throwsA(isA<LedgerException>().having((e) => e.code, 'code', 'invalidAmount')),
        );
      }
      expect(l.reserved(goalId: 'trip'), kzt(20000));
      expect(l.balance('kaspi'), kzt(100000));
      expect(l.byId('e'), isNull);
    });

    test('резерв не может превышать доступный остаток', () {
      final l = seed();
      expect(
        () => l.reserve(goalId: 'g', accountId: 'kaspi', amount: kzt(100001)),
        throwsA(isA<LedgerException>()),
      );
    });

    test('T34 при отказе операции резерв не меняется', () {
      final l = seed()..reserve(goalId: 'g', accountId: 'kaspi', amount: kzt(20000));
      final unbalanced = Transaction(
        id: 'bad',
        date: d1,
        type: EventType.expense,
        postings: [Posting('kaspi', -kzt(5000))],
      );
      expect(
        () => l.postFromReservation(unbalanced, goalId: 'g', accountId: 'kaspi', amount: kzt(5000)),
        throwsA(isA<LedgerException>()),
      );
      expect(l.reserved(goalId: 'g'), kzt(20000));
      expect(l.transactions.length, 1);
    });
  });

  group('Личные долги', () {
    test('T07 взять долг 30 000: деньги 130 000, обязательство 30 000, капитал 100 000', () {
      final l = seed()
        ..borrow(id: 'b', date: d1, account: 'kaspi', person: 'daniyar', amount: kzt(30000));
      final nw = l.netWorth();
      expect(nw.money, kzt(130000));
      expect(nw.liabilities, kzt(30000));
      expect(nw.capital, kzt(100000));
      expect(l.report(periodFrom, periodTo).earned, 0, reason: 'заработанного нет');
      expect(l.report(periodFrom, periodTo).income, 0, reason: 'заём меняет деньги и долг, но не доход');
    });

    test('T08 дать долг 30 000: деньги 70 000, требование 30 000, капитал 100 000', () {
      final l = seed()
        ..lendOut(id: 'g', date: d1, account: 'kaspi', person: 'askhat', amount: kzt(30000));
      final nw = l.netWorth();
      expect(nw.money, kzt(70000));
      expect(nw.receivables, kzt(30000));
      expect(nw.capital, kzt(100000));
      expect(l.report(periodFrom, periodTo).expense, 0);
    });

    test('T09 возврат 10 000: деньги 80 000, требование 20 000, доход 0', () {
      final l = seed()
        ..lendOut(id: 'g', date: d1, account: 'kaspi', person: 'askhat', amount: kzt(30000))
        ..repaymentReceived(
            id: 'r', date: d2, account: 'kaspi', person: 'askhat', principal: kzt(10000));
      expect(l.balance('kaspi'), kzt(80000));
      expect(l.balance(receivableAccount('askhat')), kzt(20000));
      expect(l.report(periodFrom, periodTo).income, 0);
    });

    test('возврат сверх требования отклоняется', () {
      final l = seed()
        ..lendOut(id: 'g', date: d1, account: 'kaspi', person: 'askhat', amount: kzt(30000));
      expect(
        () => l.repaymentReceived(
            id: 'r', date: d2, account: 'kaspi', person: 'askhat', principal: kzt(30001)),
        throwsA(isA<LedgerException>()),
      );
    });
  });

  group('Кредиты и рассрочки', () {
    test('T10 платёж 52 000 = тело 40 000 + проценты 12 000', () {
      final l = seed()
        ..openingDebt(id: 'od', date: d0, debtId: 'loan', amount: kzt(200000));
      final before = l.netWorth().capital;
      l.loanPayment(
          id: 'p', date: d1, account: 'kaspi', debtId: 'loan', principal: kzt(40000), interest: kzt(12000));
      final nw = l.netWorth();
      expect(nw.money, kzt(48000));
      expect(nw.liabilities, kzt(160000));
      expect(l.report(periodFrom, periodTo).expense, kzt(12000));
      expect(before - nw.capital, kzt(12000));
    });

    test('T11 рассрочка 240 000 без взноса: расход 240 000, долг 240 000, деньги не меняются', () {
      final l = seed()
        ..creditPurchase(id: 'cp', date: d1, debtId: 'inst', splits: {'electronics': kzt(240000)});
      expect(l.report(periodFrom, periodTo).expense, kzt(240000));
      expect(l.balance(liabilityAccount('inst')), kzt(240000));
      expect(l.balance('kaspi'), kzt(100000));
      expect(l.report(periodFrom, periodTo).cashFlow, 0);
    });

    test('T12 платёж 20 000 по рассрочке: отток 20 000, долг 220 000, новый расход 0', () {
      final l = seed()
        ..creditPurchase(id: 'cp', date: d1, debtId: 'inst', splits: {'electronics': kzt(240000)});
      final expenseBefore = l.report(periodFrom, periodTo).expense;
      l.loanPayment(id: 'p', date: d2, account: 'kaspi', debtId: 'inst', principal: kzt(20000));
      expect(l.balance('kaspi'), kzt(80000));
      expect(l.balance(liabilityAccount('inst')), kzt(220000));
      expect(l.report(periodFrom, periodTo).expense, expenseBefore);
    });

    test('T19 возврат 120 000 по неоплаченной кредитной покупке: долг 120 000, деньги те же', () {
      final l = seed()
        ..creditPurchase(id: 'cp', date: d1, debtId: 'inst', splits: {'electronics': kzt(240000)})
        ..refund(id: 'rf', date: d2, category: 'electronics', amount: kzt(120000), reduceDebtId: 'inst');
      expect(l.balance(liabilityAccount('inst')), kzt(120000));
      expect(l.balance('kaspi'), kzt(100000));
      expect(l.report(periodFrom, periodTo).expense, kzt(120000));
    });

    test('T32 квартира 20 млн полностью в кредит: актив и долг +20 млн, расхода и дохода нет', () {
      final l = seed()
        ..assetPurchase(id: 'flat', date: d1, assetId: 'flat', amount: kzt(20000000), viaDebtId: 'mortgage');
      final nw = l.netWorth();
      expect(nw.otherAssets, kzt(20000000));
      expect(nw.liabilities, kzt(20000000));
      expect(nw.capital, kzt(100000));
      final r = l.report(periodFrom, periodTo);
      expect(r.expense, 0);
      expect(r.income, 0);
    });

    test('тело платежа больше остатка долга отклоняется', () {
      final l = seed()..openingDebt(id: 'od', date: d0, debtId: 'loan', amount: kzt(10000));
      expect(
        () => l.loanPayment(id: 'p', date: d1, account: 'kaspi', debtId: 'loan', principal: kzt(10001)),
        throwsA(isA<LedgerException>()),
      );
    });
  });

  group('Возвраты, бонусы, чеки', () {
    test('T13 покупка 10 000: деньги 8 000 + бонусы 2 000 → расход 8 000', () {
      final l = seed()..accrueBonus('kaspi-bonus', kzt(2500));
      l.expense(
        id: 'e',
        date: d1,
        account: 'kaspi',
        splits: {'food': kzt(8000)},
        bonusPoints: kzt(2000),
        bonusWallet: 'kaspi-bonus',
        meta: {'receiptTotal': kzt(10000)},
      );
      expect(l.balance('kaspi'), kzt(92000));
      expect(l.report(periodFrom, periodTo).expense, kzt(8000));
      expect(l.bonusWallets['kaspi-bonus'], kzt(500));
      expect(l.netWorth().assets, kzt(92000), reason: 'бонусы не входят в капитал');
    });

    test('T14 возврат 3 000 за прошлый месяц: деньги +3 000, расход текущего периода −3 000, доход 0', () {
      final l = seed()
        ..expense(id: 'e', date: DateTime(2026, 8, 15), account: 'kaspi', splits: {'clothes': kzt(12000)})
        ..refund(id: 'rf', date: d1, category: 'clothes', amount: kzt(3000), toAccount: 'kaspi');
      expect(l.balance('kaspi'), kzt(91000));
      final r = l.report(periodFrom, periodTo);
      expect(r.expense, -kzt(3000));
      expect(r.income, 0);
    });

    test('T24 чек 6 000 + 4 000 в двух категориях: общий расход 10 000', () {
      final l = seed()
        ..expense(id: 'e', date: d1, account: 'kaspi', splits: {'food': kzt(6000), 'household': kzt(4000)});
      expect(l.report(periodFrom, periodTo).expense, kzt(10000));
      expect(l.transactions.where((t) => t.type == EventType.expense).length, 1);
      final byCat = l.expenseByCategory(periodFrom, periodTo);
      expect(byCat[expenseAccount('food')], kzt(6000));
      expect(byCat[expenseAccount('household')], kzt(4000));
    });
  });

  group('Целостность журнала', () {
    test('T17 повтор команды с тем же ID: одна операция, одно изменение остатка', () {
      final l = seed();
      final first = l.expense(id: 'same', date: d1, account: 'kaspi', splits: {'food': kzt(1000)});
      final again = l.post(first);
      expect(again, isFalse);
      expect(l.transactions.length, 2);
      expect(l.balance('kaspi'), kzt(99000));
    });

    test('тот же ID с другим содержимым отклоняется', () {
      final l = seed()..expense(id: 'same', date: d1, account: 'kaspi', splits: {'food': kzt(1000)});
      expect(
        () => l.expense(id: 'same', date: d1, account: 'kaspi', splits: {'food': kzt(2000)}),
        throwsA(isA<LedgerException>()),
      );
    });

    test('T18 несбалансированный перевод не проводится ни одной стороной', () {
      final l = seed()..addMoneyAccount('halyk');
      final bad = Transaction(
        id: 'bad',
        date: d1,
        type: EventType.transfer,
        postings: [Posting('kaspi', -kzt(20000)), Posting('halyk', kzt(19000))],
      );
      expect(() => l.post(bad), throwsA(isA<LedgerException>()));
      expect(l.balance('kaspi'), kzt(100000));
      expect(l.balance('halyk'), 0);
    });

    test('отмена операции снимает эффект и сохраняет историю', () {
      final l = seed()..expense(id: 'e', date: d1, account: 'kaspi', splits: {'food': kzt(1000)});
      l.reverse('e', newId: 'e-rev');
      expect(l.balance('kaspi'), kzt(100000));
      expect(l.transactions.length, 3);
      expect(l.isReversed('e'), isTrue);
      expect(() => l.reverse('e', newId: 'e-rev2'), throwsA(isA<LedgerException>()));
    });

    test('F02: отмена начального остатка не создаёт фиктивный денежный поток', () {
      final l = seed(opening: 0)..openingBalance(id: 'open', date: d0, account: 'kaspi', amount: kzt(100000));
      l.reverse('open', newId: 'open-rev', date: d1);
      expect(l.balance('kaspi'), 0);
      // Ни сам ввод остатка, ни его отмена не должны попадать в cashFlow —
      // это не операционное движение денег, а исправление исходных данных.
      expect(l.report(periodFrom, periodTo).cashFlow, 0);
    });

    test('T31 агрегаты после правок совпадают с перестройкой по журналу', () {
      final l = seed();
      final agg = DailyTotals();
      agg.apply(l.byId('open')!);
      agg.apply(l.expense(id: 'e1', date: DateTime(2026, 8, 3), account: 'kaspi', splits: {'food': kzt(1200)}));
      agg.apply(l.income(id: 'i1', date: d1, account: 'kaspi', source: 'salary', amount: kzt(450000)));
      agg.apply(l.expense(id: 'e2', date: d1, account: 'kaspi', splits: {'cafe': kzt(1500)}));
      agg.apply(l.reverse('e1', newId: 'e1-rev'));
      agg.apply(l.expense(id: 'e1b', date: DateTime(2026, 8, 3), account: 'kaspi', splits: {'food': kzt(1300)}));
      expect(agg.sameAs(DailyTotals.rebuild(l)), isTrue);
      expect(agg.of(DateTime(2026, 8, 3), 'kaspi'), -kzt(1300));
    });
  });

  group('Валюта', () {
    test('T20 средневзвешенная стоимость и реализованный результат', () {
      final usd = FxPosition()
        ..buy(units: kzt(100), cost: kzt(50000))
        ..buy(units: kzt(100), cost: kzt(55000));
      expect(usd.averageCost, closeTo(kzt(525), 0.001));
      final sale = usd.sell(units: kzt(50), proceeds: kzt(28000));
      expect(sale.realized, kzt(1750));
      expect(usd.units, kzt(150));
      expect(usd.cost, kzt(78750));
    });

    test('T21 оценка остатка по 560: актив 84 000, переоценка 5 250', () {
      final usd = FxPosition()
        ..buy(units: kzt(100), cost: kzt(50000))
        ..buy(units: kzt(100), cost: kzt(55000))
        ..sell(units: kzt(50), proceeds: kzt(28000));
      expect(usd.valueAt(kzt(560)), kzt(84000));
      expect(usd.unrealizedAt(kzt(560)), kzt(5250));
    });

    test('перевод между валютными счетами переносит стоимость без результата', () {
      final a = FxPosition()..buy(units: kzt(100), cost: kzt(50000));
      final b = FxPosition();
      a.transferTo(b, kzt(40));
      expect(a.cost + b.cost, kzt(50000));
      expect(b.cost, kzt(20000));
    });

    test('перевод в другой валюте требует fxExchange', () {
      final l = seed()..addMoneyAccount('usd', currency: 'USD');
      expect(
        () => l.transfer(id: 't', date: d1, from: 'kaspi', to: 'usd', amount: kzt(1000)),
        throwsA(isA<LedgerException>()),
      );
    });
  });

  group('Формат сумм', () {
    test('целые суммы без дробной части', () {
      expect(formatMoney(kzt(1250000)), '1 250 000 ₸');
      expect(formatMoney(kzt(0)), '0 ₸');
      expect(formatMoney(kzt(999)), '999 ₸');
    });
    test('тиыны показываются, когда значимы', () {
      expect(formatMoney(123456), '1 234,56 ₸');
      expect(formatMoney(-kzt(50)), '−50 ₸');
    });
  });
}
