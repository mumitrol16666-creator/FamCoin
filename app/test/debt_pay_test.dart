/// Оплата банковского долга (аудит 08.10, N04 + CS03): основная кнопка
/// карточки засчитывает платёж в срок графика, вне графика — отдельное явное
/// действие; сумма срока одна для приложения и бота.
/// «Сегодня» заглушки — 28.09.2026, на счёте `cash` 100 000 ₸.
library;

import 'package:famcoin/state/app_state.dart';
import 'package:famcoin/state/models.dart';
import 'package:famcoin/ui/budget/debt_screens.dart';
import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audit_regression_test.dart' show FakeServer;
import 'layout_test.dart' show pumpApp;

/// Рассрочка «Телефон» 100 000 ₸, платёж 10 000 ₸ десятого числа с [start].
Future<void> phoneDebt(AppState s, {DateTime? start, int balance = 100000, int payment = 10000, String kind = 'installment', double rate = 0}) => s.sendBatch([
      {'type': 'upsertEntity', 'kind': 'debt', 'entityId': 'red', 'data': DebtInfo('red', 'Телефон', kind, rate).toJson()},
      {'type': 'openingDebt', 'id': 'od', 'date': '2026-09-01', 'debtId': 'red', 'amount': '${kzt(balance)}'},
      {'type': 'upsertEntity', 'kind': 'planned', 'entityId': 'pl', 'data': PlannedInfo('pl', 'Телефон', kzt(payment), 10, 'other', 'red', const {}, start: start ?? DateTime(2026, 9, 1)).toJson()},
    ]);

Future<FakeServer> card(WidgetTester tester, {DateTime? start}) async {
  final f = await pumpApp(tester, home: const BankDebtScreen(debtId: 'red'), size: const Size(390, 844));
  await phoneDebt(f.state, start: start);
  await tester.pumpAndSettle();
  return f;
}

Future<void> tapLast(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder.last);
  await tester.pump();
  await tester.tap(finder.last);
  await tester.pumpAndSettle();
}

void main() {
  group('N04: оплата с карточки кредита', () {
    testWidgets('«Оплатить» оплачивает текущий срок графика и закрывает его', (tester) async {
      final f = await card(tester);
      final s = f.state;
      await tapLast(tester, find.widgetWithText(FilledButton, 'Оплатить'));
      expect(find.textContaining('За срок 10 сентября'), findsOneWidget, reason: 'видно, какой срок оплачивается');
      await tapLast(tester, find.widgetWithText(FilledButton, 'Оплатить'));
      expect(s.planned.single.paid, {'2026-09'});
      expect(s.debtBalance('red'), kzt(90000));
      final pay = s.ledger.transactions.singleWhere((t) => t.type == EventType.loanPayment);
      expect([pay.meta['planned'], pay.meta['period']], ['pl', '2026-09']);
      expect(s.dueItems(DateTime(2026, 9, 30)), isEmpty);
    });

    testWidgets('несколько просроченных сроков: сначала выбор срока, оплачивается выбранный', (tester) async {
      final f = await card(tester, start: DateTime(2026, 7, 1));
      final s = f.state;
      expect(s.dueItems(DateTime(2026, 9, 30)).length, 3, reason: 'июль, август, сентябрь просрочены');
      await tapLast(tester, find.widgetWithText(FilledButton, 'Оплатить'));
      expect(find.text('Какой платёж оплачиваете?'), findsOneWidget);
      await tester.tap(find.textContaining('10 августа'));
      await tester.pump();
      await tapLast(tester, find.widgetWithText(FilledButton, 'Продолжить'));
      expect(find.textContaining('За срок 10 августа'), findsOneWidget);
      await tapLast(tester, find.widgetWithText(FilledButton, 'Оплатить'));
      expect(s.planned.single.paid, {'2026-08'});
      expect(s.dueItems(DateTime(2026, 9, 30)).map((d) => d.period), ['2026-07', '2026-09']);
    });

    testWidgets('«Платёж вне графика» явно назван, срок не закрывает и не становится расходом', (tester) async {
      final f = await card(tester);
      final s = f.state;
      final expense = s.monthReport.expense;
      await tapLast(tester, find.widgetWithText(TextButton, 'Платёж вне графика'));
      expect(find.text('Платёж вне графика: Телефон'), findsOneWidget);
      expect(find.text('Срок в календаре не закроется, долг просто уменьшится'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, '10000');
      await tester.pump();
      await tapLast(tester, find.widgetWithText(FilledButton, 'Оплатить'));
      expect(s.debtBalance('red'), kzt(90000));
      expect(s.planned.single.paid, isEmpty, reason: 'произвольная отметка не ставится');
      expect(s.dueItems(DateTime(2026, 9, 30)).single.period, '2026-09');
      expect(s.monthReport.expense, expense, reason: 'тело долга — не расход');
      expect(s.ledger.transactions.singleWhere((t) => t.type == EventType.loanPayment).meta['planned'], isNull);
    });
  });

  group('CS03: сумма срока по долгу', () {
    test('последний платёж рассрочки — остаток, а не обычный платёж', () async {
      final f = FakeServer();
      await f.init();
      await phoneDebt(f.state, balance: 10000, payment: 50000);
      expect(f.state.dueItems(DateTime(2026, 9, 30)).single.payAmount, kzt(10000));
    });

    test('кредит с процентами: остаток меньше платежа — к оплате остаток плюс проценты месяца', () async {
      final f = FakeServer();
      await f.init();
      await phoneDebt(f.state, balance: 10000, payment: 50000, kind: 'loan', rate: 24);
      // 10 000 × 24 % / 12 = 200 ₸ процентов за месяц.
      expect(f.state.dueItems(DateTime(2026, 9, 30)).single.payAmount, kzt(10200));
      // Обычный месяц: платёж меньше остатка — без изменений.
      final g = FakeServer();
      await g.init();
      await phoneDebt(g.state, balance: 100000, payment: 10000, kind: 'loan', rate: 24);
      expect(g.state.dueItems(DateTime(2026, 9, 30)).single.payAmount, kzt(10000));
    });
  });
}
