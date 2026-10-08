/// Уведомления при сбое связи (аудит 08.10, UI04): вместо вечного индикатора —
/// ошибка и «Повторить»; уже показанная история при сбое обновления остаётся.
library;

import 'package:famcoin/ui/more/notifications_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'layout_test.dart' show pumpApp;

Map<String, Object?> item(String title) =>
    {'id': title, 'kind': 'morning', 'title': title, 'body': 'Текст', 'createdAt': '2026-09-28T03:00:00Z', 'read': true};

void main() {
  testWidgets('ошибка первой загрузки → «Повторить» → история', (tester) async {
    final f = await pumpApp(tester, home: Builder(builder: (c) => FilledButton(onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const NotificationsScreen())), child: const Text('open'))), size: const Size(390, 1600));
    f.notificationItems.add(item('Доброе утро'));
    f.offline = true;
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    expect(find.byType(CircularProgressIndicator), findsNothing, reason: 'запрос завершился — индикатор не крутится вечно');
    expect(find.text('Повторить'), findsOneWidget);
    expect(find.text('Доброе утро'), findsNothing);

    f.offline = false;
    await tester.tap(find.text('Повторить'));
    await tester.pumpAndSettle();
    expect(find.text('Доброе утро'), findsOneWidget);
    expect(find.text('Повторить'), findsNothing);
  });

  testWidgets('сбой обновления при видимой истории: данные остаются, индикатора нет, есть сообщение', (tester) async {
    final f = await pumpApp(tester, home: Builder(builder: (c) => FilledButton(onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const NotificationsScreen())), child: const Text('open'))), size: const Size(390, 1600));
    f.notificationItems.add(item('Доброе утро'));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Доброе утро'), findsOneWidget);

    f.offline = true;
    await tester.fling(find.byType(ListView).first, const Offset(0, 400), 1000);
    await tester.pumpAndSettle();
    expect(find.text('Доброе утро'), findsOneWidget, reason: 'история не пропала');
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Повторить'), findsNothing, reason: 'данные есть — достаточно сообщения');
    expect(find.byType(SnackBar), findsOneWidget);
  });
}
