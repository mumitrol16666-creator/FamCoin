/// Сводка для консультанта: личные долги (D137) — кто кому должен, сколько
/// осталось и вернули, срок; без долгов поле пустое, а не нулевое.
library;

import 'package:famcoin/l10n/app_localizations_ru.dart';
import 'package:famcoin/ui/more/ai_context.dart';
import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'layout_test.dart' show pumpApp;

void main() {
  testWidgets('personDebts: должны мне и должен я, срок, возвращено частями', (tester) async {
    final f = await pumpApp(tester, home: const SizedBox(), size: const Size(390, 844));
    final s = f.state;
    expect(aiChatContext(s, AppLocalizationsRu())['personDebts'], isNull);

    await s.addPersonDebt(kind: 'lendOut', amount: kzt(50000), person: 'Друг', account: 'cash', date: DateTime(2026, 9, 20));
    await s.addPersonDebt(kind: 'repaymentReceived', amount: kzt(20000), person: 'Друг', account: 'cash', date: DateTime(2026, 9, 25));
    await s.addPersonDebt(kind: 'borrow', amount: kzt(30000), person: 'Брат', account: 'cash', date: DateTime(2026, 9, 26), dueDate: s.today.subtract(const Duration(days: 3)));
    await tester.pump();

    final debts = (aiChatContext(s, AppLocalizationsRu())['personDebts'] as List).cast<Map>();
    final friend = debts.singleWhere((d) => d['person'] == 'Друг');
    expect(friend['direction'], 'owesMe');
    expect(friend['balance'], 30000);
    expect(friend['takenInTotal'], 50000);
    expect(friend['returnedInTotal'], 20000);
    expect(friend['dueDate'], isNull);
    expect(friend['overdue'], isFalse);

    final brother = debts.singleWhere((d) => d['person'] == 'Брат');
    expect(brother['direction'], 'iOwe');
    expect(brother['balance'], 30000);
    expect(brother['dueDate'], isNotNull);
    expect(brother['overdue'], isTrue);
    await tester.pumpWidget(const SizedBox());
  });
}
