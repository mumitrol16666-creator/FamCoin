/// Отрисовка на узких экранах и поведение формы (аудит 28.09.2026, F08–F10):
/// без переполнений на 320 px с текстом 200 %, форма операции на 360×732 —
/// подписи в одну строку, «Сохранить» видна без прокрутки, заполненная форма
/// не закрывается без подтверждения; «Ещё» без дублей ввода и консультанта;
/// дни графика подписаны для экранного диктора.
library;

import 'dart:async';

import 'package:famcoin/l10n/app_localizations.dart';
import 'package:famcoin/state/app_scope.dart';
import 'package:famcoin/state/models.dart';
import 'package:famcoin/state/push.dart';
import 'package:famcoin/state/secret_store.dart';
import 'package:famcoin/state/settings.dart';
import 'package:famcoin/theme/app_theme.dart';
import 'package:famcoin/ui/analytics/analytics_screen.dart';
import 'package:famcoin/ui/auth/login_screen.dart';
import 'package:famcoin/ui/budget/budget_screen.dart';
import 'package:famcoin/ui/budget/calendar_screen.dart';
import 'package:famcoin/ui/budget/sheets.dart';
import 'package:famcoin/ui/more/ai_screen.dart';
import 'package:famcoin/ui/more/more_screen.dart';
import 'package:famcoin/ui/more/settings_screen.dart';
import 'package:famcoin/ui/onboarding/onboarding_screen.dart';
import 'package:famcoin/ui/ops/add_transaction_sheet.dart';
import 'package:famcoin/ui/shell.dart';
import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audit_regression_test.dart' show FakeServer;

