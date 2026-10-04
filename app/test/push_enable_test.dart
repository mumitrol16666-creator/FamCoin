import 'dart:async';

import 'package:famcoin/state/app_scope.dart';
import 'package:famcoin/state/push.dart';
import 'package:famcoin/ui/shell.dart';
import 'package:famcoin/ui/widgets/push_enable.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'layout_test.dart' show pumpApp;

void main() {
  setUp(() {
    debugPushStatusOverride = 'off';
    debugPushPermissionOverride = () async => 'granted';
    debugPushEnableOverride = (_) async => {'endpoint': 'https://push.example.test/1', 'p256dh': 'test', 'auth': 'test'};
    debugPushConfirmOverride = () => debugPushStatusOverride = 'on';
  });
  tearDown(() {
    debugPushStatusOverride = null;
    debugPushPermissionOverride = null;
    debugPushEnableOverride = null;
    debugPushConfirmOverride = null;
  });

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
  }

  testWidgets('разрешение до сети; успех только после сервера, плашка уходит сразу', (tester) async {
    final f = await pumpApp(tester, home: const Shell(), size: const Size(1280, 900));
    var asked = false;
    debugPushPermissionOverride = () {
      asked = true;
      expect(f.pushKeyCalls, 0);
      expect(f.pushSubscribeCalls, 0);
      return Future.value('granted');
    };
    await tester.ensureVisible(find.text('Включить уведомления'));
    await tester.tap(find.text('Включить уведомления'));
    expect(asked, isTrue);
    await settle(tester);
    expect(f.pushSubscribeCalls, 1);
    expect(find.text('Включить уведомления'), findsNothing);
    expect(find.text('Уведомления на устройстве'), findsNothing);
    expect(find.text('Уведомления включены на этом устройстве.'), findsOneWidget);
    final settings = AppScope.of(tester.element(find.byType(Shell))).settings;
    expect(settings.pushPromptDismissed, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final permission in ['denied', 'default']) {
    testWidgets('$permission: нет ложного успеха и запросов на сервер', (tester) async {
      debugPushPermissionOverride = () async => permission;
      final f = await pumpApp(tester, home: const Shell(), size: const Size(390, 844));
      await tester.ensureVisible(find.text('Включить уведомления'));
      await tester.tap(find.text('Включить уведомления'));
      await settle(tester);
      expect(f.pushKeyCalls, 0);
      expect(f.pushSubscribeCalls, 0);
      expect(find.text('Включить уведомления'), findsOneWidget);
      expect(find.textContaining(permission == 'denied' ? 'заблокированы' : 'Разрешение не получено'), findsOneWidget);
      expect(AppScope.of(tester.element(find.byType(Shell))).settings.pushPromptDismissed, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('ошибка сохранения подписки оставляет повтор; после повтора плашка уходит', (tester) async {
    final f = await pumpApp(tester, home: const Shell(), size: const Size(390, 844));
    f.pushSubscribeFails = true;
    var confirmed = 0;
    debugPushConfirmOverride = () => confirmed++;
    await tester.ensureVisible(find.text('Включить уведомления'));
    await tester.tap(find.text('Включить уведомления'));
    await settle(tester);
    expect(confirmed, 0);
    expect(find.textContaining('Не удалось подключить уведомления'), findsOneWidget);
    expect(AppScope.of(tester.element(find.byType(Shell))).settings.pushPromptDismissed, isFalse);
    f.pushSubscribeFails = false;
    await tester.tap(find.text('Включить уведомления'));
    await settle(tester);
    expect(f.pushSubscribeCalls, 2);
    expect(confirmed, 1);
    expect(find.text('Уведомления на устройстве'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('кнопка показывает ожидание и не отправляет повторные запросы', (tester) async {
    final permission = Completer<String>();
    var calls = 0;
    debugPushPermissionOverride = () { calls++; return permission.future; };
    await pumpApp(tester, home: const Scaffold(body: SingleChildScrollView(child: PushEnableSection())), size: const Size(320, 694), textScale: 2);
    await tester.tap(find.text('Включить уведомления'));
    await tester.pump();
    expect(find.text('Подключаем уведомления…'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Подключаем уведомления…')).onPressed, isNull);
    expect(calls, 1);
    permission.complete('default');
    await settle(tester);
    expect(find.textContaining('Разрешение не получено'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Позже скрывает плашку без переходов и перезагрузки', (tester) async {
    await pumpApp(tester, home: const Shell(), size: const Size(1280, 900));
    await tester.tap(find.text('Позже'));
    await settle(tester);
    expect(find.text('Уведомления на устройстве'), findsNothing);
    expect(find.text('Включить уведомления'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
