/// Формы действий бюджета: оплата срока, погашение долга, цели, счета.
library;

import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../state/app_scope.dart';
import '../../state/models.dart';
import '../../theme/app_theme.dart';
import '../more/categories_screen.dart';
import '../onboarding/onboarding_screen.dart';
import '../widgets/common.dart';

/// Кнопка отправки формы: блокируется на время запроса, чтобы повторное
/// нажатие не создало вторую операцию.
class SubmitButton extends StatefulWidget {
  const SubmitButton({super.key, required this.label, required this.onSubmit});
  final String label;

  /// Возвращает `true`, если форму можно закрыть.
  final Future<bool> Function() onSubmit;

  @override
  State<SubmitButton> createState() => _SubmitButtonState();
}

class _SubmitButtonState extends State<SubmitButton> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: _busy
          ? null
          : () async {
              setState(() => _busy = true);
              final nav = Navigator.of(context);
              final ok = await widget.onSubmit();
              if (!mounted) return;
              setState(() => _busy = false);
              if (ok) nav.pop();
            },
      child: _busy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : Text(widget.label),
    );
  }
}

String? _firstAccount(BuildContext context) {
  final accounts = AppScope.of(context).state.activeAccounts;
  final liquid = accounts.where((a) => a.liquid);
  return (liquid.isNotEmpty ? liquid.first : accounts.firstOrNull)?.id;
}

/// Оплата срока планового платежа (факт отдельно от плана, D14).
Future<void> showPayDueSheet(BuildContext context, DueItem due) {
  final l = context.l10n;
  final state = AppScope.of(context).state;
  final p = due.planned;
  final amount = TextEditingController(text: amountToField(p.amount));
  final interest = TextEditingController();
  var account = _firstAccount(context);
  return showFormSheet<void>(
    context,
    title: '${l.pay}: ${p.name}',
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        AmountField(controller: amount, label: l.amount),
        const SizedBox(height: 12),
        if (p.debtId != null) ...[
          AmountField(controller: interest, label: l.interestPart, hint: '0'),
          const SizedBox(height: 4),
          Text(l.interestPartNote, style: TextStyle(fontSize: 12, color: ctx.fam.text2)),
          const SizedBox(height: 12),
        ],
        AccountPicker(accounts: state.activeAccounts, value: account, onChanged: (v) => set(() => account = v)),
        ListenableBuilder(listenable: amount, builder: (_, _) => MinusWarning(accountId: account, amount: parseAmount(amount.text))),
        const SizedBox(height: 20),
        SubmitButton(
          label: l.pay,
          onSubmit: () async {
            final a = parseAmount(amount.text);
            final i = parseAmount(interest.text, allowZero: true) ?? 0;
            if (a == null || account == null || i > a) return false;
            return runAction(ctx, () => state.payDue(due, account: account!, amount: a, interest: i));
          },
        ),
        TextButton(
          onPressed: () async {
            final nav = Navigator.of(ctx);
            if (await runAction(ctx, () => state.upsert(p.entityKind, p.id, p.toJson(paid: {...p.paid, due.period})))) nav.pop();
          },
          child: Text(l.markPaidOnly),
        ),
      ]),
    ),
  );
}

/// Погашение банковского долга вне графика или досрочно.
Future<void> showBankPaySheet(BuildContext context, DebtInfo debt, {int? principal}) {
  final l = context.l10n;
  final state = AppScope.of(context).state;
  final principalField = TextEditingController(text: principal == null ? '' : amountToField(principal));
  final interest = TextEditingController();
  var account = _firstAccount(context);
  return showFormSheet<void>(
    context,
    title: '${l.pay}: ${debt.name}',
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('${l.balanceLeft}: ${formatMoney(state.debtBalance(debt.id))}', style: TextStyle(color: ctx.fam.text2)),
        const SizedBox(height: 12),
        AmountField(controller: principalField, label: l.principalPart),
        const SizedBox(height: 12),
        AmountField(controller: interest, label: l.interestPart, hint: '0'),
        const SizedBox(height: 12),
        AccountPicker(accounts: state.activeAccounts, value: account, onChanged: (v) => set(() => account = v)),
        ListenableBuilder(
          listenable: Listenable.merge([principalField, interest]),
          builder: (_, _) => MinusWarning(accountId: account, amount: (parseAmount(principalField.text, allowZero: true) ?? 0) + (parseAmount(interest.text, allowZero: true) ?? 0)),
        ),
        const SizedBox(height: 20),
        SubmitButton(
          label: l.pay,
          onSubmit: () async {
            final pr = parseAmount(principalField.text, allowZero: true) ?? 0;
            final i = parseAmount(interest.text, allowZero: true) ?? 0;
            if (pr + i == 0 || account == null) return false;
            return runAction(ctx, () => state.payDebt(debtId: debt.id, account: account!, principal: pr, interest: i));
          },
        ),
      ]),
    ),
  );
}

