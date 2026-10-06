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
    testWidgets('${l.localeName}: прощение долга закрывает 50 000 без выплаты', (tester) async {
      final f = await pumpApp(tester,
          home: const PersonDebtScreen(person: 'Друг'),
          size: const Size(360, 800), locale: Locale(l.localeName));
      final s = f.state;
      await s.addOldPersonDebt(kind: 'borrow', amount: kzt(50000),
          person: 'Друг', date: s.today);
      await tester.pumpAndSettle();
      final cash = s.ledger.balance('cash');
      final revision = s.revision;
      expect(find.text(l.debtPayAction), findsOneWidget);
      await tester.tap(find.text(l.debtForgivenAction));
      await tester.pumpAndSettle();
      expect(find.text(l.debtForgivenTitle('Друг')), findsOneWidget);
      expect(find.text(l.writeOffLiabilityBody('50 000 ₸')), findsOneWidget);
      await tester.tap(find.text(l.cancel));
      await tester.pumpAndSettle();
      expect(s.revision, revision);
      expect(s.personDebts.single.amount, kzt(50000));

      await tester.tap(find.text(l.debtForgivenAction));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l.closeDebtAction));
      await tester.pumpAndSettle();
      expect(find.text(l.debtClosed), findsOneWidget);
      expect(find.text('${l.debtForgiven} · Друг'), findsOneWidget);
      expect(find.text(l.debtForgivenAction), findsNothing);
      expect(s.personDebts, isEmpty);
      expect(s.ledger.balance('cash'), cash);
      // Закрытие долга без оплаты — не доход (D124): отдельная строка отчёта.
      expect(s.monthReport.income, 0);
      expect(s.monthReport.expense, 0);
      expect(s.monthReport.forgiven, kzt(50000));
      expect(s.ledger.netWorth().capital, kzt(100000), reason: 'капитал вырос с 50 000 до 100 000: долг больше не нужно возвращать');
      expect(s.ledger.transactions.where((t) => t.type == EventType.writeOff), hasLength(1));
      expect(s.ledger.transactions.where((t) => t.type == EventType.repaymentMade), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      s.dispose();
    });
  }
}
