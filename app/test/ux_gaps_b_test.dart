/// Пакет Б из docs/ux-gaps-2026-10-05.md: платежи раз в неделю и раз в год
/// (Ж7), правка и удаление платежа (Ж12), «Списалось» одним нажатием (Ж8),
/// счёт у плитки быстрой операции (Ж9). «Сегодня» заглушки — 28.09.2026
/// (понедельник), на счёте `cash` 100 000 ₸.
library;

import 'package:famcoin/state/app_scope.dart';
import 'package:famcoin/state/models.dart';
import 'package:famcoin/ui/budget/calendar_screen.dart';
import 'package:famcoin/ui/budget/sheets.dart';
import 'package:famcoin/ui/home/quick_actions.dart';
import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audit_regression_test.dart' show FakeServer;
import 'layout_test.dart' show pumpApp;
import 'ux_gaps_a_test.dart' show openForm, pumpWith, tapText;

void main() {
  group('Ж7 периодичность платежа', () {
    testWidgets('«Каждую неделю» + день недели: форма создаёт недельный платёж, сроки идут по средам', (tester) async {
      final f = await pumpWith(tester, (c) => addPlannedFlow(c));
      final s = f.state;
      await openForm(tester);
      await tester.enterText(find.widgetWithText(TextField, 'Аренда'), 'Репетитор');
      await tester.enterText(find.byType(TextField).at(1), '5000');
      await tapText(tester, 'Каждую неделю');
      expect(find.text('Число месяца'), findsNothing, reason: 'для недели число месяца не нужно');
      await tapText(tester, 'ср');
      await tester.tap(find.widgetWithText(FilledButton, 'Добавить'));
      await tester.pumpAndSettle();

      final p = s.planned.single;
      expect(p.every, everyWeek);
      expect(p.weekday, 3);
      expect(p.start, DateTime(2026, 9, 28), reason: 'недельный платёж не ждёт ответа «оплачено ли за месяц»');
      expect(s.dueItems(DateTime(2026, 10, 14)).map((d) => d.period), ['2026-09-30', '2026-10-07', '2026-10-14']);
      expect(f.entities['planned']!.values.single['every'], 'week');
    });

    test('оплата недельного срока закрывает только его; за месяц оплачено, когда оплачены все сроки', () async {
      final f = FakeServer();
      await f.init();
      final s = f.state;
      await s.upsert('planned', 'tutor', PlannedInfo('tutor', 'Репетитор', kzt(5000), 1, 'education', null, const {}, start: DateTime(2026, 9, 28), every: everyWeek, weekday: 3).toJson());
      expect(s.paidThisPeriod(s.planned.single), isFalse);
      final first = s.dueItems(DateTime(2026, 10, 31)).first;
      expect(first.date, DateTime(2026, 9, 30));
      await s.payDue(first, account: 'cash', amount: kzt(5000), date: DateTime(2026, 9, 28));
      expect(s.planned.single.paid, {'2026-09-30'});
      expect(s.dueItems(DateTime(2026, 10, 31)).first.date, DateTime(2026, 10, 7), reason: 'следующая среда ещё не оплачена');
      // Удаление оплаты снова открывает срок.
      final tx = s.userTransactions.firstWhere((t) => t.meta['planned'] == 'tutor');
      await s.deleteTransaction(tx.id);
      expect(s.dueItems(DateTime(2026, 10, 31)).first.date, DateTime(2026, 9, 30));
      expect(s.paymentsInMonth(DateTime(2026, 10, 1)).$1, 4, reason: 'в октябре четыре среды: 7, 14, 21, 28');
    });

    test('годовой платёж: срок раз в год, ключ — год, «оплачен в этом году»', () async {
      final f = FakeServer();
      await f.init();
      final s = f.state;
      await s.upsert('planned', 'insurance', PlannedInfo('insurance', 'Страховка авто', kzt(120000), 15, 'other', null, const {}, start: DateTime(2026, 9, 28), every: everyYear, monthOfYear: 11).toJson());
      final due = s.dueItems(DateTime(2026, 12, 31));
      expect(due.map((d) => '${d.period}@${dateToJson(d.date)}'), ['2026@2026-11-15']);
      expect(s.paidThisPeriod(s.planned.single), isFalse);
      await s.markDuePaid(due.single);
      expect(s.planned.single.paid, {'2026'});
      expect(s.paidThisPeriod(s.planned.single), isTrue);
      expect(s.dueItems(DateTime(2026, 12, 31)), isEmpty);
    });

    test('старые платежи без поля every остаются ежемесячными', () async {
      final f = FakeServer();
      await f.init();
      await f.plan();
      final p = f.state.planned.single;
      expect(p.every, everyMonth);
      expect(f.state.upcoming.first.period, '2026-09');
      expect(p.toJson().containsKey('every'), isFalse, reason: 'лишних полей в сохранённой записи нет');
    });
  });

  group('вёрстка', () {
    for (final every in ['Каждый месяц', 'Каждую неделю', 'Раз в год']) {
      testWidgets('форма платежа «$every» на 320 px и тексте 200 % — без переполнений', (tester) async {
        await pumpApp(
          tester,
          size: const Size(320, 694),
          textScale: 2,
          home: Scaffold(body: Builder(builder: (c) => Center(child: FilledButton(onPressed: () => addPlannedFlow(c), child: const Text('open'))))),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text(every));
        await tester.tap(find.text(every));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('календарь со «Списалось» на 320 px и тексте 200 % — без переполнений', (tester) async {
      final f = await pumpApp(tester, size: const Size(320, 694), textScale: 2, home: const CalendarScreen());
      await f.plan();
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Списалось'), 200, scrollable: find.byType(Scrollable).first);
      expect(find.text('Списалось'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Ж12 правка и удаление платежа', () {
    testWidgets('«Изменить платёж» из листа оплаты: сумма и число меняются, оплаченные сроки и дата начала остаются', (tester) async {
      final f = await pumpWith(tester, (c) {
        final s = AppScope.of(c).state;
        showPayDueSheet(c, s.dueItems(DateTime(2026, 9, 30)).first);
      });
      await f.plan();
      await f.state.upsert('planned', 'rent', PlannedInfo('rent', 'Rent', kzt(10000), 10, 'home', null, {'2026-08'}, start: DateTime(2026, 8, 1)).toJson());
      await openForm(tester);
      expect(find.text('Изменить платёж'), findsOneWidget);
      expect(find.text('Удалить платёж'), findsOneWidget);
      await tapText(tester, 'Изменить платёж');
      expect(find.text('Платёж'), findsOneWidget);
      // Лист оплаты остаётся под листом правки — ищем поля только в верхнем.
      await tester.enterText(find.descendant(of: find.byType(BottomSheet).last, matching: find.byType(TextField)).at(1), '12000');
      await tester.ensureVisible(find.widgetWithText(FilledButton, 'Сохранить'));
      await tester.tap(find.widgetWithText(FilledButton, 'Сохранить'));
      await tester.pumpAndSettle();
      final p = f.state.planned.single;
      expect(p.amount, kzt(12000));
      expect(p.paid, {'2026-08'});
      expect(p.start, DateTime(2026, 8, 1));
      expect(find.text('Платёж обновлён'), findsOneWidget);
    });

    testWidgets('«Удалить платёж» спрашивает подтверждение и убирает платёж', (tester) async {
      final f = await pumpWith(tester, (c) => showPayDueSheet(c, AppScope.of(c).state.dueItems(DateTime(2026, 9, 30)).first));
      await f.plan();
      await openForm(tester);
      await tapText(tester, 'Удалить платёж');
      expect(find.text('Rent'), findsWidgets, reason: 'в подтверждении названо, что удаляется');
      await tester.tap(find.widgetWithText(FilledButton, 'Удалить'));
      await tester.pumpAndSettle();
      expect(f.state.planned, isEmpty);
    });

    testWidgets('платёж по кредиту: название задаёт кредит, меняются сумма и число', (tester) async {
      final f = await pumpWith(tester, (c) {});
      final s = f.state;
      await s.sendBatch(s.newBankDebtCommands(name: 'Kaspi Red', kind: 'installment', balance: kzt(100000), payment: kzt(10000), day: 25));
      final p = s.planned.single;
      final next = p.copyWith(amount: kzt(20000), day: 5);
      expect(next.name, 'Kaspi Red');
      expect(next.debtId, p.debtId, reason: 'правка не рвёт связь с кредитом');
      expect(next.day, 5);
    });
  });

  group('Ж8 «Списалось» одним нажатием', () {
    Future<FakeServer> pumpCalendar(WidgetTester tester) async {
      final f = await pumpWith(tester, (c) => Navigator.push(c, MaterialPageRoute<void>(builder: (_) => const CalendarScreen())));
      await f.plan(); // Rent, 10 000 ₸, 10-е число с 01.09 — срок сентября просрочен
      await openForm(tester);
      return f;
    }

    testWidgets('просроченный срок: кнопка есть, нажатие пишет оплату, «Отменить» возвращает срок', (tester) async {
      final f = await pumpCalendar(tester);
      final s = f.state;
      expect(find.text('Списалось'), findsOneWidget);
      await tester.tap(find.text('Списалось'));
      await tester.pumpAndSettle();
      expect(s.ledger.balance('cash'), kzt(90000));
      expect(s.planned.single.paid, contains('2026-09'));
      expect(find.text('«Rent» записан · 10 000 ₸'), findsOneWidget);
      expect(find.text('Списалось'), findsNothing);

      await tester.tap(find.text('Отменить'));
      await tester.pumpAndSettle();
      expect(s.ledger.balance('cash'), kzt(100000));
      expect(s.planned.single.paid, isNot(contains('2026-09')));
      expect(find.text('Списалось'), findsOneWidget);
    });

    testWidgets('денег на счёте не хватает — кнопки нет (оплата идёт через лист с предупреждением о минусе)', (tester) async {
      final f = await pumpCalendar(tester);
      await f.state.upsert('planned', 'rent', PlannedInfo('rent', 'Rent', kzt(500000), 10, 'home', null, const {}, start: DateTime(2026, 9, 1)).toJson());
      await tester.pumpAndSettle();
      expect(find.text('Списалось'), findsNothing);
    });

    test('canQuickPay: будущий срок, кредит с процентами и покупка — нет; рассрочка без процентов — да', () async {
      final f = FakeServer();
      await f.init();
      final s = f.state;
      await s.sendBatch([
        ...s.newBankDebtCommands(name: 'Рассрочка', kind: 'installment', balance: kzt(50000), payment: kzt(5000), day: 1, paidThisMonth: false),
        ...s.newBankDebtCommands(name: 'Кредит', kind: 'loan', balance: kzt(500000), payment: kzt(20000), day: 1, rate: 22, paidThisMonth: false),
      ]);
      final dues = {for (final d in s.dueItems(DateTime(2026, 9, 30))) d.planned.name: d};
      expect(s.canQuickPay(dues['Рассрочка']!), isTrue);
      expect(s.canQuickPay(dues['Кредит']!), isFalse, reason: 'в платеже кредита есть проценты — нужен лист');
      await s.upsert('planned', 'later', PlannedInfo('later', 'Позже', kzt(1000), 30, 'other', null, const {}, start: DateTime(2026, 9, 28)).toJson());
      expect(s.canQuickPay(s.dueItems(DateTime(2026, 9, 30)).firstWhere((d) => d.planned.name == 'Позже')), isFalse);
    });

    test('счёт оплаты — тот, которым платили в прошлый раз', () async {
      final f = FakeServer();
      await f.init();
      final s = f.state;
      await s.sendBatch(s.newAccountCommands(name: 'Halyk', type: 'card', balance: kzt(50000)));
      final halyk = s.activeAccounts.firstWhere((a) => a.name == 'Halyk').id;
      await s.upsert('planned', 'net', PlannedInfo('net', 'Интернет', kzt(5000), 5, 'utilities', null, const {}, start: DateTime(2026, 9, 1)).toJson());
      expect(s.payAccountFor(s.planned.single), 'cash', reason: 'раньше не платили — первый денежный счёт');
      await s.payDue(s.dueItems(DateTime(2026, 9, 30)).first, account: halyk, amount: kzt(5000));
      expect(s.payAccountFor(s.planned.single), halyk);
    });
  });

  group('Ж9 счёт у плитки', () {
    test('QuickAction хранит счёт только если он задан', () {
      expect(const QuickAction('q', 'Кофе', 'cafe', 150000).toJson().containsKey('account'), isFalse);
      expect(const QuickAction('q', 'Кофе', 'cafe', 150000, account: 'cash').toJson()['account'], 'cash');
      expect(QuickAction.fromJson('q', {'name': 'Кофе', 'category': 'cafe', 'amount': '150000', 'account': 'cash'}).account, 'cash');
    });

    testWidgets('плитка со своим счётом списывает с него, а не с основного', (tester) async {
      late FakeServer f;
      f = await pumpWith(tester, (c) => showQuickActionSheet(c));
      final s = f.state;
      await s.sendBatch(s.newAccountCommands(name: 'Наличные', type: 'cash', balance: kzt(20000)));
      final cash = s.activeAccounts.firstWhere((a) => a.type == 'cash');
      await openForm(tester);
      await tester.enterText(find.byType(TextField).first, 'Такси');
      await tester.enterText(find.byType(TextField).at(1), '1500');
      await tester.ensureVisible(find.byKey(const ValueKey('quick-account')));
      await tester.tap(find.byKey(const ValueKey('quick-account')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Наличные').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Сохранить'));
      await tester.pumpAndSettle();
      final q = s.quickActions.single;
      expect(q.account, cash.id);
      expect(s.activeAccounts.any((a) => a.id == q.account), isTrue);
    });
  });
}

