import 'package:famcoin/l10n/app_localizations.dart';
import 'package:famcoin/state/app_scope.dart';
import 'package:famcoin/state/app_state.dart';
import 'package:famcoin/state/models.dart';
import 'package:famcoin/state/secret_store.dart';
import 'package:famcoin/state/settings.dart';
import 'package:famcoin/theme/app_theme.dart';
import 'package:famcoin/ui/ops/add_transaction_sheet.dart';
import 'package:famcoin/ui/widgets/common.dart';
import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audit_regression_test.dart' show FakeServer;

/// Доход → цели (D96). «Сегодня» заглушки — 28.09.2026, на счёте `cash`
/// 100 000 ₸. Цель по умолчанию: 600 000 ₸ к 31.03.2027, то есть 6 месяцев
/// и «нужно в месяц» 100 000 ₸.
Future<GoalInfo> addGoal(FakeServer f, {String name = 'Подушка', int target = 600000, bool noDeadline = false}) async {
  await f.state.sendBatch(f.state.newGoalCommands(name: name, target: kzt(target), deadline: noDeadline ? null : DateTime(2027, 3, 31)));
  return f.state.goals.firstWhere((g) => g.name == name);
}

Future<FakeServer> pumpForm(WidgetTester tester) async {
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
      home: Scaffold(body: Builder(builder: (context) => Center(child: FilledButton(onPressed: () => showAddTransactionSheet(context), child: const Text('open'))))),
    ),
  ));
  await tester.pump(const Duration(seconds: 1));
  return f;
}

/// Открыть форму, выбрать «Доход», ввести сумму и сохранить.
Future<void> saveIncome(WidgetTester tester, String amount) async {
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Доход').first);
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField).first, amount);
  await tester.pump();
  await tester.tap(find.widgetWithText(FilledButton, 'Сохранить'));
  await tester.pumpAndSettle();
}

