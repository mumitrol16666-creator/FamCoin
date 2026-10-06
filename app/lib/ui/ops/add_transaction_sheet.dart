import 'package:famcoin_core/famcoin_core.dart' show VoiceDraft, VoiceKind, formatMoney;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../l10n/app_localizations.dart';
import '../../state/api_client.dart' show ApiException;
import '../../state/app_scope.dart';
import '../../state/app_state.dart' show ReconciliationEditCancelled;
import '../../state/app_state.dart' show AppState;
import '../../state/models.dart' show AccountInfo, DebtInfo, DueItem, newId;
import '../../theme/app_theme.dart';
import '../budget/sheets.dart';
import '../more/categories_screen.dart';
import '../onboarding/onboarding_screen.dart' show DayPicker;
import 'voice_sheet.dart';
import '../widgets/common.dart';
import 'big_purchase.dart';
import 'income_goals_sheet.dart';

enum FieldsKind { expense, income, transfer, debt }

/// Q02 — ручная операция. Кнопка «Сохранить» закреплена внизу и видна без
/// прокрутки; заполненная форма не закрывается без подтверждения.
/// [kind] и [account] открывают форму сразу на нужной вкладке и со счётом
/// (например, «Перевести» на экране счёта или копилки).
Future<void> showAddTransactionSheet(BuildContext context, {VoiceDraft? draft, FieldsKind? kind, String? account, String? debtKind}) {
  final state = AppScope.of(context).state;
  if (state.activeAccounts.isEmpty) return addAccountFlow(context);
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    // Смахивание вниз закрывало бы форму мимо проверки черновика — закрытие
    // только крестиком, кнопкой «назад» или нажатием на затемнение.
    enableDrag: false,
    builder: (_) => _AddSheet(draft: draft, kind: kind, account: account, debtKind: debtKind),
  );
}

class _AddSheet extends StatefulWidget {
  const _AddSheet({this.draft, this.kind, this.account, this.debtKind});
  final VoiceDraft? draft;
  final FieldsKind? kind;
  final String? account;
  final String? debtKind;

  @override
  State<_AddSheet> createState() => _AddSheetState();
}

class _AddSheetState extends State<_AddSheet> {
  /// Есть введённые данные — закрытие требует подтверждения.
  final _dirty = ValueNotifier<bool>(false);

  @override
  void dispose() {
    _dirty.dispose();
    super.dispose();
  }

  Future<void> _close() async {
    final l = context.l10n;
    if (_dirty.value && !await confirm(context, title: l.discardDraftTitle, message: l.discardDraftMessage, action: l.discardDraft)) return;
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return ValueListenableBuilder<bool>(
      valueListenable: _dirty,
      builder: (context, dirty, child) => PopScope(
        canPop: !dirty,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _close();
        },
        child: child!,
      ),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: .92,
        minChildSize: .5,
        maxChildSize: .95,
        builder: (context, controller) => Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
            child: Row(children: [
              Expanded(child: Text(l.addOperation, style: Theme.of(context).textTheme.headlineSmall)),
              IconButton(tooltip: l.tipClose, onPressed: _close, icon: const Icon(Icons.close)),
            ]),
          ),
          Expanded(child: TransactionFields(draft: widget.draft, initialKind: widget.kind, initialAccount: widget.account, initialDebtKind: widget.debtKind, scrollController: controller, dirty: _dirty)),
        ]),
      ),
    );
  }
}

/// Поля операции — сумма, тип, категория, счёт, дата и время. Используются
/// и как самостоятельная форма (Q02), и как редактируемый черновик после
/// голоса (S38): один и тот же код правки, чтобы не расходились два места.
class TransactionFields extends StatefulWidget {
  const TransactionFields({super.key, this.draft, this.initialKind, this.initialAccount, this.initialDebtKind, this.scrollController, this.showVoiceChip = true, this.dirty});

  /// Вкладка и счёт, с которых форма открывается; без них — расход с основного счёта.
  final FieldsKind? initialKind;
  final String? initialAccount;

  /// Какой личный долг выбран при открытии вкладки «Долг»: lendOut, borrow и т. д.
  final String? initialDebtKind;

