import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../state/app_scope.dart';
import '../../state/app_state.dart';
import '../../state/models.dart';
import '../../theme/app_theme.dart';
import '../home/home_screen.dart';
import '../widgets/common.dart';
import 'budget_screen.dart';
import 'sheets.dart';

/// Сверка месяца (D75): итоги месяца сразу, потом несколько вопросов —
/// остатки на счетах, платежи, что осталось, лимит на следующий месяц.
/// Любой шаг можно пропустить; «Закрыть месяц» только отмечает, что порядок
/// наведён, и ничего не блокирует.
class MonthCloseScreen extends StatefulWidget {
  const MonthCloseScreen({super.key, required this.month});
  final DateTime month;

  @override
  State<MonthCloseScreen> createState() => _MonthCloseScreenState();
}

class _MonthCloseScreenState extends State<MonthCloseScreen> {
  /// Счета, остаток которых уже сверен (совпал или исправлен) — только на экране.
  final _checked = <String>{};
  bool _justClosed = false;

  Future<void> _close(AppState state) async {
    final ok = await runAction(context, () => state.closeMonth(widget.month));
    if (ok && mounted) setState(() => _justClosed = true);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final state = AppScope.of(context).state;
    final locale = Localizations.localeOf(context).toString();
    final title = '${toBeginningOfSentenceCase(DateFormat.LLLL(locale).format(widget.month))} ${widget.month.year}';

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          final fam = context.fam;
          final m = widget.month;
          final sum = state.monthSummary(m);
          final closed = state.isMonthClosed(m);
          final accounts = state.activeAccounts;
          final unchecked = [for (final a in accounts) if (!_checked.contains(a.id)) a.id];
          final lastDay = DateTime(m.year, m.month + 1, 0);
          final due = state.dueItems(lastDay);
          final goals = [for (final g in state.goals) if (g.account != null) g];
          final limit = state.dailyLimit;

          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
            children: [
              Text(l.monthCloseIntro, style: TextStyle(fontSize: 13, color: fam.text2)),
              const SizedBox(height: 12),
              _SummaryCard(sum: sum),

              // 1. Остатки на счетах
              _Step(
                title: l.monthStepBalances,
                hint: l.monthStepBalancesHint,
                children: [
                  for (final a in accounts)
                    _AccountRow(
                      name: a.name,
                      balance: state.ledger.balance(a.id),
                      checked: _checked.contains(a.id),
                      onMatches: () => setState(() => _checked.add(a.id)),
                      onFix: () async {
                        await showAdjustBalanceSheet(context, a.id);
                        if (mounted) setState(() => _checked.add(a.id));
                      },
                    ),
                  if (unchecked.length > 1)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        icon: const Icon(Icons.done_all, size: 18),
                        label: Text(l.monthAllMatch),
                        onPressed: () => setState(() => _checked.addAll(unchecked)),
                      ),
                    ),
                ],
              ),

