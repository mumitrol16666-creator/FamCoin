/// Приветствие после входа и два уровня настройки: «Быстрый старт» (имя, счёт,
/// дневной лимит) и «Подробная настройка» (вся анкета).
library;

import 'package:famcoin/ui/onboarding/welcome_screen.dart';
import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'layout_test.dart' show pumpApp;

void main() {
  Future<void> next(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(FilledButton, 'Продолжить'));
    await tester.pumpAndSettle();
  }

  testWidgets('после входа — приветствие с двумя входами, без номера шага', (tester) async {
    await pumpApp(tester, home: const OnboardingGate(), size: const Size(360, 732));
    expect(find.text('Добро пожаловать в FamCoin'), findsOneWidget, reason: 'имени нет, а email в приветствие не берём');
    expect(find.text('Быстрый старт'), findsOneWidget);
    expect(find.text('Подробная настройка'), findsOneWidget);
    expect(find.textContaining('Шаг'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('приветствие обращается по имени', (tester) async {
    final f = await pumpApp(tester, home: const OnboardingGate(), size: const Size(360, 732));
    await f.state.send({'type': 'updateProfile', 'profile': {'firstName': 'Айдос', 'lastName': 'Серик'}});
    await tester.pump();
    expect(find.text('Добро пожаловать, Айдос'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('«Быстрый старт»: три шага, лимит и счёт сохраняются, уведомления остаются по умолчанию', (tester) async {
    final f = await pumpApp(tester, home: const OnboardingGate(), size: const Size(390, 844));
    final s = f.state;
    final before = s.ledger.liquid();
    await s.send({'type': 'updateProfile', 'profile': {'onboarded': false}});
    await tester.tap(find.text('Быстрый старт'));
    await tester.pumpAndSettle();
    expect(find.text('Шаг 1 из 3'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'Тест');
    await tester.pump();
    await next(tester);
    expect(find.text('Шаг 2 из 3'), findsOneWidget);
    expect(find.text('Первый денежный счёт'), findsOneWidget);
    await tester.enterText(find.byType(TextField).at(1), '100000');
    await tester.pump();
    await next(tester);

    expect(find.text('Шаг 3 из 3'), findsOneWidget);
    expect(find.text('Сколько тратить в день на мелочи?'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Продолжить'), findsNothing, reason: 'последний шаг — сразу «Начать учёт»');
    await tester.enterText(find.byType(TextField).first, '5000');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Начать учёт'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));

    expect(s.onboarded, isTrue);
    expect(s.firstName, 'Тест');
    expect(s.profile['mode'], 'personal');
    expect(s.dailyLimit, kzt(5000));
    expect(s.ledger.liquid(), before + kzt(100000));
    expect(f.notif, isEmpty, reason: 'шага уведомлений нет — настройки на сервере не трогаем, по умолчанию всё включено');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('«Подробная настройка»: все 11 шагов анкеты', (tester) async {
    await pumpApp(tester, home: const OnboardingGate(), size: const Size(390, 844));
    await tester.tap(find.text('Подробная настройка'));
    await tester.pumpAndSettle();
    expect(find.text('Шаг 1 из 11'), findsOneWidget);
    expect(find.text('Как вас зовут?'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('с первого шага анкеты можно вернуться на приветствие и выбрать другой уровень', (tester) async {
    await pumpApp(tester, home: const OnboardingGate(), size: const Size(390, 844));
    await tester.tap(find.text('Быстрый старт'));
    await tester.pumpAndSettle();
    expect(find.text('Шаг 1 из 3'), findsOneWidget);
    await tester.tap(find.byTooltip('Назад'));
    await tester.pumpAndSettle();
    expect(find.text('Быстрый старт'), findsOneWidget);
    await tester.tap(find.text('Подробная настройка'));
    await tester.pumpAndSettle();
    expect(find.text('Шаг 1 из 11'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('приветствие на узком экране и крупном шрифте — без переполнений', (tester) async {
    await pumpApp(tester, home: const OnboardingGate(), size: const Size(320, 694), textScale: 1.5);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
