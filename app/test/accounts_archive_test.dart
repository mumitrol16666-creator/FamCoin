/// D171: архивные счета (копилки реализованных целей) свёрнуты в строку
/// «Архив · N» внизу списка счетов и раскрываются по нажатию.
library;

import 'package:famcoin/ui/more/accounts_screen.dart';
import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'layout_test.dart' show pumpApp;

void main() {
  testWidgets('архив свёрнут по умолчанию, раскрывается кнопкой; без архива кнопки нет', (tester) async {
    final f = await pumpApp(tester, home: const AccountsScreen(), size: const Size(390, 1200));
    final s = f.state;
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('accounts-archive')), findsNothing);

    await s.sendBatch(s.newGoalCommands(name: 'Процессор', target: kzt(200000)));
    await s.depositToGoal(s.goals.single, from: 'cash', amount: kzt(10000));
    await s.realizeGoal(s.goals.single, account: 'cash', category: 'other', amount: kzt(10000));
    await tester.pumpAndSettle();
    expect(find.text('Архив · 1'), findsOneWidget);
    expect(find.text('Процессор'), findsNothing, reason: 'копилка реализованной цели спрятана');

    await tester.tap(find.byKey(const ValueKey('accounts-archive')));
    await tester.pumpAndSettle();
    expect(find.text('Процессор'), findsOneWidget);
    expect(find.textContaining('в архиве'), findsOneWidget);
  });
}
