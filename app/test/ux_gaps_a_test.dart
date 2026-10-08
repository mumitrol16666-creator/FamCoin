/// Пакет А из docs/ux-gaps-2026-10-05.md: покупка в рассрочку (Ж1), перехват
/// платежа по кредиту (Ж2), частые переводы (Ж3), «откуда разница» при
/// уточнении остатка (Ж4), списание долга (Ж6).
library;

import 'package:famcoin/l10n/app_localizations.dart';
import 'package:famcoin/l10n/app_localizations_ru.dart';
import 'package:famcoin/state/app_scope.dart';
import 'package:famcoin/state/secret_store.dart';
import 'package:famcoin/state/settings.dart';
import 'package:famcoin/theme/app_theme.dart';
import 'package:famcoin/ui/budget/debt_screens.dart';
import 'package:famcoin/ui/budget/sheets.dart';
import 'package:famcoin/ui/home/tips.dart';
import 'package:famcoin/ui/ops/add_transaction_sheet.dart';
import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audit_regression_test.dart' show FakeServer;

/// Экран с кнопкой `open`, которая открывает [body]. На счёте `cash`
/// («Kaspi Gold», карта) 100 000 ₸, «сегодня» — 28.09.2026.
Future<FakeServer> pumpWith(WidgetTester tester, void Function(BuildContext) open) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final f = FakeServer();
  await f.init();
  await f.state.upsert('account', 'cash', {'name': 'Kaspi Gold', 'type': 'card'});
  await f.state.send({'type': 'updateProfile', 'profile': {'onboarded': true}});
  final settings = await Settings.load(api: f.state.api, secrets: MemorySecretStore());
  await tester.pumpWidget(AppScope(
    settings: settings,
    stateOrNull: f.state,
    child: MaterialApp(
      locale: const Locale('ru'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      theme: buildTheme(Brightness.light),
      home: Scaffold(body: Builder(builder: (context) => Center(child: FilledButton(onPressed: () => open(context), child: const Text('open'))))),
    ),
  ));
  await tester.pump(const Duration(seconds: 1));
  return f;
}

Future<FakeServer> pumpForm(WidgetTester tester) => pumpWith(tester, (c) => showAddTransactionSheet(c));

