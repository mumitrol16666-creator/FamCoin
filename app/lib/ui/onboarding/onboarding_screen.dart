import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../l10n/app_localizations.dart';
import '../../state/app_scope.dart';
import '../../state/app_state.dart';
import '../../state/models.dart';
import '../../theme/app_theme.dart';
import '../more/categories_screen.dart';
import 'notification_step.dart';
import '../widgets/common.dart';

/// Уровень настройки, который человек выбирает на приветствии.
enum OnboardingLevel {
  /// Имя, счёт и дневной лимит — остальное добавляется в самом приложении.
  quick,

  /// Вся анкета.
  full,
}

/// Шаги анкеты. Порядок задаёт [_stepsOf]; номер шага на экране — позиция в нём.
enum _Step { about, mode, account, debts, planned, people, daily, limits, goal, notifications, summary }

const _quickSteps = [_Step.about, _Step.account, _Step.daily];
const _fullSteps = [
  _Step.about,
  _Step.mode,
  _Step.account,
  // Кредиты раньше обязательных платежей: платёж по кредиту создаётся
  // вместе с кредитом, и на следующем шаге он уже виден в списке.
  _Step.debts,
  _Step.planned,
  _Step.people,
  _Step.daily,
  _Step.limits,
  _Step.goal,
  _Step.notifications,
  _Step.summary,
];

/// S06 — анкета первого запуска. Всё введённое отправляется одной
/// командой: либо сохраняется целиком, либо не сохраняется ничего.
/// Любой шаг, кроме имени и счёта, можно пропустить и заполнить позже.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, this.level = OnboardingLevel.full, this.onBack});
  final OnboardingLevel level;

  /// Возврат на приветствие с первого шага; `null` — стрелки на первом шаге нет.
  final VoidCallback? onBack;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

/// Кредит, рассрочка или кредитка, введённые в анкете.
class BankDebtDraft {
  BankDebtDraft(this.name, this.kind, this.balance, this.payment, this.day, this.rate, {this.paidThisMonth = true});
  final String name;
  final String kind;
  final int balance;
  final int payment;
  final int day;
  final double rate;
  final bool paidThisMonth;
}

class _PersonDraft {
  _PersonDraft(this.person, this.oweMe, this.amount);
  final String person;
  final bool oweMe;
  final int amount;
}

class _LimitDraft {
  _LimitDraft(this.category, this.amount);
  final String category;
  final int amount;
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  late final List<_Step> _steps = widget.level == OnboardingLevel.quick ? _quickSteps : _fullSteps;
  int _step = 0;
  bool _busy = false;

