import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../state/app_scope.dart';
import '../../state/app_state.dart';
import '../../state/models.dart';
import '../../theme/app_theme.dart';
import '../budget/sheets.dart';
import '../widgets/common.dart';
import '../ops/big_purchase.dart';

/// Быстрые операции (D46): ряд плиток на главной. Тап — расход записан
/// на основной счёт сегодняшним числом, с возможностью сразу отменить.
/// Долгое нажатие — изменить или удалить плитку.
class QuickActionsRow extends StatelessWidget {
  const QuickActionsRow({super.key});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final fam = context.fam;
    final state = AppScope.of(context).state;
    // Виджет const внутри главной — без своей подписки он не перестроится
    // после сохранения плитки.
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final items = state.quickActions..sort((a, b) => a.name.compareTo(b.name));
        return _row(context, l, fam, state, items);
      },
    );
  }

  Widget _row(BuildContext context, AppLocalizations l, FamColors fam, AppState state, List<QuickAction> items) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SectionHeader(l.quickActions),
      SizedBox(
        // Высота растёт вместе с размером шрифта: при 200 % подпись и сумма
        // не помещались в 92 px.
        height: 92 + 70 * (MediaQuery.textScalerOf(context).scale(1) - 1).clamp(0.0, 2.0),
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            for (final q in items)
              SizedBox(
                width: 118,
                child: Card(
                  margin: const EdgeInsets.only(right: 10, bottom: 4),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => _run(context, state, q),
                    onLongPress: () => showQuickActionSheet(context, initial: q),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                        Icon(categoryById(q.category).icon, size: 20, color: fam.accent),
                        const SizedBox(height: 6),
                        Text(q.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                        MoneyText(q.amount, style: TextStyle(fontSize: 12, color: fam.text2)),
                      ]),
                    ),
                  ),
                ),
              ),
            SizedBox(
              width: items.isEmpty ? 200 : 118,
              child: AppCard(
                onTap: () => showQuickActionSheet(context),
                padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                  const Icon(Icons.add, size: 20),
                  const SizedBox(height: 6),
                  Text(items.isEmpty ? l.quickFirst : l.quickNew, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                ]),
              ),
            ),
          ],
        ),
      ),
    ]);
  }

  Future<void> _run(BuildContext context, AppState state, QuickAction q) async {
    final l = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final accounts = state.activeAccounts;
    if (accounts.isEmpty) return addAccountFlow(context);
    final account = (accounts.where((a) => a.liquid).firstOrNull ?? accounts.first).id;
    // Крупная покупка (D74): спрашиваем, запланирована ли — тогда вне лимита.
    final planned = await askPlannedPurchase(context, state, q.amount);
    if (planned == null || !context.mounted) return;
    final ok = await runAction(
      context,
      () => state.addExpense(amount: q.amount, category: q.category, account: account, date: state.today, note: q.name, time: timeToField(TimeOfDay.now()), plannedPurchase: planned),
    );
    if (!ok) return;
    // Свежая запись — первая в журнале; «Отменить» проводит отмену, история остаётся.
    final tx = state.userTransactions.firstOrNull;
    // Плашка живёт несколько секунд и не остаётся навсегда даже при
    // включённых средствах доступности; «Отменить» срабатывает один раз.
    messenger.showSnackBar(SnackBar(
      content: Text('${q.name} · ${formatMoney(q.amount)}'),
      duration: const Duration(seconds: 6),
      persist: false,
      action: tx == null
          ? null
          : SnackBarAction(
              label: l.undo,
              onPressed: () {
                messenger.hideCurrentSnackBar();
                runAction(context, () => state.deleteTransaction(tx.id));
              },
            ),
    ));
  }
}

/// Форма плитки: подпись, сумма, категория расхода.
Future<void> showQuickActionSheet(BuildContext context, {QuickAction? initial}) {
  final l = context.l10n;
  final state = AppScope.of(context).state;
  final name = TextEditingController(text: initial?.name ?? '');
  final amount = TextEditingController(text: initial == null ? '' : amountToField(initial.amount));
  var category = initial?.category ?? 'cafe';
  return showFormSheet<void>(
    context,
    title: initial == null ? l.quickNew : l.edit,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(controller: name, autofocus: initial == null, maxLength: 30, decoration: InputDecoration(labelText: l.quickName, hintText: l.quickNameHint, counterText: '')),
        const SizedBox(height: 10),
        AmountField(controller: amount, label: l.amount),
        const SizedBox(height: 12),
        Text(l.category, style: TextStyle(fontSize: 12, color: ctx.fam.text2)),
        const SizedBox(height: 6),
        CategoryPicker(options: ensureIncluded(state.visibleExpenseCategories, category), value: category, onChanged: (c) => set(() => category = c)),
        const SizedBox(height: 8),
        Text(l.quickNote, style: TextStyle(fontSize: 12, color: ctx.fam.text2)),
        const SizedBox(height: 16),
        SubmitButton(
          label: l.save,
          onSubmit: () async {
            final a = parseAmount(amount.text);
            if (a == null) return false;
            final n = name.text.trim().isEmpty ? categoryName(l, category) : name.text.trim();
            return runAction(ctx, () => state.upsert('quick', initial?.id ?? newId(), QuickAction('', n, category, a).toJson()));
          },
        ),
        if (initial != null)
          TextButton(
            style: TextButton.styleFrom(foregroundColor: ctx.fam.expense),
            onPressed: () async {
              final nav = Navigator.of(ctx);
              if (!await confirm(ctx, title: l.quickDelete, action: l.delete)) return;
              if (!ctx.mounted) return;
              if (await runAction(ctx, () => state.delete('quick', initial.id))) nav.pop();
            },
            child: Text(l.delete),
          ),
      ]),
    ),
  );
}
