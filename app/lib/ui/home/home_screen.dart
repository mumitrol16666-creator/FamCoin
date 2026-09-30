import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../state/app_scope.dart';
import '../../state/app_state.dart';
import '../../state/models.dart';
import '../../theme/app_theme.dart';
import '../analytics/analytics_screen.dart';
import '../budget/calendar_screen.dart';
import '../budget/sheets.dart';
import '../more/accounts_screen.dart';
import '../more/settings_screen.dart';
import '../more/tariff_screen.dart';
import '../ops/transaction_tile.dart';
import '../ops/voice_sheet.dart';
import '../widgets/common.dart';
import 'quick_actions.dart';

/// S07 — главная: ориентир → счета → обязательства → лимиты с риском →
/// отчёт за месяц → последние операции.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.onOpenJournal, required this.onOpenBudget, required this.onAdd});
  final VoidCallback onOpenJournal;
  final VoidCallback onOpenBudget;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context).state;
    final l = context.l10n;
    final fam = context.fam;
    final locale = Localizations.localeOf(context).toString();

    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final report = state.monthReport;
        final accounts = state.activeAccounts;
        final upcoming = state.upcoming.take(5).toList();
        final riskLimits = [
          for (final def in state.limits)
            if (state.limitStatusFor(def) case final st when st.warn80 || st.forecastExceeds) (def, st),
        ];
        final recent = state.userTransactions.take(5).toList();

        return Scaffold(
          appBar: AppBar(
            title: Text(l.navHome),
            actions: [
              PlanChip(pro: state.pro, onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const TariffScreen()))),
              const SizedBox(width: 4),
              IconButton(tooltip: l.voice, onPressed: () => showVoiceSheet(context), icon: const Icon(Icons.mic_none)),
              IconButton(
                tooltip: l.settings,
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen())),
                icon: CircleAvatar(
                  radius: 16,
                  backgroundColor: context.scheme.primary,
                  child: Text(state.displayName.isEmpty ? '?' : state.displayName.characters.first.toUpperCase(),
                      style: TextStyle(color: context.scheme.onPrimary, fontSize: 13, fontWeight: FontWeight.w700)),
                ),
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: RefreshIndicator(
            onRefresh: state.load,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              // Секции появляются каскадом при первом показе.
              children: [for (final (i, w) in <Widget>[
                // Ориентир на сегодня — главная цифра. По умолчанию доля на
                // сегодня; переключатель «Всего» показывает всю сумму,
                // свободную до зарплаты/конца месяца, без деления на дни —
                // не у всех бюджет живёт строго от выплаты до выплаты.
                _GuideCard(
                  state: state,
                  onSetLimit: () => _showLimitSheet(context, state),
                  onExplain: () => _showExplainSheet(context, state),
                ),
                const QuickActionsRow(),

                SectionHeader(l.accounts, action: '${l.all} ›', onAction: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AccountsScreen()))),
                SizedBox(
                  height: 82,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (final a in accounts) _AccountCard(a, state.ledger.balance(a.id)),
                      SizedBox(
                        width: 150,
                        child: AppCard(
                          onTap: () => addAccountFlow(context),
                          padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                            Row(children: [const Icon(Icons.add, size: 18), const Spacer(), if (!state.pro) const ProBadge()]),
                            const SizedBox(height: 4),
                            Text(l.addAccount, style: const TextStyle(fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
                          ]),
                        ),
                      ),
                    ],
                  ),
                ),

                SectionHeader(l.upcoming, action: '${l.allPayments} ›', onAction: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CalendarScreen()))),
                if (upcoming.isEmpty)
                  EmptyHint(l.noUpcoming, icon: Icons.event_available_outlined)
                else
                  AppCard(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: Column(children: [for (final d in upcoming) DueTile(due: d, locale: locale)]),
                  ),

                if (riskLimits.isNotEmpty) ...[
                  SectionHeader(l.limitsRisk, action: '${l.all} ›', onAction: onOpenBudget),
                  AppCard(
                    child: Column(children: [
                      for (final (def, st) in riskLimits)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Row(children: [
                              Icon(categoryById(def.category).icon, size: 18),
                              const SizedBox(width: 8),
                              Expanded(child: Text(categoryName(l, def.category))),
                              MoneyText(st.spent, style: const TextStyle(fontSize: 13)),
                              Text(' ${l.ofLimit} ${formatMoney(st.limit)}', style: TextStyle(fontSize: 13, color: fam.text2)),
                            ]),
                            const SizedBox(height: 6),
                            UsageBar(value: st.spent, max: st.limit),
                            const SizedBox(height: 4),
                            Text(
                              '${st.usedPercent?.round() ?? '—'}%${st.linearForecast != null ? ' · ${l.forecastToEnd}: ≈ ${formatMoney(st.linearForecast!)}' : ''}',
                              style: TextStyle(fontSize: 12, color: st.forecastExceeds ? fam.warn : fam.text2),
                            ),
                          ]),
                        ),
                    ]),
                  ),
                ],

                SectionHeader(l.monthReport, action: '${l.openReport} ›', onAction: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AnalyticsScreen()))),
                AppCard(
                  child: Column(children: [
                    Row(children: [
                      Expanded(child: _Kpi(l.reportIncome, report.income, fam.income)),
                      Expanded(child: _Kpi(l.reportExpense, report.expense, fam.expense)),
                    ]),
                    const Divider(height: 20),
                    Row(children: [
                      Expanded(child: Text(l.reportResult, style: TextStyle(color: fam.text2))),
                      MoneyText(report.result, sign: true),
                    ]),
                  ]),
                ),

                SectionHeader(l.recent, action: '${l.all} ›', onAction: onOpenJournal),
                if (recent.isEmpty)
                  AppCard(
                    onTap: onAdd,
                    child: Row(children: [
                      Icon(Icons.add_circle_outline, color: context.scheme.primary),
                      const SizedBox(width: 12),
                      Expanded(child: Text(l.noOperations, style: TextStyle(color: fam.text2, fontSize: 13))),
                    ]),
                  )
                else
                  AppCard(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                    child: Column(children: [for (final tx in recent) TransactionTile(tx)]),
                  ),
              ].indexed) FadeIn(index: i, child: w)],
            ),
          ),
        );
      },
    );
  }

  /// Дневной лимит задаёт сам владелец (D48); расчёт до зарплаты — подсказка.
  void _showLimitSheet(BuildContext context, AppState state) {
    final l = context.l10n;
    final amount = TextEditingController(text: state.dailyLimit == null ? '' : amountToField(state.dailyLimit!));
    showFormSheet<void>(
      context,
      title: l.dailyLimitTitle,
      builder: (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        AmountField(controller: amount, label: l.limitAmountDay, autofocus: true),
        const SizedBox(height: 8),
        // Сколько в день позволяют свободные деньги до дохода (D73) — чтобы
        // выбирать лимит, зная, на что хватит денег.
        if (state.guide.dailyBudget > 0) ...[
          Text(l.dailyLimitHint(moneyInText(state.guide.dailyBudget)), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: ctx.fam.text2)),
          const SizedBox(height: 4),
        ],
        Text(state.dailyLimitCarryOn ? l.dailyLimitNote : l.dailyLimitNoteNoCarry, style: TextStyle(fontSize: 12, color: ctx.fam.text2)),
        const SizedBox(height: 12),
        SubmitButton(
          label: l.save,
          onSubmit: () async {
            final a = parseAmount(amount.text);
            if (a == null) return false;
            return runAction(ctx, () => state.setDailyLimit(a));
          },
        ),
        if (state.dailyLimit != null && state.dailyLimitCarryOn && state.dailyLimitCarry != 0)
          TextButton(
            onPressed: () async {
              final nav = Navigator.of(ctx);
              if (await runAction(ctx, state.resetDailyLimitCarry)) nav.pop();
            },
            child: Text(l.carryReset),
          ),
        if (state.dailyLimit != null)
          TextButton(
            onPressed: () async {
              final nav = Navigator.of(ctx);
              if (await runAction(ctx, () => state.setDailyLimit(null))) nav.pop();
            },
            child: Text(l.dailyLimitRemove),
          ),
      ]),
    );
  }


  /// «Как посчитано» (D73): от денег на счетах до суммы, доступной сегодня.
  void _showExplainSheet(BuildContext context, AppState state) {
    final l = context.l10n;
    final ex = state.limitExplain;
    final locale = Localizations.localeOf(context).toString();
    String date(DateTime d) => DateFormat.MMMd(locale).format(d);

    showFormSheet<void>(
      context,
      title: l.explainTitle,
      builder: (ctx) {
        final fam = ctx.fam;
        Widget line(String label, Widget value, {String? hint, bool bold = false}) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(label, style: TextStyle(fontWeight: bold ? FontWeight.w700 : null)),
                    if (hint != null) Text(hint, style: TextStyle(fontSize: 12, color: fam.text2)),
                  ]),
                ),
                value,
              ]),
            );
        Widget money(int minor, {bool sign = false, bool bold = false, Color? color}) =>
            MoneyText(minor, sign: sign, color: color, style: TextStyle(fontWeight: bold ? FontWeight.w700 : null));
        Widget note(String text, {Color? color}) => Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(text, style: TextStyle(fontSize: 13, color: color ?? fam.text2)),
            );

        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          line(l.guideLiquid, money(ex.liquid)),
          if (ex.reserves > 0) line(l.guideReserves, money(-ex.reserves, sign: true)),
          if (ex.obligations > 0)
            line(
              l.explainObligationsUntil(date(ex.until)),
              money(-ex.obligations, sign: true),
              hint: ex.overdue > 0 ? l.explainOverdue(moneyInText(ex.overdue)) : null,
            ),
          const Divider(height: 16),
          line(l.free, money(ex.free, bold: true, color: ex.free < 0 ? fam.expense : null), bold: true),
          const SizedBox(height: 8),
          line(ex.byMonthEnd ? l.guideDaysMonth : l.guideDays, Text('${ex.days}')),
          line(l.guideFormula, money(ex.guideDaily), hint: l.explainGuideHint),
          if (ex.limit == null) ...[
            const Divider(height: 24),
            note(l.explainNoLimit),
          ] else ...[
            const Divider(height: 24),
            line(l.explainLimitDay, money(ex.limit!)),
            if (state.dailyLimitCarryOn && ex.carry != 0) line(l.explainCarry, money(ex.carry, sign: true)),
            line(l.explainSpent, money(-ex.spent, sign: true)),
            const Divider(height: 16),
            line(l.explainAvailable, money(ex.available!, bold: true, color: ex.available! < 0 ? fam.expense : null), bold: true),
            if (ex.outside > 0) note(l.explainOutside(moneyInText(ex.outside))),
            if (ex.shortfall > 0)
              note(l.explainNoteShortfall(moneyInText(ex.shortfall)), color: fam.expense)
            else ...[
              if (ex.capped) note(l.explainNoteCapped(moneyInText(ex.planned!))),
              if (ex.limitTooHigh)
                note(l.explainNoteHigh(date(ex.runOutDate!), date(ex.until)), color: fam.warn)
              else if (!ex.capped)
                note(l.explainNoteOk, color: fam.income),
            ],
          ],
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: () {
              Navigator.pop(ctx);
              _showLimitSheet(context, state);
            },
            child: Text(ex.limit == null ? l.dailyLimitSet : l.explainChangeLimit),
          ),
        ]);
      },
    );
  }

}

