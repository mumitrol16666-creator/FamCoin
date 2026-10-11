import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../state/app_scope.dart';
import '../../state/app_state.dart';
import '../../state/models.dart';
import '../../theme/app_theme.dart';
import '../budget/sheets.dart';
import '../widgets/common.dart';
import '../widgets/record_feedback.dart';
import '../ops/big_purchase.dart';

/// Быстрые операции (D46): ряд плиток на главной. Тап — расход записан
/// на основной счёт сегодняшним числом, с возможностью сразу отменить.
/// Долгое нажатие (D106) — записать с другой суммой: лист с подставленной
/// суммой плитки, «Записать» проводит трату один раз, сама плитка не меняется;
/// в том же листе — «Настроить плитку».
///
/// Отклик (D166): пока сервер не ответил, на плитке вместо значка крутится
/// индикатор; после записи — вибрация и звук «монетки» (отключается в
/// настройках). Повторное нажатие не блокируется: два касания — две поездки.
class QuickActionsRow extends StatefulWidget {
  const QuickActionsRow({super.key});

  @override
  State<QuickActionsRow> createState() => _QuickActionsRowState();
}

class _QuickActionsRowState extends State<QuickActionsRow> {
  /// Сколько записей по плитке ещё ждут ответа сервера.
  final _inFlight = <String, int>{};

