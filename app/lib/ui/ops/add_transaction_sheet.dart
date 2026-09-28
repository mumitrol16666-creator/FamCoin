import 'package:famcoin_core/famcoin_core.dart' show VoiceDraft, VoiceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../state/app_scope.dart';
import '../../theme/app_theme.dart';
import '../budget/sheets.dart';
import '../more/categories_screen.dart';
import 'voice_sheet.dart';
import '../widgets/common.dart';

enum FieldsKind { expense, income, transfer, debt }

/// Q02 — ручная операция. Одна заметная кнопка «Сохранить» внизу;
/// голос, чек и шаблоны — явные кнопки рядом с полями (Pro).
Future<void> showAddTransactionSheet(BuildContext context, {VoiceDraft? draft}) {
  final state = AppScope.of(context).state;
  if (state.activeAccounts.isEmpty) return addAccountFlow(context);
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => _AddSheet(draft: draft),
  );
}

class _AddSheet extends StatelessWidget {
  const _AddSheet({this.draft});
  final VoiceDraft? draft;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: .92,
      maxChildSize: .95,
      builder: (context, controller) => Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 8, 4),
          child: Row(children: [
            Expanded(child: Text(l.addOperation, style: Theme.of(context).textTheme.headlineSmall)),
            IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
          ]),
        ),
        Expanded(child: TransactionFields(draft: draft, scrollController: controller)),
      ]),
    );
  }
}

/// Поля операции — сумма, тип, категория, счёт, дата и время. Используются
/// и как самостоятельная форма (Q02), и как редактируемый черновик после
/// голоса (S38): один и тот же код правки, чтобы не расходились два места.
class TransactionFields extends StatefulWidget {
  const TransactionFields({super.key, this.draft, this.scrollController, this.showVoiceChip = true});

  /// Черновик из голосового ввода: поля заполняются, но не сохраняются
  /// до нажатия «Сохранить».
  final VoiceDraft? draft;

  /// Задан — форма прокручивается сама (самостоятельный экран); не задан —
  /// встроена в чужой скролл (черновик внутри голосового экрана).
  final ScrollController? scrollController;
  final bool showVoiceChip;

  @override
  State<TransactionFields> createState() => _TransactionFieldsState();
}

class _TransactionFieldsState extends State<TransactionFields> {
  FieldsKind _kind = FieldsKind.expense;
  final _amount = TextEditingController();
  final _note = TextEditingController();
  final _person = TextEditingController();
  String _category = 'food';
  String _source = 'salary';
  String? _account;
  String? _to;
  String _who = 'me';

  /// lendOut, borrow, repaymentReceived, repaymentMade.
  String _debtKind = 'lendOut';
  DateTime? _dateOverride;
  TimeOfDay _time = TimeOfDay.now();
  bool _busy = false;

  /// Категория/счёт/человек не распознаны голосом — не блокирует сохранение,
  /// только подсказывает проверить поле (раздел 10 карты: черновик всегда
  /// можно поправить перед записью).
  bool _categoryMissing = false;
  bool _accountMissing = false;
  bool _personMissing = false;

  DateTime get _date => _dateOverride ?? AppScope.of(context).state.today;
  bool _prefilled = false;