void main() {
  group('когда предлагать', () {
    test('нужны незакрытые цели с копилкой, заметный доход и не выключенное предложение', () async {
      final f = FakeServer();
      await f.init();
      final s = f.state;
      expect(s.shouldOfferGoals(kzt(300000)), isFalse, reason: 'целей нет');

      final g = await addGoal(f);
      expect(s.shouldOfferGoals(kzt(300000)), isTrue);
      expect(s.shouldOfferGoals(AppState.incomeOfferMin - 1), isFalse, reason: 'ниже порога');
      expect(s.shouldOfferGoals(AppState.incomeOfferMin), isTrue, reason: 'порог включительно');

      await s.setOfferGoalsOnIncome(false);
      expect(s.shouldOfferGoals(kzt(300000)), isFalse, reason: 'владелец выключил');
      await s.setOfferGoalsOnIncome(true);
      expect(s.shouldOfferGoals(kzt(300000)), isTrue);

      // Достигнутая цель из предложения уходит.
      await s.depositToGoal(g, from: 'cash', amount: kzt(600000) - kzt(500000));
      expect(s.openGoals.map((x) => x.id), [g.id]);
      final small = await addGoal(f, name: 'Велосипед', target: 50000);
      await s.depositToGoal(small, from: 'cash', amount: kzt(50000));
      expect(s.openGoals.map((x) => x.id), [g.id], reason: 'накопленная цель не предлагается');
    });
  });

  group('подсказка суммы', () {
    test('«нужно в месяц» минус уже отложенное в этом месяце', () async {
      final f = FakeServer();
      await f.init();
      final s = f.state;
      final g = await addGoal(f);
      expect(s.goalSuggestedDeposit(g, date: s.today), kzt(100000));

      await s.depositToGoal(g, from: 'cash', amount: kzt(40000));
      // Остаток 560 000 / 6 = 93 334 (вверх до тенге), минус 40 000 в этом месяце.
      expect(s.goalDepositedInMonth(g, s.today), kzt(40000));
      expect(s.goalSuggestedDeposit(g, date: s.today), kzt(93334) - kzt(40000));

      // Взнос прошлого месяца на подсказку этого месяца не влияет напрямую:
      // только через остаток до цели.
      final f2 = FakeServer();
      await f2.init();
      final g2 = await addGoal(f2);
      await f2.state.depositToGoal(g2, from: 'cash', amount: kzt(60000), date: DateTime(2026, 8, 15));
      expect(f2.state.goalDepositedInMonth(g2, f2.state.today), 0);
      expect(f2.state.goalSuggestedDeposit(g2, date: f2.state.today), kzt(90000));
    });

    test('без срока подсказки нет; подсказки по всем целям не превышают доход', () async {
      final f = FakeServer();
      await f.init();
      final s = f.state;
      final free = await addGoal(f, name: 'Когда-нибудь', target: 1000000, noDeadline: true);
      expect(s.goalSuggestedDeposit(free, date: s.today), isNull);
      expect(s.incomeGoalSuggestions(kzt(300000), date: s.today), isEmpty);

      final a = await addGoal(f, name: 'Подушка');
      final b = await addGoal(f, name: 'Отпуск', target: 300000); // 50 000 в месяц
      expect(s.incomeGoalSuggestions(kzt(300000), date: s.today), {a.id: kzt(100000), b.id: kzt(50000)});
      expect(s.incomeGoalSuggestions(kzt(120000), date: s.today), {a.id: kzt(100000), b.id: kzt(20000)}, reason: 'второй цели достаётся остаток');
      expect(s.incomeGoalSuggestions(kzt(70000), date: s.today), {a.id: kzt(70000)}, reason: 'на вторую цель дохода не осталось');
    });
  });

  test('allocateToGoals: одна пачка переводов датой дохода со счёта дохода', () async {
    final f = FakeServer();
    await f.init();
    final s = f.state;
    final a = await addGoal(f, name: 'Подушка');
    final b = await addGoal(f, name: 'Отпуск', target: 300000);
    final before = f.applied;
    await s.allocateToGoals({a: kzt(30000), b: kzt(10000)}, from: 'cash', date: DateTime(2026, 9, 5), commandId: 'alloc-1');
    expect(f.applied - before, 1, reason: 'один запрос');
    expect(s.goalSaved(a), kzt(30000));
    expect(s.goalSaved(b), kzt(10000));
    expect(s.ledger.balance('cash'), kzt(100000) - kzt(40000));
    final transfers = s.ledger.transactions.where((t) => t.type == EventType.transfer).toList();
    expect(transfers.map((t) => t.date).toSet(), {DateTime(2026, 9, 5)});
    expect(s.goalDepositedInMonth(a, s.today), kzt(30000));

    // Повтор с тем же commandId после «обрыва» ничего не задваивает.
    await s.allocateToGoals({a: kzt(30000), b: kzt(10000)}, from: 'cash', date: DateTime(2026, 9, 5), commandId: 'alloc-1');
    expect(s.goalSaved(a), kzt(30000));
  });

  testWidgets('после дохода — лист с подсказкой, «Отложить» переводит в копилку; «Не предлагать» выключает', (tester) async {
    final f = await pumpForm(tester);
    final g = await addGoal(f);

    // 1. Заметный доход → лист с подставленной суммой 100 000.
    await saveIncome(tester, '300000');
    expect(find.text('Отложить часть на цели?'), findsOneWidget);
    expect(find.text('Операция записана'), findsNothing, reason: 'лист сам говорит, что доход записан');
    final field = find.byKey(ValueKey('income-goal-${g.id}'));
    expect(tester.widget<AmountField>(field).controller.text, amountToField(kzt(100000)));
    expect(find.text('Итого ${moneyInText(kzt(100000))} · на счёте останется ${moneyInText(kzt(300000))}'), findsOneWidget);
    expect(find.text('${moneyInText(kzt(0))} из ${moneyInText(kzt(600000))} · нужно в месяц ${moneyInText(kzt(100000))}'.replaceFirst(moneyInText(kzt(0)), 'отложено ${moneyInText(kzt(0))}')), findsOneWidget);

    // Правка суммы меняет итог.
    await tester.enterText(field, '50000');
    await tester.pump();
    expect(find.text('Итого ${moneyInText(kzt(50000))} · на счёте останется ${moneyInText(kzt(350000))}'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Отложить'));
    await tester.pumpAndSettle();
    expect(find.text('Отложить часть на цели?'), findsNothing);
    expect(find.text('Отложено на цели: ${moneyInText(kzt(50000))}'), findsOneWidget);
    expect(f.state.goalSaved(g), kzt(50000));
    expect(f.state.ledger.balance('cash'), kzt(350000));
    await tester.pumpAndSettle(const Duration(seconds: 5));

    // 2. Мелкий доход вопроса не вызывает.
    await saveIncome(tester, '3000');
    expect(find.text('Отложить часть на цели?'), findsNothing);
    expect(find.text('Операция записана'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 5));

    // 3. Второй заметный доход в том же месяце: подсказка меньше на уже
    //    отложенное, кнопка без суммы неактивна; «Не предлагать» выключает.
    await saveIncome(tester, '300000');
    expect(find.text('Отложить часть на цели?'), findsOneWidget);
    // Остаток 550 000 / 6 = 91 667, минус 50 000 в этом месяце.
    expect(tester.widget<AmountField>(find.byKey(ValueKey('income-goal-${g.id}'))).controller.text, amountToField(kzt(91667) - kzt(50000)));
    await tester.enterText(find.byKey(ValueKey('income-goal-${g.id}')), '');
    await tester.pump();
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Отложить')).onPressed, isNull);
    await tester.tap(find.text('Не предлагать при доходе'));
    await tester.pumpAndSettle();
    expect(f.state.offerGoalsOnIncome, isFalse);
    expect(f.profile['offerGoalsOnIncome'], isFalse, reason: 'флаг ушёл на сервер');
    expect(find.text('Больше не предлагаем. Включить снова можно в настройках.'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 5));

    // 4. После выключения — обычное «Операция записана».
    await saveIncome(tester, '300000');
    expect(find.text('Отложить часть на цели?'), findsNothing);
    expect(find.text('Операция записана'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