/// Возврат личного долга в любую сторону.
Future<void> showPersonRepaySheet(BuildContext context, PersonDebt debt) {
  final l = context.l10n;
  final state = AppScope.of(context).state;
  final amount = TextEditingController(text: amountToField(debt.amount));
  var account = _firstAccount(context);
  return showFormSheet<void>(
    context,
    title: debt.oweMe ? '${l.returnedToMe}: ${debt.person}' : '${l.iReturned}: ${debt.person}',
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        AmountField(controller: amount, label: l.amount),
        const SizedBox(height: 12),
        AccountPicker(accounts: state.activeAccounts, value: account, onChanged: (v) => set(() => account = v)),
        const SizedBox(height: 20),
        SubmitButton(
          label: l.save,
          onSubmit: () async {
            final a = parseAmount(amount.text);
            if (a == null || account == null) return false;
            return runAction(
              ctx,
              () => state.addPersonDebt(
                kind: debt.oweMe ? 'repaymentReceived' : 'repaymentMade',
                amount: a,
                person: debt.person,
                account: account!,
                date: state.today,
              ),
            );
          },
        ),
      ]),
    ),
  );
}

/// Новая цель: вместе с ней создаётся копилка — отдельный счёт.
/// В обычной версии — одна цель (D05).
Future<void> showGoalSheet(BuildContext context, {GoalInfo? initial}) async {
  final l = context.l10n;
  final state = AppScope.of(context).state;
  if (initial == null && !state.pro && state.goals.isNotEmpty) {
    await showProGate(context, l.proGateGoals);
    return;
  }
  final name = TextEditingController(text: initial?.name ?? '');
  final target = TextEditingController(text: initial == null ? '' : amountToField(initial.target));
  DateTime? deadline = initial?.deadline;
  return showFormSheet<void>(
    context,
    title: initial == null ? l.addGoal : l.editGoal,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(controller: name, autofocus: initial == null, decoration: InputDecoration(labelText: l.goalName, hintText: l.goalNameHint)),
        const SizedBox(height: 12),
        AmountField(controller: target, label: l.goalTarget),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          icon: const Icon(Icons.event_outlined),
          label: Text(deadline == null ? l.deadlineOptional : '${l.deadline}: ${dateToJson(deadline!)}'),
          onPressed: () async {
            final picked = await showDatePicker(
              context: ctx,
              initialDate: deadline ?? state.today.add(const Duration(days: 180)),
              firstDate: state.today,
              lastDate: DateTime(state.today.year + 30),
            );
            if (picked != null) set(() => deadline = DateTime(picked.year, picked.month, picked.day));
          },
        ),
        const SizedBox(height: 8),
        if (initial == null) InfoBanner(l.piggyNote, icon: Icons.savings_outlined),
        const SizedBox(height: 12),
        SubmitButton(
          label: l.save,
          onSubmit: () async {
            final t = parseAmount(target.text);
            if (name.text.trim().isEmpty || t == null) return false;
            if (initial == null) {
              return runAction(ctx, () => state.sendBatch(state.newGoalCommands(name: name.text.trim(), target: t, deadline: deadline)));
            }
            return runAction(ctx, () => state.sendBatch([
                  {'type': 'upsertEntity', 'kind': 'goal', 'entityId': initial.id, 'data': GoalInfo(initial.id, name.text.trim(), t, deadline, account: initial.account).toJson()},
                  if (initial.account != null)
                    {'type': 'upsertEntity', 'kind': 'account', 'entityId': initial.account, 'data': {'name': name.text.trim(), 'type': piggyType, 'goalId': initial.id, 'color': 0xFFE0A43A}},
                ]));
          },
        ),
      ]),
    ),
  );
}

