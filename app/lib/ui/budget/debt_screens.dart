import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';

import '../../state/app_scope.dart';
import '../../state/app_state.dart';
import '../../state/models.dart';
import '../../theme/app_theme.dart';
import '../ops/transaction_tile.dart';
import '../widgets/common.dart';
import 'sheets.dart';

/// S19 — кредит, рассрочка или кредитная карта: остаток, модельный график,
/// история платежей.
class BankDebtScreen extends StatelessWidget {
  const BankDebtScreen({super.key, required this.debtId});
  final String debtId;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final state = AppScope.of(context).state;
    final fam = context.fam;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final debt = state.bankDebt(debtId);
        if (debt == null) return const Scaffold();
        final balance = state.debtBalance(debtId);
        final planned = state.plannedForDebt(debtId);
        final payment = planned?.amount ?? 0;
        final schedule = payment > 0 && balance > 0 ? buildSchedule(principal: balance, annualRatePercent: debt.rate, payment: payment) : null;
        final history = state.debtTransactions(liabilityAccount(debtId)).where((t) => t.type != EventType.opening).toList();

        return Scaffold(
          appBar: AppBar(title: Text(debt.name)),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            children: [
              AppCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${debtKindName(l, debt.kind)} · ${l.balanceLeft}', style: TextStyle(fontSize: 12, color: fam.text2)),
                  BigMoney(balance, color: fam.debt),
                  const SizedBox(height: 6),
                  if (payment > 0) Text('${l.monthlyPayment}: ${formatMoney(payment)} · ${l.everyMonthOn(planned!.day)}', style: TextStyle(fontSize: 12, color: fam.text2)),
                  Text('${l.rate}: ${debt.rate == 0 ? '0' : debt.rate}', style: TextStyle(fontSize: 12, color: fam.text2)),
                ]),
              ),
              Row(children: [
                Expanded(child: FilledButton(onPressed: balance > 0 ? () => showBankPaySheet(context, debt) : null, child: Text(l.pay))),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: balance <= 0 || payment <= 0
                        ? null
                        : () => state.pro
                            ? Navigator.push(context, MaterialPageRoute(builder: (_) => EarlyRepaymentScreen(debtId: debtId)))
                            : showProGate(context, l.proGateEarly),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [Flexible(child: Text(l.earlyShort, overflow: TextOverflow.ellipsis)), if (!state.pro) ...[const SizedBox(width: 6), const ProBadge()]]),
                  ),
                ),
              ]),
              if (schedule != null) ...[
                SectionHeader(l.schedule),
                AppCard(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(l.scheduleSummary(schedule.months, formatEstimate(schedule.totalInterest)), style: TextStyle(fontSize: 13, color: fam.text2)),
                    const SizedBox(height: 8),
                    Table(
                      columnWidths: const {0: FixedColumnWidth(32)},
                      children: [
                        TableRow(children: [
                          for (final h in ['#', l.payment, l.interestShort, l.balanceLeft])
                            Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(h, textAlign: h == '#' ? TextAlign.left : TextAlign.right, style: TextStyle(fontSize: 11, color: fam.text2))),
                        ]),
                        for (final r in schedule.rows.take(24))
                          TableRow(children: [
                            Text('${r.index}', style: const TextStyle(fontSize: 12)),
                            Text(formatMoney(r.payment, symbol: ''), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12, fontFeatures: [FontFeature.tabularFigures()])),
                            Text(formatMoney(r.interest, symbol: ''), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12, fontFeatures: [FontFeature.tabularFigures()])),
                            Text(formatMoney(r.balanceAfter, symbol: ''), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12, fontFeatures: [FontFeature.tabularFigures()])),
                          ]),
                      ],
                    ),
                    if (schedule.rows.length > 24) Text('…', style: TextStyle(color: fam.text2)),
                    const SizedBox(height: 8),
                    Text(l.scheduleNote, style: TextStyle(fontSize: 11, color: fam.text2)),
                  ]),
                ),
              ] else if (balance > 0 && payment > 0)
                InfoBanner(l.paymentBelowInterest, color: fam.warnBg),
              SectionHeader(l.history),
              if (history.isEmpty)
                EmptyHint(l.noPaymentsYet)
              else
                AppCard(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Column(children: [for (final t in history) TransactionTile(t)]),
                ),
              const SizedBox(height: 12),
              TextButton(
                style: TextButton.styleFrom(foregroundColor: fam.expense),
                onPressed: balance != 0
                    ? null
                    : () async {
                        final nav = Navigator.of(context);
                        if (!await confirm(context, title: l.deleteDebt, action: l.delete) || !context.mounted) return;
                        final ok = await runAction(context, () => state.sendBatch([
                              {'type': 'deleteEntity', 'kind': 'debt', 'entityId': debtId},
                              if (planned != null) {'type': 'deleteEntity', 'kind': 'planned', 'entityId': planned.id},
                            ]));
                        if (ok) nav.pop();
                      },
                child: Text(balance != 0 ? l.deleteDebtWhenPaid : l.deleteDebt),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// S20 — личный долг: остаток, выдачи и возвраты.
class PersonDebtScreen extends StatelessWidget {
  const PersonDebtScreen({super.key, required this.person});
  final String person;

  Future<void> _writeOff(BuildContext context, AppState state, PersonDebt d) async {
    final l = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final ok = await confirm(
      context,
      title: d.oweMe ? l.writeOffTitle(d.person) : l.debtForgivenTitle(d.person),
      message: d.oweMe ? l.writeOffReceivableBody(formatMoney(d.amount)) : l.writeOffLiabilityBody(formatMoney(d.amount)),
      action: d.oweMe ? l.writeOffAction : l.closeDebtAction,
    );
    if (!ok || !context.mounted) return;
    if (await runAction(context, () => state.writeOffDebt(d))) {
      messenger.showSnackBar(SnackBar(content: Text(d.oweMe ? l.writeOffDone : l.debtForgiven)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final state = AppScope.of(context).state;
    final fam = context.fam;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final debts = state.personDebts.where((d) => d.person == person).toList();
        final history = [
          ...state.debtTransactions(receivableAccount(person)),
          ...state.debtTransactions(liabilityAccount(person)),
        ]..sort((a, b) => b.date.compareTo(a.date));
        return Scaffold(
          appBar: AppBar(title: Text(person)),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            children: [
              if (debts.isEmpty) AppCard(child: Text(l.debtClosed, style: TextStyle(color: fam.income))),
              for (final d in debts)
                AppCard(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(d.oweMe ? l.oweMe : l.iOwe, style: TextStyle(fontSize: 12, color: fam.text2)),
                    BigMoney(d.amount, color: d.oweMe ? fam.income : fam.expense),
                    const SizedBox(height: 8),
                    FilledButton(onPressed: () => showPersonRepaySheet(context, d), child: Text(d.oweMe ? l.returnedToMe : l.iReturned)),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: () => _writeOff(context, state, d),
                      child: Text(d.oweMe ? l.writeOffDebt : l.debtForgivenAction),
                    ),
                  ]),
                ),
              SectionHeader(l.history),
              if (history.isEmpty)
                EmptyHint(l.noOperations)
              else
                AppCard(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Column(children: [for (final t in history) TransactionTile(t)]),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// S21 — досрочное погашение (Pro): сократить срок или уменьшить платёж.
class EarlyRepaymentScreen extends StatefulWidget {
  const EarlyRepaymentScreen({super.key, required this.debtId});
  final String debtId;

  @override
  State<EarlyRepaymentScreen> createState() => _EarlyRepaymentScreenState();
}

class _EarlyRepaymentScreenState extends State<EarlyRepaymentScreen> {
  final _extra = TextEditingController();

  @override
  void dispose() {
    _extra.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final state = AppScope.of(context).state;
    final fam = context.fam;
    final debt = state.bankDebt(widget.debtId)!;
    final balance = state.debtBalance(widget.debtId);
    final payment = state.plannedForDebt(widget.debtId)?.amount ?? 0;
    final extra = (parseAmount(_extra.text) ?? 0).clamp(0, balance);
    final r = earlyRepayment(balance: balance, annualRatePercent: debt.rate, payment: payment, extra: extra);

    Widget option(String title, EarlyRepaymentOption? o, {bool best = false}) => Expanded(
          child: AppCard(
            color: best ? fam.incomeBg : null,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: TextStyle(fontSize: 12, color: fam.text2)),
              const SizedBox(height: 4),
              if (o == null)
                const Text('—')
              else ...[
                Text(l.paymentsCount(o.months), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                Text('${l.payment}: ${formatEstimate(o.payment)}', style: const TextStyle(fontSize: 12)),
                const SizedBox(height: 6),
                Text('${l.interestSaved}: ${formatEstimate(o.interestSaved)}', style: TextStyle(fontSize: 12, color: fam.income, fontWeight: FontWeight.w600)),
              ],
            ]),
          ),
        );

    return Scaffold(
      appBar: AppBar(title: Text(l.early)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          AppCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${debt.name} · ${l.balanceLeft} ${formatMoney(balance)} · ${debt.rate}% · ${l.payment} ${formatMoney(payment)}', style: TextStyle(fontSize: 12, color: fam.text2)),
              const SizedBox(height: 12),
              AmountField(controller: _extra, label: l.earlyAmount, onChanged: (_) => setState(() {})),
            ]),
          ),
          if (r.reason != null)
            InfoBanner(l.paymentBelowInterest, color: fam.warnBg)
          else ...[
            Text(l.withoutEarly(l.paymentsCount(r.baseline.months), formatEstimate(r.baseline.totalInterest)), style: TextStyle(fontSize: 12, color: fam.text2)),
            const SizedBox(height: 8),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              option(l.shortenTerm, r.shortenTerm, best: extra > 0),
              const SizedBox(width: 8),
              option(l.reducePayment, r.reducePayment),
            ]),
            Text(l.earlyNote, style: TextStyle(fontSize: 11, color: fam.text2)),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: extra <= 0 ? null : () => showBankPaySheet(context, debt, principal: extra),
              child: Text(l.makeEarlyPayment),
            ),
          ],
        ],
      ),
    );
  }
}