  // 1. О вас (D50) — имя из Telegram подставляется, если есть.
  final _firstName = TextEditingController();
  final _lastName = TextEditingController();
  DateTime? _birth;
  bool _prefilled = false;
  // 2. Режим
  bool _family = false;
  final _members = <Member>[];
  // 3. Счёт
  final _accName = TextEditingController(text: 'Kaspi Gold');
  String _accType = 'card';
  final _accBalance = TextEditingController();
  // 4–7
  final _planned = <PlannedResult>[];
  final _debts = <BankDebtDraft>[];
  final _people = <_PersonDraft>[];
  final _limits = <_LimitDraft>[];
  final _goalName = TextEditingController();
  // 7. Дневной лимит на мелочи (D120): центральное понятие приложения вводится в анкете.
  final _dailyLimit = TextEditingController();
  // 10. Уведомления (D76): по умолчанию включено всё, как на сервере.
  final _notif = {for (final k in notificationKinds) k: true};
  final _goalTarget = TextEditingController();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_prefilled) return;
    _prefilled = true;
    final parts = (AppScope.of(context).state.name ?? '').trim().split(RegExp(r'\s+'));
    if (parts.isNotEmpty && parts.first.isNotEmpty) {
      _firstName.text = parts.first;
      _lastName.text = parts.skip(1).join(' ');
    }
  }

  @override
  void dispose() {
    for (final c in [_firstName, _lastName, _accName, _accBalance, _goalName, _goalTarget, _dailyLimit]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _accountValid => _accName.text.trim().isNotEmpty && parseAmount(_accBalance.text, allowZero: true) != null;
  bool get _aboutValid => _firstName.text.trim().isNotEmpty;

  List<Map<String, dynamic>> _commands(AppState state) {
    final today = dateToJson(state.today);
    final accountCmds = state.newAccountCommands(
      name: _accName.text.trim(),
      type: _accType,
      balance: parseAmount(_accBalance.text, allowZero: true) ?? 0,
    );
    final goalTarget = parseAmount(_goalTarget.text);
    final dailyLimit = parseAmount(_dailyLimit.text);
    return [
      ...accountCmds,
      for (final m in _members) {'type': 'upsertEntity', 'kind': 'member', 'entityId': m.id, 'data': m.toJson()},
      for (final p in _planned) {'type': 'upsertEntity', 'kind': 'planned', 'entityId': newId(), 'data': p.toInfo(state).toJson()},
      for (final d in _debts) ...state.newBankDebtCommands(name: d.name, kind: d.kind, balance: d.balance, payment: d.payment, day: d.day, rate: d.rate, paidThisMonth: d.paidThisMonth),
      for (final p in _people)
        p.oweMe
            ? {'type': 'openingReceivable', 'id': newId(), 'date': today, 'person': p.person, 'amount': p.amount.toString()}
            : {'type': 'openingDebt', 'id': newId(), 'date': today, 'debtId': p.person, 'amount': p.amount.toString()},
      for (final lim in _limits) {'type': 'upsertEntity', 'kind': 'limit', 'entityId': newId(), 'data': LimitInfo('', lim.category, lim.amount).toJson()},
      if (_goalName.text.trim().isNotEmpty && goalTarget != null) ...state.newGoalCommands(name: _goalName.text.trim(), target: goalTarget),
      {
        'type': 'updateProfile',
        'profile': {
          'mode': _family ? 'family' : 'personal',
          'firstName': _firstName.text.trim(),
          'lastName': _lastName.text.trim(),
          'birthDate': _birth == null ? null : dateToJson(_birth!),
          // Как AppState.setDailyLimit при первом включении: лимит, дата начала и история суммы.
          if (dailyLimit != null) ...{
            'dailyLimit': dailyLimit.toString(),
            'dailyLimitSince': today,
            'dailyLimitHistory': [{'from': today, 'amount': dailyLimit.toString()}],
          },
          'onboarded': true,
        },
      },
    ];
  }

  /// Итог анкеты считается тем же ядром на копии журнала, до отправки.
  NetWorth? _preview(AppState state) {
    if (!_accountValid) return null;
    try {
      final l = Ledger();
      for (final c in _commands(state)) {
        if (ledgerCommandTypes.contains(c['type'])) applyLedgerCommand(l, c);
      }
      return l.netWorth();
    } catch (_) {
      return null;
    }
  }

  Future<void> _finish() async {
    final state = AppScope.of(context).state;
    setState(() => _busy = true);
    final ok = await runAction(context, () => state.sendBatch(_commands(state)));
    // Выбор уведомлений — отдельным запросом после анкеты: он не часть
    // журнала. Если не дошёл, останутся значения по умолчанию (всё включено),
    // человек поправит в «Ещё → Уведомления» — анкету из-за этого не ронять.
    // В быстром старте шага нет, и по умолчанию остаётся «всё включено».
    if (ok && _steps.contains(_Step.notifications)) {
      try {
        await state.api.updateNotificationSettings(state.token, Map<String, Object?>.from(_notif));
      } catch (_) {}
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final fam = context.fam;
    final state = AppScope.of(context).state;
    final current = _steps[_step];
    final last = _step == _steps.length - 1;
    final canSkip = current != _Step.about && current != _Step.account && !last;
    final canNext = switch (current) { _Step.about => _aboutValid, _Step.account => _accountValid, _ => true };

    final (title, hint, tip, body) = switch (current) {
      _Step.about => (l.ob0Title, l.ob0Hint, l.tipAbout, _aboutStep()),
      _Step.mode => (l.ob1Title, l.ob1Hint, l.tipMode, _modeStep()),
      _Step.account => (l.ob2Title, l.ob2Hint, l.tipAccount, _accountStep()),
      _Step.debts => (l.ob5Title, l.ob5Hint, l.tipDebts, _debtStep()),
      _Step.planned => (l.ob4Title, l.ob4Hint, l.tipPlanned, _plannedStep()),
      _Step.people => (l.ob6Title, l.ob6Hint, l.tipPeople, _peopleStep()),
      _Step.daily => (l.obDailyTitle, l.obDailyHint, l.tipDailyLimit, _dailyStep()),
      _Step.limits => (l.ob7Title, l.ob7Hint, l.tipLimits, _limitsStep()),
      _Step.goal => (l.obGoalTitle, l.obGoalHint, l.tipGoal, _goalStep()),
      _Step.notifications => (l.obNotifTitle, l.obNotifHint, l.tipNotif, NotificationStep(values: _notif, onToggle: (k, v) => setState(() => _notif[k] = v))),
      _Step.summary => (l.ob8Title, l.ob8Hint, l.tipSummary, _summaryStep(state)),
    };

    return Scaffold(
      appBar: AppBar(
        title: Text(l.obStep(_step + 1, _steps.length)),
        leading: _step == 0
            ? (widget.onBack == null ? null : IconButton(tooltip: l.tipBack, icon: const Icon(Icons.arrow_back), onPressed: widget.onBack))
            : IconButton(tooltip: l.tipBack, icon: const Icon(Icons.arrow_back), onPressed: () => setState(() => _step--)),
        actions: [
          if (canSkip) TextButton(onPressed: () => setState(() => _step++), child: Text(l.skip)),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              for (var i = 0; i < _steps.length; i++)
                Expanded(
                  child: Container(
                    height: 4,
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    decoration: BoxDecoration(color: i <= _step ? context.scheme.primary : fam.line, borderRadius: BorderRadius.circular(2)),
                  ),
                ),
            ]),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
              children: [
                Row(children: [
                  Expanded(child: Text(title, style: Theme.of(context).textTheme.headlineSmall)),
                  InfoTip(tip, title: title),
                ]),
                const SizedBox(height: 4),
                Text(hint, style: TextStyle(color: fam.text2, fontSize: 13)),
                const SizedBox(height: 16),
                body,
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: !last
                ? FilledButton(onPressed: canNext ? () => setState(() => _step++) : null, child: Text(l.next))
                : FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: fam.accent, foregroundColor: fam.onAccent),
                    onPressed: _busy ? null : _finish,
                    child: _busy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : Text(l.obStart),
                  ),
          ),
        ]),
      ),
    );
  }

  // --------------------------------------------------------------- шаги

  Widget _radio(String title, String subtitle, bool selected, VoidCallback onTap) {
    return AppCard(
      onTap: onTap,
      child: Row(children: [
        Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off, color: selected ? context.scheme.primary : context.fam.text2),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
            Text(subtitle, style: TextStyle(fontSize: 12, color: context.fam.text2)),
          ]),
        ),
      ]),
    );
  }

  Widget _modeStep() {
    final l = context.l10n;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _radio(l.modePersonal, l.personalDesc, !_family, () => setState(() => _family = false)),
      _radio(l.modeFamily, l.familyDesc, _family, () => setState(() => _family = true)),
      if (_family) ...[
        SectionHeader(l.familyMembers),
        for (final m in _members)
          AppCard(
            child: Row(children: [
              CircleAvatar(child: Text(m.name.characters.first.toUpperCase())),
              const SizedBox(width: 12),
              Expanded(child: Text('${m.name} · ${roleName(l, m.role)}')),
              IconButton(tooltip: l.tipRemove, icon: const Icon(Icons.close), onPressed: () => setState(() => _members.remove(m))),
            ]),
          ),
        OutlinedButton.icon(onPressed: _addMember, icon: const Icon(Icons.person_add_alt), label: Text(l.addMember)),
        const SizedBox(height: 8),
        Text(l.familyNote, style: TextStyle(fontSize: 12, color: context.fam.text2)),
      ],
    ]);
  }

  Future<void> _addMember() async {
    final m = await showMemberSheet(context);
    if (m != null) setState(() => _members.add(m));
  }

  Widget _accountStep() {
    final l = context.l10n;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(controller: _accName, decoration: InputDecoration(labelText: l.accName), onChanged: (_) => setState(() {})),
      const SizedBox(height: 12),
      Wrap(spacing: 8, children: [
        for (final t in accountTypes)
          ChoiceChip(
            avatar: Icon(accountTypeIcon(t), size: 16, color: _accType == t ? context.scheme.onPrimary : null),
            label: Text(accountTypeName(l, t)),
            selected: _accType == t,
            onSelected: (_) => setState(() => _accType = t),
          ),
      ]),
      const SizedBox(height: 6),
      Text(
        switch (_accType) { 'cash' => l.accountTypeCashNote, 'deposit' => l.accountTypeDepositNote, _ => l.accountTypeCardNote },
        style: TextStyle(fontSize: 12, color: context.fam.text2),
      ),
      const SizedBox(height: 12),
      AmountField(controller: _accBalance, label: l.openingBalance, onChanged: (_) => setState(() {})),
      const SizedBox(height: 8),
      Text(l.openingBalanceNote, style: TextStyle(fontSize: 12, color: context.fam.text2)),
    ]);
  }

  Widget _aboutStep() {
    final l = context.l10n;
    final locale = Localizations.localeOf(context).toString();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(controller: _firstName, autofocus: _firstName.text.isEmpty, textCapitalization: TextCapitalization.words, decoration: InputDecoration(labelText: l.firstName), onChanged: (_) => setState(() {})),
      const SizedBox(height: 12),
      TextField(controller: _lastName, textCapitalization: TextCapitalization.words, decoration: InputDecoration(labelText: l.lastName)),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        icon: const Icon(Icons.cake_outlined),
        label: Text(_birth == null ? l.birthDatePick : DateFormat.yMMMMd(locale).format(_birth!)),
        onPressed: () async {
          final now = DateTime.now();
          final picked = await showDatePicker(context: context, initialDate: _birth ?? DateTime(now.year - 30, now.month, now.day), firstDate: DateTime(1920), lastDate: now);
          if (picked != null) setState(() => _birth = DateTime(picked.year, picked.month, picked.day));
        },
      ),
    ]);
  }

  Widget _list<T>(List<T> items, Widget Function(T) row, String addLabel, VoidCallback onAdd) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final i in items)
        AppCard(
          child: Row(children: [
            Expanded(child: row(i)),
            IconButton(tooltip: context.l10n.tipRemove, icon: const Icon(Icons.close), onPressed: () => setState(() => items.remove(i))),
          ]),
        ),
      OutlinedButton.icon(onPressed: onAdd, icon: const Icon(Icons.add), label: Text(addLabel)),
    ]);
  }

  Widget _two(String title, String subtitle, [Widget? trailing]) => Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
            Text(subtitle, style: TextStyle(fontSize: 12, color: context.fam.text2)),
          ]),
        ),
        if (trailing != null) trailing,
      ]);

  Widget _plannedStep() {
    final l = context.l10n;
    return _list<PlannedResult>(
      _planned,
      (p) => _two(p.name, '${categoryName(l, p.category)} · ${scheduleLabel(l, Localizations.localeOf(context).toString(), p.every, p.day, p.weekday, p.monthOfYear)}', MoneyText(p.amount)),
      l.addPayment,
      () async {
        final r = await showPlannedSheet(context);
        if (r != null) setState(() => _planned.add(r));
      },
    );
  }

  Widget _debtStep() {
    final l = context.l10n;
    return _list<BankDebtDraft>(
      _debts,
      (d) => _two(d.name, '${debtKindName(l, d.kind)} · ${formatMoney(d.payment)} · ${l.everyMonthOn(d.day)}', MoneyText(d.balance, color: context.fam.debt)),
      l.addDebt,
      () async {
        final r = await showBankDebtSheet(context);
        if (r != null) setState(() => _debts.add(r));
      },
    );
  }

  Widget _peopleStep() {
    final l = context.l10n;
    return _list<_PersonDraft>(
      _people,
      (p) => _two(p.person, p.oweMe ? l.oweMe : l.iOwe, MoneyText(p.amount, color: p.oweMe ? context.fam.income : context.fam.expense)),
      l.addPersonDebt,
      () async {
        final r = await _personSheet();
        if (r != null) setState(() => _people.add(r));
      },
    );
  }

  Future<_PersonDraft?> _personSheet() {
    final l = context.l10n;
    final name = TextEditingController();
    final amount = TextEditingController();
    var oweMe = true;
    return showFormSheet<_PersonDraft>(
      context,
      title: l.addPersonDebt,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: [ButtonSegment(value: true, label: Text(l.oweMe)), ButtonSegment(value: false, label: Text(l.iOwe))],
            selected: {oweMe},
            onSelectionChanged: (s) => set(() => oweMe = s.first),
          ),
          const SizedBox(height: 12),
          TextField(controller: name, decoration: InputDecoration(labelText: l.person)),
          const SizedBox(height: 12),
          AmountField(controller: amount, label: l.amount),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: () {
              final a = parseAmount(amount.text);
              if (name.text.trim().isEmpty || a == null) return;
              Navigator.pop(ctx, _PersonDraft(name.text.trim(), oweMe, a));
            },
            child: Text(l.add),
          ),
        ]),
      ),
    );
  }

  Widget _dailyStep() {
    final l = context.l10n;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      AmountField(controller: _dailyLimit, label: l.limitAmountDay),
      const SizedBox(height: 8),
      Text(l.obDailyNote, style: TextStyle(fontSize: 12, color: context.fam.text2)),
    ]);
  }

  Widget _limitsStep() {
    final l = context.l10n;
    final state = AppScope.of(context).state;
    final maxLimits = state.pro ? 20 : 2;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final lim in _limits)
        AppCard(
          child: Row(children: [
            CategoryAvatar.of(categoryById(lim.category), size: 36),
            const SizedBox(width: 12),
            Expanded(child: Text(categoryName(l, lim.category))),
            MoneyText(lim.amount),
            IconButton(tooltip: l.tipRemove, icon: const Icon(Icons.close), onPressed: () => setState(() => _limits.remove(lim))),
          ]),
        ),
      if (_limits.length < maxLimits)
        OutlinedButton.icon(
          onPressed: () async {
            final r = await showLimitSheet(context, exclude: {for (final x in _limits) x.category});
            if (r != null) setState(() => _limits.add(_LimitDraft(r.category, r.amount)));
          },
          icon: const Icon(Icons.add),
          label: Text(l.addLimit),
        ),
    ]);
  }

  Widget _goalStep() {
    final l = context.l10n;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(l.piggyNote, style: TextStyle(fontSize: 12, color: context.fam.text2)),
      const SizedBox(height: 12),
      TextField(controller: _goalName, decoration: InputDecoration(labelText: l.goalName, hintText: l.goalNameHint)),
      const SizedBox(height: 12),
      AmountField(controller: _goalTarget, label: l.goalTarget),
    ]);
  }

  Widget _summaryStep(AppState state) {
    final l = context.l10n;
    final fam = context.fam;
    final nw = _preview(state);
    if (nw == null) return InfoBanner(l.obAccountMissing, color: fam.warnBg);
    Widget row(String a, int v, {Color? color, bool bold = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            Expanded(child: Text(a, style: TextStyle(color: bold ? null : fam.text2, fontWeight: bold ? FontWeight.w700 : null))),
            MoneyText(v, color: color),
          ]),
        );
    final monthly = _planned.fold<int>(0, (s, p) => s + p.amount) + _debts.fold<int>(0, (s, d) => s + d.payment);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(l.capital, style: TextStyle(fontSize: 12, color: fam.text2)),
          BigMoney(nw.capital),
          const SizedBox(height: 8),
          row(l.money, nw.money),
          if (nw.receivables > 0) row(l.oweMe, nw.receivables, color: fam.income),
          if (nw.liabilities > 0) row(l.liabilities, -nw.liabilities, color: fam.debt),
        ]),
      ),
      AppCard(
        child: Column(children: [
          row(l.monthlyObligations, monthly),
          if (_limits.isNotEmpty) row(l.limits, _limits.fold<int>(0, (s, x) => s + x.amount)),
        ]),
      ),
      Text(l.obSummaryNote, style: TextStyle(fontSize: 12, color: fam.text2)),
    ]);
  }
}

