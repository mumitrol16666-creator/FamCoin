import 'package:famcoin/ui/home/home_screen.dart';
import 'package:famcoin/ui/analytics/analytics_screen.dart';
import 'package:famcoin/ui/analytics/overview_tab.dart';
import 'package:famcoin/ui/more/more_screen.dart';
import 'package:famcoin/ui/more/ai_screen.dart';
import 'package:famcoin/ui/shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'layout_test.dart' show pumpApp;

void main() {
  testWidgets('нижняя панель открывает Аналитику; Бюджет внутри, без дубля в Ещё', (tester) async {
    await pumpApp(tester, home: const Shell(), size: const Size(390, 844));
    final nav = find.byWidgetPredicate((w) => w is Material && w.child is SafeArea);
    final analytics = find.descendant(of: nav, matching: find.text('Аналитика'));
    expect(analytics, findsOneWidget);
    expect(find.descendant(of: nav, matching: find.text('Бюджет')), findsNothing);
    await tester.tap(analytics);
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(AnalyticsScreen), findsOneWidget);
    final budget = find.descendant(of: find.byType(TabBar), matching: find.text('Бюджет'));
    await tester.tap(budget);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Планы, лимиты и будущие платежи').hitTestable(), findsOneWidget);
    await tester.tap(find.text('Открыть отчёт').hitTestable());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(OverviewTab).hitTestable(), findsOneWidget);
    await tester.tap(find.descendant(of: nav, matching: find.text('Ещё')));
    await tester.pump(const Duration(milliseconds: 600));
    for (final label in ['Аналитика', 'Голос', 'ИИ-консультант']) {
      expect(find.descendant(of: find.byType(MoreScreen), matching: find.text(label)), findsNothing);
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final locale in ['ru', 'kk']) {
    testWidgets('ИИ на главной: телефон 320 px, крупный текст, $locale', (tester) async {
      final ai = locale == 'ru' ? 'ИИ-консультант' : 'ЖИ-кеңесші';
      await pumpApp(
        tester,
        home: const Shell(),
        size: const Size(320, 694),
        textScale: 2,
        locale: Locale(locale),
        brightness: locale == 'ru' ? Brightness.light : Brightness.dark,
        prefs: {'season': 'none'},
      );
      final assistant = find.byTooltip(ai);
      expect(assistant, findsOneWidget);
      await tester.tap(assistant);
      await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(AiScreen), findsOneWidget);
      expect(find.byType(Dialog), findsNothing, reason: 'на телефоне чат занимает весь экран');
      expect(tester.getSize(find.byType(AiScreen)).width, 320);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byType(BackButton));
      await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(HomeScreen), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('ИИ: боковая панель, отправка вопроса и повторное открытие истории', (tester) async {
    final f = await pumpApp(tester, home: const Shell(), size: const Size(1280, 900), prefs: {'season': 'none'});
    f.billingPlan = 'pro';
    await f.state.load();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.byTooltip('ИИ-консультант'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(Dialog), findsOneWidget);
    expect(tester.getSize(find.byType(AiScreen)).width, 480);
    expect(tester.getTopLeft(find.byType(AiScreen)).dx, 800);
    await tester.enterText(find.descendant(of: find.byType(AiScreen), matching: find.byType(TextField)), 'Куда ушли деньги?');
    await tester.tap(find.byTooltip('Отправить'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Ответ на «Куда ушли деньги?»'), findsOneWidget);
    await tester.tap(find.byType(CloseButton));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.byTooltip('ИИ-консультант'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Ответ на «Куда ушли деньги?»'), findsOneWidget);
    expect(f.aiRequests, hasLength(1), reason: 'открытие панели не отправляет новый вопрос');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
