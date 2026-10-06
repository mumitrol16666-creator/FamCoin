/// Технический аудит 05.10.2026: формы и связи (APP-01, APP-03…APP-07, R01…R04).
/// «Сегодня» заглушки — 28.09.2026, на счёте `cash` 100 000 ₸.
library;

import 'package:famcoin/state/api_client.dart' show ApiException;
import 'package:famcoin/state/app_scope.dart';
import 'package:famcoin/state/models.dart';
import 'package:famcoin/l10n/app_localizations_kk.dart';
import 'package:famcoin/l10n/app_localizations_ru.dart';
import 'package:famcoin/ui/budget/budget_screen.dart';
import 'package:famcoin/ui/budget/calendar_screen.dart';
import 'package:famcoin/ui/more/accounts_screen.dart';
import 'package:famcoin/ui/budget/sheets.dart';
import 'package:famcoin/ui/more/family_screen.dart';
import 'package:famcoin/ui/widgets/common.dart';
import 'package:famcoin/ui/ops/add_transaction_sheet.dart';
import 'package:famcoin/ui/ops/edit_transaction_sheet.dart';
import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audit_regression_test.dart' show FakeServer;
import 'layout_test.dart' show pumpApp;
import 'ux_gaps_a_test.dart' show openForm, pumpWith;