Future<void> openForm(WidgetTester tester) async {
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<void> tapText(WidgetTester tester, String text) async {
  await tester.ensureVisible(find.text(text).first);
  await tester.tap(find.text(text).first);
  await tester.pumpAndSettle();
}

/// Поле заметки лежит внизу ленивого списка — до него надо докрутить.
Future<void> enterNote(WidgetTester tester, String text) async {
  await tester.dragUntilVisible(find.text('Магазин или комментарий'), find.byType(ListView).last, const Offset(0, -200));
  await tester.enterText(find.widgetWithText(TextField, 'Магазин или комментарий'), text);
  await tester.pump();
}

Future<void> save(WidgetTester tester) async {
  // Кадр после ввода: кнопка включается только при перестроении формы.
  await tester.pump();
  await tester.ensureVisible(find.widgetWithText(FilledButton, 'Сохранить'));
  await tester.tap(find.widgetWithText(FilledButton, 'Сохранить'));
  await tester.pumpAndSettle();
}

void main() {
  final october = DateTime(2026, 10, 1);

  group('Ж1 покупка в рассрочку', () {
    testWidgets('расход сейчас, долг на остаток, график в календаре', (tester) async {
      final f = await pumpForm(tester);
      final s = f.state;
      await openForm(tester);
      await tester.enterText(find.byType(TextField).first, '300000');
      await tapText(tester, 'В рассрочку');
      expect(find.text('Покупка в рассрочку'), findsNothing, reason: 'заголовок формы не меняется, появляется пояснение');
      expect(find.textContaining('Покупка попадёт в расходы сейчас'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, 'Телефон, холодильник…'), 'iPhone');
      await tester.pump();
      expect(find.text('≈ 25 000 ₸ в месяц'), findsOneWidget, reason: '300 000 / 12');
      await save(tester);

      expect(find.text('Покупка записана, платежи — в календаре'), findsOneWidget);
      final buy = s.userTransactions.firstWhere((t) => t.type == EventType.creditPurchase);
      expect(buy.meta['note'], 'iPhone');
      expect(s.monthReport.expense, kzt(300000), reason: 'покупка — расход месяца покупки');
      expect(s.ledger.balance('cash'), kzt(100000), reason: 'без взноса деньги не уходят');
      final debt = s.bankDebts.single;
      expect(debt.kind, 'installment');
      expect(debt.name, 'iPhone');
      expect(s.debtBalance(debt.id), kzt(300000));
      final plan = s.planned.single;
      expect(plan.debtId, debt.id);
      expect(plan.amount, kzt(25000));
      expect(plan.day, 25);
      expect(s.dueItems(DateTime(2026, 9, 30)), isEmpty, reason: 'первый платёж — в следующем месяце');
      expect(s.dueItems(DateTime(2026, 10, 31)).single.date, DateTime(2026, 10, 25));
      expect(f.ledger.balance(liabilityAccount(debt.id)), kzt(300000), reason: 'сервер видит тот же долг');
    });

    testWidgets('первый взнос уходит со счёта, платёж считается от остатка', (tester) async {
      final f = await pumpForm(tester);
      final s = f.state;
      await openForm(tester);
      await tester.enterText(find.byType(TextField).first, '300000');
      await tapText(tester, 'В рассрочку');
      await tester.enterText(find.widgetWithText(TextField, 'Телефон, холодильник…'), 'Холодильник');
      await tester.enterText(find.byKey(const ValueKey('installment-down')), '60000');
      await tester.enterText(find.byKey(const ValueKey('installment-months')), '6');
      await tester.pump();
      expect(find.text('≈ 40 000 ₸ в месяц'), findsOneWidget, reason: '(300 000 − 60 000) / 6');
      await save(tester);
      expect(s.ledger.balance('cash'), kzt(40000));
      expect(s.debtBalance(s.bankDebts.single.id), kzt(240000));
      expect(s.monthReport.expense, kzt(300000));
      expect(s.spentToday(), 0, reason: 'покупка в рассрочку не входит в дневной лимит');
    });
  });

  group('Ж2 платёж по кредиту через «＋»', () {
    // Платёж за сентябрь (25-е) ещё не оплачен — иначе срока, который можно закрыть, нет (APP-04).
    Future<FakeServer> withDebt(WidgetTester tester, {String kind = 'creditCard', double rate = 0}) async {
      final f = await pumpForm(tester);
      await f.state.sendBatch(f.state.newBankDebtCommands(name: 'Kaspi Red', kind: kind, balance: kzt(100000), payment: kzt(10000), day: 25, rate: rate, paidThisMonth: false));
      return f;
    }

    testWidgets('расход с названием кредита в заметке → вопрос → лист оплаты уменьшает долг', (tester) async {
      final f = await withDebt(tester);
      final s = f.state;
      await openForm(tester);
      await tester.enterText(find.byType(TextField).first, '10000');
      await enterNote(tester, 'kaspi red за сентябрь');
      await save(tester);
      expect(find.text('Это платёж по кредиту?'), findsOneWidget);
      expect(find.textContaining('«Kaspi Red», остаток 100 000 ₸'), findsOneWidget);
      await tapText(tester, 'Платёж по кредиту');
      // Какой срок оплачивается: сентябрьский просроченный выбран сам, есть «досрочно».
      expect(find.text('Какой платёж оплачиваете?'), findsOneWidget);
      expect(find.text('Досрочно, вне графика'), findsOneWidget);
      await tapText(tester, 'Продолжить');
      expect(find.text('Оплатить: Kaspi Red'), findsOneWidget, reason: 'открылся лист оплаты срока');
      expect(s.planned.single.paid, isEmpty);
      await tester.tap(find.widgetWithText(FilledButton, 'Оплатить'));
      await tester.pumpAndSettle();
      expect(s.debtBalance(s.bankDebts.single.id), kzt(90000));
      expect(s.ledger.balance('cash'), kzt(90000));
      expect(s.userTransactions.where((t) => t.type == EventType.expense), isEmpty, reason: 'обычный расход не записан');
      // Срок закрыт именно этой оплатой и связан с ней — APP-04.
      expect(s.planned.single.paid, {'2026-09'});
      final pay = s.userTransactions.firstWhere((t) => t.type == EventType.loanPayment);
      expect(pay.meta['planned'], s.planned.single.id);
      expect(pay.meta['period'], '2026-09');
      expect(s.upcoming.where((d) => d.period == '2026-09'), isEmpty);
      // Отмена оплаты снова открывает тот же срок.
      await s.deleteTransaction(pay.id);
      expect(s.planned.single.paid, isEmpty);
      expect(s.upcoming.where((d) => d.period == '2026-09'), hasLength(1));
    });

    testWidgets('APP-04: выбранные в расходе дата, счёт и сумма сохраняются; проценты делят платёж на тело и проценты', (tester) async {
      final f = await withDebt(tester, kind: 'loan', rate: 20);
      final s = f.state;
      await s.sendBatch(s.newAccountCommands(name: 'Halyk', type: 'card', balance: kzt(50000)));
      final halyk = s.activeAccounts.firstWhere((a) => a.name == 'Halyk').id;
      await openForm(tester);
      await tester.enterText(find.byType(TextField).first, '10000');
      await tester.dragUntilVisible(find.text('Вчера'), find.byType(ListView).last, const Offset(0, -200));
      await tester.tap(find.text('Вчера'));
      await tester.pump();
      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Halyk').last);
      await tester.pumpAndSettle();
      await enterNote(tester, 'kaspi red');
      await save(tester);
      await tapText(tester, 'Платёж по кредиту');
      await tapText(tester, 'Продолжить');
      // Лист оплаты открыт с суммой 10 000 и счётом Halyk.
      expect(find.text('Оплатить: Kaspi Red'), findsOneWidget);
      final fields = find.descendant(of: find.byType(BottomSheet).last, matching: find.byType(TextField));
      expect(tester.widget<TextField>(fields.at(0)).controller!.text.replaceAll(' ', ''), '10000');
      expect(find.text('Halyk'), findsWidgets);
      await tester.enterText(fields.at(1), '2000'); // проценты
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Оплатить'));
      await tester.pumpAndSettle();
      final pay = s.userTransactions.firstWhere((t) => t.type == EventType.loanPayment);
      expect(pay.date, DateTime(2026, 9, 27), reason: 'дата из формы расхода, а не «сегодня»');
      expect(s.ledger.balance(halyk), kzt(40000));
      expect(s.ledger.balance('cash'), kzt(100000));
      expect(s.debtBalance(s.bankDebts.single.id), kzt(92000), reason: 'тело 8 000, проценты 2 000');
      expect(s.planned.single.paid, {'2026-09'});
    });

    testWidgets('APP-04: несколько сроков и «досрочно» — выбор явный; досрочный платёж срок не закрывает', (tester) async {
      final f = await withDebt(tester);
      final s = f.state;
      // Август тоже не оплачен: платёж заведён с начала августа.
      final p = s.planned.single;
      await s.upsert('planned', p.id, p.copyWith().toJson()..['start'] = '2026-08-01');
      expect(s.upcoming.where((d) => d.planned.id == p.id).map((d) => d.period).toList()..sort(), ['2026-08', '2026-09', '2026-10']);
      await openForm(tester);
      await tester.enterText(find.byType(TextField).first, '10000');
      await enterNote(tester, 'kaspi red');
      await save(tester);
      await tapText(tester, 'Платёж по кредиту');
      expect(find.textContaining('августа'), findsOneWidget);
      expect(find.textContaining('сентября'), findsOneWidget);
      await tapText(tester, 'Досрочно, вне графика');
      await tapText(tester, 'Продолжить');
      // Лист явно назван платежом вне графика (N04).
      expect(find.text('Платёж вне графика: Kaspi Red'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Оплатить'));
      await tester.pumpAndSettle();
      expect(s.debtBalance(s.bankDebts.single.id), kzt(90000));
      expect(s.planned.single.paid, isEmpty, reason: 'досрочный платёж не закрывает срок');
      expect(s.userTransactions.firstWhere((t) => t.type == EventType.loanPayment).meta.containsKey('planned'), isFalse);
    });

    testWidgets('«Обычный расход» — записывается как расход, вопрос не повторяется', (tester) async {
      final f = await withDebt(tester);
      final s = f.state;
      await openForm(tester);
      await tester.enterText(find.byType(TextField).first, '3000');
      await enterNote(tester, 'кредит на книгу');
      await save(tester);
      await tapText(tester, 'Обычный расход');
      expect(s.userTransactions.where((t) => t.type == EventType.expense).single.meta['note'], 'кредит на книгу');
      expect(s.debtBalance(s.bankDebts.single.id), kzt(100000));
    });

    testWidgets('без похожего названия вопроса нет', (tester) async {
      final f = await withDebt(tester);
      await openForm(tester);
      await tester.enterText(find.byType(TextField).first, '3000');
      await enterNote(tester, 'обед');
      await save(tester);
      expect(find.text('Это платёж по кредиту?'), findsNothing);
      expect(f.state.userTransactions.where((t) => t.type == EventType.expense), hasLength(1));
    });
  });

  group('Ж3 частые переводы', () {
    testWidgets('«Снял наличные» подставляет карту → наличные', (tester) async {
      final f = await pumpForm(tester);
      final s = f.state;
      await s.sendBatch(s.newAccountCommands(name: 'Наличные', type: 'cash', balance: 0));
      final cash = s.activeAccounts.firstWhere((a) => a.type == 'cash');
      await openForm(tester);
      await tapText(tester, 'Перевод');
      expect(find.text('Снял наличные'), findsOneWidget);
      expect(find.text('Положил на карту'), findsOneWidget);
      expect(find.text('В копилку'), findsNothing, reason: 'копилок нет');
      await tapText(tester, 'Снял наличные');
      await tester.enterText(find.byType(TextField).first, '20000');
      await save(tester);
      expect(s.ledger.balance(cash.id), kzt(20000));
      expect(s.ledger.balance('cash'), kzt(80000));
      expect(s.monthReport.expense, 0);
    });
  });

  group('Ж4 откуда разница', () {
    testWidgets('по умолчанию «забыл записать траты»: расход «Прочее» вне дневного лимита', (tester) async {
      final f = await pumpWith(tester, (c) => showAdjustBalanceSheet(c, 'cash'));
      final s = f.state;
      await s.setDailyLimit(kzt(5000));
      await openForm(tester);
      expect(find.text('Откуда разница?'), findsNothing, reason: 'разницы ещё нет');
      await tester.enterText(find.widgetWithText(TextField, 'Сколько на счёте на самом деле'), '93000');
      await tester.pump();
      expect(find.text('Забыл записать траты'), findsOneWidget);
      expect(find.text('Ошибка в остатке или другое'), findsOneWidget);
      await save(tester);
      final tx = s.userTransactions.first;
      expect(tx.type, EventType.expense);
      expect(tx.meta['note'], 'Неучтённые траты');
      expect(tx.meta['catchUp'], true);
      expect(s.ledger.balance('cash'), kzt(93000));
      expect(s.monthReport.expense, kzt(7000));
      expect(s.spentToday(), 0, reason: 'разница не съедает дневной лимит');
      expect(s.monthAdjustments, 0);
    });

    testWidgets('плюс на счёте — доход; «другое» — уточнение с причиной, как раньше', (tester) async {
      final f = await pumpWith(tester, (c) => showAdjustBalanceSheet(c, 'cash'));
      final s = f.state;
      await openForm(tester);
      await tester.enterText(find.widgetWithText(TextField, 'Сколько на счёте на самом деле'), '104000');
      await tester.pump();
      expect(find.text('Пришли деньги, которые не записал'), findsOneWidget);
      await save(tester);
      expect(s.userTransactions.first.type, EventType.income);
      expect(s.monthReport.income, kzt(4000));

      await openForm(tester);
      await tester.enterText(find.widgetWithText(TextField, 'Сколько на счёте на самом деле'), '100000');
      await tester.pump();
      await tapText(tester, 'Ошибка в остатке или другое');
      await save(tester);
      expect(s.ledger.balance('cash'), kzt(104000), reason: 'без причины уточнение не сохраняется');
      await tester.enterText(find.widgetWithText(TextField, 'Причина'), 'ошибся в начальном остатке');
      await save(tester);
      expect(s.ledger.balance('cash'), kzt(100000));
      expect(s.userTransactions.first.type, EventType.adjustment);
      expect(s.monthReport.income, kzt(4000), reason: 'уточнение не меняет доходы и расходы');
    });

    test('совет «давно нет записей» ведёт к сверке остатка', () async {
      final f = FakeServer();
      await f.init();
      await f.state.addExpense(amount: kzt(1000), category: 'food', account: 'cash', date: DateTime(2026, 9, 20));
      final tip = dataTipsFor(f.state, AppLocalizationsRu()).first;
      expect(tip.action, TipAction.catchUp);
    });
  });

  group('Ж6 списание долга', () {
    testWidgets('«не вернут» → отдельная строка, не расход; долг закрыт, деньги не меняются', (tester) async {
      late FakeServer f;
      f = await pumpWith(tester, (c) => Navigator.push(c, MaterialPageRoute<void>(builder: (_) => const PersonDebtScreen(person: 'Друг'))));
      final s = f.state;
      await s.addPersonDebt(kind: 'lendOut', amount: kzt(50000), person: 'Друг', account: 'cash', date: DateTime(2026, 9, 20));
      expect(s.ledger.balance('cash'), kzt(50000));
      await openForm(tester);
      await tapText(tester, 'Списать долг');
      expect(find.text('Списать долг «Друг»?'), findsOneWidget);
      expect(find.textContaining('50 000 ₸ не вернутся'), findsOneWidget);
      await tapText(tester, 'Списать');
      expect(find.text('Долг списан'), findsOneWidget);
      expect(find.text('Долг закрыт'), findsOneWidget);
      expect(s.personDebts, isEmpty);
      expect(s.ledger.balance('cash'), kzt(50000));
      expect(s.reportFor(DateTime(2026, 9, 1)).expense, 0, reason: 'списание не раздувает расходы месяца (D124)');
      expect(s.reportFor(DateTime(2026, 9, 1)).writtenOff, kzt(50000));
      expect(s.reportFor(october).writtenOff, 0);
      expect(find.text('Списан долг · Друг'), findsOneWidget, reason: 'запись видна в истории долга');
    });
  });
}
