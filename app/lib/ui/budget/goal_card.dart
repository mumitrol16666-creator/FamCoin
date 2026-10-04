import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';

import '../../state/app_scope.dart';
import '../../state/models.dart';
import '../../theme/app_theme.dart';
import '../widgets/common.dart';
import 'sheets.dart';

class GoalCard extends StatelessWidget {
  const GoalCard({super.key, required this.goal});
  final GoalInfo goal;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final fam = context.fam;
    final state = AppScope.of(context).state;
    final st = state.goalStatusFor(goal);
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(goal.name, style: const TextStyle(fontWeight: FontWeight.w600))),
          Text('${st.progressPercent?.round() ?? 0}%', style: TextStyle(fontWeight: FontWeight.w700, color: context.scheme.primary)),
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'edit') {
                await showGoalSheet(context, initial: goal);
              } else if (await confirm(context, title: l.deleteGoal, message: l.deleteGoalHint, action: l.delete) && context.mounted) {
                final back = state.activeAccounts.where((a) => a.liquid).firstOrNull ?? state.activeAccounts.firstOrNull;
                if (back == null) return;
                await runAction(context, () => state.closeGoal(goal, returnTo: back.id));
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'edit', child: Text(l.edit)),
              PopupMenuItem(value: 'delete', child: Text(l.delete)),
            ],
          ),
        ]),
        const SizedBox(height: 6),
        UsageBar(value: st.saved, max: st.target, color: context.scheme.primary),
        const SizedBox(height: 6),
        Row(children: [
          MoneyText(st.saved, style: const TextStyle(fontSize: 13)),
          Expanded(child: Text(' / ${formatMoney(st.target)}', style: TextStyle(fontSize: 13, color: fam.text2))),
        ]),
        if (st.requiredContribution != null && !st.reached)
          Text('${l.needMonthly}: ${formatMoney(st.requiredContribution!)}', style: TextStyle(fontSize: 12, color: fam.text2)),
        const SizedBox(height: 8),
        if (goal.account == null)
          Text(l.legacyGoalNote, style: TextStyle(fontSize: 12, color: fam.warn))
        else
          Row(children: [
            Expanded(child: FilledButton.tonal(onPressed: () => showReserveSheet(context, goal, release: false), child: Text(l.reserveAdd))),
            const SizedBox(width: 8),
            if (st.saved > 0) Expanded(child: OutlinedButton(onPressed: () => showReserveSheet(context, goal, release: true), child: Text(l.reserveRelease))),
          ]),
        // «Реализовать» (D98): накопленное становится расходом, цель закрывается.
        if (goal.account != null && st.saved > 0) ...[
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => showRealizeGoalSheet(context, goal),
              icon: const Icon(Icons.check_circle_outline, size: 18),
              label: Text(l.goalRealize),
            ),
          ),
        ],
      ]),
    );
  }
}
