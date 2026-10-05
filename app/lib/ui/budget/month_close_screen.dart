import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../state/app_scope.dart';
import '../../state/app_state.dart';
import '../../state/models.dart';
import '../../theme/app_theme.dart';
import '../widgets/common.dart';
import '../ops/transaction_tile.dart';
import 'sheets.dart';

/// Сверяем завершённый месяц по остаткам на его последний день.
class MonthCloseScreen extends StatefulWidget {
  const MonthCloseScreen({super.key, required this.month});
  final DateTime month;

  @override
  State<MonthCloseScreen> createState() => _MonthCloseScreenState();
}

class _MonthCloseScreenState extends State<MonthCloseScreen> {
  // Запоминаем именно проверенную сумму: правка платежа снимает подтверждение.
  final _checked = <String, int>{};
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  bool _saving = false;

  Future<void> _close(AppState state) async {
    setState(() => _saving = true);
    final ok = await runAction(context, () => state.closeMonth(widget.month));
    if (mounted) {
      setState(() => _saving = false);
      if (ok) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _scroll.hasClients) {
            _scroll.jumpTo(0);
          }
        });
      }
    }
    if (!ok && mounted) await runAction(context, state.refresh);
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
          final m = DateTime(widget.month.year, widget.month.month, 1);
          final lastDay = reconciliationEnd(m);
          final date = DateFormat('d MMMM y', locale).format(lastDay);
          final available = canReconcileMonth(m, state.today);
          final sum = state.monthSummary(m);
          final closed = state.isMonthClosed(m);
          final balances = state.balancesAtMonthEnd(m);
          final accounts = state.moneyAccounts.where((a) => balances.containsKey(a.id)).toList();
          final unchecked = [
            for (final a in accounts)
              if (_checked[a.id] != balances[a.id]) a.id,
          ];
          final due = state.unpaidOccurrences(m, lastDay);
          final savedAt = state.monthReconciliation(m)?['closedAt'] as String?;

          return Column(
            children: [
              Expanded(
                child: ListView(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
                  children: [
                    Text(l.monthCloseIntro, style: TextStyle(fontSize: 13, color: fam.text2)),
                    const SizedBox(height: 12),
                    if (!available) AppCard(child: Text(l.monthAvailableFrom(DateFormat('d MMMM y', locale).format(DateTime(m.year, m.month + 1, 1))))),
                    if (available && state.monthNeedsRecheck(m)) _RecheckCard(state: state, month: m),
                    if (closed && savedAt != null)
                      AppCard(
                        color: fam.income.withValues(alpha: .12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(l.monthClosed, style: Theme.of(context).textTheme.titleMedium),
                            const SizedBox(height: 6),
                            Text(l.monthClosedDone),
                            const SizedBox(height: 6),
                            Text(
                              l.monthSnapshotSaved(DateFormat.yMd(locale).add_Hm().format(DateTime.parse(savedAt).toUtc().add(const Duration(hours: 5)))),
                              style: TextStyle(fontSize: 12, color: fam.text2),
                            ),
                          ],
                        ),
                      ),
                    _SummaryCard(sum: sum),
                    if (available) ...[
                      _Step(
                        title: l.monthStepBalances,
                        hint: l.monthBalancesAsOf(date),
                        children: [
                          Text(l.monthStepBalancesHint, style: TextStyle(fontSize: 12, color: fam.text2)),
                          const SizedBox(height: 12),
                          for (final a in accounts)
                            _AccountRow(
                              name: a.archived ? '${a.name} · ${l.archived}' : a.name,
                              balance: balances[a.id]!,
                              checked: closed || _checked[a.id] == balances[a.id],
                              onMatches: closed ? null : () => setState(() => _checked[a.id] = balances[a.id]!),
                              onFix: closed
                                  ? null
                                  : () async {
                                      final saved = await showAdjustBalanceSheet(context, a.id, asOf: lastDay);
                                      if (saved && mounted) {
                                        setState(() => _checked[a.id] = state.balancesAtMonthEnd(m)[a.id]!);
                                      }
                                    },
                            ),
                          if (!closed && unchecked.length > 1)
                            TextButton.icon(
                              icon: const Icon(Icons.done_all, size: 18),
                              label: Text(l.monthAllMatch),
                              onPressed: () => setState(() {
                                for (final id in unchecked) {
                                  _checked[id] = balances[id]!;
                                }
                              }),
                            ),
                          const Divider(),
                          Text(l.monthBalanceTotal(date), style: TextStyle(fontSize: 12, color: fam.text2)),
                          MoneyText(balances.values.fold(0, (a, b) => a + b), style: const TextStyle(fontSize: 22)),
                        ],
                      ),
                      if (!closed)
                        _Step(
                          title: l.monthStepPayments,
                          hint: due.isEmpty ? null : l.monthPaymentsHint,
                          children: [
                            if (due.isEmpty)
                              Text(
                                l.monthNoPendingPayments,
                                style: TextStyle(color: fam.income, fontWeight: FontWeight.w600),
                              )
                            else
                              for (final d in due) ...[
                                ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(d.planned.name),
                                  subtitle: Text(DateFormat.yMd(locale).format(d.date)),
                                  trailing: MoneyText(d.planned.amount),
                                ),
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: TextButton(
                                    onPressed: () => showPayDueSheet(context, d, date: d.date, title: l.payAlreadyTitle(d.planned.name)),
                                    child: Text(l.monthAlreadyPaid),
                                  ),
                                ),
                              ],
                          ],
                        ),
                    ],
                  ],
                ),
              ),
              if (available)
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!closed && unchecked.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Text(l.monthCheckAllHint, style: TextStyle(fontSize: 13, color: fam.text2)),
                          ),
                        FilledButton(
                          onPressed: closed
                              ? () => Navigator.of(context).maybePop()
                              : _saving || state.busy || unchecked.isNotEmpty
                              ? null
                              : () => _close(state),
                          child: Text(
                            closed
                                ? l.monthDone
                                : _saving
                                ? l.monthSaving
                                : l.monthCloseAction,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _RecheckCard extends StatelessWidget {
  const _RecheckCard({required this.state, required this.month});
  final AppState state;
  final DateTime month;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final fam = context.fam;
    if (state.monthHasLegacyMark(month)) {
      return AppCard(color: fam.warn.withValues(alpha: .12), child: Text(l.monthLegacyHint));
    }
    final changes = state.monthChanges(month)!;
    final transactions = state.monthChangesSinceConfirmation(month);
    final legacy = reconciliationVersion(state.monthReconciliation(month)!['snapshot'] as Map) < 2;
    final locale = Localizations.localeOf(context).toString();
    Widget row(String label, ReconciliationAmountChange change) =>
        Padding(padding: const EdgeInsets.only(top: 8), child: Text(l.monthChangedAmount(label, moneyInText(change.before), moneyInText(change.after))));
    return AppCard(
      color: fam.warn.withValues(alpha: .12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l.monthRecheckStatus, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(l.monthRecheckHint),
          for (final e in changes.balances.entries) row(state.accountInfo(e.key)?.name ?? e.key, e.value),
          for (final e in changes.totals.entries)
            row(switch (e.key) {
              'income' => legacy ? l.legacyReconciliationIncome : l.reportIncome,
              'expense' => legacy ? l.legacyReconciliationExpense : l.reportExpense,
              _ => l.cashFlow,
            }, e.value),
          if (transactions == null) ...[
            const SizedBox(height: 10),
            Text(l.monthChangeHistoryUnavailable, style: TextStyle(fontSize: 12, color: fam.text2)),
          ] else if (transactions.isNotEmpty)
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text(l.monthChangesHistoryTitle),
              subtitle: Text(l.monthChangesHistoryHint, style: const TextStyle(fontSize: 12)),
              children: [
                for (final tx in transactions.take(20))
                  Builder(
                    builder: (context) {
                      final view = TxView.of(state, l, tx);
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('${DateFormat.yMd(locale).format(tx.date)} · ${view.title} · ${moneyInText(view.amount)}'),
                            if (view.subtitle.isNotEmpty) Text(view.subtitle.join(' · '), style: TextStyle(fontSize: 12, color: fam.text2)),
                          ],
                        ),
                      );
                    },
                  ),
                if (transactions.length > 20) Text(l.monthChangesRecentOnly),
              ],
            ),
        ],
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
    Widget kpi(String label, int minor, Color color) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 12, color: fam.text2)),
        const SizedBox(height: 2),
        MoneyText(minor, color: color, style: const TextStyle(fontSize: 17)),
      ],
    );

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (sum.current) ...[Text(l.monthPartial, style: TextStyle(fontSize: 12, color: fam.warn)), const SizedBox(height: 8)],
          Row(
            children: [
              Expanded(child: kpi(l.reportIncome, sum.income, fam.income)),
              Expanded(child: kpi(l.reportExpense, sum.expense, fam.expense)),
            ],
          ),
          const Divider(height: 20),
          Row(
            children: [
              Expanded(
                child: Text(l.monthResultLabel, style: TextStyle(color: fam.text2)),
              ),
              InfoTip(l.reportHelpBody, title: l.reportHelpTitle),
              MoneyText(sum.result, sign: true, style: const TextStyle(fontSize: 17)),
            ],
          ),
          const SizedBox(height: 6),
          Text(l.monthResultHint, style: TextStyle(fontSize: 12, color: fam.text2)),
          if (sum.borrowed > 0)
            Text(l.reportBorrowed(moneyInText(sum.borrowed)), style: TextStyle(fontSize: 12, color: fam.text2)),
          if (sum.debtPayments > 0)
            Text(l.reportIncludesDebts(moneyInText(sum.debtPayments)), style: TextStyle(fontSize: 12, color: fam.text2)),
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
                child: Row(
                  children: [
                    CategoryGlyph(categoryById(e.key), size: 18, color: fam.text2),
                    const SizedBox(width: 8),
                    Expanded(child: Text(categoryName(l, e.key), maxLines: 1, overflow: TextOverflow.ellipsis)),
                    MoneyText(e.value),
                  ],
                ),
              ),
          ],
          if (sum.paymentsTotal > 0 || sum.adjustments != 0 || sum.unexpected > 0) const Divider(height: 20),
          if (sum.paymentsTotal > 0) Text(l.monthPaymentsLine(sum.paymentsPaid, sum.paymentsTotal), style: TextStyle(fontSize: 13, color: fam.text2)),
          if (sum.unexpected > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(l.unexpectedTitle, style: TextStyle(fontSize: 13, color: fam.text2)),
                  ),
                  MoneyText(sum.unexpected, style: const TextStyle(fontSize: 13)),
                ],
              ),
            ),
          if (sum.adjustments != 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(l.adjustments, style: TextStyle(fontSize: 13, color: fam.text2)),
                  ),
                  MoneyText(sum.adjustments, sign: true, style: const TextStyle(fontSize: 13)),
                ],
              ),
            ),
        ],
      ),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          if (hint != null) ...[const SizedBox(height: 4), Text(hint!, style: TextStyle(fontSize: 12, color: fam.text2))],
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    );
  }
}