  void _applyDraft(VoiceDraft d) {
    final today = AppScope.of(context).state.today;
    _kind = switch (d.kind) {
      VoiceKind.expense => FieldsKind.expense,
      VoiceKind.income => FieldsKind.income,
      VoiceKind.transfer => FieldsKind.transfer,
      _ => FieldsKind.debt,
    };
    _debtKind = switch (d.kind) {
      VoiceKind.borrow => 'borrow',
      VoiceKind.repaymentReceived => 'repaymentReceived',
      VoiceKind.repaymentMade => 'repaymentMade',
      _ => 'lendOut',
    };
    if (d.amount != null) _amount.text = amountToField(d.amount!);
    if (d.category != null) {
      if (d.kind == VoiceKind.income) {
        _source = d.category!;
      } else {
        _category = d.category!;
      }
    } else if (d.kind == VoiceKind.expense) {
      _categoryMissing = true;
    }
    if (d.accountId != null) {
      _account = d.accountId;
    } else if (AppScope.of(context).state.activeAccounts.length > 1) {
      // При одном счёте выбирать не из чего — предупреждать не о чем.
      _accountMissing = true;
    }
    if (d.toAccountId != null) _to = d.toAccountId;
    if (d.person != null) {
      _person.text = d.person!;
    } else if (d.kind != VoiceKind.expense && d.kind != VoiceKind.income && d.kind != VoiceKind.transfer) {
      _personMissing = true;
    }
    if (d.note.isNotEmpty) _note.text = d.note;
    if (d.date != null && d.date != 0) _dateOverride = today.add(Duration(days: d.date!));
  }

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    _person.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    final l = context.l10n;
    final state = AppScope.of(context).state;
    final messenger = ScaffoldMessenger.of(context);
    final amount = parseAmount(_amount.text);
    if (amount == null) {
      messenger.showSnackBar(SnackBar(content: Text(l.enterAmount)));
      return;
    }
    final account = _account!;
    final note = _note.text.trim();
    final time = timeToField(_time);
    setState(() => _busy = true);
    final ok = await runAction(context, () {
      switch (_kind) {
        case FieldsKind.expense:
          return state.addExpense(amount: amount, category: _category, account: account, date: _date, who: state.familyMode ? _who : 'me', note: note, time: time);
        case FieldsKind.income:
          return state.addIncome(amount: amount, source: _source, account: account, date: _date, note: note, time: time);
        case FieldsKind.transfer:
          return state.addTransfer(amount: amount, from: account, to: _to!, date: _date, time: time);
        case FieldsKind.debt:
          return state.addPersonDebt(kind: _debtKind, amount: amount, person: _person.text.trim(), account: account, date: _date, time: time);
      }
    });
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      Navigator.pop(context);
      messenger.showSnackBar(SnackBar(content: Text(l.saved)));
    }
  }

  bool get _valid {
    if (parseAmount(_amount.text) == null || _account == null) return false;
    if (_kind == FieldsKind.transfer) return _to != null && _to != _account;
    if (_kind == FieldsKind.debt) return _person.text.trim().isNotEmpty;
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final state = AppScope.of(context).state;
    final fam = context.fam;
    final locale = Localizations.localeOf(context).toString();
    final accounts = state.activeAccounts;
    if (!_prefilled && widget.draft != null) {
      _prefilled = true;
      _applyDraft(widget.draft!);
    }
    _account ??= (accounts.where((a) => a.liquid).firstOrNull ?? accounts.first).id;
    final others = [...accounts, ...state.piggyAccounts].where((a) => a.id != _account).toList();
    if (_to == null || _to == _account) _to = others.firstOrNull?.id;

    Widget label(String text) => Padding(padding: const EdgeInsets.only(top: 14, bottom: 6), child: Text(text, style: TextStyle(fontSize: 12, color: fam.text2)));

    Widget proChip(IconData icon, String text) => ActionChip(
          avatar: Icon(icon, size: 16),
          label: Row(mainAxisSize: MainAxisSize.min, children: [Text(text), const SizedBox(width: 6), const ProBadge()]),
          // Диалог, а не SnackBar: снэкбар рисуется под открытой формой и на
          // телефоне не виден вовсе.
          onPressed: () => state.pro
              ? showDialog<void>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: Text(l.receipt),
                    content: Text(l.receiptsSoon),
                    actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: Text(l.later))],
                  ),
                )
              : showProGate(context, l.proGateFast),
        );

    final missingHints = [
      if (_accountMissing) l.account,
      if (_categoryMissing) l.category,
      if (_personMissing) l.person,
    ];

    final children = <Widget>[
      SegmentedButton<FieldsKind>(
        showSelectedIcon: false,
        segments: [
          ButtonSegment(value: FieldsKind.expense, label: Text(l.expense)),
          ButtonSegment(value: FieldsKind.income, label: Text(l.income)),
          ButtonSegment(value: FieldsKind.transfer, label: Text(l.transfer)),
          ButtonSegment(value: FieldsKind.debt, label: Text(l.debt)),
        ],
        selected: {_kind},
        onSelectionChanged: (s) => setState(() => _kind = s.first),
      ),
      if (missingHints.isNotEmpty) ...[
        const SizedBox(height: 10),
        InfoBanner('${l.voiceCheckFields}: ${missingHints.join(', ').toLowerCase()}', color: fam.warnBg, icon: Icons.record_voice_over_outlined),
      ],
      const SizedBox(height: 14),
      AppCard(
        child: Column(children: [
          Text(l.amount, style: TextStyle(fontSize: 12, color: fam.text2)),
          TextField(
            controller: _amount,
            autofocus: widget.draft == null,
            textAlign: TextAlign.center,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9\s.,]'))],
            onChanged: (_) => setState(() {}),
            style: Theme.of(context).textTheme.displayMedium!.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
            decoration: const InputDecoration(border: InputBorder.none, enabledBorder: InputBorder.none, focusedBorder: InputBorder.none, filled: false, hintText: '0'),
          ),
          Text('KZT · ${_date == state.today ? l.today : DateFormat.yMMMd(locale).format(_date)}', style: TextStyle(fontSize: 12, color: fam.text2)),
        ]),
      ),
      if (_kind == FieldsKind.expense && widget.showVoiceChip)
        Wrap(spacing: 8, runSpacing: 4, children: [
          ActionChip(
            avatar: const Icon(Icons.mic_none, size: 16),
            label: Text(l.voice),
            onPressed: () {
              Navigator.pop(context);
              showVoiceSheet(context);
            },
          ),
          proChip(Icons.qr_code_scanner, l.receipt),
        ]),
      if (_kind == FieldsKind.transfer) ...[
        const SizedBox(height: 14),
        AccountPicker(key: ValueKey('from$_account'), accounts: accounts, value: _account, label: l.fromAccount, onChanged: (v) => setState(() => _account = v)),
        const SizedBox(height: 12),
        if (others.isEmpty)
          InfoBanner(state.pro ? l.needSecondAccount : l.proGateAccounts, color: fam.warnBg)
        else
          AccountPicker(key: ValueKey('to$_to'), accounts: others, value: _to, label: l.toAccount, onChanged: (v) => setState(() => _to = v)),
        const SizedBox(height: 12),
        InfoBanner(l.transferNote),
      ] else if (_kind == FieldsKind.debt) ...[
        label(l.debt),
        Wrap(spacing: 8, runSpacing: 4, children: [
          for (final (k, t) in [('lendOut', l.lendOut), ('borrow', l.borrow), ('repaymentReceived', l.returnedToMe), ('repaymentMade', l.iReturned)])
            ChoiceChip(label: Text(t), selected: _debtKind == k, onSelected: (_) => setState(() => _debtKind = k)),
        ]),
        label(l.person),
        TextField(controller: _person, onChanged: (_) => setState(() => _personMissing = false), decoration: InputDecoration(hintText: l.personHint)),
        if (state.knownPeople.isNotEmpty) ...[
          const SizedBox(height: 6),
          Wrap(spacing: 8, children: [
            for (final p in state.knownPeople) ActionChip(label: Text(p), onPressed: () => setState(() { _person.text = p; _personMissing = false; })),
          ]),
        ],
        const SizedBox(height: 14),
        AccountPicker(accounts: accounts, value: _account, onChanged: (v) => setState(() { _account = v; _accountMissing = false; })),
        const SizedBox(height: 12),
        InfoBanner(_debtKind == 'lendOut' || _debtKind == 'borrow' ? l.debtNote : l.repaymentNote),
      ] else ...[
        label(l.category),
        if (_kind == FieldsKind.expense)
          CategoryPicker(
            options: ensureIncluded(state.visibleExpenseCategories, _category),
            value: _category,
            onChanged: (c) => setState(() { _category = c; _categoryMissing = false; }),
            onAdd: () async {
              final id = await showCategorySheet(context);
              if (id != null && mounted) setState(() => _category = id);
            },
          )
        else
          CategoryPicker(
            options: ensureIncluded(state.visibleIncomeCategories, _source),
            value: _source,
            onChanged: (c) => setState(() => _source = c),
            onAdd: () async {
              final id = await showCategorySheet(context, income: true);
              if (id != null && mounted) setState(() => _source = id);
            },
          ),
        const SizedBox(height: 14),
        AccountPicker(accounts: accounts, value: _account, onChanged: (v) => setState(() { _account = v; _accountMissing = false; })),
        if (state.familyMode && _kind == FieldsKind.expense) ...[
          label(l.forWhom),
          Wrap(spacing: 8, runSpacing: 4, children: [
            ChoiceChip(label: Text(l.me), selected: _who == 'me', onSelected: (_) => setState(() => _who = 'me')),
            ChoiceChip(label: Text(l.shared), selected: _who == 'shared', onSelected: (_) => setState(() => _who = 'shared')),
            for (final m in state.members)
              ChoiceChip(label: Text(m.name), selected: _who == m.id, onSelected: (_) => setState(() => _who = m.id)),
          ]),
        ],
      ],
      label(l.date),
      Wrap(spacing: 8, children: [
        ChoiceChip(label: Text(l.today), selected: _date == state.today, onSelected: (_) => setState(() => _dateOverride = state.today)),
        ChoiceChip(
          label: Text(l.yesterday),
          selected: _date == state.today.subtract(const Duration(days: 1)),
          onSelected: (_) => setState(() => _dateOverride = state.today.subtract(const Duration(days: 1))),
        ),
        ActionChip(
          avatar: const Icon(Icons.calendar_month_outlined, size: 16),
          label: Text(l.pickDate),
          onPressed: () async {
            final picked = await showDatePicker(context: context, initialDate: _date, firstDate: DateTime(2000), lastDate: state.today);
            if (picked != null) setState(() => _dateOverride = DateTime(picked.year, picked.month, picked.day));
          },
        ),
        ActionChip(
          avatar: const Icon(Icons.access_time, size: 16),
          label: Text(timeToField(_time)),
          onPressed: () async {
            final picked = await showTimePicker(context: context, initialTime: _time);
            if (picked != null) setState(() => _time = picked);
          },
        ),
      ]),
      if (_kind == FieldsKind.expense || _kind == FieldsKind.income) ...[
        label(l.note),
        TextField(controller: _note, maxLength: 120, decoration: InputDecoration(hintText: l.noteHint, counterText: '')),
      ],
      const SizedBox(height: 20),
      FilledButton(
        onPressed: _valid && !_busy ? _save : null,
        child: _busy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : Text(l.save),
      ),
    ];

    final controller = widget.scrollController;
    if (controller != null) {
      return ListView(controller: controller, padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.of(context).viewInsets.bottom), children: children);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }
}