  /// Черновик из голосового ввода: поля заполняются, но не сохраняются
  /// до нажатия «Сохранить».
  final VoiceDraft? draft;

  /// Задан — форма прокручивается сама (самостоятельный экран); не задан —
  /// встроена в чужой скролл (черновик внутри голосового экрана).
  final ScrollController? scrollController;
  final bool showVoiceChip;

  /// Сообщает владельцу формы, что в ней есть несохранённые данные.
  final ValueNotifier<bool>? dirty;

  @override
  State<TransactionFields> createState() => _TransactionFieldsState();
}

class _TransactionFieldsState extends State<TransactionFields> {
  late FieldsKind _kind = widget.initialKind ?? FieldsKind.expense;
  final _amount = TextEditingController();
  final _note = TextEditingController();
  final _person = TextEditingController();
  String _category = 'food';
  String _source = 'salary';
  late String? _account = widget.initialAccount;
  String? _to;
  String _who = 'me';

  /// Пользователь сам тронул «для кого» — счёт больше не подставляет
  /// значение за него.
  bool _whoTouched = false;

  /// lendOut, borrow, repaymentReceived, repaymentMade.
  late String _debtKind = widget.initialDebtKind ?? 'lendOut';

  /// Старый долг (D102): денег на счёте уже нет — записывается только остаток
  /// долга, счёт не нужен.
  bool _oldDebt = false;

  /// Когда вернуть (D133): для «Взял в долг» — срок попадает в платежи и прогноз,
  /// для «Дал в долг» — виден на экране долга. `null` — без срока.
  DateTime? _dueDate;

  /// Покупка в рассрочку (Ж1): расход сейчас, долг на остаток, график в
  /// календаре — одной пачкой команд.
  bool _installment = false;
  final _months = TextEditingController(text: '12');
  final _downPayment = TextEditingController();
  int _dueDay = 25;
  bool _firstDueNextMonth = true;

  /// Похожий кредит уже предложен (Ж2) — при повторе «Сохранить» после
  /// ошибки сети не переспрашиваем.
  bool _loanChecked = false;
  bool get _isNewDebt => _kind == FieldsKind.debt && (_debtKind == 'lendOut' || _debtKind == 'borrow');
  DateTime? _dateOverride;
  TimeOfDay _time = TimeOfDay.now();
  bool _busy = false;

  /// Ошибка последней попытки сохранить — показывается прямо в форме:
  /// снэкбар под открытой панелью на телефоне не виден.
  String? _error;

  /// Идентификаторы записи и команды создаются один раз на форму: повтор
  /// «Сохранить» после обрыва связи отправляет ту же команду, и сервер не
  /// заводит вторую запись.
  final _txId = newId();
  final _commandId = newId();

  /// Ответ на «запланированная ли покупка» (D74) — спрашиваем один раз на сумму,
  /// повтор сохранения после ошибки сети не переспрашивает.
  PurchaseKind _purchase = PurchaseKind.regular;
  int? _plannedFor;
  bool _asking = false;

  /// Категория/счёт/человек не распознаны голосом — не блокирует сохранение,
  /// только подсказывает проверить поле (раздел 10 карты: черновик всегда
  /// можно поправить перед записью).
  bool _categoryMissing = false;
  bool _accountMissing = false;
  bool _personMissing = false;

  DateTime get _date => _dateOverride ?? AppScope.of(context).state.today;
  bool _prefilled = false;

  void _markDirty() {
    widget.dirty?.value = _amount.text.isNotEmpty || _note.text.isNotEmpty || _person.text.isNotEmpty;
  }

