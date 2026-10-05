import 'package:flutter/material.dart';

import '../../state/app_scope.dart';
import '../../theme/app_theme.dart';
import '../analytics/analytics_screen.dart';
import '../budget/calendar_screen.dart';
import '../budget/month_close_screen.dart';
import '../budget/sheets.dart';
import '../home/home_screen.dart';
import '../ops/add_transaction_sheet.dart';
import '../shell.dart';
import '../widgets/common.dart';

/// «Как устроен FamCoin» (D120): семь коротких карточек о том, что где лежит
/// и как записать то, что кажется сложным. У каждой кнопка в нужное место.
class GuideScreen extends StatelessWidget {
  const GuideScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final fam = context.fam;
    final state = AppScope.of(context).state;
    void push(Widget screen) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
    void tab(void Function() open) {
      Navigator.of(context).popUntil((r) => r.isFirst);
      open();
    }

    final cards = <(IconData, String, String, String, VoidCallback)>[
      (Icons.add_circle_outline, l.guide1Title, l.guide1Text, l.guide1Action, () => showAddTransactionSheet(context)),
      (Icons.today_outlined, l.guide2Title, l.guide2Text, l.guide2Action, () => HomeScreen.showLimitSheet(context, state)),
      (Icons.speed_outlined, l.guide3Title, l.guide3Text, l.guide3Action, () => addLimitFlow(context)),
      (Icons.event_repeat_outlined, l.guide4Title, l.guide4Text, l.guide4Action, () => push(const CalendarScreen())),
      (Icons.savings_outlined, l.guide5Title, l.guide5Text, l.guide5Action, () => showGoalSheet(context)),
      (Icons.handshake_outlined, l.guide6Title, l.guide6Text, l.guide6Action, () => tab(() => Shell.openAnalytics(AnalyticsSection.budget))),
      (Icons.fact_check_outlined, l.guide7Title, l.guide7Text, l.guide7Action, () => push(const MonthCloseListScreen())),
    ];

    return Scaffold(
      appBar: AppBar(title: Text(l.guideTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(l.guideIntro, style: TextStyle(color: fam.text2))),
          for (final (icon, title, text, action, onTap) in cards)
            AppCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  CategoryAvatar(icon),
                  const SizedBox(width: 12),
                  Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
                ]),
                const SizedBox(height: 8),
                Text(text, style: TextStyle(fontSize: 14, color: fam.text2)),
                const SizedBox(height: 8),
                Align(alignment: Alignment.centerLeft, child: TextButton(onPressed: onTap, child: Text('$action ›'))),
              ]),
            ),
        ],
      ),
    );
  }
}
