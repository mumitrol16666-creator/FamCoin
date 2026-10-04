import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../state/app_scope.dart';
import '../../theme/app_theme.dart';
import '../widgets/common.dart';

/// Сравнение фактических результатов месяцев с переходом к деталям.
class HistoryTab extends StatelessWidget {
  const HistoryTab({super.key, required this.onOpenMonth, this.months = 6});
  final ValueChanged<int> onOpenMonth;
  final int months;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final fam = context.fam;
    final state = AppScope.of(context).state;
    final locale = Localizations.localeOf(context).toString();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        SectionHeader(l.monthsCompare),
        AppCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Column(children: [
            for (var k = 0; k < months; k++)
              Builder(builder: (context) {
                final month = state.monthOf(-k);
                final report = state.reportFor(month);
                return InkWell(
                  onTap: () => onOpenMonth(-k),
                  child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(child: Text(toBeginningOfSentenceCase(DateFormat.yMMMM(locale).format(month)), style: const TextStyle(fontWeight: FontWeight.w600))),
                      if (report.income > 0) Text('${(report.result * 100 / report.income).round()}%', style: TextStyle(color: fam.text2, fontSize: 12)),
                      const Icon(Icons.chevron_right, size: 18),
                    ]),
                    const SizedBox(height: 4),
                    Row(children: [
                      Expanded(child: MoneyText(report.income, sign: true, color: fam.income, style: const TextStyle(fontSize: 13))),
                      Expanded(child: MoneyText(-report.total, sign: true, color: fam.expense, style: const TextStyle(fontSize: 13))),
                    ]),
                    if (k < months - 1) const Divider(height: 16),
                  ]),
                  ),
                );
              }),
          ]),
        ),
      ],
    );
  }
}