// ----------------------------------------------------------- общие формы

/// Выбор числа месяца 1–31.
class DayPicker extends StatelessWidget {
  const DayPicker({super.key, required this.value, required this.onChanged, required this.label});
  final int value;
  final ValueChanged<int> onChanged;
  final String label;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<int>(
      initialValue: value,
      decoration: InputDecoration(labelText: label),
      items: [for (var d = 1; d <= 31; d++) DropdownMenuItem(value: d, child: Text('$d'))],
      onChanged: (v) => v == null ? null : onChanged(v),
    );
  }
}

Future<Member?> showMemberSheet(BuildContext context) {
  final l = context.l10n;
  final name = TextEditingController();
  var role = 'spouse';
  return showFormSheet<Member>(
    context,
    title: l.addMember,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(controller: name, autofocus: true, decoration: InputDecoration(labelText: l.memberName)),
        const SizedBox(height: 12),
        Wrap(spacing: 8, children: [
          for (final r in ['spouse', 'child', 'other'])
            ChoiceChip(label: Text(roleName(l, r)), selected: role == r, onSelected: (_) => set(() => role = r)),
        ]),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: () {
            if (name.text.trim().isEmpty) return;
            Navigator.pop(ctx, Member(newId(), name.text.trim(), role));
          },
          child: Text(l.add),
        ),
      ]),
    ),
  );
}

