/// Формы действий бюджета: оплата срока, погашение долга, цели, счета.
library;

import 'dart:async';

import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../state/app_scope.dart';
import '../../state/models.dart';
import '../../theme/app_theme.dart';
import '../more/categories_screen.dart';
import '../onboarding/onboarding_screen.dart';
import '../widgets/common.dart';
import 'goal_card.dart';

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

  /// Идентификаторы отправки живут, пока форма открыта: после потерянного
  /// ответа повторное нажатие шлёт те же факт и ключ команды (APP-03).
  final _attempt = SubmitAttempt();

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: _busy
          ? null
          : () async {
              setState(() => _busy = true);
              final nav = Navigator.of(context);
              _attempt.beginCall();
              final ok = await runZoned(widget.onSubmit, zoneValues: {submitAttemptKey: _attempt});
              // Новая отправка получит новые идентификаторы, если эта завершилась
              // определённо: успехом или отказом. Неопределённый обрыв связи
              // оставляет прежние — повтор не создаст второй факт.
              if (ok || !_attempt.uncertain) _attempt.reset();
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
/// [date] — дата оплаты (по умолчанию сегодня); из сверки месяца приходит дата
/// срока: «уже оплачено» записывается фактом, а не только галочкой (D98).
Future<void> showPayDueSheet(BuildContext context, DueItem due, {DateTime? date, String? title, int? initialAmount, String? initialAccount}) {
  final l = context.l10n;
  final state = AppScope.of(context).state;
  final locale = Localizations.localeOf(context).toString();
  final p = due.planned;
  final amount = TextEditingController(text: amountToField(initialAmount ?? due.payAmount));
  final interest = TextEditingController();
  var account = state.activeAccounts.any((a) => a.id == initialAccount) ? initialAccount : (state.payAccountFor(p) ?? _firstAccount(context));
  var payDate = date == null || date.isAfter(state.today) ? state.today : date;
  // Покупка из копилки (D90): накопленное вернётся на счёт оплаты той же командой.
  final fromPiggy = p.once == null ? 0 : state.purchaseSaved(p);
  return showFormSheet<void>(
    context,
    title: title ?? (p.person != null ? plannedTitle(l, p) : '${l.pay}: ${p.name}'),
    titleAction: p.debtId == null ? null : InfoTip(l.repaymentNote, title: l.repayHelpTitle),
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        AmountField(controller: amount, label: l.amount),
        // Возврат человеку можно внести частью (N01): срок останется на остаток.
        if (p.person != null)
          ListenableBuilder(
            listenable: amount,
            builder: (_, _) {
              final a = parseAmount(amount.text);
              if (a == null || a >= due.payAmount) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(l.duePartLeft(moneyInText(due.payAmount - a)), style: TextStyle(fontSize: 12, color: ctx.fam.text2)),
              );
            },
          ),
        const SizedBox(height: 8),
        Row(children: [
          Text(l.date, style: TextStyle(fontSize: 12, color: ctx.fam.text2)),
          const SizedBox(width: 8),
          ActionChip(
            avatar: const Icon(Icons.calendar_month_outlined, size: 16),
            label: Text(DateFormat.MMMd(locale).format(payDate)),
            onPressed: () async {
              final picked = await showDatePicker(context: ctx, initialDate: payDate, firstDate: DateTime(2000), lastDate: state.today);
              if (picked != null) set(() => payDate = DateTime(picked.year, picked.month, picked.day));
            },
          ),
        ]),
        const SizedBox(height: 12),
        if (p.debtId != null) ...[
          AmountField(controller: interest, label: l.interestPart, hint: '0'),
          const SizedBox(height: 4),
          Text(l.interestPartNote, style: TextStyle(fontSize: 12, color: ctx.fam.text2)),
          const SizedBox(height: 12),
        ],
        AccountPicker(accounts: state.activeAccounts, value: account, onChanged: (v) => set(() => account = v)),
        if (fromPiggy > 0) Padding(padding: const EdgeInsets.only(top: 8), child: Text(l.purchaseFromPiggy(moneyInText(fromPiggy)), style: TextStyle(fontSize: 12, color: ctx.fam.text2))),
        ListenableBuilder(listenable: amount, builder: (_, _) => MinusWarning(accountId: account, amount: parseAmount(amount.text), returned: fromPiggy)),
        const SizedBox(height: 20),
        SubmitButton(
          label: l.pay,
          onSubmit: () async {
            final a = parseAmount(amount.text);
            final i = parseAmount(interest.text, allowZero: true) ?? 0;
            if (a == null || account == null || i > a) return false;
            return runAction(ctx, () => state.payDue(due, account: account!, amount: a, interest: i, date: payDate));
          },
        ),
        TextButton(
          onPressed: () async {
            final nav = Navigator.of(ctx);
            if (await runAction(ctx, () => state.markDuePaid(due))) nav.pop();
          },
          child: Text(l.markPaidOnly),
        ),
        // Правка и удаление платежа (Ж12): раньше удалить можно было только
        // долгим нажатием в бюджете, а изменить — никак.
        if (p.once == null)
          Row(children: [
            // У срока возврата долга условия не правятся: дата меняется на экране долга.
            if (p.person == null)
              Expanded(
                child: TextButton(
                  onPressed: () async {
                    final nav = Navigator.of(ctx);
                    if (await editPlannedFlow(ctx, p)) nav.pop();
                  },
                  child: Text(l.editPayment),
                ),
              ),
            Expanded(
              child: TextButton(
                style: TextButton.styleFrom(foregroundColor: ctx.fam.expense),
                onPressed: () async {
                  final nav = Navigator.of(ctx);
                  if (await deletePlannedFlow(ctx, p)) nav.pop();
                },
                child: Text(l.deletePaymentAction),
              ),
            ),
          ]),
      ]),
    ),
  );
}