              // 2. Платежи месяца
              _Step(
                title: l.monthStepPayments,
                hint: due.isEmpty ? null : l.monthPaymentsHint,
                children: [
                  if (due.isEmpty)
                    Text(l.monthPaymentsAllPaid, style: TextStyle(color: fam.income, fontWeight: FontWeight.w600))
                  else
                    for (final d in due) ...[
                      DueTile(due: d, locale: locale),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () => runAction(context, () => state.markDuePaid(d)),
                          child: Text(l.monthAlreadyPaid),
                        ),
                      ),
                    ],
                ],
              ),

              // 3. Что осталось
              if (sum.result != 0)
                _Step(
                  title: l.monthStepLeft,
                  children: [
                    if (sum.result > 0) ...[
                      Text(l.monthLeftPlus(moneyInText(sum.result))),
                      const SizedBox(height: 8),
                      Wrap(spacing: 8, runSpacing: 4, children: [
                        for (final g in goals)
                          ActionChip(
                            label: Text(l.monthToGoal(g.name)),
                            onPressed: () => showReserveSheet(context, g, release: false, initial: sum.result),
                          ),
                        if (goals.isEmpty)
                          ActionChip(
                            avatar: const Icon(Icons.flag_outlined, size: 18),
                            label: Text(l.monthNewGoal),
                            onPressed: () => showGoalSheet(context),
                          ),
                      ]),
                    ] else
                      Text(l.monthLeftMinus(moneyInText(-sum.result))),
                  ],
                ),

              // 4. Следующий месяц
              _Step(
                title: l.monthStepNext,
                children: [
                  Text(limit == null
                      ? l.monthNoLimit
                      : sum.avgDaily > 0
                          ? l.monthLimitLine(moneyInText(limit), moneyInText(sum.avgDaily))
                          : l.monthLimitOnly(moneyInText(limit))),
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, runSpacing: 4, children: [
                    OutlinedButton(
                      onPressed: () => HomeScreen.showLimitSheet(context, state),
                      child: Text(limit == null ? l.dailyLimitSet : l.explainChangeLimit),
                    ),
                    OutlinedButton(
                      onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BudgetScreen())),
                      child: Text(l.monthCheckLimits),
                    ),
                  ]),
                  if (limit != null && state.dailyLimitCarryOn && state.dailyLimitCarry != 0) ...[
                    const SizedBox(height: 12),
                    Row(children: [
                      Expanded(child: Text(l.monthCarryLine(moneyInText(state.dailyLimitCarry)))),
                      TextButton(onPressed: () => runAction(context, state.resetDailyLimitCarry), child: Text(l.carryReset)),
                    ]),
                  ],
                ],
              ),

              const SizedBox(height: 8),
              if (_justClosed) ...[
                AppCard(
                  color: fam.guideBg,
                  child: DefaultTextStyle(
                    style: const TextStyle(color: FamColors.onGuide),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(l.monthClosedDone, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                      if (state.closedStreakFrom(m) > 1) ...[
                        const SizedBox(height: 4),
                        Text(l.monthClosedStreak(state.closedStreakFrom(m))),
                      ],
                      const SizedBox(height: 4),
                      Text(l.monthNextRecon, style: const TextStyle(fontSize: 12)),
                    ]),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton(onPressed: () => Navigator.pop(context), child: Text(l.monthDone)),
              ] else
                FilledButton(
                  onPressed: closed ? null : () => _close(state),
                  child: Text(closed ? l.monthClosed : l.monthCloseAction),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Итоги месяца: доходы, расходы, результат, сравнение, куда ушло, платежи.
class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.sum});
  final MonthSummary sum;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final fam = context.fam;
    final pct = sum.expenseChangePercent;
    Widget kpi(String label, int minor, Color color) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: TextStyle(fontSize: 12, color: fam.text2)),
          const SizedBox(height: 2),
          MoneyText(minor, color: color, style: const TextStyle(fontSize: 17)),
        ]);

    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (sum.current) ...[
          Text(l.monthPartial, style: TextStyle(fontSize: 12, color: fam.warn)),
          const SizedBox(height: 8),
        ],
        Row(children: [
          Expanded(child: kpi(l.reportIncome, sum.income, fam.income)),
          Expanded(child: kpi(l.reportExpense, sum.expense, fam.expense)),
        ]),
        const Divider(height: 20),
        Row(children: [
          Expanded(child: Text(l.reportResult, style: TextStyle(color: fam.text2))),
          MoneyText(sum.result, sign: true, style: const TextStyle(fontSize: 17)),
        ]),
        if (pct != null && pct != 0) ...[
          const SizedBox(height: 4),
          Text(pct < 0 ? l.monthExpenseLess(-pct) : l.monthExpenseMore(pct), style: TextStyle(fontSize: 12, color: fam.text2)),
        ],
        if (sum.top.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text(l.monthTopTitle, style: TextStyle(fontSize: 12, color: fam.text2)),
          const SizedBox(height: 4),
          for (final e in sum.top)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(children: [
                Icon(categoryById(e.key).icon, size: 18, color: fam.text2),
                const SizedBox(width: 8),
                Expanded(child: Text(categoryName(l, e.key), maxLines: 1, overflow: TextOverflow.ellipsis)),
                MoneyText(e.value),
              ]),
            ),
        ],
        if (sum.paymentsTotal > 0 || sum.adjustments != 0) const Divider(height: 20),
        if (sum.paymentsTotal > 0) Text(l.monthPaymentsLine(sum.paymentsPaid, sum.paymentsTotal), style: TextStyle(fontSize: 13, color: fam.text2)),
        if (sum.adjustments != 0)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(children: [
              Expanded(child: Text(l.adjustments, style: TextStyle(fontSize: 13, color: fam.text2))),
              MoneyText(sum.adjustments, sign: true, style: const TextStyle(fontSize: 13)),
            ]),
          ),
      ]),
    );
  }
}

