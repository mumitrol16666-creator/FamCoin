import 'package:famcoin/l10n/app_localizations.dart';
import 'package:famcoin/l10n/app_localizations_kk.dart';
import 'package:famcoin/l10n/app_localizations_ru.dart';
import 'package:famcoin/ui/ops/add_transaction_sheet.dart';
import 'package:famcoin/ui/more/ai_context.dart';
import 'package:famcoin/ui/widgets/common.dart';
import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'layout_test.dart' show pumpApp;
import 'audit_regression_test.dart' show FakeServer;

void main() {
  for (final AppLocalizations l in [
    AppLocalizationsRu(),
    AppLocalizationsKk(),
  ]) {
    testWidgets(
      '${l.localeName}: справка по выбранному виду долга, без автопоказа и потери черновика',
      (tester) async {
        final f = await pumpApp(
          tester,
          size: const Size(360, 732),
          locale: Locale(l.localeName),
          home: Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () => showAddTransactionSheet(context),
                child: const Text('open'),
              ),
            ),
          ),
        );
        final revision = f.state.revision;
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(l.debt).first);
        await tester.pumpAndSettle();
        final amountController = tester
            .widget<TextField>(find.byType(TextField).first)
            .controller!;
        await tester.enterText(find.byType(TextField).first, '25000');
        final personController = tester
            .widget<TextField>(find.byType(TextField).at(1))
            .controller!;
        await tester.enterText(find.byType(TextField).at(1), 'Друг');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        for (final (choice, title, body) in [
          (l.borrow, l.borrowHelpTitle, l.borrowNote),
          (l.lendOut, l.lendHelpTitle, l.debtNote),
          (l.returnedToMe, l.repayHelpTitle, l.repaymentReceivedNote),
          (l.iReturned, l.repayHelpTitle, l.repaymentNote),
        ]) {
          await tester.ensureVisible(find.widgetWithText(ChoiceChip, choice));
          await tester.tap(find.widgetWithText(ChoiceChip, choice));
          await tester.pumpAndSettle();
          expect(find.text(body), findsNothing);
          final help = find.byTooltip(title);
          await tester.scrollUntilVisible(
            help,
            -150,
            scrollable: find
                .descendant(
                  of: find.byType(TransactionFields),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          await tester.tap(help);
          await tester.pumpAndSettle();
          expect(find.text(body), findsOneWidget);
          await tester.scrollUntilVisible(
            find.text(l.gotIt),
            200,
            scrollable: find.byType(Scrollable).last,
          );
          await tester.tap(find.text(l.gotIt));
          await tester.pumpAndSettle();
          expect(parseAmount(amountController.text), kzt(25000));
          expect(personController.text, 'Друг');
          expect(
            f.state.revision,
            revision,
            reason: 'справка не записывает операции',
          );
        }
        await tester.tap(find.widgetWithText(ChoiceChip, l.borrow));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text(l.debtOld));
        await tester.tap(find.text(l.debtOld));
        await tester.pumpAndSettle();
        final help = find.byTooltip(l.oldDebtHelpTitle);
        await tester.scrollUntilVisible(
          help,
          -150,
          scrollable: find
              .descendant(
                of: find.byType(TransactionFields),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.tap(help);
        await tester.pumpAndSettle();
        expect(find.descendant(of: find.byType(BottomSheet).last, matching: find.text(l.debtOldBorrowNote)), findsOneWidget);
        expect(find.text(l.borrowNote), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      '${l.localeName}: длинная справка прокручивается на 320 px с текстом 200 %',
      (tester) async {
        await pumpApp(
          tester,
          size: const Size(320, 694),
          textScale: 2,
          locale: Locale(l.localeName),
          home: Scaffold(
            body: InfoTip(l.reportHelpBody, title: l.reportHelpTitle),
          ),
        );
        await tester.tap(find.byTooltip(l.reportHelpTitle));
        await tester.pumpAndSettle();
        expect(find.text(l.reportHelpBody), findsOneWidget);
        await tester.scrollUntilVisible(
          find.text(l.gotIt),
          250,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.tap(find.text(l.gotIt));
        await tester.pumpAndSettle();
        expect(find.text(l.reportHelpBody), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  test(
    'графики, категории, сверка и контекст ИИ используют одинаковые доходы и расходы',
    () async {
      final f = FakeServer();
      await f.init();
      final s = f.state;
      await s.addPersonDebt(
        kind: 'borrow',
        amount: kzt(50000),
        person: 'Друг',
        account: 'cash',
        date: s.today,
      );
      await s.addExpense(
        amount: kzt(20000),
        category: 'food',
        account: 'cash',
        date: s.today,
      );
      await s.addPersonDebt(
        kind: 'repaymentMade',
        amount: kzt(10000),
        person: 'Друг',
        account: 'cash',
        date: s.today,
      );
      final report = s.monthReport;
      expect(report.income, 0);
      expect(report.expense, kzt(20000));
      expect(report.cashFlow, kzt(20000));
      expect(
        s.dailyIncome(s.monthStart).fold(0, (a, b) => a + b),
        report.income,
      );
      expect(
        s.dailyExpense(s.monthStart).fold(0, (a, b) => a + b),
        report.expense,
      );
      expect(
        s.categoriesFor(s.monthStart).fold(0, (a, b) => a + b.value),
        report.expense,
      );
      expect(s.monthSummary(s.monthStart).expense, report.expense);
      final ai = aiChatContext(s, AppLocalizationsRu())['thisMonth'] as Map;
      expect(ai['income'], 0);
      expect(ai['expense'], 20000);
      expect(ai['borrowed'], 50000);
      expect(ai['debtPayments'], 10000);
      expect(ai.containsKey('ofWhichBorrowed'), isFalse);
    },
  );
}
