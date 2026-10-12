/// D167, часть 6: переключатели сигналов, платежей и напоминания записать
/// на экране уведомлений — включены по умолчанию, выключение уходит на сервер.
library;

import 'package:famcoin/ui/more/notifications_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'layout_test.dart' show pumpApp;

void main() {
  testWidgets('три новых переключателя включены; выключение «Платежи» сохраняется на сервере', (tester) async {
    final f = await pumpApp(tester, home: const NotificationsScreen(), size: const Size(390, 1800));
    await tester.pumpAndSettle();
    for (final title in ['Сигналы о лимитах', 'Платежи', 'Напоминание записать']) {
      expect(find.text(title), findsOneWidget);
      final tile = tester.widget<SwitchListTile>(find.ancestor(of: find.text(title), matching: find.byType(SwitchListTile)));
      expect(tile.value, isTrue, reason: '$title включён по умолчанию');
    }
    expect(find.textContaining('по воскресеньям итоги недели'), findsOneWidget);
    await tester.tap(find.text('Платежи'));
    await tester.pumpAndSettle();
    expect(f.notif['payments'], isFalse);
    final tile = tester.widget<SwitchListTile>(find.ancestor(of: find.text('Платежи'), matching: find.byType(SwitchListTile)));
    expect(tile.value, isFalse);
    expect(f.notif.containsKey('signals'), isFalse, reason: 'остальные не трогали');
  });
}
