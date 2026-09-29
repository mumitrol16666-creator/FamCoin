import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';

import '../../state/app_scope.dart';
import '../../state/models.dart';
import '../../state/retryable_action.dart';
import '../widgets/common.dart';

/// Deliberately non-dismissible while an outcome is unknown: the user can
/// retry the SAME attempt instead of accidentally starting another payment.
Future<void> showPaymentSheet(BuildContext context, {
  DueItem? due, DebtInfo? bankDebt, PersonDebt? personDebt, int? principal,
}) => showModalBottomSheet<void>(
  context: context, isScrollControlled: true, useSafeArea: true,
  isDismissible: false, enableDrag: false,
  builder: (_) => _PaymentSheet(due: due, bankDebt: bankDebt, personDebt: personDebt, principal: principal),
);

class _PaymentSheet extends StatefulWidget {
  const _PaymentSheet({this.due, this.bankDebt, this.personDebt, this.principal});
  final DueItem? due;
  final DebtInfo? bankDebt;
  final PersonDebt? personDebt;
  final int? principal;
  @override
  State<_PaymentSheet> createState() => _PaymentSheetState();
}

class _PaymentSheetState extends State<_PaymentSheet> {
  final _attempt = RetryableAction();
  late final TextEditingController _amount;
  final _interest = TextEditingController();
  String? _account;
  bool _initialized = false;
  bool _busy = false;

  bool get _hasInterest => widget.bankDebt != null || widget.due?.planned.debtId != null;

  @override
  void initState() {
    super.initState();
    final amount = widget.due?.planned.amount ?? widget.personDebt?.amount ?? widget.principal;
    _amount = TextEditingController(text: amount == null ? '' : amountToField(amount));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final accounts = AppScope.of(context).state.activeAccounts;
    _account = accounts.where((a) => a.liquid).firstOrNull?.id ?? accounts.firstOrNull?.id;
  }

  @override
  void dispose() {
    _amount.dispose();
    _interest.dispose();
    super.dispose();
  }

  Future<void> _submit({bool markOnly = false}) async {
    if (_busy) return;
    final state = AppScope.of(context).state;
    CommandAction? action;
    if (!_attempt.pending) {
      final due = widget.due;
      final bank = widget.bankDebt;
      final person = widget.personDebt;
      if (markOnly) {
        if (due == null) return;
        action = (key) => state.markDuePaid(due, commandId: key);
      } else {
        final amount = parseAmount(_amount.text, allowZero: bank != null);
        final interest = _interest.text.trim().isEmpty ? 0 : parseAmount(_interest.text, allowZero: true);
        final account = _account;
        if (amount == null || interest == null || account == null) return;
        if (bank == null && amount <= 0) return;
        if (bank != null && amount + interest <= 0) return;
        if (due != null && interest > amount) return;
        // Capture every value, including date/transaction ID, only once.
        final id = newId();
        final date = state.today;
        if (due != null) {
          action = (key) => state.payDue(due, account: account, amount: amount,
              interest: interest, date: date, id: id, commandId: key);
        } else if (bank != null) {
          action = (key) => state.payDebt(debtId: bank.id, account: account,
              principal: amount, interest: interest, date: date, id: id, commandId: key);
        } else if (person != null) {
          action = (key) => state.addPersonDebt(
              kind: person.oweMe ? 'repaymentReceived' : 'repaymentMade',
              amount: amount, person: person.person, account: account,
              date: date, id: id, commandId: key);
        } else {
          return;
        }
      }
    }
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    try {
      final ok = await runAction(context, () => _attempt.run(action));
      if (!mounted) return;
      setState(() => _busy = false);
      if (ok) Navigator.pop(context);
    } finally {
      if (mounted && _busy) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final state = AppScope.of(context).state;
    final locked = _busy || _attempt.pending;
    final name = widget.due?.planned.name ?? widget.bankDebt?.name ?? widget.personDebt?.person ?? '';
    final person = widget.personDebt;
    final title = person == null ? '${l.pay}: $name' : '${person.oweMe ? l.returnedToMe : l.iReturned}: $name';
    return PopScope(
      canPop: !locked,
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: Text(title, style: Theme.of(context).textTheme.titleLarge)),
              IconButton(onPressed: locked ? null : () => Navigator.pop(context),
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip, icon: const Icon(Icons.close)),
            ]),
            if (_attempt.pending && !_busy) InfoBanner(l.paymentRetryHint),
            ExcludeFocus(
              excluding: locked,
              child: AbsorbPointer(
                absorbing: locked,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const SizedBox(height: 12),
                  if (widget.bankDebt != null)
                    Text('${l.balanceLeft}: ${formatMoney(state.debtBalance(widget.bankDebt!.id))}'),
                  AmountField(controller: _amount, label: widget.bankDebt == null ? l.amount : l.principalPart),
                  if (_hasInterest) ...[
                    const SizedBox(height: 12),
                    AmountField(controller: _interest, label: l.interestPart, hint: '0'),
                    Text(l.interestPartNote, style: const TextStyle(fontSize: 12)),
                  ],
                  const SizedBox(height: 12),
                  AccountPicker(accounts: state.activeAccounts, value: _account,
                      onChanged: (v) => setState(() => _account = v)),
                ]),
              ),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _busy ? null : () => _submit(),
              child: _busy
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(_attempt.pending ? l.paymentRetryAction : l.pay),
            ),
            if (widget.due != null)
              TextButton(onPressed: locked ? null : () => _submit(markOnly: true), child: Text(l.markPaidOnly)),
          ]),
        ),
      ),
    );
  }
}