/// Отложить в копилку или забрать из неё — это перевод между своими счетами.
Future<void> showReserveSheet(BuildContext context, GoalInfo goal, {required bool release, int? initial}) {
  final l = context.l10n;
  final state = AppScope.of(context).state;
  final amount = TextEditingController(text: initial == null ? '' : amountToField(initial));
  final accounts = state.activeAccounts;
  var account = accounts.where((a) => a.liquid).firstOrNull?.id ?? accounts.firstOrNull?.id;
  final inGoal = state.goalSaved(goal);
  return showFormSheet<void>(
    context,
    title: '${release ? l.reserveRelease : l.reserveAdd}: ${goal.name}',
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) {
        final available = account == null ? 0 : state.ledger.balance(account!);
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          AccountPicker(accounts: accounts, value: account, label: release ? l.toAccount : l.fromAccount, onChanged: (v) => set(() => account = v)),
          const SizedBox(height: 8),
          Text(release ? '${l.inGoal}: ${formatMoney(inGoal)}' : '${l.availableOnAccount}: ${formatMoney(available)}', style: TextStyle(fontSize: 12, color: ctx.fam.text2)),
          const SizedBox(height: 12),
          AmountField(controller: amount, label: l.amount, autofocus: true),
          if (!release) ListenableBuilder(listenable: amount, builder: (_, _) => MinusWarning(accountId: account, amount: parseAmount(amount.text))),
          const SizedBox(height: 8),
          Text(l.reserveNote, style: TextStyle(fontSize: 12, color: ctx.fam.text2)),
          const SizedBox(height: 20),
          SubmitButton(
            label: release ? l.reserveRelease : l.reserveAdd,
            onSubmit: () async {
              final a = parseAmount(amount.text);
              if (a == null || account == null || goal.account == null) return false;
              if (release && a > inGoal) return false;
              return runAction(ctx, () => release ? state.withdrawFromGoal(goal, to: account!, amount: a) : state.depositToGoal(goal, from: account!, amount: a));
            },
          ),
        ]);
      },
    ),
  );
}

/// Новый денежный счёт. В обычной версии — один активный счёт (D05).
Future<void> addAccountFlow(BuildContext context) async {
  final l = context.l10n;
  final state = AppScope.of(context).state;
  if (!state.pro && state.activeAccounts.isNotEmpty) {
    await showProGate(context, l.proGateAccounts);
    return;
  }
  final name = TextEditingController();
  final balance = TextEditingController();
  var type = 'card';
  String? owner;
  await showFormSheet<void>(
    context,
    title: l.addAccount,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(controller: name, autofocus: true, decoration: InputDecoration(labelText: l.accName, hintText: 'Halyk')),
        const SizedBox(height: 12),
        Wrap(spacing: 8, children: [
          for (final t in accountTypes)
            ChoiceChip(label: Text(accountTypeName(l, t)), selected: type == t, onSelected: (_) => set(() => type = t)),
        ]),
        const SizedBox(height: 12),
        AmountField(controller: balance, label: l.openingBalance),
        if (state.familyMode) ...[
          const SizedBox(height: 12),
          AccountOwnerPicker(value: owner, onChanged: (v) => set(() => owner = v)),
        ],
        const SizedBox(height: 20),
        SubmitButton(
          label: l.save,
          onSubmit: () async {
            final b = parseAmount(balance.text, allowZero: true);
            if (name.text.trim().isEmpty || b == null) return false;
            return runAction(ctx, () => state.sendBatch(state.newAccountCommands(name: name.text.trim(), type: type, balance: b, owner: owner)));
          },
        ),
      ]),
    ),
  );
}

/// Новый плановый платёж.
Future<void> addPlannedFlow(BuildContext context) async {
  final state = AppScope.of(context).state;
  final r = await showPlannedSheet(context);
  if (r == null || !context.mounted) return;
  final id = newId();
  await runAction(context, () => state.upsert('planned', id, PlannedInfo(id, r.name, r.amount, r.day, r.category, null, const {}, start: state.plannedStart(r.day, paidThisMonth: r.paidThisMonth)).toJson()));
}

