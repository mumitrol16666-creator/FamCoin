import 'package:famcoin/l10n/app_localizations.dart';
import 'package:famcoin/state/app_scope.dart';
import 'package:famcoin/state/secret_store.dart';
import 'package:famcoin/state/settings.dart';
import 'package:famcoin/theme/app_theme.dart';
import 'package:famcoin/ui/analytics/category_screen.dart';
import 'package:famcoin/ui/budget/limits_section.dart';
import 'package:famcoin/ui/widgets/common.dart';
import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audit_regression_test.dart' show FakeServer;

Future<FakeServer> pumpLimits(WidgetTester tester, {String language = 'ru', double width = 390, double scale = 1, Brightness brightness = Brightness.light}) async {
  tester.view.physicalSize = Size(width, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final f = FakeServer();
  await f.init();
  final settings = await Settings.load(api: f.state.api, secrets: MemorySecretStore());
  await tester.pumpWidget(AppScope(
    settings: settings,
    stateOrNull: f.state,
    child: MaterialApp(
      locale: Locale(language),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      theme: buildTheme(brightness),
      builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
      home: const Scaffold(body: SingleChildScrollView(padding: EdgeInsets.all(16), child: LimitsSection())),
    ),
  ));
  await tester.pumpAndSettle();
  return f;
}

Future<void> addLimit(FakeServer f, String category, int amount) => f.state.upsert('limit', category, {'category': category, 'amount': kzt(amount).toString()});
Finder row(String category) => find.byKey(ValueKey('limit-$category'));
Finder summaryMoney(int amount) => find.descendant(of: find.byKey(const ValueKey('limits-summary')), matching: find.text(moneyInText(kzt(amount))));

Future<void> openRow(WidgetTester tester, String category) async {
  await tester.ensureVisible(row(category));
  await tester.tap(row(category));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('сводка только по категориям с лимитом и текущему месяцу; подробности и операции', (tester) async {
    final f = await pumpLimits(tester);
    final semantics = tester.ensureSemantics();
    await addLimit(f, 'cafe', 10000);
    await addLimit(f, 'transport', 12000);
    await f.state.addExpense(amount: kzt(2500), category: 'cafe', account: 'cash', date: f.state.today);
    await f.state.addExpense(amount: kzt(740), category: 'transport', account: 'cash', date: f.state.today);
    await f.state.addExpense(amount: kzt(999), category: 'food', account: 'cash', date: f.state.today);
    await f.state.addExpense(amount: kzt(500), category: 'cafe', account: 'cash', date: DateTime(2026, 8, 30));
    await tester.pumpAndSettle();
    expect(summaryMoney(22000), findsOneWidget);
    expect(summaryMoney(3240), findsOneWidget);
    expect(summaryMoney(18760), findsOneWidget);
    expect(find.text('25%'), findsOneWidget);
    expect(find.text('6%'), findsOneWidget);
    expect(find.text('осталось: ${moneyInText(kzt(7500))} · ≈ ${moneyInText(kzt(2500))} в день'), findsOneWidget);
    expect(find.byType(PopupMenuButton<String>), findsNothing);
    expect(tester.getSemantics(row('cafe')), matchesSemantics(isButton: true, hasTapAction: true,
      label: 'Кафе. 25%. ${moneyInText(kzt(2500))} из ${moneyInText(kzt(10000))}. осталось: ${moneyInText(kzt(7500))} · ≈ ${moneyInText(kzt(2500))} в день', hint: 'Открыть подробности лимита'));
    semantics.dispose();

    await openRow(tester, 'cafe');
    expect(find.text('Использовано 25%'), findsOneWidget);
    expect(find.textContaining('Остаток ÷ 3 дн.'), findsOneWidget, reason: '28 сентября: 28, 29 и 30-е входят в расчёт');
    expect(find.text(moneyInText(kzt(2500))), findsWidgets);
    await tester.ensureVisible(find.text('Операции категории'));
    await tester.tap(find.text('Операции категории'));
    await tester.pumpAndSettle();
    expect(find.byType(CategoryScreen), findsOneWidget);
    expect(tester.widget<BigMoney>(find.byType(BigMoney)).minor, kzt(2500));
    expect(tester.widget<CategoryScreen>(find.byType(CategoryScreen)).category, 'cafe');
    expect(find.text('500 ₸'), findsNothing, reason: 'операция августа не попадает в сентябрь');
    expect(tester.takeException(), isNull);
  });

  testWidgets('редактирование, подтверждение удаления и ограничение двух лимитов сохранены', (tester) async {
    final f = await pumpLimits(tester);
    await addLimit(f, 'cafe', 10000);
    await addLimit(f, 'transport', 12000);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Добавить'));
    await tester.pumpAndSettle();
    expect(find.text('Добавить лимит'), findsNothing, reason: 'третий лимит в бесплатном тарифе не открывает форму');
    expect(find.textContaining('Pro'), findsWidgets);
    expect(tester.takeException(), isNull, reason: 'окно Pro');
    Navigator.of(tester.element(find.byType(LimitsSection))).pop();
    await tester.pumpAndSettle();

    await openRow(tester, 'cafe');
    await tester.tap(find.text('Изменить лимит'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '20000');
    await tester.ensureVisible(find.text('Сохранить'));
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'форма изменения');
    expect(f.state.limits.first.amount, kzt(20000));
    expect(summaryMoney(32000), findsWidgets);

    await openRow(tester, 'cafe');
    await tester.ensureVisible(find.text('Удалить'));
    await tester.tap(find.text('Удалить'));
    await tester.pumpAndSettle();
    expect(find.text('Удалить лимит?'), findsOneWidget);
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(f.state.limits.length, 2);
    await openRow(tester, 'cafe');
    await tester.ensureVisible(find.text('Удалить'));
    await tester.tap(find.text('Удалить'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Удалить'));
    await tester.pumpAndSettle();
    expect(row('cafe'), findsNothing);
    expect(f.state.limits.length, 1);
    expect(summaryMoney(12000), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ноль, превышение и возврат: точные остатки, конечные шкалы, порядок не меняется', (tester) async {
    final f = await pumpLimits(tester);
    await addLimit(f, 'cafe', 0);
    await addLimit(f, 'transport', 100);
    await f.state.addExpense(amount: kzt(150), category: 'transport', account: 'cash', date: f.state.today);
    await tester.pumpAndSettle();
    expect(find.text('Сверх лимита'), findsOneWidget); // сводка
    expect(find.text('осталось: ${moneyInText(kzt(-50))} · ≈ ${moneyInText(0)} в день'), findsOneWidget);
    expect(summaryMoney(50), findsOneWidget);
    expect(tester.getTopLeft(row('cafe')).dy, lessThan(tester.getTopLeft(row('transport')).dy));
    await openRow(tester, 'cafe');
    expect(find.text('Процент не рассчитывается при нулевом лимите.'), findsOneWidget);
    Navigator.of(tester.element(find.byType(LimitsSection))).pop();
    await tester.pumpAndSettle();
    await openRow(tester, 'transport');
    expect(find.text('Использовано 150%'), findsOneWidget);
    expect(find.textContaining('Остаток ÷'), findsNothing, reason: 'отрицательный остаток нельзя выдавать за дневной ориентир');
    Navigator.of(tester.element(find.byType(LimitsSection))).pop();
    await tester.pumpAndSettle();

    // Возврат прошлой покупки может сделать расход этого месяца отрицательным.
    await f.state.addExpense(amount: kzt(200), category: 'transport', account: 'cash', date: DateTime(2026, 8, 30));
    final old = f.state.userTransactions.firstWhere((t) => t.date.month == 8);
    await f.state.refund(old, category: 'transport', amount: kzt(200), account: 'cash');
    await tester.pumpAndSettle();
    expect(summaryMoney(-50), findsOneWidget);
    expect(summaryMoney(150), findsOneWidget);
    expect(find.text('Сверх лимита'), findsNothing);
    expect(tester.getTopLeft(row('cafe')).dy, lessThan(tester.getTopLeft(row('transport')).dy));
    for (final bar in tester.widgetList<LinearProgressIndicator>(find.byType(LinearProgressIndicator))) {
      expect(bar.value, inInclusiveRange(0, 1));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('35 лимитов: бюджет ограничен тремя строками; превышение вне превью видно и открывается', (tester) async {
    final f = await pumpLimits(tester);
    await seedManyLimits(f);
    await tester.pumpAndSettle();
    expect(find.text('Показаны первые 3 из 35'), findsOneWidget);
    expect(row('c00'), findsOneWidget);
    expect(row('c02'), findsOneWidget);
    expect(row('c03'), findsNothing);
    expect(row('c34'), findsNothing);
    expect(summaryMoney(35000), findsOneWidget);
    expect(summaryMoney(3400), findsOneWidget);
    expect(summaryMoney(31600), findsOneWidget);
    expect(find.text('Превышены: 1'), findsOneWidget, reason: 'общий остаток положительный, но одна категория превышена');

    await tester.tap(find.byKey(const ValueKey('limits-exceeded')));
    await tester.pumpAndSettle();
    expect(find.byType(LimitsScreen), findsOneWidget);
    expect(find.text('Найдено: 1 из 35'), findsOneWidget);
    expect(row('c34'), findsOneWidget);
    expect(row('c00'), findsNothing);
    await openRow(tester, 'c34');
    expect(find.text('Использовано 110%'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('полный список: поиск, фильтры, возврат из подробностей и доступ к последнему из 35 лимитов', (tester) async {
    final f = await pumpLimits(tester);
    await seedManyLimits(f);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('all-limits')));
    await tester.tap(find.byKey(const ValueKey('all-limits')));
    await tester.pumpAndSettle();
    expect(find.text('Найдено: 35 из 35'), findsOneWidget);
    expect(row('c34'), findsNothing, reason: 'далёкие строки не строятся заранее');
    final search = find.byKey(const ValueKey('limits-search'));
    await tester.enterText(search, '  КАТЕГОРИЯ 34  ');
    await tester.pumpAndSettle();
    expect(find.text('Найдено: 1 из 35'), findsOneWidget);
    await openRow(tester, 'c34');
    Navigator.of(tester.element(find.byType(LimitsScreen))).pop();
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(search).controller!.text, '  КАТЕГОРИЯ 34  ');
    await tester.enterText(search, 'нет такой категории');
    await tester.pumpAndSettle();
    expect(find.text('Ничего не найдено'), findsOneWidget);
    await tester.tap(find.byTooltip('Очистить поиск'));
    await tester.pumpAndSettle();

    Future<void> filter(String name) async {
      await tester.tap(find.byKey(ValueKey('limits-filter-$name')));
      await tester.pumpAndSettle();
    }
    await filter('near');
    expect(find.text('Найдено: 2 из 35'), findsOneWidget);
    expect(row('c32'), findsOneWidget, reason: 'ровно 100% ещё не превышение');
    expect(row('c33'), findsOneWidget);
    expect(row('c34'), findsNothing);
    await filter('exceeded');
    expect(find.text('Найдено: 1 из 35'), findsOneWidget);
    expect(row('c34'), findsOneWidget);
    await filter('unused');
    expect(find.text('Найдено: 31 из 35'), findsOneWidget);
    await filter('all');
    await tester.scrollUntilVisible(row('c34'), 450, scrollable: find.descendant(of: find.byType(LimitsScreen), matching: find.byType(Scrollable)).first);
    await openRow(tester, 'c34');
    expect(find.text('Использовано 110%'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('полный список: когда все категории заняты, добавление создаёт новую категорию и лимит', (tester) async {
    final f = await pumpLimits(tester);
    f.billingPlan = 'pro';
    await f.state.refresh();
    final categories = f.state.visibleExpenseCategories;
    await f.state.sendBatch([
      for (final category in categories)
        {'type': 'upsertEntity', 'kind': 'limit', 'entityId': category.id, 'data': {'category': category.id, 'amount': kzt(1000).toString()}},
    ]);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('all-limits')));
    await tester.tap(find.byKey(const ValueKey('all-limits')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Добавить лимит'));
    await tester.pumpAndSettle();
    expect(find.text('Своя категория'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'Новый лимит');
    await tester.ensureVisible(find.text('Сохранить'));
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(find.text('Добавить лимит'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, '5000');
    await tester.ensureVisible(find.text('Сохранить'));
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(f.state.limits.length, categories.length + 1);
    final added = f.state.ownCategories.single;
    expect(added.name, 'Новый лимит');
    expect(f.state.limits.singleWhere((limit) => limit.category == added.id).amount, kzt(5000));
    expect(find.text('Найдено: ${categories.length + 1} из ${categories.length + 1}'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final language in ['ru', 'kk']) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('$language, 320 px, текст ${scale * 100}%: крупные суммы, длинная категория и подробности', (tester) async {
        final f = await pumpLimits(tester, language: language, width: 320, scale: scale, brightness: language == 'kk' ? Brightness.dark : Brightness.light);
        expect(find.byKey(const ValueKey('limits-summary')), findsNothing, reason: 'пустому списку не нужна сводка из нулей');
        const name = 'Длинное название моей категории';
        await f.state.upsert('category', 'custom', {'name': name, 'icon': 1});
        await addLimit(f, 'custom', 9999999);
        await tester.pumpAndSettle();
        expect(find.text(name), findsOneWidget);
        expect(tester.takeException(), isNull);
        await openRow(tester, 'custom');
        expect(find.textContaining(language == 'ru' ? 'Остаток ÷ 3' : 'Қалдық ÷ ай'), findsOneWidget);
        await tester.ensureVisible(find.text(language == 'ru' ? 'Операции категории' : 'Санат операциялары'));
        expect(tester.takeException(), isNull);
        Navigator.of(tester.element(find.byType(LimitsSection))).pop();
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const ValueKey('all-limits')));
        await tester.tap(find.byKey(const ValueKey('all-limits')));
        await tester.pumpAndSettle();
        expect(find.byType(LimitsScreen), findsOneWidget);
        await tester.enterText(find.byKey(const ValueKey('limits-search')), '  МОЕЙ ');
        await tester.pumpAndSettle();
        await tester.ensureVisible(row('custom'));
        expect(row('custom'), findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'поиск и фильтры доступны на узком экране с увеличенным текстом');
      });
    }
  }
}

Future<void> seedManyLimits(FakeServer f) async {
  f.billingPlan = 'pro';
  await f.state.refresh();
  await f.state.sendBatch([
    for (var i = 0; i < 35; i++) ...[
      {'type': 'upsertEntity', 'kind': 'category', 'entityId': 'c${i.toString().padLeft(2, '0')}', 'data': {'name': 'Категория ${i.toString().padLeft(2, '0')}', 'icon': 0}},
      {'type': 'upsertEntity', 'kind': 'limit', 'entityId': 'c${i.toString().padLeft(2, '0')}', 'data': {'category': 'c${i.toString().padLeft(2, '0')}', 'amount': kzt(1000).toString()}},
    ],
  ]);
  for (final entry in {'c30': 500, 'c32': 1000, 'c33': 800, 'c34': 1100}.entries) {
    await f.state.addExpense(amount: kzt(entry.value), category: entry.key, account: 'cash', date: f.state.today);
  }
}
