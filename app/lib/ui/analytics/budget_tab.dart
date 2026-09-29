import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';

import '../../state/app_scope.dart';
import '../../theme/app_theme.dart';
import '../budget/budget_screen.dart';
import '../widgets/common.dart';

/// Бюджет (D66): план/факт по категориям с лимитом, где стоим относительно
/// месяца, постоянные обязательства и их доля от дохода. Заводить и менять
/// лимиты/платежи — по-прежнему в «Бюджете» (эта вкладка только показывает).
class BudgetTab extends StatelessWidget {
  const BudgetTab({super.key});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final fam = context.fam;
    final state = AppScope.of(context).state;
    final used = state.budgetUsedPercent;
    final elapsed = state.monthElapsedPercent;
    final income = state.avgMonthlyIncome();
    final share = state.recurringShareOfIncome;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        if (used != null) ...[
          SectionHeader(l.budgetProgress),
          AppCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              UsageBar(value: used.round(), max: 100, color: used > elapsed ? fam.warn : context.scheme.primary),
              const SizedBox(height: 8),
              Text(l.budgetUsedVsElapsed(used.round(), elapsed.round()), style: TextStyle(fontSize: 13, color: fam.text2)),
              if (used > elapsed + 10) Text(l.budgetFaster, style: TextStyle(fontSize: 12, color: fam.warn)),
            ]),
          ),
        ],

        SectionHeader(l.planVsFact, action: l.manage, onAction: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BudgetScreen()))),
        if (state.limits.isEmpty)
          EmptyHint(l.noLimits, icon: Icons.speed_outlined)
        else
          AppCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Column(children: [
              Row(children: [
                const Expanded(flex: 3, child: SizedBox()),
                Expanded(flex: 2, child: Text(l.plan, textAlign: TextAlign.right, style: TextStyle(fontSize: 11, color: fam.text2))),
                Expanded(flex: 2, child: Text(l.fact, textAlign: TextAlign.right, style: TextStyle(fontSize: 11, color: fam.text2))),
                Expanded(flex: 2, child: Text(l.left, textAlign: TextAlign.right, style: TextStyle(fontSize: 11, color: fam.text2))),
              ]),
              const Divider(height: 12),
              for (final def in state.limits)
                Builder(builder: (context) {
                  final st = state.limitStatusFor(def);
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(children: [
                      Expanded(flex: 3, child: Text(categoryName(l, def.category), overflow: TextOverflow.ellipsis)),
                      Expanded(flex: 2, child: Text(formatMoney(st.limit), textAlign: TextAlign.right, style: const TextStyle(fontSize: 13))),
                      Expanded(flex: 2, child: Text(formatMoney(st.spent), textAlign: TextAlign.right, style: const TextStyle(fontSize: 13))),
                      Expanded(
                        flex: 2,
                        child: Text(
                          '${st.remaining < 0 ? '−' : '+'}${formatMoney(st.remaining.abs())}',
                          textAlign: TextAlign.right,
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: st.remaining < 0 ? fam.expense : fam.income),
                        ),
                      ),
                    ]),
                  );
                }),
            ]),
          ),

        SectionHeader(l.recurringExpenses),
        AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (state.activePlanned.isEmpty)
              Text(l.noPlanned, style: TextStyle(color: fam.text2))
            else
              for (final p in state.activePlanned)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(children: [Expanded(child: Text(p.name, style: TextStyle(color: fam.text2))), MoneyText(p.amount, style: const TextStyle(fontSize: 13))]),
                ),
            const Divider(height: 20),
            Row(children: [Expanded(child: Text(l.total, style: const TextStyle(fontWeight: FontWeight.w700))), MoneyText(state.recurringMonthly, style: const TextStyle(fontSize: 16))]),
            if (share != null) ...[
              const SizedBox(height: 8),
              Text(l.recurringShareOfIncome(share.round()), style: TextStyle(fontSize: 12, color: fam.text2)),
            ] else if (income == 0)
              Text(l.recurringShareUnknown, style: TextStyle(fontSize: 12, color: fam.text2)),
          ]),
        ),
      ],
    );
  }
}
