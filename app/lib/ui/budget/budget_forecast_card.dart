import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';

import '../../state/app_scope.dart';
import '../../theme/app_theme.dart';
import '../widgets/common.dart';

/// Прогноз относится к планированию: показывается только в «Бюджете».
class BudgetForecastCard extends StatelessWidget {
  const BudgetForecastCard({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context).state;
    final l = context.l10n;
    final fam = context.fam;
    final f = state.monthEndForecast;
    final negative = f.estimate < 0;
    return AppCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text(l.forecastEstimate, style: TextStyle(color: fam.text2))),
        MoneyText(f.estimate, color: negative ? fam.expense : null, style: const TextStyle(fontSize: 18)),
      ]),
      const SizedBox(height: 4),
      Text(l.forecastRange(formatMoney(f.rangeLow), formatMoney(f.rangeHigh)), style: TextStyle(fontSize: 12, color: fam.text2)),
      const SizedBox(height: 8),
      Text('${l.forecastObligations}: −${formatMoney(f.remainingObligations)}', style: TextStyle(fontSize: 12, color: fam.text2)),
      Text('${l.forecastSpend}: ≈−${formatMoney(f.expectedRegularSpend)}', style: TextStyle(fontSize: 12, color: fam.text2)),
      if (f.expectedIncome > 0) Text('${l.forecastIncome}: +${formatMoney(f.expectedIncome)}', style: TextStyle(fontSize: 12, color: fam.text2)),
      // Чему в оценке не стоит верить (D92): начало месяца и неполные доходы.
      if (state.today.day < 7) Padding(padding: const EdgeInsets.only(top: 6), child: Text(l.forecastEarly, style: TextStyle(fontSize: 12, color: fam.warn))),
      if (state.incomeLooksIncomplete) Padding(padding: const EdgeInsets.only(top: 6), child: Text(l.incomeIncompleteNote, style: TextStyle(fontSize: 12, color: fam.warn))),
    ]));
  }
}