Future<FakeServer> pumpApp(WidgetTester tester, {required Widget home, required Size size, double textScale = 1, Map<String, Object> prefs = const {}, Locale locale = const Locale('ru'), Brightness brightness = Brightness.light}) async {
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
      locale: locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      theme: buildTheme(brightness),
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

  testWidgets('разовые покупки (D88, D90): раздел в «Бюджете», подсказка сколько откладывать, копилка и «купил»', (tester) async {
    final f = await pumpApp(tester, home: const BudgetPurchasesPage(), size: const Size(360, 732));
    await f.state.addPurchase(name: 'Колёса', amount: kzt(100000), month: DateTime(2027, 3, 1), category: 'transport');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.scrollUntilVisible(find.text('Колёса'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('Разовые покупки', skipOffstage: false), findsOneWidget);
    expect(find.textContaining('Март 2027'), findsOneWidget);
    expect(find.textContaining('в месяц'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Колёса'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'лист покупки открывается без переполнений');
    expect(find.text('Купил'), findsOneWidget);
    expect(find.text('Убрать из плана'), findsOneWidget);

    // «Копить в копилку» заводит цель — строка покупки показывает прогресс.
    await tester.tap(find.text('Копить в копилку'));
    await tester.pumpAndSettle();
    expect(f.state.goals.single.name, 'Колёса');
    expect(find.text('Колёса'), findsOneWidget, reason: 'копилка покупки не повторяется в самостоятельных целях');
    expect(find.textContaining('отложено 0'), findsOneWidget);
    expect(find.textContaining('ещё ≈'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Колёса').first);
    await tester.pumpAndSettle();
    expect(find.text('Пополнить копилку'), findsOneWidget);
    await tester.tap(find.text('Управлять копилкой'));
    await tester.pumpAndSettle();
    expect(find.text('Отложить в копилку'), findsOneWidget);
    expect(find.byType(PopupMenuButton<String>), findsOneWidget, reason: 'изменение и удаление копилки остаются доступны');
    Navigator.pop(tester.element(find.byType(BottomSheet)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Колёса'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Купил'));
    await tester.pumpAndSettle();
    expect(find.text('Оплатить'), findsWidgets, reason: 'форма «купил» открывается');
    expect(tester.takeException(), isNull);
    Navigator.pop(tester.element(find.byType(BottomSheet)));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('предупреждение «уйдёт в минус» (D87) — в форме операции и в оплате платежа, запись не блокирует', (tester) async {
    final f = await pumpApp(
      tester,
      size: const Size(360, 732),
      home: Scaffold(
        body: Builder(
          builder: (context) => Column(children: [
            FilledButton(onPressed: () => showAddTransactionSheet(context), child: const Text('add')),
            FilledButton(
              onPressed: () => showPayDueSheet(context, AppScope.of(context).state.dueItems(AppScope.of(context).state.monthEnd).first),
              child: const Text('pay'),
            ),
          ]),
        ),
      ),
    );
    final s = f.state; // на счёте 100 000 ₸
    await s.upsert('planned', 'rent', {'name': 'Аренда', 'amount': '${kzt(150000)}', 'day': 29, 'category': 'home', 'paid': []});

    await tester.tap(find.text('add'));
    await tester.pumpAndSettle();
    expect(find.textContaining('уйдёт в минус'), findsNothing);
    await tester.enterText(find.byType(TextField).first, '120000');
    await tester.pump();
    expect(find.textContaining('уйдёт в минус на 20'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '90000');
    await tester.pump();
    expect(find.textContaining('уйдёт в минус'), findsNothing);
    Navigator.pop(tester.element(find.byType(BottomSheet)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('pay'));
    await tester.pumpAndSettle();
    expect(find.textContaining('уйдёт в минус на 50'), findsOneWidget, reason: 'платёж 150 000 ₸ при 100 000 ₸ на счёте');
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Оплатить').last);
    await tester.pumpAndSettle();
    expect(s.ledger.balance('cash'), -kzt(50000), reason: 'предупреждение не мешает записать');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('счёт в минусе (D87): карточка на главной просит пояснение и показывает его', (tester) async {
    final f = await pumpApp(tester, home: const Shell(), size: const Size(360, 732));
    final s = f.state;
    await s.addExpense(amount: kzt(110000), category: 'home', account: 'cash', date: s.today);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.scrollUntilVisible(find.textContaining('в минусе на'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.textContaining('«Kaspi Gold» в минусе на 10'), findsOneWidget);
    expect(find.textContaining('Почему так вышло?'), findsOneWidget);
    await s.setMinusNote('cash', 'Овердрафт до зарплаты');
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Ваше пояснение: Овердрафт до зарплаты'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2)); // дать догореть таймерам прокрутки
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
    expect(tester.takeException(), isNull, reason: 'диалог с четырьмя кнопками не должен переполняться');
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Отмена')));
    await tester.pumpAndSettle();
    expect(find.text('Записать операцию'), findsOneWidget);
    expect(s.ledger.balance('cash'), kzt(96000));

    // «Запланированная» — сохранено, но в лимит не входит.
    await tester.tap(find.widgetWithText(FilledButton, 'Сохранить'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Запланированная'));
    await tester.pumpAndSettle();
    expect(find.text('Записать операцию'), findsNothing);
    expect(s.ledger.balance('cash'), kzt(90000));
    expect(s.spentToday(), kzt(4000), reason: 'запланированная покупка в лимит не вошла');
    expect(s.userTransactions.first.meta['plannedPurchase'], isTrue);

    // «Непредвиденная» (D101) — тоже вне лимита, но со своей отметкой; копилок
    // нет, поэтому покрыть из копилки не предлагается.
    await enter('7000');
    await tester.tap(find.text('Непредвиденная'));
    await tester.pumpAndSettle();
    expect(find.text('Покрыть из копилки?'), findsNothing);
    expect(s.ledger.balance('cash'), kzt(83000));
    expect(s.spentToday(), kzt(4000), reason: 'непредвиденная трата в лимит не вошла');
    expect(s.spentUnexpectedBetween(s.today, s.today), kzt(7000));
    expect(s.userTransactions.first.meta['unexpected'], isTrue);
    expect(s.userTransactions.first.meta.containsKey('plannedPurchase'), isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('карточка push на главной: при статусе off есть кнопка «Включить уведомления» и строка не ломается', (tester) async {
    debugPushStatusOverride = 'off';
    addTearDown(() => debugPushStatusOverride = null);
    await pumpApp(tester, home: const Shell(), size: const Size(360, 732));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Уведомления на устройстве'), findsOneWidget);
    expect(find.text('Позже'), findsOneWidget);
    expect(find.text('Включить уведомления'), findsOneWidget, reason: 'кнопка включения рядом с «Позже» (на Mac её не было: кнопка с минимальной шириной «во всю строку» внутри Row)');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('плитка: долгое нажатие записывает другую сумму, плитка не меняется (D106)', (tester) async {
    final f = await pumpApp(tester, home: const Shell(), size: const Size(360, 732));
    final s = f.state;
    await s.upsert('quick', 'q1', QuickAction('', 'Кофе', 'cafe', kzt(1590)).toJson());
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Удерживайте плитку, чтобы записать другую сумму'), findsOneWidget);
    await tester.longPress(find.text('Кофе'));
    await tester.pump(const Duration(seconds: 1)); // главная анимирует фон — pumpAndSettle не дождётся
    final sheet = find.byType(BottomSheet);
    expect(find.descendant(of: sheet, matching: find.text('Настроить плитку')), findsOneWidget);
    await tester.enterText(find.descendant(of: sheet, matching: find.byType(TextField)), '2300');
    await tester.tap(find.descendant(of: sheet, matching: find.text('Записать')));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    final tx = s.userTransactions.first;
    expect(tx.type, EventType.expense);
    expect(tx.postings.firstWhere((p) => p.accountId == 'expense:cafe').amount, kzt(2300));
    expect(tx.meta['note'], 'Кофе');
    expect(s.quickActions.single.amount, kzt(1590), reason: 'сумма плитки не изменилась');
    expect(find.text('Удерживайте плитку, чтобы записать другую сумму'), findsNothing, reason: 'подсказка показана один раз');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('своя категория со смайликом (D107): смайлик вместо значка в журнале и в плитке', (tester) async {
    final f = await pumpApp(tester, home: const Shell(), size: const Size(360, 732));
    final s = f.state;
    final id = await s.addCategory(name: 'Сигареты', iconIndex: 0, income: false, emoji: '🚬');
    expect(categoryById(id).hasEmoji, isTrue);
    await s.upsert('quick', 'q1', QuickAction('', 'Пачка', id, kzt(1270)).toJson());
    await s.addExpense(amount: kzt(1270), category: id, account: 'cash', date: s.today, note: 'пачка');
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('🚬'), findsWidgets, reason: 'смайлик рисуется и на плитке, и в последних операциях');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('сверка месяца (D75): карточка на главной, итоги и вопросы сразу, «Подтвердить сверку» снимает карточку', (tester) async {
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
    await tester.scrollUntilVisible(find.text('1. Остатки на счетах'), 150, scrollable: find.byType(Scrollable).first);
    expect(find.text('1. Остатки на счетах'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Совпадает'), 150, scrollable: find.byType(Scrollable).first);
    await Scrollable.ensureVisible(tester.element(find.text('Совпадает')), alignment: .5);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.text('Совпадает'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.scrollUntilVisible(find.text('2. Платежи месяца'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('2. Платежи месяца'), findsOneWidget);
    expect(find.text('3. Текущие планы'), findsNothing);

    await tester.scrollUntilVisible(find.text('Подтвердить сверку'), 300, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Подтвердить сверку'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    expect(s.isMonthClosed(DateTime(2026, 9, 1)), isTrue);
    expect(find.text('Сверка сохранена. Остатки на конец месяца зафиксированы.', skipOffstage: false), findsOneWidget);
    expect(tester.takeException(), isNull);

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
    for (var i = 0; i < 7; i++) {
      await next(); // кредиты, платежи, люди, дневной лимит, лимиты, цель → уведомления
    }
    expect(find.text('Шаг 10 из 11'), findsOneWidget);
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
    await next(); // 11. сводка
    expect(find.text('Шаг 11 из 11'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Начать учёт'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));

    expect(s.onboarded, isTrue);
    expect(f.notif, {'morning': true, 'evening': false, 'month': true}, reason: 'выбор из анкеты сохранён на сервере');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Telegram: повторное нажатие не создаёт второй вход; ожидание и код готовы до перехода', (tester) async {
    final f = await pumpApp(tester, home: const LoginScreen(), size: const Size(390, 844));
    final settings = AppScope.of(tester.element(find.byType(LoginScreen))).settings;
    final gate = Completer<void>();
    f.tgStartGate = gate.future;
    var launches = 0;
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'launch') {
        launches++;
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.textContaining('Start'), findsOneWidget);
        expect(settings.pendingTelegramLogin?.code, 'logincode1234');
        expect(call.arguments['url'], 'https://t.me/famcoin_test_bot?start=login_logincode1234');
      }
      return true;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

    await tester.tap(find.text('Войти через Telegram'));
    await tester.tap(find.text('Войти через Telegram'));
    await tester.pump();
    expect(f.tgStarts, 1);
    expect(launches, 0);
    gate.complete();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(launches, 1);
    await tester.tap(find.text('Отмена'));
    await tester.pump(const Duration(milliseconds: 600));
    expect(settings.pendingTelegramLogin, isNull);
    expect(tester.takeException(), isNull);
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

  testWidgets('«Ещё»: без дублирующих входов в голос, консультант и чек', (tester) async {
    await pumpApp(tester, home: const MoreScreen(), size: const Size(360, 732));
    expect(find.text('Чек'), findsNothing);
    expect(find.text('скоро'), findsNothing);
    expect(find.text('Голос'), findsNothing);
    expect(find.text('ИИ-консультант'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('консультант (D82): вопрос уходит со сводкой показателей, ответ и остаток квоты видны; ошибка — с повтором тем же id', (tester) async {
    final f = await pumpApp(
      tester,
      size: const Size(360, 732),
      home: Builder(builder: (context) => TextButton(onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const AiScreen())), child: const Text('open'))),
    );
    f.billingPlan = 'pro';
    f.aiLimit = 3;
    await f.state.load();
    await f.state.addExpense(amount: kzt(1500), category: 'cafe', account: 'cash', date: f.state.today, note: 'Латте');
    await f.state.addIncome(amount: kzt(8000), source: 'side', account: 'cash', date: f.state.today, note: 'уроки');
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.textContaining('отправляются сервису ИИ'), findsOneWidget);
    expect(find.text('Осталось вопросов в этом месяце: 3 из 3'), findsOneWidget);

    f.aiDown = true;
    await tester.enterText(find.byType(TextField), 'Сколько ушло на кафе?');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();
    expect(find.textContaining('Консультант сейчас недоступен'), findsOneWidget);
    expect(find.text('Осталось вопросов в этом месяце: 3 из 3'), findsOneWidget);

    f.aiDown = false;
    await tester.tap(find.text('Повторить'));
    await tester.pumpAndSettle();
    expect(find.text('Ответ на «Сколько ушло на кафе?»'), findsOneWidget);
    expect(find.text('Осталось вопросов в этом месяце: 2 из 3'), findsOneWidget);
    expect(f.aiRequests[0]['requestId'], f.aiRequests[1]['requestId'], reason: 'повтор — та же отправка');
    final context = f.aiRequests.last['context'] as Map<String, dynamic>;
    expect((context['thisMonth'] as Map)['expense'], 1500, reason: 'суммы уходят в тенге');
    expect((context['expenseByCategory'] as List).first, containsPair('name', 'Кафе'));
    expect(context['dailyLimit'], isNull, reason: 'лимит не задан — так и передаём, а не ноль');
    expect(context['recordedIncome'], containsPair('looksIncomplete', false));
    expect(context.containsKey('userFirstName'), isTrue);
    expect(context['operationsToday'], [containsPair('category', 'Кафе')], reason: 'консультант видит операции (D86), разложенные по дням (D91)');
    expect((context['operationsToday'] as List).single, allOf(containsPair('amount', 1500), containsPair('account', 'Kaspi Gold'), containsPair('type', 'expense'), containsPair('note', 'Латте')));
    for (final day in ['operationsYesterday', 'operationsDayBeforeYesterday', 'operationsEarlier']) {
      expect(context[day], isEmpty, reason: 'пустой день — явный пустой список ($day)');
    }
    // Доход — не трата: в дневных списках его нет, он в своём списке с датой (D100).
    expect((context['incomes'] as List).single, allOf(containsPair('type', 'income'), containsPair('amount', 8000), containsPair('note', 'уроки'), contains('date')));
    expect(context['tracking'], containsPair('daysOfHistory', 1), reason: 'учёт начат сегодня — консультант это видит');
    expect((context['monthEndBalanceForecast'] as Map)['roughEstimate'], isNotNull);
    // Слагаемые прогноза нужны для сценариев «а если»: итог сходится с их суммой.
    final fc = context['monthEndBalanceForecast'] as Map;
    expect(fc['estimate'], closeTo((fc['freeMoneyNow'] as num) - (fc['unpaidPaymentsUntilMonthEnd'] as num) - (fc['expectedRegularSpendUntilMonthEnd'] as num) + (fc['expectedIncomeUntilMonthEnd'] as num), 1), reason: 'estimate = слагаемые');
    expect(fc['daysLeftInMonth'], isA<int>());
    expect((context['observations'] as Map)['incomeDaySpendRatio'], isNull, reason: 'меньше трёх доходов — не закономерность');
    expect(context.keys.where((k) => k.toLowerCase().contains('birth') || k.toLowerCase().contains('lastname')), isEmpty, reason: 'кроме имени, личных данных в сводке нет');
    expect(tester.takeException(), isNull);

    // Сумма, которую сервер не смог подтвердить данными, — с пометкой (D91, D93).
    f.aiUnverified = ['50 100 ₸'];
    await tester.enterText(find.byType(TextField), 'Сколько накоплю за 3 месяца?');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();
    expect(find.textContaining('не удалось подтвердить данными'), findsOneWidget);
    expect(find.textContaining('50\u00A0100'), findsOneWidget);
    f.aiUnverified = const [];
    expect(tester.takeException(), isNull);

    // Кнопки-переходы под ответом (D108): известный id — кнопка, нажатие открывает экран; чужой id не рисуется.
    f.aiActions = ['calendar', 'secret_admin'];
    await tester.enterText(find.byType(TextField), 'Когда следующий платёж?');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();
    f.aiActions = const [];
    expect(find.widgetWithText(ActionChip, 'Календарь платежей'), findsOneWidget);
    expect(find.byType(ActionChip), findsOneWidget, reason: 'неизвестный id не превращается в кнопку');
    await tester.tap(find.widgetWithText(ActionChip, 'Календарь платежей'));
    await tester.pumpAndSettle();
    expect(find.byType(CalendarScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
    Navigator.of(tester.element(find.byType(CalendarScreen))).pop();
    await tester.pumpAndSettle();

    // Меню: что видит консультант и разбор прошлого месяца (составляется один раз).
    await tester.tap(find.byType(PopupMenuButton<VoidCallback>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Что видит консультант'));
    await tester.pumpAndSettle();
    expect(find.textContaining('"expenseByCategory"'), findsOneWidget);
    Navigator.pop(tester.element(find.textContaining('"expenseByCategory"')));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<VoidCallback>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Разбор: Август 2026'));
    await tester.pumpAndSettle();
    expect(find.text('Составить разбор'), findsOneWidget);
    await tester.tap(find.text('Составить разбор'));
    await tester.pumpAndSettle();
    expect(find.text('Разбор за 2026-08'), findsOneWidget);
    expect((f.aiRequests.last['context'] as Map)['period'], containsPair('month', '2026-08'));
    expect(tester.takeException(), isNull);
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
