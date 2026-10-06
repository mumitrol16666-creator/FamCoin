/// Плашка «Скачайте приложение» для сайта на Android.
library;

import 'package:famcoin/state/app_scope.dart';
import 'package:famcoin/ui/widgets/install_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'layout_test.dart' show pumpApp;

void main() {
  test('условие показа: только сайт в браузере на Android, не установленный на экран Домой, не закрытый', () {
    bool show({bool web = true, bool android = true, bool standalone = false, bool dismissed = false}) =>
        shouldShowInstallBanner(web: web, androidBrowser: android, standalone: standalone, dismissed: dismissed);
    expect(show(), isTrue);
    expect(show(web: false), isFalse, reason: 'в самом приложении ставить нечего');
    expect(show(android: false), isFalse, reason: 'iPhone и компьютер');
    expect(show(standalone: true), isFalse, reason: 'уже открыт как приложение');
    expect(show(dismissed: true), isFalse);
  });

  test('ссылка ведёт на APK нашего сервера', () {
    expect(apkUrl, endsWith('/download/famcoin.apk'));
    expect(apkUrl, isNot(contains('/api/')));
  });

  testWidgets('плашка видна на Android в браузере, «Позже» прячет её насовсем', (tester) async {
    await pumpApp(tester, size: const Size(390, 844), home: const Scaffold(body: InstallBanner(web: true, androidBrowser: true, standalone: false)));
    expect(find.textContaining('Скачайте приложение для Android'), findsOneWidget);
    expect(find.text('Скачать'), findsOneWidget);
    final settings = AppScope.of(tester.element(find.byType(InstallBanner))).settings;
    await tester.tap(find.text('Позже'));
    await tester.pumpAndSettle();
    expect(settings.installBannerDismissed, isTrue);
    expect(find.textContaining('Скачайте приложение для Android'), findsNothing);
  });

  for (final c in [('не Android', false, false), ('установлен на экран Домой', true, true)]) {
    testWidgets('плашки нет: ${c.$1}', (tester) async {
      await pumpApp(tester, size: const Size(390, 844), home: Scaffold(body: InstallBanner(web: true, androidBrowser: c.$2, standalone: c.$3)));
      expect(find.textContaining('Скачайте приложение для Android'), findsNothing);
    });
  }

  testWidgets('на 320 px и тексте 200 % — без переполнений', (tester) async {
    await pumpApp(tester, size: const Size(320, 694), textScale: 2, home: const Scaffold(body: InstallBanner(web: true, androidBrowser: true, standalone: false)));
    expect(tester.takeException(), isNull);
  });
}