class PlannedResult {
  PlannedResult(this.name, this.amount, this.day, this.category, {this.paidThisMonth = true, this.every = everyMonth, this.weekday, this.monthOfYear});
  final String name;
  final int amount;
  final int day;
  final String category;

  /// Если дата в этом месяце уже прошла: платёж за этот месяц сделан?
  final bool paidThisMonth;

  /// [everyMonth], [everyWeek] или [everyYear] (Ж7).
  final String every;
  final int? weekday;
  final int? monthOfYear;

  /// Новый платёж: с какой даты считать сроки, решает состояние.
  PlannedInfo toInfo(AppState state, {String id = ''}) => PlannedInfo(id, name, amount, day, category, null, const {},
      start: state.plannedStart(day, paidThisMonth: paidThisMonth, every: every), every: every, weekday: weekday, monthOfYear: monthOfYear);
}

/// Подпись частоты платежа: «каждое 10-е число», «Каждую неделю · пн»,
/// «Раз в год · 15 ноября».
String scheduleLabel(AppLocalizations l, String locale, String every, int day, int? weekday, int? monthOfYear) => switch (every) {
      everyWeek => l.everyWeekOn(DateFormat.E(locale).format(DateTime(2024, 1, weekday ?? 1))),
      everyYear => l.everyYearOn(DateFormat.MMMMd(locale).format(DateTime(2024, monthOfYear ?? 1, day))),
      _ => l.everyMonthOn(day),
    };

