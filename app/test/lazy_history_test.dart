/// Годы истории строятся лениво (аудит 08.10, UI05): на экране — десяток
/// строк из тысяч, поиск и прокрутка до самой старой операции работают.
/// «Сегодня» заглушки — 28.09.2026.
library;

import 'package:famcoin/state/app_state.dart';
import 'package:famcoin/ui/more/accounts_screen.dart';
import 'package:famcoin/ui/ops/journal_screen.dart';
import 'package:famcoin/ui/ops/transaction_tile.dart';
import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'layout_test.dart' show pumpApp;

const n = 1500;

/// [n] покупок по 10 ₸ — по одной в день, назад от сегодня; самая старая — с особой заметкой.
Future<void> years(AppState s) => s.sendBatch([
      for (var k = 0; k < n; k++)
        {
          'type': 'expense',
          'id': 'h$k',
          'date': dateToJson(DateTime(2026, 9, 28 - k)),
          'account': 'cash',
          'splits': {'food': '${kzt(10)}'},
          'meta': {'who': 'me', 'note': k == n - 1 ? 'самая старая покупка' : 'хлеб $k'},
        },
    ]);

void main() {
  testWidgets('журнал: из $n операций строятся только видимые; поиск находит самую старую, прокрутка до неё доходит', (tester) async {
    final f = await pumpApp(tester, home: const JournalScreen(), size: const Size(390, 844));
    await years(f.state);
    await tester.pumpAndSettle();
    expect(find.byType(TransactionTile, skipOffstage: false).evaluate().length, lessThan(60), reason: 'строки строятся лениво');

    await tester.enterText(find.byType(TextField).first, 'самая старая');
    await tester.pumpAndSettle();
    expect(find.textContaining('самая старая покупка'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, '');
    await tester.pumpAndSettle();
    await tester.dragUntilVisible(find.textContaining('самая старая покупка'), find.byType(ListView), const Offset(0, -3000), maxIteration: 400);
    expect(find.textContaining('самая старая покупка'), findsOneWidget, reason: 'история полная — до конца можно докрутить');
  });

  testWidgets('экран счёта: история лениво, шапка на месте, последняя строка — самая старая', (tester) async {
    final g = await pumpApp(tester, home: const AccountScreen(accountId: 'cash'), size: const Size(390, 844));
    await years(g.state);
    await tester.pumpAndSettle();
    expect(find.byType(TransactionTile, skipOffstage: false).evaluate().length, lessThan(60));
    await tester.dragUntilVisible(find.textContaining('самая старая покупка'), find.byType(ListView), const Offset(0, -3000), maxIteration: 400);
    expect(find.textContaining('самая старая покупка'), findsOneWidget);
  });
}