/// Новая разовая покупка (D88): что, сколько и в каком месяце.
Future<void> addPurchaseFlow(BuildContext context) async {
  final l = context.l10n;
  final state = AppScope.of(context).state;
  final locale = Localizations.localeOf(context).toString();
  final name = TextEditingController();
  final amount = TextEditingController();
  final months = [for (var i = 0; i < 24; i++) state.monthOf(i)];
  var month = months[1];
  var category = 'other';
  await showFormSheet<void>(
    context,
    title: l.addPurchase,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(controller: name, autofocus: true, maxLength: 60, decoration: InputDecoration(labelText: l.purchaseName, hintText: l.purchaseNameHint, counterText: '')),
        const SizedBox(height: 12),
        AmountField(controller: amount, label: l.amount),
        const SizedBox(height: 12),
        DropdownButtonFormField<DateTime>(
          initialValue: month,
          decoration: InputDecoration(labelText: l.purchaseMonth),
          items: [for (final m in months) DropdownMenuItem(value: m, child: Text(toBeginningOfSentenceCase(DateFormat.yMMMM(locale).format(m))))],
          onChanged: (m) => set(() => month = m ?? month),
        ),
        const SizedBox(height: 12),
        CategoryPicker(
          options: expenseCategories,
          value: category,
          onChanged: (c) => set(() => category = c),
          onAdd: () async {
            final id = await showCategorySheet(ctx);
            if (id != null) set(() => category = id);
          },
        ),
        const SizedBox(height: 20),
        SubmitButton(
          label: l.add,
          onSubmit: () async {
            final a = parseAmount(amount.text);
            if (name.text.trim().isEmpty || a == null) return false;
            return runAction(ctx, () => state.addPurchase(name: name.text.trim(), amount: a, month: month, category: category));
          },
        ),
      ]),
    ),
  );
}

/// Новый кредит, рассрочка или кредитка с текущим остатком.
Future<void> addBankDebtFlow(BuildContext context) async {
  final state = AppScope.of(context).state;
  final d = await showBankDebtSheet(context);
  if (d == null || !context.mounted) return;
  await runAction(context, () => state.sendBatch(state.newBankDebtCommands(name: d.name, kind: d.kind, balance: d.balance, payment: d.payment, day: d.day, rate: d.rate, paidThisMonth: d.paidThisMonth)));
}

/// Лимит на категорию. В обычной версии — два лимита (D05).
Future<void> addLimitFlow(BuildContext context, {LimitInfo? initial}) async {
  final l = context.l10n;
  final state = AppScope.of(context).state;
  if (initial == null && !state.pro && state.limits.length >= 2) {
    await showProGate(context, l.proGateLimit);
    return;
  }
  final r = await showLimitSheet(context, exclude: {for (final x in state.limits) x.category}, initial: initial);
  if (r == null || !context.mounted) return;
  final id = initial?.id ?? newId();
  await runAction(context, () => state.upsert('limit', id, LimitInfo(id, r.category, r.amount).toJson()));
}

/// Q06 — сверка остатка: пользователь вводит фактический остаток, разница
/// проводится корректировкой с причиной. Не доход и не расход.
Future<void> showAdjustBalanceSheet(BuildContext context, String accountId) {
  final l = context.l10n;
  final state = AppScope.of(context).state;
  final current = state.ledger.balance(accountId);
  final actual = TextEditingController(text: amountToField(current));
  final reason = TextEditingController();
  return showFormSheet<void>(
    context,
    title: l.adjustBalance,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) {
        final target = parseAmount(actual.text, allowZero: true);
        final delta = target == null ? null : target - current;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('${l.inApp}: ${formatMoney(current)}', style: TextStyle(color: ctx.fam.text2)),
          const SizedBox(height: 12),
          AmountField(controller: actual, label: l.actualBalance, autofocus: true, onChanged: (_) => set(() {})),
          const SizedBox(height: 8),
          if (delta != null)
            Text(
              delta == 0 ? l.noDifference : '${l.difference}: ${delta > 0 ? '+' : ''}${formatMoney(delta)}',
              style: TextStyle(fontWeight: FontWeight.w600, color: delta == 0 ? ctx.fam.text2 : delta > 0 ? ctx.fam.income : ctx.fam.expense),
            ),
          const SizedBox(height: 12),
          TextField(controller: reason, maxLength: 200, decoration: InputDecoration(labelText: l.reason, hintText: l.reasonHint, counterText: ''), onChanged: (_) => set(() {})),
          const SizedBox(height: 4),
          Text(l.adjustmentNote, style: TextStyle(fontSize: 12, color: ctx.fam.text2)),
          const SizedBox(height: 20),
          SubmitButton(
            label: l.save,
            onSubmit: () async {
              if (target == null || delta == 0 || reason.text.trim().isEmpty) return false;
              return runAction(ctx, () => state.adjustBalance(account: accountId, actualBalance: target, reason: reason.text.trim()));
            },
          ),
        ]);
      },
    ),
  );
}
