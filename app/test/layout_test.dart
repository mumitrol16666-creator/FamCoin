/// Отрисовка на узких экранах и поведение формы (аудит 28.09.2026, F08–F10):
/// без переполнений на 320 px с текстом 200 %, форма операции на 360×732 —
/// подписи в одну строку, «Сохранить» видна без прокрутки, заполненная форма
/// не закрывается без подтверждения; «Ещё» без «Чека», ИИ помечен «скоро»;
/// дни графика подписаны для экранного диктора.
library;

import 'package:famcoin/l10n/app_localizations.dart';
import 'package:famcoin/state/app_scope.dart';
import 'package:famcoin/state/secret_store.dart';
import 'package:famcoin/state/settings.dart';
import 'package:famcoin/theme/app_theme.dart';
import 'package:famcoin/ui/analytics/analytics_screen.dart';
import 'package:famcoin/ui/budget/sheets.dart';
import 'package:famcoin/ui/more/more_screen.dart';
import 'package:famcoin/ui/more/settings_screen.dart';
import 'package:famcoin/ui/ops/add_transaction_sheet.dart';
import 'package:famcoin/ui/shell.dart';
import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audit_regression_test.dart' show FakeServer;

Future<FakeServer> pumpApp(WidgetTester tester, {required Widget home, required Size size, double textScale = 1}) async {
  tester.view.physicalSize = size;
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
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: home,
    ),
  ));
  await tester.pump(const Duration(seconds: 1));
  return f;
}