/// Форма планового платежа: название, сумма, частота, день, категория.
/// С [initial] — правка: у платежа по кредиту меняются только сумма и число
/// (название и категорию задаёт кредит), оплаченные сроки не теряются.
Future<PlannedResult?> showPlannedSheet(BuildContext context, {PlannedInfo? initial}) {
  final l = context.l10n;
  final locale = Localizations.localeOf(context).toString();
  final name = TextEditingController(text: initial?.name ?? '');
  final amount = TextEditingController(text: initial == null ? '' : amountToField(initial.amount));
  var day = initial?.day ?? 10;
  var category = initial?.category ?? 'home';
  var every = initial?.every ?? everyMonth;
  var weekday = initial?.weekday ?? 1;
  var monthOfYear = initial?.monthOfYear ?? AppScope.of(context).state.today.month;
  var paidThisMonth = true;
  final isDebt = initial?.debtId != null;
  final todayDay = AppScope.of(context).state.today.day;
  return showFormSheet<PlannedResult>(
    context,
    title: initial == null ? l.addPayment : l.editPaymentTitle,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (isDebt) ...[
          Text(initial!.name, style: Theme.of(ctx).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(l.paymentDebtNote, style: TextStyle(fontSize: 12, color: ctx.fam.text2)),
        ] else
          TextField(controller: name, autofocus: initial == null, decoration: InputDecoration(labelText: l.paymentName, hintText: l.paymentNameHint)),
        const SizedBox(height: 12),
        AmountField(controller: amount, label: l.amount),
        if (!isDebt && initial?.once == null) ...[
          const SizedBox(height: 12),
          Text(l.payEvery, style: TextStyle(fontSize: 12, color: ctx.fam.text2)),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 4, children: [
            for (final (k, t) in [(everyMonth, l.everyMonthChip), (everyWeek, l.everyWeekChip), (everyYear, l.everyYearChip)])
              ChoiceChip(label: Text(t), selected: every == k, onSelected: (_) => set(() => every = k)),
          ]),
        ],
        const SizedBox(height: 12),
        if (every == everyWeek)
          Wrap(spacing: 8, runSpacing: 4, children: [
            for (var w = 1; w <= 7; w++)
              ChoiceChip(label: Text(DateFormat.E(locale).format(DateTime(2024, 1, w))), selected: weekday == w, onSelected: (_) => set(() => weekday = w)),
          ])
        else ...[
          if (every == everyYear) ...[
            DropdownButtonFormField<int>(
              isExpanded: true,
              initialValue: monthOfYear,
              decoration: InputDecoration(labelText: l.monthOfYearLabel),
              items: [for (var m = 1; m <= 12; m++) DropdownMenuItem(value: m, child: Text(toBeginningOfSentenceCase(DateFormat.MMMM(locale).format(DateTime(2024, m)))))],
              onChanged: (v) => v == null ? null : set(() => monthOfYear = v),
            ),
            const SizedBox(height: 12),
          ],
          DayPicker(value: day, label: l.dayOfMonth, onChanged: (d) => set(() => day = d)),
        ],
        if (initial == null && every == everyMonth && day < todayDay) PaidThisMonthSwitch(value: paidThisMonth, onChanged: (v) => set(() => paidThisMonth = v)),
        if (!isDebt && initial?.once == null) ...[
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
        ],
        const SizedBox(height: 20),
        FilledButton(
          onPressed: () {
            final a = parseAmount(amount.text);
            if ((!isDebt && name.text.trim().isEmpty) || a == null) return;
            Navigator.pop(
              ctx,
              PlannedResult(isDebt ? initial!.name : name.text.trim(), a, day, category,
                  paidThisMonth: initial == null && every == everyMonth && day < todayDay ? paidThisMonth : true,
                  every: every,
                  weekday: every == everyWeek ? weekday : null,
                  monthOfYear: every == everyYear ? monthOfYear : null),
            );
          },
          child: Text(initial == null ? l.add : l.save),
        ),
      ]),
    ),
  );
}