/// Главная карточка (D44/D48). «Всего» — остаток на денежных счетах, как в
/// «Счета». «В день» — лимит, который задал сам владелец, минус потраченное
/// сегодня; формула до зарплаты — только подсказка в форме лимита.
/// Текст всегда белый на своём фоне (`guideBg`), а не на `primary`.
class _GuideCard extends StatelessWidget {
  const _GuideCard({required this.state, required this.onSetLimit, required this.onExplain});
  final AppState state;
  final VoidCallback onSetLimit;
  final VoidCallback onExplain;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final fam = context.fam;
    final showTotal = state.guideView == 'total';
    final limit = state.dailyLimit;
    final spent = state.spentToday();
    final int? headline = showTotal ? state.ledger.liquid() : state.dailyLimitAvailable;
    final negative = (headline ?? 0) < 0;
    final carry = state.dailyLimitCarry;
    final ex = (!showTotal && limit != null) ? state.limitExplain : null;

    return AppCard(
      color: negative ? fam.guideBad : fam.guideBg,
      onTap: showTotal ? null : onSetLimit,
      child: DefaultTextStyle(
        style: const TextStyle(color: FamColors.onGuide),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(showTotal ? l.guideTotalTitle : l.leftToday, style: const TextStyle(fontSize: 13))),
            InfoTip(showTotal ? l.tipTotal : l.tipDailyLimit, title: showTotal ? l.guideTotalTitle : l.dailyLimitTitle, color: FamColors.onGuide),
            if (!showTotal) Text('${l.dailyLimitTitle} ›', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          ]),
          const SizedBox(height: 4),
          if (headline != null)
            BigMoney(headline, color: FamColors.onGuide)
          else
            Text(l.dailyLimitSet, style: Theme.of(context).textTheme.headlineSmall!.copyWith(color: FamColors.onGuide)),
          if (!showTotal) ...[
            const SizedBox(height: 2),
            Text(
              limit == null
                  ? l.dailyLimitPrompt
                  : '${formatMoney(limit)} ${l.perDay} · ${l.spentTodayLabel} ${formatMoney(spent)}'
                      '${carry == 0 ? '' : carry > 0 ? ' · ${l.carryPositive(moneyInText(carry))}' : ' · ${l.carryNegative(moneyInText(-carry))}'}',
              style: const TextStyle(fontSize: 13),
            ),
            // Доступное упирается в деньги, а не в лимит (D73) — говорим прямо.
            if (ex != null && (ex.shortfall > 0 || ex.capped))
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  ex.shortfall > 0 ? l.cardShortfall(moneyInText(ex.shortfall)) : l.cardCapped,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                ),
              ),
          ],
          const SizedBox(height: 10),
          Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            // Чипы переносятся, а ссылка сжимается: на узком экране и крупном
            // шрифте ничего не выходит за карточку.
            Expanded(
              flex: 3,
              child: Wrap(spacing: 8, runSpacing: 6, children: [
                _GuideModeChip(label: l.guideModeDaily, selected: !showTotal, onTap: () => runAction(context, () => state.setGuideView('daily'))),
                _GuideModeChip(label: l.guideModeTotal, selected: showTotal, onTap: () => runAction(context, () => state.setGuideView('total'))),
              ]),
            ),
            const SizedBox(width: 8),
            Flexible(
              flex: 2,
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: onExplain,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  child: Text('${l.explainOpen} ›', textAlign: TextAlign.end, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                ),
              ),
            ),
          ]),
          if (!showTotal && limit != null && limit > 0) ...[
            const SizedBox(height: 10),
            UsageBar(value: spent, max: limit, color: fam.accent),
          ],
        ]),
      ),
    );
  }
}

