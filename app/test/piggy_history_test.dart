/// Покупка из копилки задним числом (аудит 08.10, N05): перевод из копилки не
/// уводит её в минус ни на одну дату, предпросмотр в форме равен проведённому.
/// «Сегодня» заглушки — 28.09.2026, на счёте `cash` 100 000 ₸.
library;

import 'package:famcoin/state/app_scope.dart';
import 'package:famcoin/state/models.dart';
import 'package:famcoin/ui/budget/sheets.dart';
import 'package:famcoin/ui/widgets/common.dart' show moneyInText;
import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audit_regression_test.dart' show FakeServer;
import 'ux_gaps_a_test.dart' show openForm, pumpWith;

/// Колёса 50 000 ₸ на сентябрь, в копилке 50 000 ₸ с 28 сентября.
Future<GoalInfo> savedForPurchase(FakeServer f) async {
  final s = f.state;
  await s.addPurchase(name: 'Колёса', amount: kzt(50000), month: DateTime(2026, 9, 1), category: 'transport');
  await s.startSavingFor(s.purchases.single);
  final goal = s.purchaseGoal(s.purchases.single)!;
  await s.depositToGoal(goal, from: 'cash', amount: kzt(50000));
  return goal;
}

void at(FakeServer f, DateTime day) {
  f.now = day;
  f.state.checkDayChange();
}

final sep30 = DateTime(2026, 9, 30);

Future<void> payOnSep30(FakeServer f) {
  final s = f.state;
  return s.payDue(DueItem(s.purchases.single, sep30, '2026-09'), account: 'cash', amount: kzt(50000), date: sep30);
}

/// Остаток копилки на каждый день с 28 сентября по сегодня.
List<int> piggyByDay(FakeServer f, String account) => [
      for (var d = DateTime(2026, 9, 28); !d.isAfter(f.state.today); d = DateTime(d.year, d.month, d.day + 1)) f.state.ledger.balance(account, asOf: d),
    ];

int fromPiggy(FakeServer f, String account) => f.state.userTransactions
    .where((t) => t.type == EventType.transfer && t.postings.any((x) => x.accountId == account && x.amount < 0) && t.date == sep30)
    .fold(0, (s, t) => s - t.amountOn(account));

void main() {
  group('N05: копилка задним числом', () {
    test('позднее снятие: из копилки берётся только то, что не уводит её в минус; остальное — со счёта', () async {
      final f = FakeServer();
      await f.init();
      final goal = await savedForPurchase(f);
      final s = f.state;
      at(f, DateTime(2026, 10, 2));
      await s.withdrawFromGoal(goal, to: 'cash', amount: kzt(30000));
      at(f, DateTime(2026, 10, 5));
      expect(s.piggyAvailableOn(goal, sep30), kzt(20000));
      await payOnSep30(f);
      expect(fromPiggy(f, goal.account!), kzt(20000));
      expect(piggyByDay(f, goal.account!).every((b) => b >= 0), isTrue, reason: '${piggyByDay(f, goal.account!)}');
      expect(s.ledger.balance(goal.account!, asOf: sep30), kzt(30000));
      expect(s.ledger.balance(goal.account!), 0);
      expect(s.goals, isEmpty, reason: 'всё, что было в копилке, ушло на покупку — она закрыта');
      expect(s.ledger.balance('cash'), kzt(50000), reason: '100 000 − покупка 50 000: счёт не завышен');
      expect(f.ledger.balance('cash'), kzt(50000));
    });

    test('позднее пополнение и большее снятие: доступное — наименьший остаток после даты покупки', () async {
      final f = FakeServer();
      await f.init();
      final goal = await savedForPurchase(f);
      final s = f.state;
      at(f, DateTime(2026, 10, 1));
      await s.depositToGoal(goal, from: 'cash', amount: kzt(10000));
      at(f, DateTime(2026, 10, 2));
      await s.withdrawFromGoal(goal, to: 'cash', amount: kzt(40000));
      at(f, DateTime(2026, 10, 5));
      await payOnSep30(f);
      expect(fromPiggy(f, goal.account!), kzt(20000));
      expect(piggyByDay(f, goal.account!).every((b) => b >= 0), isTrue, reason: '${piggyByDay(f, goal.account!)}');
      expect(s.ledger.balance(goal.account!), 0);
      expect(s.ledger.balance('cash') + s.ledger.balance(goal.account!), kzt(50000));
    });

    test('итог тот же, но посередине копилку опустошали: перевод не уходит в минус, остаток копилки сохранён', () async {
      final f = FakeServer();
      await f.init();
      final goal = await savedForPurchase(f);
      final s = f.state;
      at(f, DateTime(2026, 10, 1));
      await s.withdrawFromGoal(goal, to: 'cash', amount: kzt(30000));
      at(f, DateTime(2026, 10, 3));
      await s.depositToGoal(goal, from: 'cash', amount: kzt(30000));
      at(f, DateTime(2026, 10, 5));
      expect(s.ledger.balance(goal.account!, asOf: sep30), s.ledger.balance(goal.account!), reason: 'итоговая разница нулевая');
      await payOnSep30(f);
      expect(fromPiggy(f, goal.account!), kzt(20000), reason: 'на 1 октября в копилке оставалось 20 000');
      expect(piggyByDay(f, goal.account!).every((b) => b >= 0), isTrue, reason: '${piggyByDay(f, goal.account!)}');
      expect(s.ledger.balance(goal.account!), kzt(30000));
      expect(s.goals.map((g) => g.id), [goal.id], reason: 'в копилке остались деньги — она не закрыта молча');
      expect(s.ledger.balance('cash') + s.ledger.balance(goal.account!), kzt(50000));
    });

    testWidgets('форма оплаты на 30 сентября показывает ту же сумму из копилки и снятие, которое её урезало', (tester) async {
      late FakeServer server;
      final f = await pumpWith(tester, (c) {
        final s = AppScope.of(c).state;
        showPayDueSheet(c, DueItem(s.purchases.single, sep30, '2026-09'), date: sep30);
      });
      server = f;
      final goal = await savedForPurchase(server);
      at(server, DateTime(2026, 10, 2));
      await server.state.withdrawFromGoal(goal, to: 'cash', amount: kzt(30000));
      at(server, DateTime(2026, 10, 5));
      final available = server.state.piggyAvailableOn(goal, sep30);
      await openForm(tester);
      expect(find.textContaining('2 октября — ${moneyInText(kzt(30000))}'), findsOneWidget);
      expect(find.textContaining('Из копилки вернётся ${moneyInText(available)}'), findsOneWidget);
      final pay = find.widgetWithText(FilledButton, 'Оплатить');
      await tester.ensureVisible(pay);
      await tester.pump();
      await tester.tap(pay);
      await tester.pumpAndSettle();
      expect(fromPiggy(server, goal.account!), available, reason: 'проведено ровно то, что показано');
    });
  });
}