/// Погашение банковского долга вне графика или досрочно.
Future<void> showBankPaySheet(BuildContext context, DebtInfo debt, {int? principal, DateTime? date, String? initialAccount}) {
  final l = context.l10n;
  final state = AppScope.of(context).state;
  final principalField = TextEditingController(text: principal == null ? '' : amountToField(principal));
  final interest = TextEditingController();
  var account = state.activeAccounts.any((a) => a.id == initialAccount) ? initialAccount : _firstAccount(context);
  return showFormSheet<void>(
    context,
    title: '${l.pay}: ${debt.name}',
    titleAction: InfoTip(l.repaymentNote, title: l.repayHelpTitle),
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
            return runAction(ctx, () => state.payDebt(debtId: debt.id, account: account!, principal: pr, interest: i, date: date));
          },
        ),
      ]),
    ),
  );
}

/// Возврат личного долга в любую сторону.
Future<void> showPersonRepaySheet(BuildContext context, PersonDebt debt, {bool all = false}) {
  final l = context.l10n;
  final state = AppScope.of(context).state;
  final messenger = ScaffoldMessenger.of(context);
  // Платёж по частям — обычное дело, поэтому поле пустое: подставленная вся сумма
  // выглядела как «вернул всё». Всю сумму и прошлый платёж можно выбрать кнопками.
  final amount = TextEditingController(text: all ? amountToField(debt.amount) : '');
  final progress = state.personDebtProgress(debt.person, oweMe: debt.oweMe);
  var account = _firstAccount(context);
  return showFormSheet<void>(
    context,
    title: debt.oweMe ? l.debtReceiveSheetTitle(debt.person) : l.debtPaySheetTitle(debt.person),
    titleAction: InfoTip(debt.oweMe ? l.repaymentReceivedNote : l.repaymentNote, title: l.repayHelpTitle),
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('${l.balanceLeft}: ${formatMoney(debt.amount)}', style: TextStyle(color: ctx.fam.text2)),
        const SizedBox(height: 12),
        AmountField(controller: amount, label: l.amount, hint: l.debtAmountHint, autofocus: !all),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 4, children: [
          if (progress.lastPayment > 0 && progress.lastPayment < debt.amount)
            ActionChip(label: Text(l.debtChipLast(formatMoney(progress.lastPayment))), onPressed: () => set(() => amount.text = amountToField(progress.lastPayment))),
          ActionChip(label: Text(l.debtChipAll(formatMoney(debt.amount))), onPressed: () => set(() => amount.text = amountToField(debt.amount))),
        ]),
        const SizedBox(height: 12),
        AccountPicker(accounts: state.activeAccounts, value: account, onChanged: (v) => set(() => account = v)),
        const SizedBox(height: 20),
        SubmitButton(
          label: l.save,
          onSubmit: () async {
            final a = parseAmount(amount.text);
            if (a == null || account == null) return false;
            final ok = await runAction(
              ctx,
              () => state.addPersonDebt(
                kind: debt.oweMe ? 'repaymentReceived' : 'repaymentMade',
                amount: a,
                person: debt.person,
                account: account!,
                date: state.today,
              ),
            );
            if (ok) {
              final left = debt.amount - a;
              messenger.showSnackBar(SnackBar(content: Text(left <= 0 ? l.debtClosedSnack : l.debtLeftSnack(formatMoney(left)))));
            }
            return ok;
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
/// «Реализовать цель» (D98): накопленное возвращается на счёт и тут же
/// списывается с него расходом в выбранную категорию; цель закрывается.
Future<void> showRealizeGoalSheet(BuildContext context, GoalInfo goal) {
  final l = context.l10n;
  final state = AppScope.of(context).state;
  final saved = state.goalSaved(goal);
  final amount = TextEditingController(text: amountToField(saved));
  var account = _firstAccount(context);
  var category = 'other';
  return showFormSheet<void>(
    context,
    title: l.goalRealizeTitle(goal.name),
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(l.goalRealizeNote, style: TextStyle(fontSize: 13, color: ctx.fam.text2)),
        const SizedBox(height: 12),
        AmountField(controller: amount, label: l.amount),
        const SizedBox(height: 4),
        Text(l.goalRealizeSaved(moneyInText(saved)), style: TextStyle(fontSize: 12, color: ctx.fam.text2)),
        const SizedBox(height: 12),
        Text(l.category, style: TextStyle(fontSize: 12, color: ctx.fam.text2)),
        const SizedBox(height: 6),
        CategoryPicker(options: ensureIncluded(state.visibleExpenseCategories, category), value: category, onChanged: (c) => set(() => category = c)),
        const SizedBox(height: 12),
        AccountPicker(accounts: state.activeAccounts, value: account, label: l.goalRealizeAccount, onChanged: (v) => set(() => account = v)),
        ListenableBuilder(listenable: amount, builder: (_, _) => MinusWarning(accountId: account, amount: parseAmount(amount.text), returned: saved)),
        const SizedBox(height: 20),
        SubmitButton(
          label: l.goalRealize,
          onSubmit: () async {
            final a = parseAmount(amount.text);
            if (a == null || account == null) return false;
            return runAction(ctx, () => state.realizeGoal(goal, amount: a, category: category, account: account!));
          },
        ),
      ]),
    ),
  );
}

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
        const SizedBox(height: 6),
        Text(
          switch (type) { 'cash' => l.accountTypeCashNote, 'deposit' => l.accountTypeDepositNote, _ => l.accountTypeCardNote },
          style: TextStyle(fontSize: 12, color: ctx.fam.text2),
        ),
        const SizedBox(height: 12),
        AmountField(controller: balance, label: l.openingBalance),
        const SizedBox(height: 4),
        Text(l.openingBalanceNote, style: TextStyle(fontSize: 12, color: ctx.fam.text2)),
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
  await runAction(context, () => state.upsert('planned', id, r.toInfo(state, id: id).toJson()));
}

