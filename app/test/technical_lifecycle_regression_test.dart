import 'package:famcoin/state/api_client.dart';
import 'package:famcoin/ui/ops/journal_screen.dart';
import 'package:famcoin/ui/ops/transaction_tile.dart';
import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'layout_test.dart' show pumpApp;

void main() {
  testWidgets('C01/T02 корзина после двух удалений восстанавливает один факт', (tester) async {
    final f = await pumpApp(tester, home: const JournalScreen(), size: const Size(430, 900));
    final s = f.state;
    await s.send({'type': 'expense', 'id': 'purchase', 'date': '2026-09-28',
      'account': 'cash', 'splits': {'cafe': '${kzt(10000)}'}});
    await s.deleteTransaction('purchase');
    await s.restoreTransaction('purchase');
    final restored = s.ledger.transactions.singleWhere((t) => t.meta['restoredFrom'] == 'purchase');
    await s.deleteTransaction(restored.id);
    await s.load();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Удалённые'));
    await tester.pumpAndSettle();
    expect(find.byType(TransactionTile), findsOneWidget);
    expect(s.deletedTransactions.single.id, restored.id);
    await tester.tap(find.byType(TransactionTile));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Восстановить'));
    await tester.tap(find.widgetWithText(FilledButton, 'Восстановить'));
    await tester.pumpAndSettle();
    expect(find.text('Удалённых операций нет'), findsOneWidget);
    expect(s.ledger.balance('cash'), kzt(90000));
    expect(s.monthReport.expense, kzt(10000));
    await expectLater(s.restoreTransaction('purchase'),
        throwsA(isA<ApiException>().having((e) => e.code, 'code', 'ledger')
            .having((e) => e.ledgerCode, 'ledgerCode', 'alreadyRestored')
            .having((e) => e.status, 'status', 422)));
    await s.load();
    expect(s.ledger.balance('cash'), kzt(90000));
    expect(s.monthReport.expense, kzt(10000));
    expect(s.deletedTransactions, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    s.dispose();
  });
}
