import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';

import '../../state/app_scope.dart';
import '../../theme/app_theme.dart';
import '../budget/debt_load_screen.dart';
import '../more/accounts_screen.dart';
import '../widgets/common.dart';
import 'trend_chart.dart';

/// Капитал (D66): активы минус обязательства — отдельно от аналитики периода
/// (владелец 29.09.2026: сверху за месяц 0 ₸, а снизу капитал — путаница).
/// Здесь только «что есть сейчас» и как это менялось.
class CapitalTab extends StatelessWidget {
  const CapitalTab({super.key});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final fam = context.fam;
    final state = AppScope.of(context).state;
    final nw = state.ledger.netWorth();
    final history = state.netWorthHistory(6);
    final changed = history.length < 2 ? 0 : nw.capital - history.first.capital;
    final labels = List<String>.generate(history.length, (i) => i == history.length - 1 ? l.now : '−${history.length - 1 - i}${l.monthsShort}');

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        Row(children: [
          Expanded(child: SectionHeader(l.netCapital)),
          InfoTip(l.capitalHelpBody, title: l.capitalHelpTitle),
        ]),
        AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _row(context, l.assets, nw.assets),
            _row(context, l.money, nw.money, muted: true),
            if (nw.receivables > 0) _row(context, l.oweMe, nw.receivables, muted: true, color: fam.income),
            if (nw.otherAssets != 0) _row(context, l.otherAssets, nw.otherAssets, muted: true),
            _row(context, l.liabilities, -nw.liabilities, color: fam.debt),
            const Divider(height: 20),
            Row(children: [
              Expanded(child: Text(l.capital, style: const TextStyle(fontWeight: FontWeight.w700))),
              MoneyText(nw.capital, style: const TextStyle(fontSize: 18)),
            ]),
            if (changed != 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  l.capitalChanged(changed > 0 ? '↑' : '↓', formatMoney(changed.abs())),
                  style: TextStyle(fontSize: 12, color: changed > 0 ? fam.income : fam.expense),
                ),
              ),
          ]),
        ),

        SectionHeader(l.capitalTrend),
        AppCard(child: TrendChart(values: [for (final n in history) n.capital], labels: labels)),

        SectionHeader(l.debtLoad, action: l.details, onAction: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const DebtLoadScreen()))),
        Builder(builder: (context) {
          final status = state.debtLoadStatus;
          if (status.totalDebt == 0) return EmptyHint(l.noDebts, icon: Icons.handshake_outlined);
          return AppCard(
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const DebtLoadScreen())),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(l.totalDebt, style: TextStyle(fontSize: 12, color: fam.text2)),
                  MoneyText(status.totalDebt, color: fam.debt, style: const TextStyle(fontSize: 18)),
                  if (status.incomeSharePercent != null)
                    Text(status.incomeSharePercent! > 100 ? l.incomeIncompleteShort : l.incomeShareShort(status.incomeSharePercent!.round()), style: TextStyle(fontSize: 12, color: fam.text2)),
                ]),
              ),
              const Icon(Icons.chevron_right),
            ]),
          );
        }),

        AppCard(
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AccountsScreen())),
          child: Row(children: [
            Expanded(child: Text(l.accounts)),
            const Icon(Icons.chevron_right),
          ]),
        ),
      ],
    );
  }

  Widget _row(BuildContext context, String label, int value, {bool muted = false, Color? color}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Expanded(child: Padding(padding: EdgeInsets.only(left: muted ? 12 : 0), child: Text(label, style: TextStyle(color: context.fam.text2, fontSize: muted ? 12 : 14)))),
          MoneyText(value, color: color, style: muted ? const TextStyle(fontSize: 12) : null),
        ]),
      );
}
