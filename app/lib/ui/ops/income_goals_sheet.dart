/// После записи дохода — предложение отложить часть в копилки целей (D96).
library;

import 'package:flutter/material.dart';

import '../../state/app_scope.dart';
import '../../state/app_state.dart';
import '../../state/models.dart';
import '../../theme/app_theme.dart';
import '../budget/sheets.dart' show SubmitButton;
import '../widgets/common.dart';

/// Лист «Отложить часть на цели?». Показывается, когда доход заметный
/// (от [AppState.incomeOfferMin]), есть незакрытые цели с копилкой и
/// владелец не отключил предложение. Возвращает `true`, если лист показан:
/// он сам сообщает, что доход записан, и «Операция записана» не нужна.
Future<bool> offerIncomeToGoals(BuildContext context, {required int amount, required String account, required String source, required DateTime date}) async {
  final state = AppScope.of(context).state;
  if (!state.shouldOfferGoals(amount)) return false;
  // Список целей и подсказки считаются один раз при открытии: пока лист
  // открыт, они не должны «уезжать» из-под пальцев при обновлении состояния.
  await showFormSheet<void>(
    context,
    title: context.l10n.incomeGoalsTitle,
    builder: (_) => _IncomeGoals(
      amount: amount,
      account: account,
      source: source,
      date: date,
      goals: state.openGoals,
      suggested: state.incomeGoalSuggestions(amount, date: date),
    ),
  );
  return true;
}

class _IncomeGoals extends StatefulWidget {
  const _IncomeGoals({required this.amount, required this.account, required this.source, required this.date, required this.goals, required this.suggested});
  final int amount;
  final String account;
  final String source;
  final DateTime date;
  final List<GoalInfo> goals;

  /// Подсказка суммы по id цели; без записи — поле пустое.
  final Map<String, int> suggested;

  @override
  State<_IncomeGoals> createState() => _IncomeGoalsState();
}

class _IncomeGoalsState extends State<_IncomeGoals> {
  late final Map<String, TextEditingController> _fields = {
    for (final g in widget.goals) g.id: TextEditingController(text: widget.suggested[g.id] == null ? '' : amountToField(widget.suggested[g.id]!)),
  };

  /// Один на попытку: повтор «Отложить» после обрыва связи не задвоит переводы.
  final _commandId = newId();

  List<GoalInfo> get _goals => widget.goals;

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  Map<GoalInfo, int> get _amounts => {
        for (final g in _goals)
          if ((parseAmount(_fields[g.id]!.text) ?? 0) > 0) g: parseAmount(_fields[g.id]!.text)!,
      };

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final fam = context.fam;
    final state = AppScope.of(context).state;
    final caption = TextStyle(fontSize: 12, color: fam.text2);
    final accountName = state.accountInfo(widget.account)?.name ?? '';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(l.incomeGoalsSaved(categoryName(l, widget.source), moneyInText(widget.amount), accountName), style: TextStyle(fontSize: 13, color: fam.text2)),
      const SizedBox(height: 12),
      for (final g in _goals) ...[
        AmountField(key: ValueKey('income-goal-${g.id}'), controller: _fields[g.id]!, label: g.name),
        const SizedBox(height: 4),
        Builder(builder: (_) {
          final st = state.goalStatusFor(g);
          final parts = [
            l.purchaseProgress(moneyInText(st.saved), moneyInText(st.target)),
            if (st.requiredContribution != null) l.incomeGoalsNeed(moneyInText(st.requiredContribution!)),
          ];
          return Text(parts.join(' · '), style: caption);
        }),
        const SizedBox(height: 12),
      ],
      ListenableBuilder(
        listenable: Listenable.merge(_fields.values.toList()),
        builder: (ctx, _) {
          final total = _amounts.values.fold(0, (a, b) => a + b);
          final left = state.ledger.balance(widget.account) - total;
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(l.incomeGoalsTotal(moneyInText(total), moneyInText(left)), key: const ValueKey('income-goals-total'), style: const TextStyle(fontWeight: FontWeight.w600)),
            MinusWarning(accountId: widget.account, amount: total),
            const SizedBox(height: 8),
            Text(l.reserveNote, style: caption),
            const SizedBox(height: 20),
            if (total <= 0)
              FilledButton(onPressed: null, child: Text(l.incomeGoalsSubmit))
            else
              SubmitButton(
                label: l.incomeGoalsSubmit,
                onSubmit: () async {
                  final messenger = ScaffoldMessenger.of(ctx);
                  final ok = await runAction(ctx, () => state.allocateToGoals(_amounts, from: widget.account, date: widget.date, commandId: _commandId));
                  if (ok) messenger.showSnackBar(SnackBar(content: Text(l.incomeGoalsDone(moneyInText(total)))));
                  return ok;
                },
              ),
          ]);
        },
      ),
      const SizedBox(height: 4),
      Row(children: [
        Expanded(child: TextButton(onPressed: () => Navigator.pop(context), child: Text(l.notNow))),
        Expanded(
          child: TextButton(
            onPressed: () async {
              final nav = Navigator.of(context);
              final messenger = ScaffoldMessenger.of(context);
              if (!await runAction(context, () => state.setOfferGoalsOnIncome(false))) return;
              nav.pop();
              messenger.showSnackBar(SnackBar(content: Text(l.incomeGoalsMuted)));
            },
            child: Text(l.incomeGoalsMute, textAlign: TextAlign.center),
          ),
        ),
      ]),
    ]);
  }
}
