/// Пакет В из docs/ux-gaps-2026-10-05.md: шаг «сколько в день» в анкете,
/// «Как устроен FamCoin», пояснения у форм и отчётов. «Сегодня» заглушки —
/// 28.09.2026, на счёте `cash` 100 000 ₸.
library;

import 'package:famcoin/l10n/app_localizations_ru.dart';
import 'package:famcoin/state/app_scope.dart';
import 'package:famcoin/ui/analytics/overview_tab.dart';
import 'package:famcoin/ui/budget/budget_forecast_card.dart';
import 'package:famcoin/ui/budget/sheets.dart';
import 'package:famcoin/ui/more/guide_screen.dart';
import 'package:famcoin/ui/more/more_screen.dart';
import 'package:famcoin/ui/onboarding/onboarding_screen.dart';
import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'layout_test.dart' show pumpApp;
import 'ux_gaps_a_test.dart' show openForm, pumpForm, pumpWith, tapText;

void main() {
  group('анкета: шаг «Сколько тратить в день на мелочи?»', () {
    Future<void> next(WidgetTester tester) async {
      await tester.tap(find.widgetWithText(FilledButton, 'Продолжить'));
      await tester.pumpAndSettle();
    }

    Future<void> toDailyStep(WidgetTester tester) async {
      await tester.enterText(find.byType(TextField).first, 'Тест');
      await tester.pump();
      await next(tester); // режим
      await next(tester); // счёт
      await tester.enterText(find.byType(TextField).at(1), '100000');
      await tester.pump();
      for (var i = 0; i < 4; i++) {
        await next(tester); // кредиты, платежи, люди → дневной лимит
      }
    }

    testWidgets('сумма из анкеты становится дневным лимитом с историей и датой начала', (tester) async {
      final f = await pumpApp(tester, home: const OnboardingScreen(), size: const Size(390, 844));
      final s = f.state;
      await toDailyStep(tester);
      expect(find.text('Шаг 7 из 11'), findsOneWidget);
      expect(find.text('Сколько тратить в день на мелочи?'), findsOneWidget);
      expect(find.textContaining('Крупные покупки сюда не входят'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, '5000');
      await tester.pump();
      for (var i = 0; i < 4; i++) {
        await next(tester); // лимиты, цель, уведомления → сводка
      }
      await tester.tap(find.widgetWithText(FilledButton, 'Начать учёт'));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
      expect(s.onboarded, isTrue);
      expect(s.dailyLimit, kzt(5000));
      expect(s.dailyLimitSince, s.today);
      expect(s.dailyLimitHistory.single.amount, kzt(5000));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('шаг можно пропустить — лимит не задан, как раньше', (tester) async {
      final f = await pumpApp(tester, home: const OnboardingScreen(), size: const Size(390, 844));
      await toDailyStep(tester);
      for (var i = 0; i < 4; i++) {
        await next(tester);
      }
      await tester.tap(find.widgetWithText(FilledButton, 'Начать учёт'));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
      expect(f.state.onboarded, isTrue);
      expect(f.state.dailyLimit, isNull);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('«Как устроен FamCoin»', () {
    testWidgets('есть в «Ещё», семь карточек, кнопка ведёт в нужное место', (tester) async {
      await pumpApp(tester, home: const MoreScreen(), size: const Size(390, 844));
      await tester.tap(find.text('Как устроен FamCoin'));
      await tester.pumpAndSettle();
      expect(find.byType(GuideScreen), findsOneWidget);
      for (final title in [
        'Записывайте деньги одним нажатием',
        'Сколько можно потратить сегодня',
        'Лимиты на категории',
        'Платежи и рассрочки',
        'Копилки и разовые покупки',
        'Кредиты и личные долги',
        'Сверка с банком',
      ]) {
        await tester.scrollUntilVisible(find.text(title), 200, scrollable: find.byType(Scrollable).first);
        expect(find.text(title), findsOneWidget);
      }
      await tester.scrollUntilVisible(find.text('Записать ›'), -200, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('Записать ›'));
      await tester.pumpAndSettle();
      expect(find.text('Записать операцию'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('на 320 px и тексте 200 % — без переполнений', (tester) async {
      await pumpApp(tester, home: const GuideScreen(), size: const Size(320, 694), textScale: 2);
      for (var i = 0; i < 6; i++) {
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -500));
        await tester.pump();
      }
      expect(tester.takeException(), isNull);
    });
  });

  group('пояснения у форм', () {
    testWidgets('«Расход» и «Доход»: справка про переводы и про долги', (tester) async {
      await pumpForm(tester);
      await openForm(tester);
      await tester.tap(find.byTooltip('Что такое расход'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Снять наличные, положить на карту'), findsOneWidget);
      await tester.tap(find.text('Понятно'));
      await tester.pumpAndSettle();
      await tapText(tester, 'Доход');
      await tester.tap(find.byTooltip('Что такое доход'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Деньги, взятые в долг, это не доход'), findsOneWidget);
    });

    testWidgets('форма лимита на категорию объясняет, что он месячный и чем отличается от дневного', (tester) async {
      await pumpWith(tester, (c) => addLimitFlow(c));
      await openForm(tester);
      expect(find.textContaining('Лимит на месяц для этой категории'), findsOneWidget);
      expect(find.textContaining('Это не дневной лимит'), findsOneWidget);
    });

    testWidgets('форма счёта: подпись типа меняется, депозит не входит в остаток', (tester) async {
      final f = await pumpWith(tester, (c) => addAccountFlow(c));
      f.billingPlan = 'pro';
      await f.state.load();
      await openForm(tester);
      expect(find.textContaining('Банковская карта или счёт'), findsOneWidget);
      expect(find.textContaining('отправная точка, не доход'), findsOneWidget);
      await tapText(tester, 'Депозит');
      expect(find.textContaining('Депозит или вклад: деньги не входят'), findsOneWidget);
      await tapText(tester, 'Наличные');
      expect(find.textContaining('Наличные дома или в кошельке'), findsOneWidget);
    });
  });

  group('отчёты', () {
    testWidgets('«Дал в долг» и «Мне вернули долг» видны в итогах месяца отдельно от доходов и расходов', (tester) async {
      final f = await pumpApp(
        tester,
        home: Scaffold(body: Builder(builder: (c) => ListenableBuilder(listenable: AppScope.of(c).state, builder: (c, _) => OverviewTab(offset: 0, onOffset: (_) {}, selectedDay: null, onSelectDay: (_) {})))),
        size: const Size(390, 844),
      );
      final s = f.state;
      await s.addPersonDebt(kind: 'lendOut', amount: kzt(50000), person: 'Друг', account: 'cash', date: DateTime(2026, 9, 20));
      await s.addPersonDebt(kind: 'repaymentReceived', amount: kzt(20000), person: 'Друг', account: 'cash', date: DateTime(2026, 9, 25));
      await tester.pump(const Duration(milliseconds: 500));
      // Сумма в тексте идёт с неразрывным пробелом.
      String shown(String start) => tester.widgetList<Text>(find.textContaining(start)).single.data!.replaceAll('\u00A0', ' ');
      expect(shown('Дал в долг:'), 'Дал в долг: 50 000 ₸');
      expect(shown('Мне вернули долг:'), 'Мне вернули долг: 20 000 ₸');
      expect(s.monthReport.income, 0);
      expect(s.monthReport.expense, 0);
    });

    testWidgets('карточка прогноза имеет справку', (tester) async {
      await pumpApp(tester, home: const Scaffold(body: BudgetForecastCard()), size: const Size(390, 844));
      await tester.tap(find.byTooltip('Как считается прогноз'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Деньги на счетах сейчас минус платежи'), findsOneWidget);
    });
  });

  group('тексты', () {
    test('сверка месяца называется одинаково: «пара вопросов», без «5 минут» и «15 минут»', () {
      final l = AppLocalizationsRu();
      expect(l.monthCardBody('1', '2'), isNot(contains('5 минут')));
      expect(l.adviceAppMonthClose, isNot(contains('15 минут')));
      expect(l.adviceAppMonthClose, isNot(contains('четыре')));
      expect(l.dailyLimitHintMonth('5 000 ₸'), contains('до конца месяца'));
      expect(l.noPlanned, isNot(contains('отложит')));
    });
  });
}