/// [hintNewPurchase] — вне анкеты: покупку, которую делают прямо сейчас,
/// лучше записать через «＋» → «В рассрочку» (Ж1), а не как готовый долг.
Future<BankDebtDraft?> showBankDebtSheet(BuildContext context, {bool hintNewPurchase = false}) {
  final l = context.l10n;
  final name = TextEditingController();
  final balance = TextEditingController();
  final payment = TextEditingController();
  final rate = TextEditingController();
  var kind = 'installment';
  var day = 5;
  var paidThisMonth = true;
  final todayDay = AppScope.of(context).state.today.day;
  return showFormSheet<BankDebtDraft>(
    context,
    title: l.addDebt,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 8, children: [
          for (final k in ['installment', 'creditCard', 'loan'])
            ChoiceChip(label: Text(debtKindName(l, k)), selected: kind == k, onSelected: (_) => set(() => kind = k)),
        ]),
        const SizedBox(height: 12),
        TextField(controller: name, decoration: InputDecoration(labelText: l.debtName, hintText: 'Kaspi Red')),
        const SizedBox(height: 12),
        AmountField(controller: balance, label: l.remaining),
        const SizedBox(height: 12),
        AmountField(controller: payment, label: l.monthlyPayment),
        const SizedBox(height: 12),
        DayPicker(value: day, label: l.dayOfMonth, onChanged: (d) => set(() => day = d)),
        if (day < todayDay) PaidThisMonthSwitch(value: paidThisMonth, onChanged: (v) => set(() => paidThisMonth = v)),
        if (kind != 'installment') ...[
          const SizedBox(height: 12),
          TextField(
            controller: rate,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: l.rate, suffixText: '%'),
          ),
        ],
        const SizedBox(height: 8),
        Text(l.debtNoIncome, style: TextStyle(fontSize: 12, color: ctx.fam.text2)),
        if (hintNewPurchase && kind == 'installment') ...[
          const SizedBox(height: 8),
          InfoBanner(l.installmentNewHint),
        ],
        const SizedBox(height: 20),
        FilledButton(
          onPressed: () {
            final b = parseAmount(balance.text);
            final p = parseAmount(payment.text, allowZero: true) ?? 0;
            if (name.text.trim().isEmpty || b == null) return;
            final r = double.tryParse(rate.text.replaceAll(',', '.')) ?? 0;
            Navigator.pop(ctx, BankDebtDraft(name.text.trim(), kind, b, p, day, r.clamp(0, 200).toDouble(), paidThisMonth: day < todayDay ? paidThisMonth : true));
          },
          child: Text(l.add),
        ),
      ]),
    ),
  );
}

