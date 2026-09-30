import 'package:flutter/material.dart';

import '../../state/app_state.dart';
import '../../theme/app_theme.dart';
import '../widgets/common.dart';

/// Крупная покупка (D74): дневной лимит — деньги на потребительские мелочи,
/// поэтому покупку от половины лимита программа спрашивает, запланирована ли
/// она. Запланированная в лимит не входит (деньги со счёта спишутся как
/// обычно).
///
/// `true` — запланированная; `false` — обычная трата (или покупка небольшая,
/// и спрашивать не о чем); `null` — человек отказался сохранять.
Future<bool?> askPlannedPurchase(BuildContext context, AppState state, int amount) async {
  if (!state.isBigPurchase(amount)) return false;
  final l = context.l10n;
  final limit = state.dailyLimit!;
  final percent = (amount * 100 / limit).round();
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(l.bigPurchaseTitle),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(l.bigPurchaseBody(moneyInText(amount), '$percent', moneyInText(limit))),
        const SizedBox(height: 8),
        Text(l.bigPurchaseNote, style: TextStyle(fontSize: 13, color: ctx.fam.text2)),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l.cancel)),
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.bigPurchaseNo)),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l.bigPurchaseYes)),
      ],
    ),
  );
}
