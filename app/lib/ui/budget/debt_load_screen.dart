import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';

import '../../state/app_scope.dart';
import '../../theme/app_theme.dart';
import '../widgets/common.dart';

/// Долговая нагрузка (раздел 9.10, D66): сколько всего должны банкам, какая
/// доля дохода уходит на платежи и когда долг будет погашен — при текущем
/// темпе и при доплате. Личные долги сюда не входят — они не ежемесячный
/// платёж по графику.
class DebtLoadScreen extends StatelessWidget {
  const DebtLoadScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final fam = context.fam;
    return ListenableBuilder(
      listenable: AppScope.of(context).state,
      builder: (context, _) {
        final state = AppScope.of(context).state;
        final status = state.debtLoadStatus;
        return Scaffold(
          appBar: AppBar(title: Text(l.debtLoad)),
          body: status.totalDebt == 0
              ? EmptyHint(l.noDebts, icon: Icons.handshake_outlined)
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                  children: [
                    AppCard(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(l.totalDebt, style: TextStyle(fontSize: 12, color: fam.text2)),
                        BigMoney(status.totalDebt, color: fam.debt),
                        const SizedBox(height: 10),
                        Row(children: [Expanded(child: Text(l.monthlyPayments, style: TextStyle(color: fam.text2))), MoneyText(status.monthlyPayments)]),
                        if (status.incomeSharePercent != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Row(children: [
                              Expanded(child: Text(l.incomeShare, style: TextStyle(color: fam.text2))),
                              Text('${status.incomeSharePercent!.round()}%', style: const TextStyle(fontWeight: FontWeight.w700)),
                            ]),
                          ),
                      ]),
                    ),
                    if (status.paidPercent != null) ...[
                      SectionHeader(l.debtProgress),
                      AppCard(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          UsageBar(value: status.paidPercent!.round(), max: 100, color: context.scheme.primary),
                          const SizedBox(height: 6),
                          Text(l.debtPaidPercent(status.paidPercent!.round()), style: TextStyle(fontSize: 12, color: fam.text2)),
                        ]),
                      ),
                    ],
                    SectionHeader(l.payoffForecast),
                    AppCard(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        _scenario(context, l.currentPace, state.monthsToPayoffAt(), bold: true),
                        const Divider(height: 20),
                        _scenario(context, l.extraPerMonth(formatMoney(kzt(20000))), state.monthsToPayoffAt(extraPerMonth: kzt(20000))),
                        const SizedBox(height: 8),
                        _scenario(context, l.extraPerMonth(formatMoney(kzt(50000))), state.monthsToPayoffAt(extraPerMonth: kzt(50000))),
                      ]),
                    ),
                  ],
                ),
        );
      },
    );
  }

  Widget _scenario(BuildContext context, String label, int? months, {bool bold = false}) {
    final l = context.l10n;
    final fam = context.fam;
    return Row(children: [
      Expanded(child: Text(label, style: TextStyle(fontWeight: bold ? FontWeight.w600 : null))),
      Text(
        months == null ? l.payoffUnknown : l.monthsCount(months),
        style: TextStyle(fontWeight: bold ? FontWeight.w700 : FontWeight.w600, color: bold ? context.scheme.primary : fam.text2),
      ),
    ]);
  }
}
