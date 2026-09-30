import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../state/app_scope.dart';
import '../../theme/app_theme.dart';
import '../budget/sheets.dart';
import '../more/categories_screen.dart';
import '../widgets/common.dart';

class _Part {
  _Part(this.category, int amount) : amount = TextEditingController(text: amount == 0 ? '' : amountToField(amount));
  String category;
  final TextEditingController amount;
}

/// Q04 + F032 — изменение покупки или дохода. Покупку можно разделить на
/// несколько категорий: это одна операция, общая сумма не удваивается (T24).
Future<void> showEditTransactionSheet(BuildContext context, Transaction tx) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => _EditSheet(tx: tx),
  );
}

class _EditSheet extends StatefulWidget {
  const _EditSheet({required this.tx});
  final Transaction tx;

  @override
  State<_EditSheet> createState() => _EditSheetState();
}

class _EditSheetState extends State<_EditSheet> {
  late final bool _isIncome = widget.tx.type == EventType.income;
  final _parts = <_Part>[];
  late final _note = TextEditingController(text: widget.tx.meta['note'] as String? ?? '');
  late String _account;
  late DateTime _date = widget.tx.date;
  late String _who = widget.tx.meta['who'] as String? ?? 'me';
  late bool _planned = widget.tx.meta['plannedPurchase'] == true;
  late TimeOfDay _time = timeFromField(widget.tx.meta['time']) ?? TimeOfDay.now();

  @override
  void initState() {
    super.initState();
    for (final p in widget.tx.postings) {
      if (p.accountId.startsWith('expense:')) _parts.add(_Part(p.accountId.substring(8), p.amount));
      if (p.accountId.startsWith('income:')) _parts.add(_Part(p.accountId.substring(7), p.amount));
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ledger = AppScope.of(context).state.ledger;
    _account = widget.tx.postings.firstWhere((p) => ledger.account(p.accountId).isMoney).accountId;
  }

  @override
  void dispose() {
    for (final p in _parts) {
      p.amount.dispose();
    }
    _note.dispose();
    super.dispose();
  }

  int get _total => _parts.fold(0, (s, p) => s + (parseAmount(p.amount.text) ?? 0));
  bool get _valid => _parts.isNotEmpty && _parts.every((p) => parseAmount(p.amount.text) != null) && {for (final p in _parts) p.category}.length == _parts.length;

  Future<bool> _save() async {
    final state = AppScope.of(context).state;
    if (!_valid) return false;
    return runAction(context, () {
      if (_isIncome) {
        return state.editIncome(widget.tx, amount: _total, source: _parts.first.category, account: _account, date: _date, note: _note.text.trim(), time: timeToField(_time));
      }
      return state.editExpense(
        widget.tx,
        splits: {for (final p in _parts) p.category: parseAmount(p.amount.text)!},
        account: _account,
        date: _date,
        who: _who,
        note: _note.text.trim(),
        time: timeToField(_time),
        plannedPurchase: _planned,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final state = AppScope.of(context).state;
    final fam = context.fam;
    final locale = Localizations.localeOf(context).toString();
    var options = _isIncome ? state.visibleIncomeCategories : state.visibleExpenseCategories;
    for (final p in _parts) {
      options = ensureIncluded(options, p.category);
    }
    final accounts = [
      ...state.activeAccounts,
      if (!state.activeAccounts.any((a) => a.id == _account)) ?state.accountInfo(_account),
    ];

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(_isIncome ? l.editIncome : l.editExpense, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 16),
          for (final (i, p) in _parts.indexed) ...[
            Row(children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: p.category,
                  isExpanded: true,
                  decoration: InputDecoration(labelText: l.category),
                  items: [
                    for (final c in options)
                      DropdownMenuItem(value: c.id, child: Row(children: [Icon(c.icon, size: 18), const SizedBox(width: 8), Flexible(child: Text(categoryName(l, c.id), overflow: TextOverflow.ellipsis))])),
                  ],
                  onChanged: (v) => setState(() => p.category = v ?? p.category),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(width: 130, child: AmountField(controller: p.amount, label: l.amount, onChanged: (_) => setState(() {}))),
              if (_parts.length > 1)
                IconButton(tooltip: l.tipRemove, icon: const Icon(Icons.close), onPressed: () => setState(() => _parts.removeAt(i).amount.dispose())),
            ]),
            const SizedBox(height: 10),
          ],
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.add),
              label: Text(l.ownCategory),
              onPressed: () async {
                final id = await showCategorySheet(context, income: _isIncome);
                if (id != null && mounted) setState(() => _parts.last.category = id);
              },
            ),
          ),
          if (!_isIncome)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.call_split),
                label: Text(l.splitAdd),
                onPressed: () {
                  final used = {for (final p in _parts) p.category};
                  final next = options.firstWhere((c) => !used.contains(c.id), orElse: () => options.last);
                  setState(() => _parts.add(_Part(next.id, 0)));
                },
              ),
            ),
          if (_parts.length > 1)
            InfoBanner('${l.splitTotal}: ${formatMoney(_total)}. ${l.splitNote}'),
          if ({for (final p in _parts) p.category}.length != _parts.length)
            InfoBanner(l.splitDuplicate, color: fam.warnBg),
          AccountPicker(accounts: accounts, value: _account, onChanged: (v) => setState(() => _account = v)),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.calendar_month_outlined),
              label: Text(DateFormat.yMMMMd(locale).format(_date)),
              onPressed: () async {
                final picked = await showDatePicker(context: context, initialDate: _date, firstDate: DateTime(2000), lastDate: state.today);
                if (picked != null) setState(() => _date = DateTime(picked.year, picked.month, picked.day));
              },
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.access_time),
              label: Text(timeToField(_time)),
              onPressed: () async {
                final picked = await showTimePicker(context: context, initialTime: _time);
                if (picked != null) setState(() => _time = picked);
              },
            ),
          ]),
          if (state.familyMode && !_isIncome) ...[
            const SizedBox(height: 12),
            Text(l.forWhom, style: TextStyle(fontSize: 12, color: fam.text2)),
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 4, children: [
              ChoiceChip(label: Text(l.me), selected: _who == 'me', onSelected: (_) => setState(() => _who = 'me')),
              ChoiceChip(label: Text(l.shared), selected: _who == 'shared', onSelected: (_) => setState(() => _who = 'shared')),
              for (final m in state.members) ChoiceChip(label: Text(m.name), selected: _who == m.id, onSelected: (_) => setState(() => _who = m.id)),
            ]),
          ],
          // Запланированная покупка не входит в дневной лимит (D74). Оплата
          // планового платежа и так вне лимита — переключатель ей не нужен.
          if (!_isIncome && widget.tx.meta['planned'] == null && (state.dailyLimit != null || _planned))
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(l.plannedPurchaseSwitch),
              subtitle: Text(l.plannedPurchaseSwitchNote, style: TextStyle(fontSize: 12, color: fam.text2)),
              value: _planned,
              onChanged: (v) => setState(() => _planned = v),
            ),
          const SizedBox(height: 12),
          TextField(controller: _note, maxLength: 120, decoration: InputDecoration(labelText: l.note, counterText: '')),
          const SizedBox(height: 8),
          Text(l.editHistoryNote, style: TextStyle(fontSize: 12, color: fam.text2)),
          const SizedBox(height: 16),
          SubmitButton(label: l.save, onSubmit: _save),
        ]),
      ),
    );
  }
}