void main() {
  testWidgets('главная на 320 px и тексте 200 % — без переполнений', (tester) async {
    await pumpApp(tester, home: const Shell(), size: const Size(320, 694), textScale: 2);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('форма операции на 360×732: подписи в строку, «Сохранить» видна, черновик защищён', (tester) async {
    await pumpApp(
      tester,
      size: const Size(360, 732),
      home: Scaffold(body: Builder(builder: (context) => Center(child: FilledButton(onPressed: () => showAddTransactionSheet(context), child: const Text('open'))))),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'форма не должна переполняться на 360 px');

    // Четыре вида операции — каждая подпись в одну строку.
    for (final label in ['Расход', 'Доход', 'Перевод', 'Долг']) {
      final text = tester.widget<Text>(find.text(label).first);
      expect(text.maxLines, 1, reason: '«$label» не должно переноситься посреди слова');
    }

    // Кнопка сохранения на экране без прокрутки.
    final save = find.widgetWithText(FilledButton, 'Сохранить');
    expect(save, findsOneWidget);
    expect(tester.getBottomRight(save).dy, lessThanOrEqualTo(732));
    expect(tester.getTopLeft(save).dy, greaterThanOrEqualTo(0));

    // Пустую форму крестик закрывает сразу.
    await tester.tap(find.byTooltip('Закрыть'));
    await tester.pumpAndSettle();
    expect(find.text('Записать операцию'), findsNothing);

    // Заполненную — только после подтверждения.
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '2500');
    await tester.pump();
    await tester.tap(find.byTooltip('Закрыть'));
    await tester.pumpAndSettle();
    expect(find.text('Закрыть без сохранения?'), findsOneWidget);
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(find.text('Записать операцию'), findsOneWidget, reason: 'после «Отмена» форма остаётся');
    await tester.tap(find.byTooltip('Закрыть'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Не сохранять'));
    await tester.pumpAndSettle();
    expect(find.text('Записать операцию'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('форма: сохранение закрывает форму, ошибка сети показывается внутри формы', (tester) async {
    final f = await pumpApp(
      tester,
      size: const Size(360, 732),
      home: Scaffold(body: Builder(builder: (context) => Center(child: FilledButton(onPressed: () => showAddTransactionSheet(context), child: const Text('open'))))),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '2500');
    await tester.pump();

    f.offline = true;
    await tester.tap(find.widgetWithText(FilledButton, 'Сохранить'));
    await tester.pumpAndSettle();
    expect(find.text('Записать операцию'), findsOneWidget, reason: 'без сети форма остаётся открытой');
    expect(find.textContaining('Не удалось сохранить'), findsOneWidget);
    expect(f.state.ledger.balance('cash'), kzt(100000), reason: 'остаток не меняется до ответа сервера');

    f.offline = false;
    await tester.tap(find.widgetWithText(FilledButton, 'Сохранить'));
    await tester.pumpAndSettle();
    expect(find.text('Записать операцию'), findsNothing);
    expect(f.state.ledger.balance('cash'), kzt(97500));
    expect(f.state.userTransactions.where((t) => t.type == EventType.expense).length, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('настройки открываются с датой рождения раньше 2000 года', (tester) async {
    final f = await pumpApp(tester, home: const SettingsScreen(), size: const Size(390, 844));
    await f.state.setAbout(firstName: 'Владислав', lastName: 'Сидоров', birthDate: DateTime(1999, 3, 24));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Владислав Сидоров'), findsOneWidget);
    expect(find.textContaining('1999'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('счёт подставляет «для кого» по владельцу, ручной выбор не сбрасывается', (tester) async {
    final f = await pumpApp(
      tester,
      size: const Size(360, 732),
      home: Scaffold(body: Builder(builder: (context) => Center(child: FilledButton(onPressed: () => showAddTransactionSheet(context), child: const Text('open'))))),
    );
    await f.state.send({'type': 'updateProfile', 'profile': {'mode': 'family'}});
    await f.state.upsert('member', 'wife', {'name': 'Дильнора', 'role': 'spouse'});
    await f.state.sendBatch(f.state.newAccountCommands(name: 'Kaspi Дильноры', type: 'card', balance: kzt(10000), owner: 'wife'));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // «Для кого» — ниже видимой области длинной формы, форма прокручивается.
    Future<void> revealForWhom() async {
      for (var i = 0; i < 10 && find.text('Для кого').evaluate().isEmpty; i++) {
        await tester.drag(find.byType(ListView).first, const Offset(0, -300));
        await tester.pump();
      }
    }

    // По умолчанию — общий счёт без владельца, «для кого» = «Я».
    await revealForWhom();
    expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Я')).selected, isTrue);

    // Выбрали счёт Дильноры — «для кого» подстроилось само.
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kaspi Дильноры').last);
    await tester.pumpAndSettle();
    await revealForWhom();
    expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Дильнора')).selected, isTrue);

    // Тронули «для кого» руками — дальше счёт больше не переопределяет её.
    await tester.tap(find.widgetWithText(ChoiceChip, 'Общее'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kaspi Gold').last);
    await tester.pumpAndSettle();
    await revealForWhom();
    expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Общее')).selected, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('лимит: можно создать свою категорию прямо в форме', (tester) async {
    await pumpApp(
      tester,
      size: const Size(360, 732),
      home: Scaffold(body: Builder(builder: (context) => Center(child: FilledButton(onPressed: () => addLimitFlow(context), child: const Text('open'))))),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final ownCategoryChip = find.widgetWithText(ActionChip, 'Своя категория');
    expect(ownCategoryChip, findsOneWidget, reason: 'иначе непонятно, что лимит можно поставить и на свою категорию');
    await tester.ensureVisible(ownCategoryChip);
    await tester.pumpAndSettle();
    await tester.tap(ownCategoryChip);
    await tester.pumpAndSettle();
    expect(find.text('Своя категория'), findsWidgets); // заголовок листа создания
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('«Ещё»: без пункта «Чек», ИИ подписан «скоро», а не Pro', (tester) async {
    await pumpApp(tester, home: const MoreScreen(), size: const Size(360, 732));
    expect(find.text('Чек'), findsNothing);
    expect(find.text('ИИ-консультант'), findsOneWidget);
    expect(find.text('скоро'), findsOneWidget);
    await tester.tap(find.text('ИИ-консультант'));
    await tester.pumpAndSettle();
    expect(find.textContaining('ещё не готов'), findsOneWidget);
    expect(find.text('Оформить Pro в Telegram'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('аналитика: дни графика подписаны, есть выбор дня календарём', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpApp(tester, home: const AnalyticsScreen(), size: const Size(390, 844));
    expect(tester.takeException(), isNull);
    expect(find.text('Выбрать день'), findsOneWidget);
    expect(find.byTooltip('Предыдущий месяц'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^28 сентября: ')), findsOneWidget);
    handle.dispose();
    await tester.pumpWidget(const SizedBox());
  });
}