  Future<void> _tracked(String id, Future<void> Function() run) async {
    setState(() => _inFlight[id] = (_inFlight[id] ?? 0) + 1);
    try {
      await run();
    } finally {
      if (mounted) {
        setState(() {
          final left = (_inFlight[id] ?? 1) - 1;
          if (left <= 0) {
            _inFlight.remove(id);
          } else {
            _inFlight[id] = left;
          }
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final fam = context.fam;
    final scope = AppScope.of(context);
    final state = scope.state;
    // Виджет const внутри главной — без своей подписки он не перестроится
    // после сохранения плитки.
    return ListenableBuilder(
      listenable: Listenable.merge([state, scope.settings]),
      builder: (context, _) {
        final items = state.quickActions..sort((a, b) => a.name.compareTo(b.name));
        return _row(context, l, fam, state, items, showHoldHint: items.isNotEmpty && !scope.settings.quickHoldHintSeen);
      },
    );
  }

  Widget _row(BuildContext context, AppLocalizations l, FamColors fam, AppState state, List<QuickAction> items, {required bool showHoldHint}) {
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
                  color: fam.season == Season.spring ? fam.incomeBg : null,
                  margin: const EdgeInsets.only(right: 10, bottom: 4),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () {
                      armRecordFeedback(context);
                      _tracked(q.id, () => _record(context, state, q, q.amount));
                    },
                    onLongPress: () {
                      armRecordFeedback(context);
                      _tracked(q.id, () => _other(context, state, q));
                    },
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                        if (_inFlight.containsKey(q.id))
                          SizedBox(
                            key: ValueKey('quick-busy-${q.id}'),
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2.2, color: context.scheme.primary),
                          )
                        else
                          CategoryGlyph(categoryById(q.category), size: 20, color: context.scheme.primary),
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
      // Подсказка про долгое нажатие — до первого использования (D106).
      if (showHoldHint)
        Padding(
          padding: const EdgeInsets.only(top: 2, bottom: 4),
          child: Text(l.quickHoldHint, style: TextStyle(fontSize: 12, color: fam.text2)),
        ),
    ]);
  }

  /// Долгое нажатие: та же плитка, но сумму вводит человек (D106).
  Future<void> _other(BuildContext context, AppState state, QuickAction q) async {
    final settings = AppScope.of(context).settings;
    final amount = await showQuickAmountSheet(context, q);
    await settings.markQuickHoldHintSeen();
    if (amount == null || !context.mounted) return;
    await _record(context, state, q, amount);
  }

  Future<void> _record(BuildContext context, AppState state, QuickAction q, int amount) async {
    final l = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final accounts = state.activeAccounts;
    if (accounts.isEmpty) return addAccountFlow(context);
    // Счёт плитки (Ж9), если он ещё действует; иначе основной.
    final account = accounts.where((a) => a.id == q.account).firstOrNull?.id ?? (accounts.where((a) => a.liquid).firstOrNull ?? accounts.first).id;
    // Крупная покупка (D74): спрашиваем, запланирована ли — тогда вне лимита.
    final kind = await askPlannedPurchase(context, state, amount);
    if (kind == null || !context.mounted) return;
    final ok = await runAction(
      context,
      () => state.addExpense(amount: amount, category: q.category, account: account, date: state.today, note: q.name, time: timeToField(TimeOfDay.now()), plannedPurchase: kind.planned_, unexpected: kind.unexpected_),
    );
    if (!ok) return;
    if (context.mounted) recordedFeedback(context);
    if (kind.unexpected_ && context.mounted && await offerCoverFromGoal(context, state, amount: amount, account: account)) return;
    // Свежая запись — первая в журнале; «Отменить» проводит отмену, история остаётся.
    final tx = state.userTransactions.firstOrNull;
    // Плашка живёт несколько секунд и не остаётся навсегда даже при
    // включённых средствах доступности; «Отменить» срабатывает один раз.
    messenger.showSnackBar(SnackBar(
      content: Text('${q.name} · ${formatMoney(amount)}'),
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

/// Лист «записать с другой суммой» (D106): сумма плитки уже подставлена и
/// выделена — стёр, ввёл свою, «Записать». Возвращает сумму или `null`.
/// Внизу — «Настроить плитку» (подпись, сумма по умолчанию, категория, удаление).
Future<int?> showQuickAmountSheet(BuildContext context, QuickAction q) {
  final l = context.l10n;
  final amount = TextEditingController(text: amountToField(q.amount));
  amount.selection = TextSelection(baseOffset: 0, extentOffset: amount.text.length);
  return showFormSheet<int>(
    context,
    title: q.name,
    builder: (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('${categoryName(l, q.category)} · ${l.quickOtherAmountNote}', style: TextStyle(fontSize: 12, color: ctx.fam.text2)),
      const SizedBox(height: 10),
      AmountField(controller: amount, label: l.amount, autofocus: true),
      const SizedBox(height: 16),
      SubmitButton(
        label: l.quickRecord,
        onSubmit: () async {
          final a = parseAmount(amount.text);
          if (a == null) return false;
          Navigator.pop(ctx, a);
          return true;
        },
      ),
      TextButton(
        onPressed: () {
          Navigator.pop(ctx);
          showQuickActionSheet(context, initial: q);
        },
        child: Text(l.quickConfigure),
      ),
    ]),
  );
}

/// Форма плитки: подпись, сумма, категория расхода.
Future<void> showQuickActionSheet(BuildContext context, {QuickAction? initial}) {
  final l = context.l10n;
  final state = AppScope.of(context).state;
  final name = TextEditingController(text: initial?.name ?? '');
  final amount = TextEditingController(text: initial == null ? '' : amountToField(initial.amount));
  var category = initial?.category ?? 'cafe';
  // Счёт, с которого плитка списывает: «Основной» — как раньше (Ж9).
  String? account = state.activeAccounts.any((a) => a.id == initial?.account) ? initial?.account : null;
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
        if (state.activeAccounts.length > 1) ...[
          const SizedBox(height: 12),
          DropdownButtonFormField<String?>(
            key: const ValueKey('quick-account'),
            initialValue: account,
            decoration: InputDecoration(labelText: l.quickAccount),
            items: [
              DropdownMenuItem<String?>(value: null, child: Text(l.quickAccountMain)),
              for (final a in state.activeAccounts) DropdownMenuItem<String?>(value: a.id, child: Text(a.name)),
            ],
            onChanged: (v) => set(() => account = v),
          ),
        ],
        const SizedBox(height: 8),
        Text(l.quickNote, style: TextStyle(fontSize: 12, color: ctx.fam.text2)),
        const SizedBox(height: 16),
        SubmitButton(
          label: l.save,
          onSubmit: () async {
            final a = parseAmount(amount.text);
            if (a == null) return false;
            final n = name.text.trim().isEmpty ? categoryName(l, category) : name.text.trim();
            return runAction(ctx, () => state.upsert('quick', initial?.id ?? newId(), QuickAction('', n, category, a, account: account).toJson()));
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