  /// Выбор счёта для расхода/дохода: если владелец счёта задан и «для кого»
  /// ещё не трогали руками — подставляет его, чтобы не выбирать дважды.
  void _selectAccount(String id) {
    _account = id;
    final owner = AppScope.of(context).state.accountInfo(id)?.owner;
    if (!_whoTouched && owner != null) _who = owner;
  }

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
    _markDirty();
  }

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    _person.dispose();
    _months.dispose();
    _downPayment.dispose();
    super.dispose();
  }

  /// Кредиты, на которые похож этот расход (Ж2): категория «Кредиты и долги»,
  /// название кредита в заметке или слово «кредит / рассрочка / ипотека».
  List<DebtInfo> _loanCandidates(AppState state, String note) {
    final active = state.bankDebts.where((d) => state.debtBalance(d.id) > 0).toList();
    if (active.isEmpty) return const [];
    final text = note.toLowerCase();
    final byName = [
      for (final d in active)
        if (d.name.trim().length >= 3 && text.contains(d.name.trim().toLowerCase())) d,
    ];
    if (byName.isNotEmpty) return byName;
    const words = ['кредит', 'рассрочк', 'ипотек', 'займ', 'заем', 'несие', 'бөліп төле', 'ипотека'];
    if (_category == 'debts' || words.any(text.contains)) return active;
    return const [];
  }

  /// «Это платёж по кредиту?» — да (какой), нет (обычный расход) или отмена.
  Future<(bool, DebtInfo?)?> _askLoanPayment(List<DebtInfo> candidates, int amount) async {
    final l = context.l10n;
    final state = AppScope.of(context).state;
    var chosen = candidates.first;
    return showDialog<(bool, DebtInfo?)>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text(l.loanPaymentAskTitle),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (candidates.length == 1)
              Text(l.loanPaymentAskBody(chosen.name, formatMoney(state.debtBalance(chosen.id))))
            else ...[
              Text(l.loanPaymentAskPick),
              for (final d in candidates)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: Icon(chosen.id == d.id ? Icons.radio_button_checked : Icons.radio_button_off, color: chosen.id == d.id ? ctx.scheme.primary : ctx.fam.text2),
                  title: Text(d.name),
                  subtitle: Text(formatMoney(state.debtBalance(d.id))),
                  onTap: () => set(() => chosen = d),
                ),
            ],
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l.cancel)),
            TextButton(onPressed: () => Navigator.pop(ctx, (false, null)), child: Text(l.loanPaymentNo)),
            FilledButton(onPressed: () => Navigator.pop(ctx, (true, chosen)), child: Text(l.loanPaymentYes)),
          ],
        ),
      ),
    );
  }

  /// Какой срок кредита оплачивается: один из неоплаченных или «досрочно».
  /// `null` — отмена; `(null,)` — досрочно, вне графика.
  Future<(DueItem?,)?> _askLoanDue(List<DueItem> dues) async {
    final l = context.l10n;
    final locale = Localizations.localeOf(context).toString();
    var chosen = dues.first;
    var early = false;
    return showDialog<(DueItem?,)>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text(l.loanPaymentWhichTitle),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final d in dues)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: Icon(!early && chosen == d ? Icons.radio_button_checked : Icons.radio_button_off, color: !early && chosen == d ? ctx.scheme.primary : ctx.fam.text2),
                title: Text('${DateFormat.MMMMd(locale).format(d.date)}${d.date.isBefore(AppScope.of(ctx).state.today) ? ' · ${l.overdue}' : ''}'),
                subtitle: Text(formatMoney(d.payAmount)),
                onTap: () => set(() {
                  chosen = d;
                  early = false;
                }),
              ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: Icon(early ? Icons.radio_button_checked : Icons.radio_button_off, color: early ? ctx.scheme.primary : ctx.fam.text2),
              title: Text(l.loanPaymentEarly),
              subtitle: Text(l.loanPaymentEarlyNote, style: TextStyle(fontSize: 12, color: ctx.fam.text2)),
              onTap: () => set(() => early = true),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l.cancel)),
            FilledButton(onPressed: () => Navigator.pop(ctx, (early ? null : chosen,)), child: Text(l.next)),
          ],
        ),
      ),
    );
  }

  Future<void> _saveInstallment(int amount) async {
    final l = context.l10n;
    final state = AppScope.of(context).state;
    final messenger = ScaffoldMessenger.of(context);
    final months = int.tryParse(_months.text.trim()) ?? 0;
    final down = parseAmount(_downPayment.text, allowZero: true) ?? 0;
    final name = _note.text.trim();
    if (name.isEmpty || months <= 0 || down >= amount) {
      setState(() => _error = l.enterAmount);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await state.sendBatch(
        state.installmentPurchaseCommands(
          name: name,
          amount: amount,
          category: _category,
          months: months,
          day: _dueDay,
          date: _date,
          downPayment: down,
          downPaymentAccount: down > 0 ? _account : null,
          firstDueNextMonth: _firstDueNextMonth,
          time: timeToField(_time),
          who: state.familyMode ? _who : 'me',
          id: _txId,
        ),
        commandId: _commandId,
      );
    } on ReconciliationEditCancelled {
      if (mounted) setState(() => _busy = false);
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e is ApiException && e.isNetwork ? l.retrySave : errorText(l, e);
      });
      return;
    }
    if (!mounted) return;
    widget.dirty?.value = false;
    Navigator.of(context).pop();
    messenger.showSnackBar(SnackBar(content: Text(l.installmentSaved)));
  }

  Future<void> _save() async {
    if (_busy || _asking) return;
    final l = context.l10n;
    final state = AppScope.of(context).state;
    final messenger = ScaffoldMessenger.of(context);
    final amount = parseAmount(_amount.text);
    if (amount == null) {
      setState(() => _error = l.enterAmount);
      return;
    }
    final oldDebt = _isNewDebt && _oldDebt;
    if (_account == null && !oldDebt) return;
    final account = _account ?? '';
    final note = _note.text.trim();
    final time = timeToField(_time);
    if (_kind == FieldsKind.expense && _installment) return _saveInstallment(amount);
    // Платёж по кредиту, записанный расходом, не уменьшил бы долг и не закрыл
    // срок в календаре (Ж2) — предлагаем провести его как платёж.
    if (_kind == FieldsKind.expense && !_loanChecked) {
      final candidates = _loanCandidates(state, note);
      if (candidates.isNotEmpty) {
        _asking = true;
        final answer = await _askLoanPayment(candidates, amount);
        _asking = false;
        if (answer == null || !mounted) return;
        if (answer.$1) {
          final debt = answer.$2!;
          // Какой срок оплачивается (APP-04): оплата срока закрывает его и
          // уменьшает долг одной командой; «досрочно» — отдельный выбор.
          final dues = state.dueItems(state.today.add(const Duration(days: 62))).where((d) => d.planned.debtId == debt.id).toList();
          DueItem? due;
          if (dues.isNotEmpty) {
            _asking = true;
            final pick = await _askLoanDue(dues);
            _asking = false;
            if (pick == null || !mounted) return;
            due = pick.$1;
          }
          widget.dirty?.value = false;
          final nav = Navigator.of(context);
          final date = _date, payAccount = _account;
          nav.pop();
          if (due != null) {
            await showPayDueSheet(nav.context, due, date: date, initialAmount: amount, initialAccount: payAccount);
          } else {
            await showBankPaySheet(nav.context, debt, principal: amount, date: date, initialAccount: payAccount);
          }
          return;
        }
        _loanChecked = true;
      }
    }
    // Крупная покупка (D74): дневной лимит — на мелочи, поэтому спрашиваем,
    // не запланирована ли она; запланированная в лимит не входит.
    if (_kind == FieldsKind.expense && _plannedFor != amount) {
      _asking = true;
      final answer = await askPlannedPurchase(context, state, amount);
      _asking = false;
      if (answer == null || !mounted) return;
      _purchase = answer;
      _plannedFor = amount;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      switch (_kind) {
        case FieldsKind.expense:
          await state.addExpense(amount: amount, category: _category, account: account, date: _date, who: state.familyMode ? _who : 'me', note: note, time: time, plannedPurchase: _purchase.planned_, unexpected: _purchase.unexpected_, id: _txId, commandId: _commandId);
        case FieldsKind.income:
          await state.addIncome(amount: amount, source: _source, account: account, date: _date, note: note, time: time, id: _txId, commandId: _commandId);
        case FieldsKind.transfer:
          await state.addTransfer(amount: amount, from: account, to: _to!, date: _date, time: time, id: _txId, commandId: _commandId);
        case FieldsKind.debt:
          if (oldDebt) {
            await state.addOldPersonDebt(kind: _debtKind, amount: amount, person: _person.text.trim(), date: _date, dueDate: _isNewDebt ? _dueDate : null, id: _txId, commandId: _commandId);
          } else {
            await state.addPersonDebt(kind: _debtKind, amount: amount, person: _person.text.trim(), account: account, date: _date, time: time, dueDate: _isNewDebt ? _dueDate : null, id: _txId, commandId: _commandId);
          }
      }
    } on ReconciliationEditCancelled {
      if (mounted) setState(() => _busy = false);
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e is ApiException && e.isNetwork ? l.retrySave : errorText(l, e);
      });
      return;
    }
    if (!mounted) return;
    widget.dirty?.value = false;
    final nav = Navigator.of(context);
    nav.pop();
    // После дохода — предложение отложить часть на цели (D96). Лист сам
    // говорит, что доход записан, поэтому «Операция записана» не дублируем.
    // Непредвиденную трату можно покрыть из копилки (D101).
    if (_kind == FieldsKind.expense && _purchase.unexpected_) {
      messenger.showSnackBar(SnackBar(content: Text(l.saved)));
      await offerCoverFromGoal(nav.context, state, amount: amount, account: account);
      return;
    }
    if (_kind == FieldsKind.income && await offerIncomeToGoals(nav.context, amount: amount, account: account, source: _source, date: _date)) return;
    messenger.showSnackBar(SnackBar(content: Text(l.saved)));
  }

  bool get _valid {
    final amount = parseAmount(_amount.text);
    if (amount == null) return false;
    if (_kind == FieldsKind.expense && _installment) {
      final months = int.tryParse(_months.text.trim()) ?? 0;
      final down = parseAmount(_downPayment.text, allowZero: true) ?? 0;
      return _note.text.trim().isNotEmpty && months > 0 && down < amount && (down == 0 || _account != null);
    }
    if (_isNewDebt && _oldDebt) return _person.text.trim().isNotEmpty; // старый долг — без счёта (D102)
    if (_account == null) return false;
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
    if (_account == null) _selectAccount((accounts.where((a) => a.liquid).firstOrNull ?? accounts.first).id);
    final others = [...accounts, ...state.piggyAccounts].where((a) => a.id != _account).toList();
    if (_to == null || _to == _account) _to = others.firstOrNull?.id;

    Widget label(String text) => Padding(padding: const EdgeInsets.only(top: 14, bottom: 6), child: Text(text, style: TextStyle(fontSize: 12, color: fam.text2)));

    final missingHints = [
      if (_accountMissing) l.account,
      if (_categoryMissing) l.category,
      if (_personMissing) l.person,
    ];

    final children = <Widget>[
      SegmentedButton<FieldsKind>(
        showSelectedIcon: false,
        // Четыре подписи на узком экране: без переносов посреди слова.
        style: const ButtonStyle(
          visualDensity: VisualDensity.compact,
          padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 4)),
        ),
        segments: [
          for (final (k, t) in [(FieldsKind.expense, l.expense), (FieldsKind.income, l.income), (FieldsKind.transfer, l.transfer), (FieldsKind.debt, l.debt)])
            ButtonSegment(value: k, label: Text(t, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13))),
        ],
        selected: {_kind},
        onSelectionChanged: (s) => setState(() {
          _kind = s.first;
          // Копилка выбирается только как сторона перевода: расход, доход и долг
          // идут со своего обычного счёта.
          if (_kind != FieldsKind.transfer && !accounts.any((a) => a.id == _account)) {
            _account = (accounts.where((a) => a.liquid).firstOrNull ?? accounts.first).id;
          }
        }),
      ),
      if (missingHints.isNotEmpty) ...[
        const SizedBox(height: 10),
        InfoBanner('${l.voiceCheckFields}: ${missingHints.join(', ').toLowerCase()}', color: fam.warnBg, icon: Icons.record_voice_over_outlined),
      ],
      // Деньги уходят со счёта, а их там меньше — говорим заранее (D87).
      ListenableBuilder(
        listenable: _amount,
        builder: (context, _) => MinusWarning(
          accountId: _kind == FieldsKind.expense || _kind == FieldsKind.transfer || (_kind == FieldsKind.debt && !_oldDebt && (_debtKind == 'lendOut' || _debtKind == 'repaymentMade')) ? _account : null,
          amount: _kind == FieldsKind.expense && _installment ? parseAmount(_downPayment.text, allowZero: true) : parseAmount(_amount.text),
        ),
      ),
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
            onChanged: (_) {
              _markDirty();
              setState(() => _error = null);
            },
            style: Theme.of(context).textTheme.displayMedium!.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
            decoration: const InputDecoration(border: InputBorder.none, enabledBorder: InputBorder.none, focusedBorder: InputBorder.none, filled: false, hintText: '0'),
          ),
          Text('KZT · ${_date == state.today ? l.today : DateFormat.yMMMd(locale).format(_date)}', style: TextStyle(fontSize: 12, color: fam.text2)),
        ]),
      ),
      if (_kind == FieldsKind.expense)
        Wrap(spacing: 8, runSpacing: 4, children: [
          if (widget.showVoiceChip)
            ActionChip(
              avatar: const Icon(Icons.mic_none, size: 16),
              label: Text(l.voice),
              onPressed: () {
                widget.dirty?.value = false;
                Navigator.pop(context);
                showVoiceSheet(context);
              },
            ),
          // Покупка в рассрочку (Ж1): самая частая крупная покупка в Казахстане
          // раньше не имела пути в приложении.
          FilterChip(
            avatar: _installment ? null : const Icon(Icons.credit_card_outlined, size: 16),
            label: Text(l.installmentChip),
            selected: _installment,
            onSelected: (v) => setState(() => _installment = v),
          ),
        ]),
      if (_kind == FieldsKind.expense && _installment) ...[
        const SizedBox(height: 10),
        InfoBanner(l.installmentNote),
        label(l.installmentName),
        TextField(controller: _note, maxLength: 120, onChanged: (_) => setState(_markDirty), decoration: InputDecoration(hintText: l.installmentNameHint, counterText: '')),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              label(l.installmentMonths),
              TextField(
                key: const ValueKey('installment-months'),
                controller: _months,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(3)],
                onChanged: (_) => setState(() {}),
              ),
            ]),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              label(l.installmentDown),
              AmountField(key: const ValueKey('installment-down'), controller: _downPayment, hint: '0', onChanged: (_) => setState(() {})),
            ]),
          ),
        ]),
        if ((parseAmount(_amount.text) ?? 0) > (parseAmount(_downPayment.text, allowZero: true) ?? 0) && (int.tryParse(_months.text.trim()) ?? 0) > 0)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              l.installmentPerMonth(formatMoney(AppState.installmentPayment(parseAmount(_amount.text)! - (parseAmount(_downPayment.text, allowZero: true) ?? 0), int.parse(_months.text.trim())))),
              style: TextStyle(fontSize: 12, color: fam.text2),
            ),
          ),
        const SizedBox(height: 8),
        DayPicker(value: _dueDay, label: l.dayOfMonth, onChanged: (d) => setState(() => _dueDay = d)),
        label(l.installmentFirstDue),
        Wrap(spacing: 8, children: [
          ChoiceChip(label: Text(l.installmentNextMonth), selected: _firstDueNextMonth, onSelected: (_) => setState(() => _firstDueNextMonth = true)),
          ChoiceChip(label: Text(l.installmentThisMonth), selected: !_firstDueNextMonth, onSelected: (_) => setState(() => _firstDueNextMonth = false)),
        ]),
      ],
      if (_kind == FieldsKind.transfer) ...[
        // Частые переводы (Ж3): снял наличные, положил на карту, в копилку —
        // люди ищут их в «Расходе», а это переводы.
        if (_transferShortcuts(l, state, accounts).isNotEmpty) ...[
          label(l.transferQuick),
          Wrap(spacing: 8, runSpacing: 4, children: [
            for (final (text, from, to) in _transferShortcuts(l, state, accounts))
              ActionChip(label: Text(text), onPressed: () => setState(() { _account = from; _to = to; })),
          ]),
        ],
        const SizedBox(height: 14),
        // Из копилки тоже можно перевести: деньги вернутся на выбранный счёт.
        AccountPicker(key: ValueKey('from$_account'), accounts: [...accounts, ...state.piggyAccounts], value: _account, label: l.fromAccount, onChanged: (v) => setState(() => _account = v)),
        const SizedBox(height: 12),
        if (others.isEmpty)
          InfoBanner(state.pro ? l.needSecondAccount : l.proGateAccounts, color: fam.warnBg)
        else
          AccountPicker(key: ValueKey('to$_to'), accounts: others, value: _to, label: l.toAccount, onChanged: (v) => setState(() => _to = v)),
        const SizedBox(height: 12),
        InfoBanner(l.transferNote),
      ] else if (_kind == FieldsKind.debt) ...[
        Row(children: [
          Expanded(child: label(l.debt)),
          InfoTip(
            _isNewDebt && _oldDebt
                ? (_debtKind == 'borrow' ? l.debtOldBorrowNote : l.debtOldLendNote)
                : switch (_debtKind) {
                    'borrow' => l.borrowNote,
                    'lendOut' => l.debtNote,
                    'repaymentReceived' => l.repaymentReceivedNote,
                    _ => l.repaymentNote,
                  },
            title: _isNewDebt && _oldDebt ? l.oldDebtHelpTitle : switch (_debtKind) {
              'borrow' => l.borrowHelpTitle,
              'lendOut' => l.lendHelpTitle,
              _ => l.repayHelpTitle,
            },
          ),
        ]),
        Wrap(spacing: 8, runSpacing: 4, children: [
          for (final (k, t) in [('lendOut', l.lendOut), ('borrow', l.borrow), ('repaymentReceived', l.returnedToMe), ('repaymentMade', l.iReturned)])
            ChoiceChip(label: Text(t), selected: _debtKind == k, onSelected: (_) => setState(() => _debtKind = k)),
        ]),
        label(l.person),
        TextField(
          controller: _person,
          onChanged: (_) {
            _markDirty();
            setState(() => _personMissing = false);
          },
          decoration: InputDecoration(hintText: l.personHint),
        ),
        if (state.knownPeople.isNotEmpty) ...[
          const SizedBox(height: 6),
          Wrap(spacing: 8, children: [
            for (final p in state.knownPeople)
              ActionChip(
                label: Text(p),
                onPressed: () => setState(() {
                  _person.text = p;
                  _personMissing = false;
                  _markDirty();
                }),
              ),
          ]),
        ],
        // Когда это было (D102): свежий долг двигает деньги по счёту, старый —
        // только запоминается. Справка об учёте открывается по значку ⓘ.
        if (_isNewDebt) ...[
          label(l.debtWhenTitle),
          for (final (old, title, note) in [
            (false, _debtKind == 'borrow' ? l.debtNowBorrow : l.debtNowLend, _debtKind == 'borrow' ? l.debtNowBorrowNote : l.debtNowLendNote),
            (true, l.debtOld, _debtKind == 'borrow' ? l.debtOldBorrowNote : l.debtOldLendNote),
          ])
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: Icon(_oldDebt == old ? Icons.radio_button_checked : Icons.radio_button_off, color: _oldDebt == old ? context.scheme.primary : fam.text2),
              title: Text(title),
              subtitle: Text(note, style: TextStyle(fontSize: 12, color: fam.text2)),
              onTap: () => setState(() => _oldDebt = old),
            ),
        ],
        if (_isNewDebt) ...[
          label(l.debtDueLabel),
          Wrap(spacing: 8, runSpacing: 4, children: [
            ChoiceChip(label: Text(l.debtDueNone), selected: _dueDate == null, onSelected: (_) => setState(() => _dueDate = null)),
            ChoiceChip(
              label: Text(l.debtDueWeek),
              selected: _dueDate == state.today.add(const Duration(days: 7)),
              onSelected: (_) => setState(() => _dueDate = state.today.add(const Duration(days: 7))),
            ),
            ChoiceChip(
              label: Text(l.debtDueMonth),
              selected: _dueDate == DateTime(state.today.year, state.today.month + 1, state.today.day),
              onSelected: (_) => setState(() => _dueDate = DateTime(state.today.year, state.today.month + 1, state.today.day)),
            ),
            ActionChip(
              avatar: const Icon(Icons.calendar_month_outlined, size: 16),
              label: Text(_dueDate == null || _dueDate == state.today.add(const Duration(days: 7)) || _dueDate == DateTime(state.today.year, state.today.month + 1, state.today.day) ? l.debtDuePick : DateFormat.yMMMd(locale).format(_dueDate!)),
              onPressed: () async {
                final picked = await showDatePicker(context: context, initialDate: _dueDate ?? state.today.add(const Duration(days: 7)), firstDate: state.today, lastDate: DateTime(state.today.year + 10));
                if (picked != null) setState(() => _dueDate = DateTime(picked.year, picked.month, picked.day));
              },
            ),
          ]),
          const SizedBox(height: 4),
          Text(_debtKind == 'borrow' ? l.debtDueNoteBorrow : l.debtDueNoteLend, style: TextStyle(fontSize: 12, color: fam.text2)),
        ],
        if (!(_isNewDebt && _oldDebt)) ...[
          const SizedBox(height: 14),
          AccountPicker(accounts: accounts, value: _account, onChanged: (v) => setState(() { _account = v; _accountMissing = false; })),
        ],
      ] else ...[
        Row(children: [
          Expanded(child: label(l.category)),
          // Развилка «расход или перевод» — главное место ошибок (И2).
          if (_kind == FieldsKind.expense) InfoTip(l.expenseHelp, title: l.expenseHelpTitle) else InfoTip(l.incomeHelp, title: l.incomeHelpTitle),
        ]),
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
        if (!(_kind == FieldsKind.expense && _installment) || (parseAmount(_downPayment.text, allowZero: true) ?? 0) > 0) ...[
          const SizedBox(height: 14),
          AccountPicker(accounts: accounts, value: _account, label: _kind == FieldsKind.expense && _installment ? l.installmentDownAccount : null, onChanged: (v) => setState(() { _selectAccount(v); _accountMissing = false; })),
        ],
        if (state.familyMode && _kind == FieldsKind.expense) ...[
          label(l.forWhom),
          Wrap(spacing: 8, runSpacing: 4, children: [
            ChoiceChip(label: Text(l.me), selected: _who == 'me', onSelected: (_) => setState(() { _who = 'me'; _whoTouched = true; })),
            ChoiceChip(label: Text(l.shared), selected: _who == 'shared', onSelected: (_) => setState(() { _who = 'shared'; _whoTouched = true; })),
            for (final m in state.members)
              ChoiceChip(label: Text(m.name), selected: _who == m.id, onSelected: (_) => setState(() { _who = m.id; _whoTouched = true; })),
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
      if ((_kind == FieldsKind.expense && !_installment) || _kind == FieldsKind.income) ...[
        label(l.note),
        TextField(controller: _note, maxLength: 120, onChanged: (_) => _markDirty(), decoration: InputDecoration(hintText: l.noteHint, counterText: '')),
      ],
    ];

    final controller = widget.scrollController;
    // Кнопка сохранения закреплена под полями и видна без прокрутки; при
    // открытой клавиатуре поднимается над ней.
    final footer = Padding(
      padding: EdgeInsets.fromLTRB(controller != null ? 20 : 0, 8, controller != null ? 20 : 0, controller != null ? 12 + MediaQuery.of(context).viewInsets.bottom : 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: InfoBanner(_error!, color: fam.warnBg, icon: Icons.error_outline)),
        FilledButton(
          onPressed: _valid && !_busy ? _save : null,
          child: _busy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : Text(l.save),
        ),
      ]),
    );
    if (controller != null) {
      return Column(children: [
        Expanded(child: ListView(controller: controller, padding: const EdgeInsets.fromLTRB(20, 0, 20, 12), children: children)),
        footer,
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [...children, const SizedBox(height: 12), footer]);
  }
}

/// Подсказки переводов (Ж3): (подпись, откуда, куда). Только те, для которых
/// есть оба счёта.
List<(String, String, String)> _transferShortcuts(AppLocalizations l, AppState state, List<AccountInfo> accounts) {
  final cash = accounts.where((a) => a.type == 'cash').firstOrNull;
  final card = accounts.where((a) => a.type != 'cash' && a.liquid).firstOrNull;
  final piggy = state.piggyAccounts.firstOrNull;
  return [
    if (cash != null && card != null) (l.transferCashOut, card.id, cash.id),
    if (cash != null && card != null) (l.transferCashIn, cash.id, card.id),
    if (piggy != null && card != null) (l.transferToPiggy, card.id, piggy.id),
  ];
}