class LimitResult {
  LimitResult(this.category, this.amount);
  final String category;
  final int amount;
}

Future<LimitResult?> showLimitSheet(BuildContext context, {Set<String> exclude = const {}, LimitInfo? initial}) async {
  final l = context.l10n;
  final state = AppScope.of(context).state;
  // Видимые встроенные плюс уже созданные свои категории (D41) — лимит
  // можно поставить и на свою категорию, не только на встроенную.
  final options = state.visibleExpenseCategories.where((c) => !exclude.contains(c.id) || c.id == initial?.category).toList();
  String category;
  if (initial != null) {
    category = initial.category;
  } else if (options.isNotEmpty) {
    category = options.first.id;
  } else {
    // Если все категории уже имеют лимит, можно создать новую прямо здесь.
    final id = await showCategorySheet(context);
    if (id == null || !context.mounted) return null;
    category = id;
  }
  final amount = TextEditingController(text: initial == null ? '' : amountToField(initial.amount));
  return showFormSheet<LimitResult>(
    context,
    title: initial == null ? l.addLimit : l.editLimit,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        CategoryPicker(
          options: ensureIncluded(options, category),
          value: category,
          onChanged: (c) => set(() => category = c),
          // Нужной категории может не быть в списке — создать её прямо тут,
          // не выходя из лимита (иначе не всем очевидно, что это вообще можно).
          onAdd: () async {
            final id = await showCategorySheet(context);
            if (id != null) set(() => category = id);
          },
        ),
        const SizedBox(height: 12),
        AmountField(controller: amount, label: l.limitAmount),
        const SizedBox(height: 8),
        Text(l.limitFormNote, style: TextStyle(fontSize: 12, color: ctx.fam.text2)),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: () {
            final a = parseAmount(amount.text);
            if (a == null) return;
            Navigator.pop(ctx, LimitResult(category, a));
          },
          child: Text(l.save),
        ),
      ]),
    ),
  );
}


/// Вопрос для платежа, дата которого в этом месяце уже прошла.
class PaidThisMonthSwitch extends StatelessWidget {
  const PaidThisMonthSwitch({super.key, required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(l.paidThisMonthQ),
      subtitle: Text(value ? l.paidThisMonthYes : l.paidThisMonthNo, style: TextStyle(fontSize: 12, color: context.fam.text2)),
      value: value,
      onChanged: onChanged,
    );
  }
}
