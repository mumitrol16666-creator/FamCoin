import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../state/app_scope.dart';
import '../../theme/app_theme.dart';
import '../widgets/common.dart';
import 'trend_chart.dart';

/// История (D66): доход/расход и капитал по последним месяцам — увидеть
/// направление, а не только текущий месяц.
class HistoryTab extends StatelessWidget {
  const HistoryTab({super.key, this.months = 6});
  final int months;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final fam = context.fam;
    final state = AppScope.of(context).state;
    final locale = Localizations.localeOf(context).toString();
    final history = state.netWorthHistory(months);
    final labels = List<String>.generate(months, (i) => i == months - 1 ? l.now : '−${months - 1 - i}${l.monthsShort}');

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        SectionHeader(l.capitalTrend),
        AppCard(child: TrendChart(values: [for (final n in history) n.capital], labels: labels)),

        SectionHeader(l.monthsCompare),
        AppCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Column(children: [
            for (var k = months - 1; k >= 0; k--)
              Builder(builder: (context) {
                final month = state.monthOf(-k);
                final report = state.reportFor(month);
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(child: Text(toBeginningOfSentenceCase(DateFormat.LLLL(locale).format(month)), style: const TextStyle(fontWeight: FontWeight.w600))),
                      if (report.income > 0) Text('${(report.result * 100 / report.income).round()}%', style: TextStyle(color: fam.text2, fontSize: 12)),
                    ]),
                    const SizedBox(height: 4),
                    Row(children: [
                      Expanded(child: MoneyText(report.income, sign: true, color: fam.income, style: const TextStyle(fontSize: 13))),
                      Expanded(child: MoneyText(-report.expense, sign: true, color: fam.expense, style: const TextStyle(fontSize: 13))),
                    ]),
                    if (k > 0) const Divider(height: 16),
                  ]),
                );
              }),
          ]),
        ),
      ],
    );
  }
}
