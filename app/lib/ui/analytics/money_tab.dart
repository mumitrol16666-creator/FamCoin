import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';

import '../../state/app_scope.dart';
import '../../theme/app_theme.dart';
import '../budget/budget_pages.dart';
import '../budget/debt_load_screen.dart';
import '../budget/sheets.dart';
import '../more/accounts_screen.dart';
import '../widgets/common.dart';
import 'trend_chart.dart';

/// «Деньги» (D136), раньше «Капитал»: что у человека есть сейчас. Сверху — сколько
/// денег всего и по каким счетам лежат, ниже — кто кому должен, итоговый капитал
/// и как он менялся за год. Период и его отчёты — на вкладке «Месяц».
class MoneyTab extends StatelessWidget {
  const MoneyTab({super.key});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final fam = context.fam;
    final state = AppScope.of(context).state;
    final nw = state.ledger.netWorth();
    final history = state.netWorthHistory(12);
    final changed = history.length < 2 ? 0 : nw.capital - history.first.capital;
    final labels = List<String>.generate(history.length, (i) => i == history.length - 1 ? l.now : '−${history.length - 1 - i}${l.monthsShort}');
    final accounts = [...state.activeAccounts, ...state.piggyAccounts];
    final inPiggies = state.piggyAccounts.fold<int>(0, (s, a) => s + state.ledger.balance(a.id));

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        // Главное: сколько денег сейчас.
        AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(l.moneyTotal, style: TextStyle(fontSize: 13, color: fam.text2)),
            BigMoney(nw.money),
            if (inPiggies > 0)
              Padding(padding: const EdgeInsets.only(top: 4), child: Text(l.moneyInPiggies(formatMoney(inPiggies)), style: TextStyle(fontSize: 12, color: fam.text2))),
          ]),
        ),

        SectionHeader(l.accounts, action: l.details, onAction: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AccountsScreen()))),
        AppCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Column(children: [
            for (final a in accounts)
              InkWell(
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AccountScreen(accountId: a.id))),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(children: [
                    Icon(accountTypeIcon(a.type), size: 20, color: a.color),
                    const SizedBox(width: 12),
                    Expanded(child: Text(a.name, overflow: TextOverflow.ellipsis)),
                    _fit(MoneyText(state.ledger.balance(a.id))),
                  ]),
                ),
              ),
            InkWell(
              onTap: () => addAccountFlow(context),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(children: [
                  Icon(Icons.add, size: 20, color: context.scheme.primary),
                  const SizedBox(width: 12),
                  Expanded(child: Text(l.addAccount, style: TextStyle(color: context.scheme.primary))),
                  if (!state.pro) const ProBadge(),
                ]),
              ),
            ),
          ]),
        ),

        // Кто кому должен: строки ведут в раздел долгов.
        if (nw.receivables > 0 || nw.liabilities > 0) ...[
          SectionHeader(l.debts),
          AppCard(
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BudgetDebtsPage())),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (nw.receivables > 0)
                    Row(children: [Expanded(child: Text(l.oweMe, style: TextStyle(color: fam.text2))), _fit(MoneyText(nw.receivables, color: fam.income))]),
                  if (nw.liabilities > 0)
                    Row(children: [Expanded(child: Text(l.iOwe, style: TextStyle(color: fam.text2))), _fit(MoneyText(nw.liabilities, color: fam.debt))]),
                ]),
              ),
              const Icon(Icons.chevron_right),
            ]),
          ),
        ],

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
              _fit(MoneyText(nw.capital, style: const TextStyle(fontSize: 18))),
            ]),
            if (changed != 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  l.capitalChanged(changed > 0 ? '↑' : '↓', formatMoney(changed.abs())),
                  style: TextStyle(fontSize: 12, color: changed > 0 ? fam.income : fam.expense),
                ),
              ),
            const SizedBox(height: 12),
            TrendChart(values: [for (final n in history) n.capital], labels: labels),
          ]),
        ),

        Builder(builder: (context) {
          final status = state.debtLoadStatus;
          if (status.totalDebt == 0) return const SizedBox.shrink();
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SectionHeader(l.debtLoad),
            AppCard(
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
            ),
          ]);
        }),
      ],
    );
  }

  Widget _row(BuildContext context, String label, int value, {bool muted = false, Color? color}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Expanded(child: Padding(padding: EdgeInsets.only(left: muted ? 12 : 0), child: Text(label, style: TextStyle(color: context.fam.text2, fontSize: muted ? 12 : 14)))),
          _fit(MoneyText(value, color: color, style: muted ? const TextStyle(fontSize: 12) : null)),
        ]),
      );

  /// Сумма в строке с подписью: на узком экране и крупном шрифте сжимается, а не вылезает.
  Widget _fit(Widget amount) => Flexible(child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerRight, child: amount));
}