/// Правка планового платежа (Ж12): сумма, число, частота, название, категория.
/// Оплаченные сроки сохраняются. `true` — платёж изменён.
Future<bool> editPlannedFlow(BuildContext context, PlannedInfo p) async {
  final state = AppScope.of(context).state;
  final messenger = ScaffoldMessenger.of(context);
  final l = context.l10n;
  final r = await showPlannedSheet(context, initial: p);
  if (r == null || !context.mounted) return false;
  // Новые условия действуют с сегодняшнего дня; оплаченное прошлое не пересчитывается (R03).
  final next = p.copyWith(name: r.name, amount: r.amount, day: r.day, category: r.category, every: r.every, weekday: r.weekday, monthOfYear: r.monthOfYear, effectiveFrom: state.today);
  final ok = await runAction(context, () => state.upsert(p.entityKind, p.id, next.toJson()));
  if (ok) messenger.showSnackBar(SnackBar(content: Text(l.paymentSaved)));
  return ok;
}

/// Удаление планового платежа с подтверждением. `true` — удалён.
Future<bool> deletePlannedFlow(BuildContext context, PlannedInfo p) async {
  final state = AppScope.of(context).state;
  final l = context.l10n;
  if (!await confirm(context, title: l.deletePlanned, message: p.name, action: l.delete) || !context.mounted) return false;
  return runAction(context, () => state.delete(p.entityKind, p.id));
}