/// Счёт в сверке: остаток в приложении и два ответа — «совпадает» или «исправить».
class _AccountRow extends StatelessWidget {
  const _AccountRow({required this.name, required this.balance, required this.checked, required this.onMatches, required this.onFix});
  final String name;
  final int balance;
  final bool checked;
  final VoidCallback? onMatches;
  final VoidCallback? onFix;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final fam = context.fam;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis)),
              MoneyText(balance),
            ],
          ),
          if (checked)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                children: [
                  Icon(Icons.check_circle, size: 16, color: fam.income),
                  const SizedBox(width: 6),
                  Text(l.monthChecked, style: TextStyle(fontSize: 12, color: fam.income)),
                  const Spacer(),
                  if (onFix != null) TextButton(onPressed: onFix, child: Text(l.monthFix)),
                ],
              ),
            )
          else
            Wrap(
              spacing: 8,
              children: [
                TextButton(onPressed: onMatches, child: Text(l.monthMatches)),
                if (onFix != null) TextButton(onPressed: onFix, child: Text(l.monthFix)),
              ],
            ),
        ],
      ),
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
    return Scaffold(
      appBar: AppBar(title: Text(l.monthCloseTitle)),
      body: ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          final months = <DateTime>{
            state.monthStart,
            for (final tx in state.ledger.transactions)
              if (!tx.date.isAfter(state.today) && tx.postings.isNotEmpty) DateTime(tx.date.year, tx.date.month, 1),
            for (final key in state.monthReconciliations.keys) DateTime.parse('$key-01'),
            for (final key in (state.profile['closedMonths'] as List?) ?? const []) DateTime.parse('$key-01'),
          }.where((m) => !m.isAfter(state.monthStart)).toList()..sort((a, b) => b.compareTo(a));
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            children: [
              Text(l.monthCloseIntro, style: TextStyle(fontSize: 13, color: fam.text2)),
              const SizedBox(height: 12),
              for (final m in months)
                AppCard(
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => MonthCloseScreen(month: m))),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${toBeginningOfSentenceCase(DateFormat.LLLL(locale).format(m))} ${m.year}',
                              style: const TextStyle(fontWeight: FontWeight.w600),
                            ),
                            Text(
                              state.isMonthClosed(m)
                                  ? l.monthListStatusClosed
                                  : (m == state.monthStart
                                        ? l.monthAvailableFrom(DateFormat('d MMMM y', locale).format(DateTime(m.year, m.month + 1, 1)))
                                        : state.monthHasLegacyMark(m)
                                        ? l.monthLegacyStatus
                                        : state.monthNeedsRecheck(m)
                                        ? l.monthRecheckStatus
                                        : l.monthListStatusOpen),
                              style: TextStyle(fontSize: 12, color: state.isMonthClosed(m) ? fam.income : fam.text2),
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.chevron_right),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