Future<void> tapButton(WidgetTester tester, String label) async {
  final button = find.widgetWithText(FilledButton, label);
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

void main() {
  group('APP-03 повтор формы после потерянного ответа не создаёт второй факт', () {
    testWidgets('оплата срока: принято сервером, ответ потерян, повтор — один расход', (tester) async {
      final f = await pumpWith(tester, (c) => showPayDueSheet(c, AppScope.of(c).state.dueItems(DateTime(2026, 9, 30)).first));
      await f.plan(); // Rent 10 000, срок 10 сентября просрочен
      await openForm(tester);
      f.dropNextResponse = true;
      await tapButton(tester, 'Оплатить');
      expect(f.ledger.balance('cash'), kzt(90000), reason: 'сервер принял платёж');
      expect(find.byType(FilledButton), findsWidgets, reason: 'форма осталась открытой с ошибкой сети');
      await tapButton(tester, 'Оплатить');
      expect(f.ledger.balance('cash'), kzt(90000), reason: 'повтор не списал второй раз');
      expect(f.ledger.transactions.where((t) => t.type == EventType.expense), hasLength(1));
      expect(f.state.ledger.balance('cash'), kzt(90000));
      expect(f.state.planned.single.paid, {'2026-09'});
    });

    testWidgets('F06 через настоящую форму дохода: повтор «Сохранить» после потерянного ответа даёт один доход', (tester) async {
      final f = await pumpWith(tester, (c) => showAddTransactionSheet(c));
      await openForm(tester);
      await tester.tap(find.text('Доход').first);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '888');
      await tester.pump();
      f.dropNextResponse = true;
      await tapButton(tester, 'Сохранить');
      expect(f.ledger.balance('cash'), kzt(100888));
      await tapButton(tester, 'Сохранить');
      expect(f.ledger.transactions.where((t) => t.type == EventType.income), hasLength(1));
      expect(f.state.ledger.balance('cash'), kzt(100888));
    });

    testWidgets('частичное погашение кредита', (tester) async {
      late String debtId;
      final f = await pumpWith(tester, (c) => showBankPaySheet(c, AppScope.of(c).state.bankDebt(debtId)!));
      final s = f.state;
      await s.sendBatch(s.newBankDebtCommands(name: 'Kaspi Red', kind: 'creditCard', balance: kzt(100000), payment: kzt(10000), day: 25));
      debtId = s.bankDebts.single.id;
      await openForm(tester);
      await tester.enterText(find.byType(TextField).first, '10000');
      f.dropNextResponse = true;
      await tapButton(tester, 'Оплатить');
      await tapButton(tester, 'Оплатить');
      expect(f.ledger.transactions.where((t) => t.type == EventType.loanPayment), hasLength(1));
      expect(f.ledger.balance(liabilityAccount(debtId)), kzt(90000));
      expect(s.debtBalance(debtId), kzt(90000));
      expect(s.ledger.balance('cash'), kzt(90000));
    });

    testWidgets('частичный возврат личного долга', (tester) async {
      final f = await pumpWith(tester, (c) => showPersonRepaySheet(c, AppScope.of(c).state.personDebts.single));
      final s = f.state;
      await s.addPersonDebt(kind: 'lendOut', amount: kzt(50000), person: 'Друг', account: 'cash', date: DateTime(2026, 9, 20));
      await openForm(tester);
      await tester.enterText(find.byType(TextField).first, '20000');
      f.dropNextResponse = true;
      await tapButton(tester, 'Сохранить');
      await tapButton(tester, 'Сохранить');
      expect(f.ledger.transactions.where((t) => t.type == EventType.repaymentReceived), hasLength(1));
      expect(f.ledger.balance(receivableAccount('Друг')), kzt(30000));
      expect(f.ledger.balance('cash'), kzt(70000));
      expect(s.ledger.balance('cash'), kzt(70000));
    });

    for (final withdraw in [false, true]) {
      testWidgets('копилка: ${withdraw ? 'забрать' : 'отложить'}', (tester) async {
        late GoalInfo goal;
        final f = await pumpWith(tester, (c) => showReserveSheet(c, AppScope.of(c).state.goals.firstWhere((g) => g.id == goal.id), release: withdraw));
        final s = f.state;
        await s.sendBatch(s.newGoalCommands(name: 'Отпуск', target: kzt(200000)));
        goal = s.goals.single;
        if (withdraw) await s.depositToGoal(goal, from: 'cash', amount: kzt(30000));
        await openForm(tester);
        await tester.enterText(find.byType(TextField).first, '10000');
        f.dropNextResponse = true;
        final label = withdraw ? 'Забрать' : 'Отложить';
        final button = find.byType(FilledButton).last;
        await tester.ensureVisible(button);
        await tester.tap(button);
        await tester.pumpAndSettle();
        await tester.tap(button);
        await tester.pumpAndSettle();
        final transfers = f.ledger.transactions.where((t) => t.type == EventType.transfer).length;
        expect(transfers, withdraw ? 2 : 1, reason: '$label: один перевод на попытку, без дубля');
        expect(f.ledger.balance(goal.account!), withdraw ? kzt(20000) : kzt(10000));
        expect(s.ledger.balance(goal.account!), f.ledger.balance(goal.account!));
      });
    }

    testWidgets('частичный возврат покупки', (tester) async {
      late Transaction purchase;
      final f = await pumpWith(tester, (c) => showRefundSheet(c, purchase));
      final s = f.state;
      await s.addExpense(amount: kzt(10000), category: 'clothes', account: 'cash', date: DateTime(2026, 9, 25));
      purchase = s.userTransactions.firstWhere((t) => t.type == EventType.expense);
      await openForm(tester);
      await tester.enterText(find.byType(TextField).first, '4000');
      f.dropNextResponse = true;
      final button = find.byType(FilledButton).last;
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(f.ledger.transactions.where((t) => t.type == EventType.refund), hasLength(1));
      expect(f.ledger.balance('cash'), kzt(94000));
      expect(s.ledger.balance('cash'), kzt(94000));
    });

    testWidgets('поля изменены после потерянного ответа: второй платёж не уходит, данные обновляются', (tester) async {
      final f = await pumpWith(tester, (c) => showPayDueSheet(c, AppScope.of(c).state.dueItems(DateTime(2026, 9, 30)).first));
      await f.plan();
      await openForm(tester);
      f.dropNextResponse = true;
      await tapButton(tester, 'Оплатить');
      expect(f.ledger.balance('cash'), kzt(90000));
      await tester.enterText(find.byType(TextField).first, '12000');
      await tapButton(tester, 'Оплатить');
      expect(f.ledger.balance('cash'), kzt(90000), reason: 'другая сумма под тем же ключом не отправляется');
      expect(f.ledger.transactions.where((t) => t.type == EventType.expense), hasLength(1));
      expect(find.textContaining('Прошлая попытка могла дойти'), findsOneWidget);
      expect(f.state.ledger.balance('cash'), kzt(90000), reason: 'состояние обновлено с сервера');
    });

    testWidgets('после отказа сервера (не обрыва) повтор получает новые идентификаторы и может уйти другим', (tester) async {
      final f = await pumpWith(tester, (c) => showPersonRepaySheet(c, AppScope.of(c).state.personDebts.single));
      final s = f.state;
      await s.addPersonDebt(kind: 'lendOut', amount: kzt(50000), person: 'Друг', account: 'cash', date: DateTime(2026, 9, 20));
      await openForm(tester);
      await tester.enterText(find.byType(TextField).first, '90000'); // больше долга: сервер откажет
      await tapButton(tester, 'Сохранить');
      expect(f.ledger.balance(receivableAccount('Друг')), kzt(50000));
      await tester.enterText(find.byType(TextField).first, '20000');
      await tapButton(tester, 'Сохранить');
      expect(f.ledger.balance(receivableAccount('Друг')), kzt(30000));
    });
  });

  group('APP-01 нагрузка платежей учитывает периодичность', () {
    Future<FakeServer> withTutorAndInsurance() async {
      final f = FakeServer();
      await f.init();
      final s = f.state;
      await s.upsert('planned', 'tutor', PlannedInfo('tutor', 'Репетитор', kzt(5000), 1, 'education', null, const {}, start: DateTime(2026, 1, 1), every: everyWeek, weekday: 3).toJson());
      await s.upsert('planned', 'ins', PlannedInfo('ins', 'Страховка', kzt(120000), 15, 'other', null, const {}, start: DateTime(2026, 1, 1), every: everyYear, monthOfYear: 11).toJson());
      return f;
    }

    test('конкретный месяц: четыре или пять сред; годовой платёж только в своём месяце', () async {
      final s = (await withTutorAndInsurance()).state;
      expect(s.scheduledForMonth(DateTime(2026, 10, 1)), kzt(20000), reason: 'сред 7, 14, 21, 28; страховки в октябре нет');
      expect(s.scheduledForMonth(DateTime(2026, 7, 1)), kzt(25000), reason: 'пять сред: 1, 8, 15, 22, 29');
      expect(s.scheduledForMonth(DateTime(2026, 11, 1)), kzt(140000), reason: 'четыре среды и страховка');
    });

    test('средняя месячная нагрузка: неделя × 52/12, год / 12, а не простая сумма', () async {
      final s = (await withTutorAndInsurance()).state;
      expect(s.averageMonthlyCommitment, 2166667 + kzt(10000), reason: '5 000 × 52 / 12 ≈ 21 666,67 и 120 000 / 12');
      expect(s.recurringMonthly, s.averageMonthlyCommitment);
      expect(s.averageMonthlyCommitment, isNot(kzt(125000)), reason: 'раньше складывалось 5 000 + 120 000');
    });
  });

  group('APP-05/APP-06 расходы по людям', () {
    testWidgets('APP-05: «Семья» показывает чистые 6 000 после возврата 4 000, как аналитика', (tester) async {
      final f = await pumpApp(tester, home: const FamilyScreen(), size: const Size(390, 844));
      final s = f.state;
      await s.setFamilyMode(true);
      await s.addExpense(amount: kzt(10000), category: 'clothes', account: 'cash', date: DateTime(2026, 9, 20), who: 'shared');
      final purchase = s.userTransactions.firstWhere((t) => t.type == EventType.expense);
      await s.refund(purchase, category: 'clothes', amount: kzt(4000), account: 'cash', date: DateTime(2026, 9, 22));
      await tester.pumpAndSettle();
      expect(s.expenseByWho(s.monthStart)['shared'], kzt(6000));
      final shared = tester.widget<ListTile>(find.widgetWithText(ListTile, 'Общее'));
      expect((shared.trailing as MoneyText).minor, kzt(6000), reason: 'экран семьи не пересчитывает расходы сам');
    });

    test('APP-06: сумма по людям равна расходу периода для expense, refund, creditPurchase, процентов и списания', () async {
      final f = FakeServer();
      await f.init();
      final s = f.state;
      await s.setFamilyMode(true);
      await s.addExpense(amount: kzt(10000), category: 'food', account: 'cash', date: DateTime(2026, 9, 20), who: 'me');
      final food = s.userTransactions.firstWhere((t) => t.type == EventType.expense);
      await s.refund(food, category: 'food', amount: kzt(1000), account: 'cash', date: DateTime(2026, 9, 21));
      await s.sendBatch(s.installmentPurchaseCommands(name: 'Телефон', amount: kzt(120000), category: 'other', months: 12, day: 25, date: DateTime(2026, 9, 22), who: 'shared'));
      final debtId = s.bankDebts.first.id;
      await s.sendBatch(s.newBankDebtCommands(name: 'Кредит', kind: 'loan', balance: kzt(200000), payment: kzt(20000), day: 5, rate: 20));
      final loan = s.bankDebts.firstWhere((d) => d.name == 'Кредит');
      await s.payDebt(debtId: loan.id, account: 'cash', principal: kzt(18000), interest: kzt(2000), date: DateTime(2026, 9, 23));
      await s.addPersonDebt(kind: 'lendOut', amount: kzt(50000), person: 'Друг', account: 'cash', date: DateTime(2026, 9, 10));
      await s.writeOffDebt(s.personDebts.single);
      expect(debtId, isNotEmpty);
      final month = DateTime(2026, 9, 1);
      final byWho = s.expenseByWho(month);
      expect(byWho.values.fold(0, (a, b) => a + b), s.reportFor(month).expense, reason: 'раздел по людям не теряет события');
      expect(byWho['shared'], kzt(120000), reason: 'покупка в рассрочку попала в «Общее»');
      expect(byWho['me'], isNotNull);
    });
  });

  group('APP-07 покупка из копилки задним числом', () {
    Future<(FakeServer, GoalInfo)> savedForPurchase() async {
      final f = FakeServer(); // сегодня 28.09.2026, на счёте 100 000
      await f.init();
      final s = f.state;
      await s.addPurchase(name: 'Колёса', amount: kzt(50000), month: DateTime(2026, 9, 1), category: 'transport');
      await s.startSavingFor(s.purchases.single);
      final goal = s.purchaseGoal(s.purchases.single)!;
      await s.depositToGoal(goal, from: 'cash', amount: kzt(50000));
      return (f, goal);
    }

    test('оплата 30 сентября, внесена 5 октября: перевод и расход одной датой, остатки на 30 сентября верны', () async {
      final (f, goal) = await savedForPurchase();
      final s = f.state;
      f.now = DateTime(2026, 10, 5);
      final p = s.purchases.single;
      await s.payDue(DueItem(p, DateTime(2026, 9, 30), '2026-09'), account: 'cash', amount: kzt(50000), date: DateTime(2026, 9, 30));
      final sep30 = DateTime(2026, 9, 30);
      expect(s.ledger.balance('cash', asOf: sep30), kzt(50000), reason: 'покупка оплачена накоплениями: деньги на счёте остались');
      expect(s.ledger.balance(goal.account!, asOf: sep30), 0, reason: 'копилка пуста на 30 сентября');
      final back = s.userTransactions.firstWhere((t) => t.type == EventType.transfer && t.postings.any((x) => x.accountId == goal.account && x.amount < 0));
      final buy = s.userTransactions.firstWhere((t) => t.type == EventType.expense);
      expect(back.date, sep30);
      expect(buy.date, sep30);
      expect(s.goals, isEmpty);
      expect(f.ledger.balance('cash'), kzt(50000), reason: 'сервер видит то же');
    });

    test('после даты оплаты в копилку добавили ещё: поздние деньги не переносятся назад и не теряются', () async {
      final (f, goal) = await savedForPurchase();
      final s = f.state;
      f.now = DateTime(2026, 10, 2);
      await s.depositToGoal(goal, from: 'cash', amount: kzt(10000)); // 2 октября
      f.now = DateTime(2026, 10, 5);
      final p = s.purchases.single;
      await s.payDue(DueItem(p, DateTime(2026, 9, 30), '2026-09'), account: 'cash', amount: kzt(50000), date: DateTime(2026, 9, 30));
      final sep30 = DateTime(2026, 9, 30);
      expect(s.ledger.balance(goal.account!, asOf: sep30), 0, reason: 'на 30 сентября накопленное 50 000 использовано');
      expect(s.ledger.balance(goal.account!), kzt(10000), reason: 'позднее пополнение осталось в копилке');
      expect(s.ledger.balance('cash', asOf: sep30), kzt(50000));
      expect(s.goals.map((g) => g.id), [goal.id], reason: 'копилка не закрыта автоматически');
      expect(s.ledger.account(goal.account!).archived, isFalse);
      expect(s.ledger.balance('cash') + s.ledger.balance(goal.account!), kzt(50000), reason: '100 000 минус покупка 50 000: деньги не потеряны и не удвоены');
    });
  });

  group('R02–R04 расписание, сверка, закрытые долги', () {
    test('R02: сверка сентября 1 декабря видит все четыре неоплаченных занятия, счётчик и список согласованы', () async {
      final f = FakeServer();
      await f.init();
      final s = f.state;
      f.now = DateTime(2026, 12, 1);
      await s.upsert('planned', 'tutor', PlannedInfo('tutor', 'Занятия', kzt(5000), 1, 'education', null, const {}, start: DateTime(2026, 9, 1), every: everyWeek, weekday: 1).toJson());
      final sep = DateTime(2026, 9, 1);
      final list = s.unpaidOccurrences(sep, DateTime(2026, 9, 30));
      expect(list.map((d) => d.period), ['2026-09-07', '2026-09-14', '2026-09-21', '2026-09-28']);
      expect(list.fold(0, (a, d) => a + d.planned.amount), kzt(20000));
      final summary = s.monthSummary(sep);
      expect((summary.paymentsPaid, summary.paymentsTotal), (0, list.length), reason: 'счётчик и список — один месяц');
      // Годовой и месячный платежи: прошлый месяц тоже без обрезки по сегодняшней дате.
      await s.upsert('planned', 'rent', PlannedInfo('rent', 'Аренда', kzt(10000), 10, 'home', null, const {}, start: DateTime(2026, 9, 1)).toJson());
      await s.upsert('planned', 'ins', PlannedInfo('ins', 'Страховка', kzt(120000), 20, 'other', null, const {}, start: DateTime(2025, 1, 1), every: everyYear, monthOfYear: 9).toJson());
      final all = s.unpaidOccurrences(sep, DateTime(2026, 9, 30)).map((d) => d.planned.id).toSet();
      expect(all, {'tutor', 'rent', 'ins'});
      expect(s.paymentsInMonth(sep).$1, s.unpaidOccurrences(sep, DateTime(2026, 9, 30)).length);
    });

    test('R03: смена дня занятий с понедельника на вторник не создаёт просрочек в оплаченном сентябре, старую оплату можно отменить', () async {
      final f = FakeServer();
      await f.init();
      final s = f.state;
      await s.upsert('planned', 'tutor', PlannedInfo('tutor', 'Занятия', kzt(5000), 1, 'education', null, const {}, start: DateTime(2026, 9, 1), every: everyWeek, weekday: 1).toJson());
      f.now = DateTime(2026, 9, 28);
      for (final d in s.dueItems(DateTime(2026, 9, 28)).where((d) => d.date.isBefore(DateTime(2026, 9, 29))).toList()) {
        await s.payDue(d, account: 'cash', amount: kzt(5000), date: d.date);
      }
      expect(s.planned.single.paid, {'2026-09-07', '2026-09-14', '2026-09-21', '2026-09-28'});
      expect(s.unpaidOccurrences(DateTime(2026, 9, 1), DateTime(2026, 9, 28)), isEmpty);

      // Форма «Изменить платёж»: те же вызовы, что у editPlannedFlow.
      final p = s.planned.single;
      await s.upsert(p.entityKind, p.id, p.copyWith(every: everyWeek, weekday: 2, effectiveFrom: s.today).toJson());
      final changed = s.planned.single;
      expect(changed.weekday, 2);
      expect(changed.paid, p.paid, reason: 'отметки сохранены');
      expect(s.unpaidOccurrences(DateTime(2026, 9, 1), DateTime(2026, 9, 28)), isEmpty, reason: 'в оплаченном прошлом новых просрочек нет');
      expect(s.dueItems(DateTime(2026, 10, 13)).map((d) => d.period), ['2026-09-29', '2026-10-06', '2026-10-13']);
      expect(f.entities['planned']!['tutor']!.containsKey('prev'), isTrue, reason: 'прежнее расписание сохранено на сервере');

      // Удаление старой оплаты снова открывает именно тот понедельник.
      final old = s.userTransactions.firstWhere((t) => t.meta['period'] == '2026-09-14');
      await s.deleteTransaction(old.id);
      expect(s.unpaidOccurrences(DateTime(2026, 9, 1), DateTime(2026, 9, 28)).map((d) => d.period), ['2026-09-14']);
    });

    test('R03: месяц → неделя: оплаченные месячные сроки остаются оплаченными', () async {
      final f = FakeServer();
      await f.init();
      final s = f.state;
      await s.upsert('planned', 'a', PlannedInfo('a', 'Услуга', kzt(5000), 10, 'other', null, {'2026-08', '2026-09'}, start: DateTime(2026, 8, 1)).toJson());
      final p = s.planned.single;
      await s.upsert('planned', 'a', p.copyWith(every: everyWeek, weekday: 3, effectiveFrom: s.today).toJson());
      expect(s.unpaidOccurrences(DateTime(2026, 8, 1), DateTime(2026, 9, 27)), isEmpty);
      expect(s.dueItems(DateTime(2026, 10, 7)).map((d) => d.period), ['2026-09-30', '2026-10-07']);
    });

    testWidgets('R04: погашенная рассрочка не требует оплаты в календаре и в предстоящих, оплаченная история остаётся', (tester) async {
      final f = await pumpApp(tester, home: const CalendarScreen(), size: const Size(390, 844));
      final s = f.state;
      await s.sendBatch(s.newBankDebtCommands(name: 'Рассрочка', kind: 'installment', balance: kzt(50000), payment: kzt(10000), day: 5, paidThisMonth: false));
      // Сентябрьский срок оплачен платежом, затем остаток закрыт полностью.
      final sep = s.dueItems(DateTime(2026, 9, 30)).single;
      await s.payDue(sep, account: 'cash', amount: kzt(10000), date: DateTime(2026, 9, 5));
      await s.payDebt(debtId: s.bankDebts.single.id, account: 'cash', principal: kzt(40000), date: DateTime(2026, 9, 20));
      expect(s.debtBalance(s.bankDebts.single.id), 0);
      f.now = DateTime(2026, 10, 5);
      s.checkDayChange();
      await tester.pumpAndSettle();
      expect(s.dueItems(DateTime(2026, 10, 31)), isEmpty, reason: 'список предстоящих');
      // Календарь открыт на октябре (сегодня 5 октября): ни строки «к оплате», ни «Списалось».
      expect(find.text('Списалось', skipOffstage: false), findsNothing);
      expect(find.text('Рассрочка', skipOffstage: false), findsNothing);
      // Прошлое сохранено: в сентябре оплаченный срок виден.
      await tester.tap(find.byTooltip('Предыдущий месяц'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Рассрочка'), 200, scrollable: find.byType(Scrollable).first);
      expect(find.text('Рассрочка'), findsOneWidget);
    });
  });

  group('R01 два устройства', () {
    Future<(FakeServer, dynamic, dynamic)> twoDevices() async {
      final f = FakeServer();
      await f.init();
      await f.state.upsert('planned', 'rent', PlannedInfo('rent', 'Аренда', kzt(10000), 10, 'home', null, const {}, start: DateTime(2026, 9, 1)).toJson());
      final b = f.newClient();
      await b.load();
      return (f, f.state, b);
    }

    test('разные сроки: оба платежа записаны, отметки обоих сохранены', () async {
      final (f, a, b) = await twoDevices();
      final sept = a.dueItems(DateTime(2026, 10, 31)).firstWhere((d) => d.period == '2026-09');
      final oct = b.dueItems(DateTime(2026, 10, 31)).firstWhere((d) => d.period == '2026-10');
      await a.payDue(sept, account: 'cash', amount: kzt(10000));
      await b.payDue(oct, account: 'cash', amount: kzt(10000)); // b ещё не знает о первой оплате
      expect(f.ledger.balance('cash'), kzt(80000));
      expect(f.entities['planned']!['rent']!['paid'], ['2026-09', '2026-10'], reason: 'сервер сложил отметки, а не заменил одну другой');
      await b.refresh();
      expect(b.planned.single.paid, {'2026-09', '2026-10'});
      expect(b.dueItems(DateTime(2026, 10, 31)).where((d) => d.period == '2026-09'), isEmpty, reason: 'сентябрь не вернулся в неоплаченные');
    });

    test('один и тот же срок с двух устройств: вторая оплата отклонена, деньги списаны один раз', () async {
      final (f, a, b) = await twoDevices();
      final dueA = a.dueItems(DateTime(2026, 10, 31)).firstWhere((d) => d.period == '2026-09');
      final dueB = b.dueItems(DateTime(2026, 10, 31)).firstWhere((d) => d.period == '2026-09');
      await a.payDue(dueA, account: 'cash', amount: kzt(10000));
      await expectLater(
        b.payDue(dueB, account: 'cash', amount: kzt(10000)),
        throwsA(isA<ApiException>().having((e) => e.ledgerCode, 'code', 'occurrencePaid')),
      );
      expect(f.ledger.balance('cash'), kzt(90000));
      expect(f.ledger.transactions.where((t) => t.type == EventType.expense), hasLength(1));
    });

    test('снятие отметки при удалении оплаты не затирает чужую отметку', () async {
      final (f, a, b) = await twoDevices();
      await a.payDue(a.dueItems(DateTime(2026, 10, 31)).firstWhere((d) => d.period == '2026-09'), account: 'cash', amount: kzt(10000));
      final tx = a.userTransactions.firstWhere((t) => t.meta['period'] == '2026-09');
      await b.payDue(b.dueItems(DateTime(2026, 10, 31)).firstWhere((d) => d.period == '2026-10'), account: 'cash', amount: kzt(10000));
      await a.deleteTransaction(tx.id); // a ещё не знает об октябре
      expect(f.entities['planned']!['rent']!['paid'], ['2026-10']);
    });
  });

  group('C03/C08 в приложении', () {
    test('C03: удаление долга после погашения отклонено, журнал и остатки прежние, текст понятный', () async {
      final f = FakeServer();
      await f.init();
      final s = f.state;
      await s.addPersonDebt(kind: 'borrow', amount: kzt(50000), person: 'Друг', account: 'cash', date: DateTime(2026, 9, 20));
      await s.addPersonDebt(kind: 'repaymentMade', amount: kzt(50000), person: 'Друг', account: 'cash', date: DateTime(2026, 9, 21));
      final borrow = s.userTransactions.firstWhere((t) => t.type == EventType.borrow);
      final before = s.ledger.transactions.length;
      await expectLater(
        s.deleteTransaction(borrow.id),
        throwsA(isA<ApiException>().having((e) => e.ledgerCode, 'code', 'reverseBreaksDebt')),
      );
      expect(s.ledger.transactions.length, before);
      expect(s.personDebts, isEmpty, reason: 'долг не стал отрицательным');
      expect(ledgerErrorText(AppLocalizationsRu(), 'reverseBreaksDebt'), contains('удалите погашения'));
      expect(ledgerErrorText(AppLocalizationsKk(), 'reverseBreaksDebt'), isNotNull);
      // Сначала погашение, потом сам долг.
      await s.deleteTransaction(s.userTransactions.firstWhere((t) => t.type == EventType.repaymentMade).id);
      await s.deleteTransaction(borrow.id);
      expect(s.personDebts, isEmpty);
      expect(s.ledger.balance('cash'), kzt(100000));
    });

    testWidgets('C08: архивный счёт возвращается из архива кнопкой, остаток и история целы', (tester) async {
      final f = await pumpApp(tester, home: const AccountScreen(accountId: 'cash'), size: const Size(390, 844));
      final s = f.state;
      await s.send({'type': 'archiveAccount', 'accountId': 'cash'});
      await tester.pumpAndSettle();
      expect(s.accountInfo('cash')!.archived, isTrue);
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Вернуть из архива'));
      await tester.pumpAndSettle();
      expect(s.accountInfo('cash')!.archived, isFalse);
      expect(s.ledger.balance('cash'), kzt(100000));
      expect(f.ledger.account('cash').archived, isFalse, reason: 'и на сервере');
    });

    testWidgets('C08: в обычной версии при другом активном счёте возврат из архива ведёт к лимиту тарифа', (tester) async {
      final f = await pumpApp(tester, home: const AccountScreen(accountId: 'cash'), size: const Size(390, 844));
      final s = f.state;
      await s.send({'type': 'archiveAccount', 'accountId': 'cash'});
      await s.sendBatch(s.newAccountCommands(name: 'Halyk', type: 'card', balance: kzt(1000)));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Вернуть из архива'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Pro'), findsWidgets);
      expect(s.accountInfo('cash')!.archived, isTrue, reason: 'второй активный счёт не открывается обходом');
    });
  });

  group('перевод из копилки', () {
    testWidgets('кнопка «Перевести отсюда» на экране копилки открывает перевод с неё на обычный счёт', (tester) async {
      late String piggy;
      final f = await pumpWith(tester, (c) => Navigator.push(c, MaterialPageRoute<void>(builder: (_) => AccountScreen(accountId: piggy))));
      final s = f.state;
      await s.sendBatch(s.newGoalCommands(name: 'Отпуск', target: kzt(200000)));
      piggy = s.goals.single.account!;
      await s.depositToGoal(s.goals.single, from: 'cash', amount: kzt(30000));
      await openForm(tester);
      await tester.tap(find.text('Перевести отсюда'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Перевод между своими счетами', skipOffstage: false), findsOneWidget, reason: 'открыта вкладка «Перевод»');
      await tester.enterText(find.byType(TextField).first, '10000');
      await tester.pump();
      await tester.ensureVisible(find.widgetWithText(FilledButton, 'Сохранить'));
      await tester.tap(find.widgetWithText(FilledButton, 'Сохранить'));
      await tester.pumpAndSettle();
      expect(s.ledger.balance(piggy), kzt(20000), reason: 'из копилки ушло 10 000');
      expect(s.ledger.balance('cash'), kzt(100000) - kzt(30000) + kzt(10000));
      expect(s.monthReport.expense, 0, reason: 'перевод — не расход');
    });
  });

  group('«Долги» → «Добавить»', () {
    testWidgets('предлагает выбор: взял в долг, дал в долг, кредит; «Я взял в долг» открывает вкладку «Долг» с этим видом', (tester) async {
      final f = await pumpApp(tester, home: const BudgetScreen(), size: const Size(390, 844));
      await tester.pumpAndSettle();
      // «Добавить» в заголовке раздела «Долги».
      await tester.scrollUntilVisible(find.text('Долги'), 300, scrollable: find.byType(Scrollable).first);
      final header = find.ancestor(of: find.text('Долги'), matching: find.byType(Row)).first;
      await tester.tap(find.descendant(of: header, matching: find.text('Добавить')));
      await tester.pumpAndSettle();
      expect(find.text('Что добавить?'), findsOneWidget);
      expect(find.text('Я взял в долг'), findsOneWidget);
      expect(find.text('Я дал в долг'), findsOneWidget);
      expect(find.text('Кредит, рассрочка или кредитная карта'), findsOneWidget);
      await tester.tap(find.text('Я взял в долг'));
      await tester.pumpAndSettle();
      expect(find.text('Записать операцию'), findsOneWidget);
      // Форма открыта на «Долг», выбрано «Взял в долг»: ⓘ называет именно этот случай.
      final chip = tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Взял в долг'));
      expect(chip.selected, isTrue);
      expect(f.state.personDebts, isEmpty);
    });

    testWidgets('пункт «Кредит…» открывает прежнюю форму кредита', (tester) async {
      await pumpApp(tester, home: const BudgetScreen(), size: const Size(390, 844));
      await tester.pumpAndSettle();
      // «Добавить» в заголовке раздела «Долги».
      await tester.scrollUntilVisible(find.text('Долги'), 300, scrollable: find.byType(Scrollable).first);
      final header = find.ancestor(of: find.text('Долги'), matching: find.byType(Row)).first;
      await tester.tap(find.descendant(of: header, matching: find.text('Добавить')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Кредит, рассрочка или кредитная карта'));
      await tester.pumpAndSettle();
      expect(find.text('Добавить кредит'), findsWidgets);
    });
  });

  group('D133 срок возврата личного долга', () {
    testWidgets('«＋» → Долг → Взял в долг → «Через неделю»: долг со сроком попадает в ближайшие платежи', (tester) async {
      final f = await pumpWith(tester, (c) => showAddTransactionSheet(c, kind: FieldsKind.debt, debtKind: 'borrow'));
      final s = f.state;
      await openForm(tester);
      await tester.enterText(find.byType(TextField).first, '80000');
      await tester.enterText(find.widgetWithText(TextField, 'Имя'), 'Теща');
      await tester.pump();
      await tester.dragUntilVisible(find.text('Через неделю'), find.byType(ListView).last, const Offset(0, -200));
      // Список строится лениво: до чипа докручиваем в несколько шагов.
      for (var i = 0; i < 3; i++) {
        await tester.ensureVisible(find.text('Через неделю'));
        await tester.pump();
      }
      expect(find.text('Когда вернуть'), findsOneWidget);
      await tester.tap(find.text('Через неделю'));
      await tester.pump();
      await tester.ensureVisible(find.widgetWithText(FilledButton, 'Сохранить'));
      await tester.tap(find.widgetWithText(FilledButton, 'Сохранить'));
      await tester.pumpAndSettle();
      final plan = s.personDuePlan('Теща')!;
      expect(plan.onDate, DateTime(2026, 10, 5), reason: '28 сентября + 7 дней');
      final due = s.dueItems(DateTime(2026, 10, 31)).single;
      expect(due.payAmount, kzt(80000));
      expect(due.planned.isPersonDue, isTrue);
      expect(f.entities['planned']!.values.single['person'], 'Теща', reason: 'сервер получил срок');
      // Срок — 5 октября: в сентябрьском прогнозе его нет, а в октябрьском — есть.
      expect(s.monthEndForecast.remainingObligations, 0);
      f.now = DateTime(2026, 10, 3);
      s.checkDayChange();
      expect(s.monthEndForecast.remainingObligations, kzt(80000), reason: 'прогноз видит возврат долга');
      // Постоянные платежи его не содержат.
      expect(s.recurringMonthly, 0);
      expect(s.activePlanned, isEmpty);
    });

    test('без срока обязательства нет; новый долг без срока снимает устаревший прошедший срок', () async {
      final f = FakeServer();
      await f.init();
      final s = f.state;
      await s.addPersonDebt(kind: 'borrow', amount: kzt(20000), person: 'Друг', account: 'cash', date: s.today);
      expect(s.personDuePlan('Друг'), isNull);
      expect(s.dueItems(DateTime(2026, 12, 31)), isEmpty);
      // Срок в прошлом, долг ещё есть; новый заём без срока снимает его.
      await s.addPersonDebt(kind: 'borrow', amount: kzt(10000), person: 'Друг', account: 'cash', date: s.today, dueDate: DateTime(2026, 9, 30));
      expect(s.personDuePlan('Друг')!.amount, kzt(30000), reason: 'сумма срока — весь остаток долга');
      f.now = DateTime(2026, 10, 15);
      await s.addPersonDebt(kind: 'borrow', amount: kzt(5000), person: 'Друг', account: 'cash', date: s.today);
      expect(s.personDuePlan('Друг'), isNull, reason: 'прошедший срок снят, просрочка по старому договору не висит');
    });

    test('частичный возврат уменьшает сумму срока; оплата срока — возврат долга и закрывает срок; полный возврат гасит срок', () async {
      final f = FakeServer();
      await f.init();
      final s = f.state;
      await s.addPersonDebt(kind: 'borrow', amount: kzt(80000), person: 'Теща', account: 'cash', date: s.today, dueDate: DateTime(2026, 10, 20));
      await s.addPersonDebt(kind: 'repaymentMade', amount: kzt(30000), person: 'Теща', account: 'cash', date: s.today);
      expect(s.dueItems(DateTime(2026, 10, 31)).single.payAmount, kzt(50000));
      final due = s.dueItems(DateTime(2026, 10, 31)).single;
      await s.payDue(due, account: 'cash', amount: due.payAmount, date: s.today);
      final pay = s.userTransactions.firstWhere((t) => t.type == EventType.repaymentMade && t.meta['planned'] != null);
      expect(pay.meta['period'], '2026-10-20');
      expect(s.personDebts, isEmpty, reason: 'долг возвращён целиком');
      expect(s.dueItems(DateTime(2026, 10, 31)), isEmpty);
      expect(s.planned.single.paid, {'2026-10-20'});
      // Отмена оплаты возвращает и долг, и срок.
      await s.deleteTransaction(pay.id);
      expect(s.dueItems(DateTime(2026, 10, 31)).single.payAmount, kzt(50000));
    });

    test('срок назначается и убирается на экране долга', () async {
      final f = FakeServer();
      await f.init();
      final s = f.state;
      await s.addPersonDebt(kind: 'borrow', amount: kzt(40000), person: 'Брат', account: 'cash', date: s.today);
      expect(s.dueItems(DateTime(2026, 12, 31)), isEmpty);
      await s.setPersonDue(s.personDebts.single, DateTime(2026, 11, 1));
      expect(s.dueItems(DateTime(2026, 12, 31)).single.date, DateTime(2026, 11, 1));
      await s.setPersonDue(s.personDebts.single, DateTime(2026, 11, 15));
      expect(s.dueItems(DateTime(2026, 12, 31)).single.date, DateTime(2026, 11, 15), reason: 'перенос, а не второй срок');
      await s.setPersonDue(s.personDebts.single, null);
      expect(s.dueItems(DateTime(2026, 12, 31)), isEmpty);
    });

    test('срок возврата не мешает платежам по кредитам и не попадает в «Обязательные платежи»', () async {
      final f = FakeServer();
      await f.init();
      final s = f.state;
      await s.sendBatch(s.newBankDebtCommands(name: 'Кредит', kind: 'loan', balance: kzt(100000), payment: kzt(10000), day: 25, paidThisMonth: false));
      await s.addPersonDebt(kind: 'borrow', amount: kzt(80000), person: 'Теща', account: 'cash', date: s.today, dueDate: DateTime(2026, 10, 20));
      expect(s.dueItems(DateTime(2026, 10, 31)).length, 3, reason: 'кредит за сентябрь и октябрь + возврат тёще');
      expect(s.activePlanned.map((p) => p.name), ['Кредит']);
      expect(s.recurringMonthly, kzt(10000));
    });
  });
}