/// Действия с разовой покупкой (D88, D90): купил, копить, убрать из плана.
Future<void> showPurchaseSheet(BuildContext context, PlannedInfo p) {
  final l = context.l10n;
  final state = AppScope.of(context).state;
  final m = p.onceMonth!;
  return showFormSheet<void>(
    context,
    title: p.name,
    builder: (ctx) {
      final goal = state.purchaseGoal(p);
      final monthly = state.purchaseMonthly(p);
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Center(child: BigMoney(p.amount)),
        const SizedBox(height: 8),
        if (goal != null)
          Text(
            '${l.purchaseProgress(moneyInText(state.purchaseSaved(p)), moneyInText(p.amount))} · ${monthly == 0 ? l.purchaseReady : l.purchaseMore(moneyInText(monthly))}',
            textAlign: TextAlign.center,
            style: TextStyle(color: ctx.fam.text2),
          )
        else
          Text(l.purchaseSaveNote, style: TextStyle(fontSize: 13, color: ctx.fam.text2)),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: () {
            Navigator.pop(ctx);
            // «Купил»: расход записывается вне дневного лимита, покупка уходит из плана.
            showPayDueSheet(context, DueItem(p, DateTime(m.year, m.month + 1, 0), p.once!));
          },
          child: Text(l.purchaseBought),
        ),
        const SizedBox(height: 8),
        FilledButton.tonal(
          onPressed: () async {
            Navigator.pop(ctx);
            if (goal != null) {
              await showReserveSheet(context, goal, release: false, initial: monthly == 0 ? null : monthly);
            } else if (!state.pro && state.goals.isNotEmpty) {
              await showProGate(context, l.proGateGoals);
            } else {
              await runAction(context, () => state.startSavingFor(p));
            }
          },
          child: Text(goal != null ? l.purchaseTopUp : l.purchaseSave),
        ),
        if (goal != null) TextButton.icon(
          icon: const Icon(Icons.savings_outlined),
          label: Text(l.purchaseManageGoal),
          onPressed: () {
            Navigator.pop(ctx);
            showFormSheet<void>(
              context,
              title: l.purchaseManageGoal,
              builder: (_) => ListenableBuilder(
                listenable: state,
                builder: (_, __) {
                  final current = state.goals.where((g) => g.id == goal.id).firstOrNull;
                  return current == null ? const SizedBox.shrink() : GoalCard(goal: current);
                },
              ),
            );
          },
        ),
        TextButton(
          onPressed: () async {
            final nav = Navigator.of(ctx);
            if (!await confirm(ctx, title: l.deletePurchase, message: goal == null ? null : l.purchaseRemoveHint, action: l.delete) || !ctx.mounted) return;
            if (await runAction(ctx, () => state.delete('purchase', p.id))) nav.pop();
          },
          child: Text(l.purchaseRemove),
        ),
      ]);
    },
  );
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
  final d = await showBankDebtSheet(context, hintNewPurchase: true);
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
Future<bool> showAdjustBalanceSheet(BuildContext context, String accountId, {DateTime? asOf}) async {
  final l = context.l10n;
  final state = AppScope.of(context).state;
  final current = state.ledger.balance(accountId, asOf: asOf);
  final actual = TextEditingController(text: amountToField(current));
  final reason = TextEditingController();
  var saved = false;
  // Откуда разница (Ж4): чаще всего — незаписанные траты, и тогда уточнение
  // занизило бы расходы месяца. В сверке месяца по умолчанию — уточнение,
  // как и раньше; в обычной жизни — «забыл записать».
  var forgot = asOf == null;
  await showFormSheet<void>(
    context,
    title: l.adjustBalance,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) {
        final target = parseAmount(actual.text, allowZero: true, allowNegative: true);
        final delta = target == null ? null : target - current;
        final spent = delta != null && delta < 0;
        Widget option(bool value, String title, String note) => ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: Icon(forgot == value ? Icons.radio_button_checked : Icons.radio_button_off, color: forgot == value ? ctx.scheme.primary : ctx.fam.text2),
              title: Text(title),
              subtitle: Text(note, style: TextStyle(fontSize: 12, color: ctx.fam.text2)),
              onTap: () => set(() => forgot = value),
            );
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (asOf != null) Text(l.monthAdjustmentAsOf(DateFormat('d MMMM y', Localizations.localeOf(context).toString()).format(asOf))),
          Text('${l.inApp}: ${formatMoney(current)}', style: TextStyle(color: ctx.fam.text2)),
          const SizedBox(height: 12),
          AmountField(controller: actual, label: l.actualBalance, autofocus: true, allowNegative: true, onChanged: (_) => set(() {})),
          const SizedBox(height: 8),
          if (delta != null)
            Text(
              delta == 0 ? l.noDifference : '${l.difference}: ${delta > 0 ? '+' : ''}${formatMoney(delta)}',
              style: TextStyle(fontWeight: FontWeight.w600, color: delta == 0 ? ctx.fam.text2 : delta > 0 ? ctx.fam.income : ctx.fam.expense),
            ),
          if (delta != null && delta != 0) ...[
            const SizedBox(height: 8),
            Text(l.adjustWhy, style: TextStyle(fontSize: 12, color: ctx.fam.text2)),
            option(true, spent ? l.adjustForgotExpense : l.adjustForgotIncome, spent ? l.adjustForgotExpenseNote : l.adjustForgotIncomeNote),
            option(false, l.adjustOther, l.adjustOtherNote),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: reason,
            maxLength: 200,
            decoration: InputDecoration(labelText: forgot ? l.noteOptional : l.reason, hintText: forgot ? (spent ? l.catchUpExpenseNote : l.catchUpIncomeNote) : l.reasonHint, counterText: ''),
            onChanged: (_) => set(() {}),
          ),
          if (!forgot) ...[
            const SizedBox(height: 4),
            Text(l.adjustmentNote, style: TextStyle(fontSize: 12, color: ctx.fam.text2)),
          ],
          const SizedBox(height: 20),
          SubmitButton(
            label: l.save,
            onSubmit: () async {
              if (target == null || delta == null || delta == 0) return false;
              if (forgot) {
                final note = reason.text.trim().isEmpty ? (spent ? l.catchUpExpenseNote : l.catchUpIncomeNote) : reason.text.trim();
                final date = asOf ?? state.today;
                saved = await runAction(
                  ctx,
                  () => spent
                      ? state.addExpense(amount: -delta, category: 'other', account: accountId, date: date, note: note, catchUp: true)
                      : state.addIncome(amount: delta, source: 'otherIncome', account: accountId, date: date, note: note, catchUp: true),
                );
                return saved;
              }
              if (reason.text.trim().isEmpty) return false;
              saved = await runAction(ctx, () => state.adjustBalance(account: accountId, actualBalance: target, reason: reason.text.trim(), date: asOf));
              return saved;
            },
          ),
        ]);
      },
    ),
  );  return saved;
}