/// Маленький переключатель поверх цветной карточки — свой стиль, чтобы не
/// тянуть стандартные цвета Material, которые на акцентном фоне не видны.
class _GuideModeChip extends StatelessWidget {
  const _GuideModeChip({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const onPrimary = FamColors.onGuide;
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: onPrimary.withValues(alpha: selected ? .22 : 0),
          border: Border.all(color: onPrimary.withValues(alpha: selected ? .7 : .35)),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(label, style: TextStyle(fontSize: 11, fontWeight: selected ? FontWeight.w700 : FontWeight.w400, color: onPrimary)),
      ),
    );
  }
}

class _Kpi extends StatelessWidget {
  const _Kpi(this.label, this.value, this.color);
  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: TextStyle(fontSize: 12, color: context.fam.text2)),
      MoneyText(value, color: color, style: const TextStyle(fontSize: 18)),
    ]);
  }
}

class _AccountCard extends StatelessWidget {
  const _AccountCard(this.info, this.balance);
  final AccountInfo info;
  final int balance;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 160,
      child: Card(
        margin: const EdgeInsets.only(right: 10, bottom: 4),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AccountScreen(accountId: info.id))),
          child: Row(children: [
            Container(width: 6, color: info.color),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                  Row(children: [
                    Expanded(child: Text(info.name, style: TextStyle(fontSize: 12, color: context.fam.text2), overflow: TextOverflow.ellipsis)),
                    if (!info.liquid) Icon(Icons.lock_outline, size: 12, color: context.fam.text2),
                  ]),
                  const SizedBox(height: 4),
                  MoneyText(balance, style: const TextStyle(fontSize: 16)),
                ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Строка срока планового платежа; нажатие открывает оплату.
class DueTile extends StatelessWidget {
  const DueTile({super.key, required this.due, required this.locale});
  final DueItem due;
  final String locale;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final fam = context.fam;
    final state = AppScope.of(context).state;
    final overdue = due.date.isBefore(state.today);
    final p = due.planned;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CategoryAvatar(p.debtId != null ? Icons.account_balance_outlined : categoryById(p.category).icon),
      title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${DateFormat.MMMMd(locale).format(due.date)}${overdue ? ' · ${l.overdue}' : ''}',
        style: TextStyle(fontSize: 12, color: overdue ? fam.expense : fam.text2),
      ),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        MoneyText(p.amount, color: p.debtId != null ? fam.debt : null),
        const SizedBox(width: 4),
        const Icon(Icons.chevron_right, size: 18),
      ]),
      onTap: () => showPayDueSheet(context, due),
    );
  }
}
