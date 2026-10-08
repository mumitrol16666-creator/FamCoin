import 'package:famcoin/l10n/app_localizations.dart';
import 'package:famcoin/l10n/app_localizations_kk.dart';
import 'package:famcoin/l10n/app_localizations_ru.dart';
import 'package:famcoin/ui/budget/debt_screens.dart';
import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'layout_test.dart' show pumpApp;

void main() {
  for (final AppLocalizations l in [AppLocalizationsRu(), AppLocalizationsKk()]) {
    for (final oweMe in [false, true]) {
      testWidgets('${l.localeName}: ${oweMe ? 'дал' : 'взял'} ещё сохраняет прошлые займы и выплаты', (tester) async {
        final f = await pumpApp(tester, home: const PersonDebtScreen(person: 'Друг'),
            size: const Size(360, 800), locale: Locale(l.localeName));
        final s = f.state;
        await s.addPersonDebt(kind: oweMe ? 'lendOut' : 'borrow', amount: kzt(50000),
            person: 'Друг', account: 'cash', date: s.today, id: 'first-loan');
        await s.addPersonDebt(kind: oweMe ? 'repaymentReceived' : 'repaymentMade',
            amount: kzt(10000), person: 'Друг', account: 'cash', date: s.today, id: 'first-payment');
        final original = transactionToJson(s.ledger.byId('first-loan')!);
        final payment = transactionToJson(s.ledger.byId('first-payment')!);
        await tester.pumpAndSettle();
        final button = find.text(oweMe ? l.lendMore : l.borrowMore);
        await tester.ensureVisible(button);
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(tester.widgetList<TextField>(find.byType(TextField))
            .any((field) => field.controller?.text == 'Друг'), isTrue);
        await tester.enterText(find.byType(TextField).first, '20000');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        final save = find.widgetWithText(FilledButton, l.save);
        await tester.ensureVisible(save);
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(s.personDebts.single.person, 'Друг');
        expect(s.personDebts.single.oweMe, oweMe);
        expect(s.personDebts.single.amount, kzt(60000));
        expect(s.ledger.balance('cash'), kzt(oweMe ? 40000 : 160000));
        expect(transactionToJson(s.ledger.byId('first-loan')!), original);
        expect(transactionToJson(s.ledger.byId('first-payment')!), payment);
        expect(s.ledger.isReversed('first-loan'), isFalse);
        expect(s.ledger.isReversed('first-payment'), isFalse);
        final loans = s.ledger.transactions.where((t) => t.type == (oweMe ? EventType.lendOut : EventType.borrow));
        expect(loans, hasLength(2));
        expect(loans.last.date, s.today);
        expect(s.monthReport.income, 0);
        expect(s.monthReport.expense, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        s.dispose();
      });
    }
  }
}