/// S22 — стратегия погашения (Pro): лавина против снежного кома при одном бюджете.
class DebtStrategyScreen extends StatefulWidget {
  const DebtStrategyScreen({super.key});

  @override
  State<DebtStrategyScreen> createState() => _DebtStrategyScreenState();
}

class _DebtStrategyScreenState extends State<DebtStrategyScreen> {
  late final TextEditingController _budget;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = AppScope.of(context).state;
    final min = state.bankDebts.fold<int>(0, (s, d) => s + (state.plannedForDebt(d.id)?.amount ?? 0));
    _budget = TextEditingController(text: amountToField(min));
  }

  @override
  void dispose() {
    _budget.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final state = AppScope.of(context).state;
    final fam = context.fam;
    final debts = [
      for (final d in state.bankDebts)
        if (state.debtBalance(d.id) > 0)
          DebtInput(id: d.id, balance: state.debtBalance(d.id), annualRatePercent: d.rate, minPayment: state.plannedForDebt(d.id)?.amount ?? 0),
    ];
    final budget = parseAmount(_budget.text) ?? 0;
    final names = {for (final d in state.bankDebts) d.id: d.name};
    final a = simulateDebtStrategy(debts: debts, monthlyBudget: budget, strategy: DebtStrategy.avalanche);
    final s = simulateDebtStrategy(debts: debts, monthlyBudget: budget, strategy: DebtStrategy.snowball);

    Widget card(String title, String hint, DebtStrategyResult r, bool best) => Expanded(
          child: AppCard(
            color: best ? fam.incomeBg : null,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
              Text(hint, style: TextStyle(fontSize: 11, color: fam.text2)),
              const SizedBox(height: 8),
              if (!r.feasible)
                Text(l.budgetBelowMinimum, style: TextStyle(fontSize: 12, color: fam.expense))
              else ...[
                Text(l.paymentsCount(r.months), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                Text('${l.interestShort}: ${formatEstimate(r.totalInterest)}', style: const TextStyle(fontSize: 12)),
                const SizedBox(height: 6),
                for (final id in r.order) Text('• ${names[id]}', style: TextStyle(fontSize: 12, color: fam.text2)),
              ],
            ]),
          ),
        );

    return Scaffold(
      appBar: AppBar(title: Text(l.strategy)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          if (debts.isEmpty)
            EmptyHint(l.noDebts)
          else ...[
            AppCard(child: AmountField(controller: _budget, label: l.debtBudget, onChanged: (_) => setState(() {}))),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              card(l.avalanche, l.avalancheHint, a, a.feasible && a.totalInterest <= s.totalInterest),
              const SizedBox(width: 8),
              card(l.snowball, l.snowballHint, s, s.feasible && s.totalInterest < a.totalInterest),
            ]),
            Text(l.strategyNote, style: TextStyle(fontSize: 11, color: fam.text2)),
          ],
        ],
      ),
    );
  }
}