/// Q05 — полный или частичный возврат покупки на счёт.
Future<void> showRefundSheet(BuildContext context, Transaction purchase) {
  final l = context.l10n;
  final state = AppScope.of(context).state;
  final parts = [
    for (final p in purchase.postings)
      if (p.accountId.startsWith('expense:')) (p.accountId.substring(8), p.amount - state.refundedFor(purchase.id, p.accountId.substring(8))),
  ].where((e) => e.$2 > 0).toList();
  if (parts.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.alreadyRefunded)));
    return Future.value();
  }
  var category = parts.first.$1;
  final amount = TextEditingController(text: amountToField(parts.first.$2));
  final paidFrom = purchase.postings.firstWhere((p) => state.ledger.account(p.accountId).isMoney).accountId;
  var account = state.activeAccounts.any((a) => a.id == paidFrom) ? paidFrom : state.activeAccounts.firstOrNull?.id;
  return showFormSheet<void>(
    context,
    title: l.refund,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) {
        final left = parts.firstWhere((e) => e.$1 == category).$2;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (parts.length > 1)
            Wrap(spacing: 8, children: [
              for (final (c, _) in parts)
                ChoiceChip(
                  label: Text(categoryName(l, c)),
                  selected: category == c,
                  onSelected: (_) => set(() {
                    category = c;
                    amount.text = amountToField(parts.firstWhere((e) => e.$1 == c).$2);
                  }),
                ),
            ]),
          const SizedBox(height: 12),
          AmountField(controller: amount, label: l.amount),
          const SizedBox(height: 4),
          Text('${l.canRefund}: ${formatMoney(left)}', style: TextStyle(fontSize: 12, color: ctx.fam.text2)),
          const SizedBox(height: 12),
          AccountPicker(accounts: state.activeAccounts, value: account, onChanged: (v) => set(() => account = v)),
          const SizedBox(height: 8),
          Text(l.refundNote, style: TextStyle(fontSize: 12, color: ctx.fam.text2)),
          const SizedBox(height: 20),
          SubmitButton(
            label: l.save,
            onSubmit: () async {
              final a = parseAmount(amount.text);
              if (a == null || a > left || account == null) return false;
              return runAction(ctx, () => state.refund(purchase, category: category, amount: a, account: account!));
            },
          ),
        ]);
      },
    ),
  );
}
