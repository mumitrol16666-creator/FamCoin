import 'package:flutter/material.dart';

import '../../state/app_scope.dart';
import '../../theme/app_theme.dart';
import '../widgets/common.dart';

/// S37 — тариф: что входит в обычную версию и в Pro (раздел 2 карты).
class TariffScreen extends StatelessWidget {
  const TariffScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final state = AppScope.of(context).state;
    final fam = context.fam;

    final rows = <(String, String, String)>[
      (l.tManual, '✓', '✓'),
      (l.accounts, '1', '∞'),
      (l.limits, '2', '∞'),
      (l.tDebts, '✓', '✓'),
      (l.tGoals, '✓', '✓'),
      (l.tReports, '✓', '✓'),
      (l.tCompare, '—', '✓'),
      (l.tEarly, '—', '✓'),
      (l.tVoice, '✓', '✓'),
      (l.tReceipts, '—', l.soon),
      (l.ai, '—', l.soon),
      (l.tFamily, '✓', '✓'),
      (l.tHistory, '✓', '✓'),
    ];

    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: Text(l.tariff)),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          children: [
            AppCard(
              color: context.scheme.primary,
              child: DefaultTextStyle(
                style: TextStyle(color: context.scheme.onPrimary),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('FamCoin Pro', style: Theme.of(context).textTheme.headlineSmall!.copyWith(color: context.scheme.onPrimary)),
                      Text(l.proSub, style: const TextStyle(fontSize: 13)),
                    ]),
                  ),
                  Text(l.proPrice, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                ]),
              ),
            ),
            AppCard(
              child: Column(children: [
                Row(children: [
                  const Expanded(child: SizedBox()),
                  SizedBox(width: 72, child: Text(l.freePlan, textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: fam.text2))),
                  const SizedBox(width: 72, child: Center(child: ProBadge())),
                ]),
                const SizedBox(height: 6),
                for (final (name, free, pro) in rows)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(children: [
                      Expanded(child: Text(name, style: const TextStyle(fontSize: 13))),
                      SizedBox(
                        width: 72,
                        // Галочка — значком: в веб-шрифте символа «✓» нет.
                        child: free == '✓'
                            ? Icon(Icons.check, size: 18, color: context.scheme.onSurface)
                            : Text(free, textAlign: TextAlign.center, style: TextStyle(color: free == '—' ? fam.text2 : null)),
                      ),
                      SizedBox(
                        width: 72,
                        child: pro == '✓'
                            ? Icon(Icons.check, size: 18, color: context.scheme.primary)
                            : Text(pro, textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.w700, color: context.scheme.primary, fontSize: pro.length > 2 ? 11 : 14)),
                      ),
                    ]),
                  ),
              ]),
            ),
            AppCard(
              child: Row(children: [
                Expanded(child: Text(state.pro ? '${l.currentPlan}: Pro' : '${l.currentPlan}: ${l.freePlan}')),
                Switch(value: state.pro, onChanged: (v) => runAction(context, () => state.setPlanDev(v))),
              ]),
            ),
            Text('${l.devPlanNote} ${l.proStoreNote}', style: TextStyle(fontSize: 12, color: fam.text2)),
            const SizedBox(height: 8),
            Text(l.dataKept, style: TextStyle(fontSize: 12, color: fam.text2)),
          ],
        ),
      ),
    );
  }
}
