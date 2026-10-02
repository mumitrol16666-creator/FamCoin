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
import 'package:famcoin/ui/auth/login_screen.dart';
import 'package:famcoin/ui/budget/sheets.dart';
import 'package:famcoin/ui/more/more_screen.dart';
import 'package:famcoin/ui/more/settings_screen.dart';
import 'package:famcoin/ui/onboarding/onboarding_screen.dart';
import 'package:famcoin/ui/ops/add_transaction_sheet.dart';
import 'package:famcoin/ui/shell.dart';
import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audit_regression_test.dart' show FakeServer;

Future<FakeServer> pumpApp(WidgetTester tester, {required Widget home, required Size size, double textScale = 1, Map<String, Object> prefs = const {}}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues(prefs);
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

  testWidgets('«Как посчитано» (D73): карточка говорит, что доступное ограничено деньгами; разбор открывается без переполнений', (tester) async {
    // Обычный телефон: в тестах шрифт Ahem вдвое шире настоящего, поэтому крайний
    // случай «320 px и 200 %» здесь дал бы ложные переполнения в старых строках.
    final f = await pumpApp(tester, home: const Shell(), size: const Size(360, 732));
    final s = f.state;
    await s.setDailyLimit(kzt(5000));
    await s.setDailyLimitCarryOn(true);
    f.now = f.now.add(const Duration(days: 9)); // перенос накопил 50 000
    await s.reserve('trip', 'cash', kzt(60000)); // свободно осталось 40 000
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('ограничено деньгами на счетах'), findsOneWidget);
    await tester.ensureVisible(find.text('Как посчитано ›'));
    await tester.tap(find.text('Как посчитано ›'));
    // На главной крутится фон сезона — pumpAndSettle не дождался бы конца.
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull, reason: 'карточка и разбор не должны переполняться');
    for (final label in ['Деньги на счетах', 'Отложено на цели', 'Свободно', 'Ваш лимит на день', 'Доступно сегодня']) {
      expect(find.text(label, skipOffstage: false), findsOneWidget, reason: label);
    }
    expect(find.textContaining('Доступное ограничено деньгами на счетах', skipOffstage: false), findsOneWidget);
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

  testWidgets('крупная покупка (D74): от половины лимита спрашиваем — «да» выносит из лимита, «отмена» не сохраняет, мелочь без вопросов', (tester) async {
    final f = await pumpApp(
      tester,
      size: const Size(360, 732),
      home: Scaffold(body: Builder(builder: (context) => Center(child: FilledButton(onPressed: () => showAddTransactionSheet(context), child: const Text('open'))))),
    );
    final s = f.state;
    await s.setDailyLimit(kzt(10000));
    Future<void> enter(String amount) async {
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, amount);
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Сохранить'));
      await tester.pumpAndSettle();
    }

    // Мелочь (40% лимита) — без вопросов, в лимите.
    await enter('4000');
    expect(find.text('Крупная покупка'), findsNothing);
    expect(s.spentToday(), kzt(4000));

    // 60% лимита — вопрос; «Отмена»: форма осталась, ничего не сохранено.
    await enter('6000');
    expect(find.text('Крупная покупка'), findsOneWidget);
    expect(find.textContaining('60%'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'диалог с тремя кнопками не должен переполняться');
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Отмена')));
    await tester.pumpAndSettle();
    expect(find.text('Записать операцию'), findsOneWidget);
    expect(s.ledger.balance('cash'), kzt(96000));

    // «Да, запланированная» — сохранено, но в лимит не входит.
    await tester.tap(find.widgetWithText(FilledButton, 'Сохранить'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Да, запланированная'));
    await tester.pumpAndSettle();
    expect(find.text('Записать операцию'), findsNothing);
    expect(s.ledger.balance('cash'), kzt(90000));
    expect(s.spentToday(), kzt(4000), reason: 'запланированная покупка в лимит не вошла');
    expect(s.userTransactions.first.meta['plannedPurchase'], isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('сверка месяца (D75): карточка на главной, итоги и вопросы сразу, «Закрыть месяц» снимает карточку', (tester) async {
    final f = await pumpApp(tester, home: const Shell(), size: const Size(360, 732));
    final s = f.state;
    await s.addIncome(amount: kzt(300000), source: 'salary', account: 'cash', date: DateTime(2026, 9, 1));
    await s.addExpense(amount: kzt(20000), category: 'food', account: 'cash', date: DateTime(2026, 9, 4));
    await f.plan();
    f.now = DateTime(2026, 10, 2); // начало октября — пора сверить сентябрь
    await s.load();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('Сверьте сентябрь'), findsOneWidget);
    expect(find.textContaining('300 000'), findsWidgets, reason: 'в карточке уже видны доходы');
    await tester.tap(find.text('Сверьте сентябрь'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.takeException(), isNull, reason: 'экран сверки не должен переполняться');

    // Итоги и вопросы — сразу, без промежуточных шагов.
    expect(find.text('Сентябрь 2026'), findsOneWidget);
    expect(find.text('Доходы'), findsWidgets);
    expect(find.text('1. Остатки на счетах'), findsOneWidget);
    expect(find.text('2. Платежи месяца', skipOffstage: false), findsOneWidget);
    await tester.scrollUntilVisible(find.text('4. Следующий месяц'), 300, scrollable: find.byType(Scrollable).first);
    expect(find.text('4. Следующий месяц'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('Закрыть месяц'), 300, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Закрыть месяц'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    expect(s.isMonthClosed(DateTime(2026, 9, 1)), isTrue);
    expect(find.text('Молодец: месяц закрыт.', skipOffstage: false), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.scrollUntilVisible(find.text('Готово'), 300, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Готово'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Сверьте сентябрь'), findsNothing, reason: 'месяц закрыт — карточка ушла');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('анкета (D76): шаг «Уведомления» с галочками; выбор уходит на сервер после «Начать учёт»', (tester) async {
    final f = await pumpApp(tester, home: const OnboardingScreen(), size: const Size(390, 844));
    final s = f.state;
    Future<void> next() async {
      await tester.tap(find.widgetWithText(FilledButton, 'Продолжить'));
      await tester.pumpAndSettle();
    }

    await tester.enterText(find.byType(TextField).first, 'Тест'); // 1. имя
    await tester.pump();
    await next(); // 2. режим
    await next(); // 3. счёт
    await tester.enterText(find.byType(TextField).at(1), '100000'); // остаток
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await next(); // кредиты, платежи, люди, лимиты, цель → уведомления
    }
    expect(find.text('Шаг 9 из 10'), findsOneWidget);
    expect(find.text('Уведомления'), findsWidgets);
    expect(find.text('Утренняя сводка'), findsOneWidget);
    expect(find.text('Вечерний отчёт'), findsOneWidget);
    expect(find.text('Сверка месяца'), findsOneWidget);
    // В тестах push недоступен (заглушка): кнопки «Включить» нет, есть пояснение.
    expect(find.text('Включить уведомления'), findsNothing);
    expect(find.textContaining('push недоступен'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Вечерний отчёт'));
    await tester.pump();
    await next(); // 10. сводка
    expect(find.text('Шаг 10 из 10'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Начать учёт'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));

    expect(s.onboarded, isTrue);
    expect(f.notif, {'morning': true, 'evening': false, 'month': true}, reason: 'выбор из анкеты сохранён на сервере');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('вход через Telegram (D77): после возврата в приложение проверка идёт сразу, код запомнен на устройстве', (tester) async {
    final f = await pumpApp(tester, home: const LoginScreen(), size: const Size(390, 844));
    final settings = AppScope.of(tester.element(find.byType(LoginScreen))).settings;
    expect(settings.signedIn, isFalse);

    await tester.tap(find.text('Войти через Telegram'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('Start'), findsOneWidget, reason: 'окно ожидания показано ещё до ухода в Telegram');
    expect(settings.pendingTelegramLogin?.code, 'logincode1234', reason: 'код переживёт перезапуск приложения');

    // Человек в Telegram: приложение в фоне, бот подтвердил код, человек вернулся.
    final before = f.tgChecks;
    for (final st in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
      tester.binding.handleAppLifecycleStateChanged(st);
    }
    f.tgConfirmed = true;
    for (final st in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
      tester.binding.handleAppLifecycleStateChanged(st);
    }
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));

    expect(f.tgChecks, before + 1, reason: 'проверка сразу при возврате, без ожидания таймера');
    expect(settings.signedIn, isTrue);
    expect(settings.pendingTelegramLogin, isNull);
    expect(find.textContaining('Start'), findsNothing, reason: 'окно ожидания закрылось');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('вход через Telegram (D77): приложение выгрузили, пока человек был в Telegram — при запуске вход продолжается сам', (tester) async {
    final until = DateTime.now().add(const Duration(minutes: 5)).millisecondsSinceEpoch;
    final f = await pumpApp(
      tester,
      home: const LoginScreen(),
      size: const Size(390, 844),
      prefs: {'tgLoginCode': 'logincode1234', 'tgLoginUrl': 'https://t.me/famcoin_test_bot?start=login_logincode1234', 'tgLoginUntil': until},
    );
    final settings = AppScope.of(tester.element(find.byType(LoginScreen))).settings;
    expect(find.textContaining('Start'), findsOneWidget, reason: 'экран входа сам открыл окно ожидания по сохранённому коду');
    expect(f.tgChecks, greaterThan(0), reason: 'и сразу проверил код');
    expect(settings.signedIn, isFalse);

    f.tgConfirmed = true;
    await tester.pump(const Duration(seconds: 2)); // следующий опрос
    await tester.pump(const Duration(milliseconds: 200));
    expect(settings.signedIn, isTrue);
    expect(settings.pendingTelegramLogin, isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('вход через Telegram (D77): устаревший сохранённый код не поднимает окно', (tester) async {
    final past = DateTime.now().subtract(const Duration(minutes: 1)).millisecondsSinceEpoch;
    final f = await pumpApp(
      tester,
      home: const LoginScreen(),
      size: const Size(390, 844),
      prefs: {'tgLoginCode': 'old', 'tgLoginUrl': 'https://t.me/x', 'tgLoginUntil': past},
    );
    expect(find.textContaining('Start'), findsNothing);
    expect(f.tgChecks, 0);
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
