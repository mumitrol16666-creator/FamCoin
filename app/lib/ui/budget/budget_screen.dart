import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../state/app_scope.dart';
import '../../theme/app_theme.dart';
import '../widgets/common.dart';
import 'budget_pages.dart';

export 'budget_pages.dart';

/// S12 — «Бюджет» (D135): набор кнопок по направлениям — лимиты, платежи,
/// покупки, цели, долги, прогноз. Содержимое каждого лежит на своём экране
/// ([budget_pages.dart]); здесь — только краткая сводка на кнопке и значок,
/// если что-то требует внимания (превышены лимиты, есть просроченные платежи).
class BudgetScreen extends StatelessWidget {
  const BudgetScreen({super.key, this.embedded = false});
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final state = AppScope.of(context).state;
    final fam = context.fam;
    final locale = Localizations.localeOf(context).toString();

    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final month = DateFormat.yMMMM(locale).format(state.today);
        void open(Widget page) => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => page));

        // Лимиты.
        final limits = state.limits;
        final limitsTotal = limits.fold(0, (s, x) => s + x.amount);
        final limitsSpent = limits.fold(0, (s, x) => s + state.spentInCategory(x.category));
        final limitsOver = limits.where((x) => state.spentInCategory(x.category) > x.amount).length;

        // Платежи.
        // Только то, что показывает страница «Платежи»: разовые покупки и сроки
        // личных долгов живут на своих страницах.
        final due = state.dueItems(state.today.add(const Duration(days: 62))).where((d) => d.planned.once == null && d.planned.person == null).toList();
        final paymentsCount = state.planned.where((p) => p.once == null && p.person == null).length;
        final overdue = due.where((d) => d.date.isBefore(state.today)).length;
        final next = due.where((d) => !d.date.isBefore(state.today)).firstOrNull;

        // Покупки и цели.
        final purchases = state.purchases;
        final purchaseGoals = purchases.map((p) => p.goalId).whereType<String>().toSet();
        final goals = state.goals.where((g) => !purchaseGoals.contains(g.id)).toList();
        final goalsSaved = goals.fold(0, (s, g) => s + state.goalSaved(g));
        final goalsTarget = goals.fold(0, (s, g) => s + g.target);

        // Долги.
        final people = state.personDebts;
        final int owe = state.totalBankDebt + people.where((p) => !p.oweMe).fold<int>(0, (s, p) => s + p.amount);
        final int lent = people.where((p) => p.oweMe).fold<int>(0, (s, p) => s + p.amount);

        // Прогноз.
        final forecast = state.monthEndForecast.estimate;

        final tiles = <_Tile>[
          _Tile(
            icon: Icons.speed_outlined,
            title: l.limits,
            summary: limits.isEmpty ? l.budgetTileLimitsNone : l.budgetTileLimits(moneyInText(limitsSpent), moneyInText(limitsTotal)),
            badge: limitsOver > 0 ? l.budgetTileOver(limitsOver) : null,
            onTap: () => open(const BudgetLimitsPage()),
          ),
          _Tile(
            icon: Icons.event_repeat_outlined,
            title: l.budgetTilePayments,
            summary: paymentsCount == 0 && next == null
                ? l.budgetTilePaymentsNone
                : next == null
                    ? l.budgetTilePaymentsCount(paymentsCount)
                    : l.budgetTilePaymentsNext(DateFormat.MMMd(locale).format(next.date), moneyInText(next.payAmount)),
            badge: overdue > 0 ? l.budgetTileOverdue(overdue) : null,
            onTap: () => open(const BudgetPaymentsPage()),
          ),
          _Tile(
            icon: Icons.shopping_bag_outlined,
            title: l.purchases,
            summary: purchases.isEmpty ? l.budgetTilePurchasesNone : l.budgetTilePurchases(purchases.length),
            onTap: () => open(const BudgetPurchasesPage()),
          ),
          _Tile(
            icon: Icons.flag_outlined,
            title: l.goals,
            summary: goals.isEmpty ? l.budgetTileGoalsNone : l.budgetTileGoals(moneyInText(goalsSaved), moneyInText(goalsTarget)),
            onTap: () => open(const BudgetGoalsPage()),
          ),
          _Tile(
            icon: Icons.handshake_outlined,
            title: l.debts,
            summary: owe == 0 && lent == 0
                ? l.budgetTileDebtsNone
                : [if (owe > 0) l.budgetTileDebtsOwe(moneyInText(owe)), if (lent > 0) l.budgetTileDebtsLent(moneyInText(lent))].join('\n'),
            onTap: () => open(const BudgetDebtsPage()),
          ),
          _Tile(
            icon: Icons.insights_outlined,
            title: l.budgetTileForecast,
            summary: l.budgetTileForecastValue(moneyInText(forecast)),
            summaryColor: forecast < 0 ? fam.expense : null,
            onTap: () => open(const BudgetForecastPage()),
          ),
        ];

        return Scaffold(
          appBar: embedded ? null : AppBar(title: Text('${l.navBudget} · $month')),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            children: [
              if (embedded)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(toBeginningOfSentenceCase(month), style: Theme.of(context).textTheme.titleLarge),
                ),
              Text(l.budgetPurpose, style: TextStyle(color: fam.text2)),
              const SizedBox(height: 8),
              // Две колонки на обычном экране; одна — на узком или при крупном шрифте.
              LayoutBuilder(builder: (context, c) {
                final single = c.maxWidth < 340 || MediaQuery.textScalerOf(context).scale(1) > 1.4;
                final rows = <Widget>[];
                for (var i = 0; i < tiles.length; i += single ? 1 : 2) {
                  final pair = [tiles[i], if (!single && i + 1 < tiles.length) tiles[i + 1]];
                  rows.add(Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: IntrinsicHeight(
                      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        for (var k = 0; k < (single ? 1 : 2); k++) ...[
                          if (k > 0) const SizedBox(width: 12),
                          Expanded(child: k < pair.length ? pair[k] : const SizedBox.shrink()),
                        ],
                      ]),
                    ),
                  ));
                }
                return Column(children: rows);
              }),
            ],
          ),
        );
      },
    );
  }
}

/// Кнопка направления: значок, название, краткая сводка и, если надо, красный
/// значок «внимание».
class _Tile extends StatelessWidget {
  const _Tile({required this.icon, required this.title, required this.summary, required this.onTap, this.badge, this.summaryColor});
  final IconData icon;
  final String title;
  final String summary;
  final String? badge;
  final Color? summaryColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fam = context.fam;
    return Material(
      color: Theme.of(context).cardColor,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 112),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(border: Border.all(color: fam.line), borderRadius: BorderRadius.circular(16)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              CategoryAvatar(icon),
              const Spacer(),
              if (badge != null)
                Flexible(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(color: fam.expense.withValues(alpha: .16), borderRadius: BorderRadius.circular(999)),
                    child: Text(badge!, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fam.expense)),
                  ),
                )
              else
                Icon(Icons.chevron_right, size: 20, color: fam.text2),
            ]),
            const SizedBox(height: 10),
            Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(summary, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: summaryColor ?? fam.text2)),
          ]),
        ),
      ),
    );
  }
}