/// Один вопрос сверки: заголовок, пояснение, содержимое.
class _Step extends StatelessWidget {
  const _Step({required this.title, required this.children, this.hint});
  final String title;
  final String? hint;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final fam = context.fam;
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        if (hint != null) ...[
          const SizedBox(height: 4),
          Text(hint!, style: TextStyle(fontSize: 12, color: fam.text2)),
        ],
        const SizedBox(height: 10),
        ...children,
      ]),
    );
  }
}

/// Счёт в сверке: остаток в приложении и два ответа — «совпадает» или «исправить».
class _AccountRow extends StatelessWidget {
  const _AccountRow({required this.name, required this.balance, required this.checked, required this.onMatches, required this.onFix});
  final String name;
  final int balance;
  final bool checked;
  final VoidCallback onMatches;
  final VoidCallback onFix;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final fam = context.fam;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis)),
          MoneyText(balance),
        ]),
        if (checked)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Row(children: [
              Icon(Icons.check_circle, size: 16, color: fam.income),
              const SizedBox(width: 6),
              Text(l.monthChecked, style: TextStyle(fontSize: 12, color: fam.income)),
              const Spacer(),
              TextButton(onPressed: onFix, child: Text(l.monthFix)),
            ]),
          )
        else
          Wrap(spacing: 8, children: [
            TextButton(onPressed: onMatches, child: Text(l.monthMatches)),
            TextButton(onPressed: onFix, child: Text(l.monthFix)),
          ]),
      ]),
    );
  }
}

/// «Ещё → Сверка месяца»: текущий и прошлые месяцы, в которых вёлся учёт.
class MonthCloseListScreen extends StatelessWidget {
  const MonthCloseListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final state = AppScope.of(context).state;
    final fam = context.fam;
    final locale = Localizations.localeOf(context).toString();
    final months = [
      for (var i = 0; i <= 12; i++)
        if (i == 0 || state.hasActivityIn(state.monthOf(-i)) || state.isMonthClosed(state.monthOf(-i))) state.monthOf(-i),
    ];
    return Scaffold(
      appBar: AppBar(title: Text(l.monthCloseTitle)),
      body: ListenableBuilder(
        listenable: state,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          children: [
            Text(l.monthCloseIntro, style: TextStyle(fontSize: 13, color: fam.text2)),
            const SizedBox(height: 12),
            for (final m in months)
              AppCard(
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => MonthCloseScreen(month: m))),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${toBeginningOfSentenceCase(DateFormat.LLLL(locale).format(m))} ${m.year}', style: const TextStyle(fontWeight: FontWeight.w600)),
                      Text(
                        state.isMonthClosed(m) ? l.monthListStatusClosed : (m == state.monthStart ? l.monthListStatusNow : l.monthListStatusOpen),
                        style: TextStyle(fontSize: 12, color: state.isMonthClosed(m) ? fam.income : fam.text2),
                      ),
                    ]),
                  ),
                  const Icon(Icons.chevron_right),
                ]),
              ),
          ],
        ),
      ),
    );
  }
}
