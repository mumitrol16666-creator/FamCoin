import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../state/app_state.dart';
import '../../state/models.dart';
import '../../theme/app_theme.dart';
import '../widgets/common.dart';

/// Какая это трата по отношению к дневному лимиту (D74, D101).
enum PurchaseKind {
  /// Обычная трата из дневных мелочей — входит в лимит.
  regular,

  /// Запланированная покупка — вне лимита.
  planned,

  /// Непредвиденная трата — вне лимита, считается отдельно.
  unexpected;

  bool get planned_ => this == PurchaseKind.planned;
  bool get unexpected_ => this == PurchaseKind.unexpected;

  static PurchaseKind ofMeta(Map<String, dynamic> meta) => meta['unexpected'] == true
      ? PurchaseKind.unexpected
      : meta['plannedPurchase'] == true
          ? PurchaseKind.planned
          : PurchaseKind.regular;
}

/// Крупная покупка (D74): дневной лимит — деньги на потребительские мелочи,
/// поэтому покупку от половины лимита программа спрашивает, что это за трата.
/// Запланированная и непредвиденная (D101) в лимит не входят (деньги со счёта
/// спишутся как обычно).
///
/// `null` — человек отказался сохранять; для небольшой покупки вопроса нет —
/// сразу [PurchaseKind.regular].
Future<PurchaseKind?> askPlannedPurchase(BuildContext context, AppState state, int amount) async {
  if (!state.isBigPurchase(amount)) return PurchaseKind.regular;
  final l = context.l10n;
  final limit = state.dailyLimit!;
  final percent = (amount * 100 / limit).round();
  return showDialog<PurchaseKind>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(l.bigPurchaseTitle),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(l.bigPurchaseBody(moneyInText(amount), '$percent', moneyInText(limit))),
        const SizedBox(height: 8),
        Text(l.bigPurchaseNote, style: TextStyle(fontSize: 13, color: ctx.fam.text2)),
      ]),
      // Четыре кнопки на узком экране — столбиком (OverflowBar сам переносит).
      actionsAlignment: MainAxisAlignment.end,
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l.cancel)),
        TextButton(onPressed: () => Navigator.pop(ctx, PurchaseKind.regular), child: Text(l.bigPurchaseNo)),
        TextButton(onPressed: () => Navigator.pop(ctx, PurchaseKind.unexpected), child: Text(l.bigPurchaseUnexpected)),
        FilledButton(onPressed: () => Navigator.pop(ctx, PurchaseKind.planned), child: Text(l.bigPurchaseYes)),
      ],
    ),
  );
}

/// После непредвиденной траты (D101): если в какой-то копилке есть деньги,
/// предлагает забрать из неё сумму траты (не больше накопленного) на тот счёт,
/// с которого платили. Берётся копилка с самым большим остатком — обычно это
/// подушка безопасности. Возвращает `true`, если деньги забрали.
Future<bool> offerCoverFromGoal(BuildContext context, AppState state, {required int amount, required String account}) async {
  GoalInfo? best;
  var saved = 0;
  for (final g in state.goals) {
    final s = state.goalSaved(g);
    if (g.account != null && s > saved) {
      best = g;
      saved = s;
    }
  }
  if (best == null || saved <= 0 || amount <= 0) return false;
  final goal = best;
  final take = math.min(amount, saved);
  final l = context.l10n;
  final accountName = state.accountInfo(account)?.name ?? '';
  final yes = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(l.coverFromGoalTitle),
      content: Text(l.coverFromGoalBody(goal.name, moneyInText(saved), moneyInText(take), accountName)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.coverFromGoalNo)),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l.coverFromGoalYes)),
      ],
    ),
  );
  if (yes != true || !context.mounted) return false;
  final ok = await runAction(context, () => state.withdrawFromGoal(goal, to: account, amount: take));
  if (ok && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.coveredFromGoal(goal.name, moneyInText(take)))));
  }
  return ok;
}
