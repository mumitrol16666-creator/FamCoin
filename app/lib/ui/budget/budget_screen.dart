import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../state/app_scope.dart';
import '../../state/models.dart';
import '../../theme/app_theme.dart';
import '../home/home_screen.dart';
import '../widgets/common.dart';
import 'calendar_screen.dart';
import 'debt_screens.dart';
import 'limits_section.dart';
import 'sheets.dart';

/// S12 — бюджет периода: итоги месяца, лимиты, обязательные платежи,
/// цели, долги.
class BudgetScreen extends StatelessWidget {
  const BudgetScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final state = AppScope.of(context).state;
    final fam = context.fam;
    final locale = Localizations.localeOf(context).toString();

    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final report = state.monthReport;
        final month = DateFormat.yMMMM(locale).format(state.today);
        final due = state.dueItems(DateTime(state.today.year, state.today.month + 1, 0));
        final nextDue = state.dueItems(state.today.add(const Duration(days: 62)));
        final period = '${state.today.year}-${state.today.month.toString().padLeft(2, '0')}';
        final people = state.personDebts;

        return Scaffold(
          appBar: AppBar(title: Text('${l.navBudget} · $month')),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            children: [
              AppCard(
                child: Column(children: [
                  Row(children: [
                    Expanded(child: _kv(context, l.reportIncome, report.income, color: fam.income)),
                    Expanded(child: _kv(context, l.reportExpense, report.total, color: fam.expense)),
                  ]),
                  if (report.debtPayments > 0) Text(l.reportIncludesDebts(moneyInText(report.debtPayments)), style: TextStyle(fontSize: 12, color: fam.text2)),
                  const Divider(height: 20),
                  _row(context, l.payouts, state.monthDebtPayouts, color: fam.debt),
                  _row(context, l.reportResult, report.result, sign: true),
                  _row(context, l.cashFlow, report.cashFlow, sign: true),
                  if (state.monthAdjustments != 0) _row(context, l.adjustments, state.monthAdjustments, sign: true),
                ]),
              ),

              const LimitsSection(),

              SectionHeader(l.planned, action: l.calendar, onAction: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CalendarScreen()))),
              if (state.planned.every((p) => p.once != null))
                EmptyHint(l.noPlanned, icon: Icons.event_repeat_outlined)
              else
                AppCard(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Column(children: [
                    for (final p in state.planned.where((p) => p.once == null))
                      Builder(builder: (context) {
                        final next = nextDue.where((d) => d.planned.id == p.id).firstOrNull;
                        final paidNow = p.paid.contains(period);
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: CategoryAvatar(p.debtId != null ? Icons.account_balance_outlined : categoryById(p.category).icon),
                          title: Text(p.name),
                          subtitle: Text(
                            [
                              l.everyMonthOn(p.day),
                              if (paidNow) l.paidThisMonth,
                              if (next != null) '${l.nextPayment}: ${DateFormat.MMMMd(locale).format(next.date)}',
                            ].join(' · '),
                            style: TextStyle(fontSize: 12, color: paidNow ? fam.income : fam.text2),
                          ),
                          trailing: MoneyText(p.amount),
                          onTap: next == null ? null : () => showPayDueSheet(context, next),
                          onLongPress: () async {
                            if (await confirm(context, title: l.deletePlanned, action: l.delete) && context.mounted) {
                              await runAction(context, () => state.delete('planned', p.id));
                            }
                          },
                        );
                      }),
                  ]),
                ),
              OutlinedButton.icon(onPressed: () => addPlannedFlow(context), icon: const Icon(Icons.add), label: Text(l.addPayment)),

              // Разовые покупки (D88): колёса к зиме, страховка, отпуск — не
              // ежемесячный платёж и не обязательно копилка, а «в марте уйдёт 100 000».
              SectionHeader(l.purchases, action: l.add, onAction: () => addPurchaseFlow(context)),
              if (state.purchases.isEmpty)
                EmptyHint(l.noPurchases, icon: Icons.shopping_bag_outlined)
              else
                AppCard(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Column(children: [
                    for (final p in state.purchases)
                      Builder(builder: (context) {
                        final m = p.onceMonth!;
                        final name = toBeginningOfSentenceCase(DateFormat.yMMMM(locale).format(m));
                        final overdue = m.isBefore(state.monthStart);
                        final saving = state.purchaseGoal(p) != null;
                        final saved = state.purchaseSaved(p);
                        final monthly = state.purchaseMonthly(p);
                        final when = overdue
                            ? l.purchaseOverdue(name)
                            : m == state.monthStart
                                ? l.purchaseThisMonth(name)
                                : saving
                                    ? name
                                    : l.purchaseBy(name, moneyInText(monthly));
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: CategoryAvatar(categoryById(p.category).icon),
                          title: Text(p.name),
                          subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(when, style: TextStyle(fontSize: 12, color: overdue ? fam.expense : fam.text2)),
                            // Копят в копилку (D90): сколько уже есть и сколько осталось откладывать.
                            if (saving) ...[
                              Text(
                                '${l.purchaseProgress(moneyInText(saved), moneyInText(p.amount))} · ${monthly == 0 ? l.purchaseReady : l.purchaseMore(moneyInText(monthly))}',
                                style: TextStyle(fontSize: 12, color: fam.text2),
                              ),
                              const SizedBox(height: 4),
                              UsageBar(value: saved, max: p.amount, color: context.scheme.primary),
                            ],
                          ]),
                          trailing: MoneyText(p.amount),
                          onTap: () => showPurchaseSheet(context, p),
                        );
                      }),
                  ]),
                ),

              SectionHeader(l.goals, action: l.add, onAction: () => showGoalSheet(context)),
              if (state.goals.isEmpty) EmptyHint(l.noGoals, icon: Icons.flag_outlined),
              for (final g in state.goals) _GoalCard(goal: g),

              SectionHeader(l.debts, action: l.add, onAction: () => addBankDebtFlow(context)),
              if (state.bankDebts.isEmpty && people.isEmpty)
                EmptyHint(l.noDebts, icon: Icons.handshake_outlined)
              else
                AppCard(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Column(children: [
                    for (final d in state.bankDebts)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: CategoryAvatar(d.kind == 'creditCard' ? Icons.credit_card_outlined : Icons.account_balance_outlined),
                        title: Text(d.name),
                        subtitle: Text('${debtKindName(l, d.kind)}${d.rate > 0 ? ' · ${d.rate}%' : ''}', style: TextStyle(fontSize: 12, color: fam.text2)),
                        trailing: MoneyText(state.debtBalance(d.id), color: fam.debt),
                        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => BankDebtScreen(debtId: d.id))),
                      ),
                    for (final p in people)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: CircleAvatar(child: Text(p.person.characters.first.toUpperCase())),
                        title: Text(p.person),
                        subtitle: Text(p.oweMe ? l.oweMe : l.iOwe, style: TextStyle(fontSize: 12, color: fam.text2)),
                        trailing: MoneyText(p.amount, color: p.oweMe ? fam.income : fam.expense),
                        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PersonDebtScreen(person: p.person))),
                      ),
                  ]),
                ),
              if (state.bankDebts.where((d) => state.debtBalance(d.id) > 0).length > 1)
                OutlinedButton(
                  onPressed: () => state.pro
                      ? Navigator.push(context, MaterialPageRoute(builder: (_) => const DebtStrategyScreen()))
                      : showProGate(context, l.proGateEarly),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [Text(l.strategy), if (!state.pro) ...[const SizedBox(width: 6), const ProBadge()]]),
                ),
              if (due.isNotEmpty) ...[
                SectionHeader(l.upcoming),
                AppCard(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Column(children: [for (final d in due) DueTile(due: d, locale: locale)]),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _kv(BuildContext context, String label, int value, {Color? color}) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: TextStyle(fontSize: 12, color: context.fam.text2)),
        MoneyText(value, color: color, style: const TextStyle(fontSize: 18)),
      ]);

  Widget _row(BuildContext context, String label, int value, {Color? color, bool sign = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [Expanded(child: Text(label, style: TextStyle(color: context.fam.text2))), MoneyText(value, color: color, sign: sign)]),
      );
}

class _GoalCard extends StatelessWidget {
  const _GoalCard({required this.goal});
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
