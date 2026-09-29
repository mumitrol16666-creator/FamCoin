import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../state/app_scope.dart';
import '../../state/models.dart';
import '../../theme/app_theme.dart';
import '../ops/transaction_tile.dart';
import '../widgets/common.dart';
import 'analytics_common.dart';
import 'day_flow_chart.dart';

/// Обзор (D66): главная сводка месяца с контекстом (сравнение с прошлым),
/// движение денег по дням, короткая сводка бюджета, прогноз, капитал одной
/// строкой и несколько наблюдений — подробности в соседних вкладках.
class OverviewTab extends StatelessWidget {
  const OverviewTab({
    super.key,
    required this.offset,
    required this.onOffset,
    required this.selectedDay,
    required this.onSelectDay,
    required this.onOpenTab,
  });

  final int offset;
  final ValueChanged<int> onOffset;
  final int? selectedDay;
  final ValueChanged<int?> onSelectDay;
  final ValueChanged<int> onOpenTab;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final fam = context.fam;
    final state = AppScope.of(context).state;
    final locale = Localizations.localeOf(context).toString();

    final month = state.monthOf(offset);
    final report = state.reportFor(month);
    final prev = state.reportFor(state.monthOf(offset - 1));
    final income = state.dailyIncome(month);
    final expense = state.dailyExpense(month);
    final elapsed = offset == 0 ? state.today.day : expense.length;
    final avgDay = elapsed == 0 ? 0 : expense.take(elapsed).fold<int>(0, (s, v) => s + v) ~/ elapsed ~/ minorPerUnit * minorPerUnit;
    final cats = state.categoriesFor(month);
    final totalCats = cats.fold<int>(0, (s, e) => s + (e.value > 0 ? e.value : 0));

    String dayLabel(int i) => l.dayFlow(
          DateFormat.MMMMd(locale).format(DateTime(month.year, month.month, i + 1)),
          formatMoney(income[i]),
          formatMoney(expense[i]),
        );

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        MonthNav(month: month, offset: offset, onOffset: onOffset),
        AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: _kv(context, l.reportIncome, report.income, fam.income)),
              Expanded(child: _kv(context, l.reportExpense, -report.expense, fam.expense)),
            ]),
            const Divider(height: 20),
            _row(context, l.incomeMinusExpense, report.result, sign: true, bold: true),
            _row(context, l.cashFlow, report.cashFlow, sign: true),
            if (report.income > 0) _text(context, l.savingsRate, '${(report.result * 100 / report.income).round()}%'),
            _text(context, l.avgPerDay, formatMoney(avgDay)),
            if (offset == 0 && (prev.expense > 0 || prev.income > 0)) ...[
              const SizedBox(height: 8),
              Text(monthCompareText(l, report: report, prev: prev), style: TextStyle(fontSize: 12, color: fam.text2)),
            ],
          ]),
        ),

        SectionHeader(l.moneyFlow),
        AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            DayFlowChart(
              income: income,
              expense: expense,
              selectedDay: selectedDay,
              onSelect: onSelectDay,
              dayLabel: dayLabel,
              todayIndex: offset == 0 ? state.today.day - 1 : null,
            ),
            const SizedBox(height: 8),
            Wrap(spacing: 12, runSpacing: 4, children: [
              _legendDot(fam.income, l.reportIncome),
              _legendDot(fam.expense, l.reportExpense),
              _legendLine(context.scheme.primary, l.runningBalance),
            ]),
            const SizedBox(height: 6),
            Row(children: [
              Expanded(
                child: Text(
                  selectedDay == null ? l.tapDayHint : dayLabel(selectedDay!),
                  style: TextStyle(fontSize: 12, color: fam.text2),
                ),
              ),
              // Столбик пальцем не всегда попадёшь — точный выбор календарём (F09).
              ActionChip(
                avatar: const Icon(Icons.calendar_month_outlined, size: 16),
                label: Text(l.pickDay),
                onPressed: () async {
                  final last = DateTime(month.year, month.month, expense.length);
                  final lastAllowed = last.isAfter(state.today) ? state.today : last;
                  final wanted = selectedDay == null ? lastAllowed : DateTime(month.year, month.month, selectedDay! + 1);
                  // На всякий случай не даём initialDate оказаться позже lastDate
                  // (повторный аудит, F06) — выбранный день теоретически может
                  // быть будущим (см. защиту в DayFlowChart), а контракт
                  // showDatePicker требует initialDate в пределах диапазона.
                  final initial = wanted.isAfter(lastAllowed) ? lastAllowed : wanted;
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: initial,
                    firstDate: month,
                    lastDate: lastAllowed,
                  );
                  if (picked != null) onSelectDay(picked.day - 1);
                },
              ),
            ]),
          ]),
        ),
        if (selectedDay != null)
          for (final t in state.transactionsOnDay(DateTime(month.year, month.month, selectedDay! + 1)))
            Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: TransactionTile(t)),

        // Лимиты и % месяца — только по текущему месяцу (F07): прошлый лимит
        // нигде не хранится, поэтому для прошлого месяца тут нечего показать
        // честно — лучше не показывать вовсе, чем текущие цифры под чужой шапкой.
        if (offset == 0) ...[
          SectionHeader(l.budgetShort, action: l.details, onAction: () => onOpenTab(2)),
          AppCard(child: _budgetSummary(context, state, l, fam)),
        ],

        SectionHeader(l.whereMoneyGoes, action: l.details, onAction: () => onOpenTab(1)),
        if (cats.isEmpty)
          EmptyHint(l.noExpensesMonth)
        else
          AppCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(children: [
              for (final e in cats.take(3))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(children: [
                    Icon(categoryById(e.key).icon, size: 18),
                    const SizedBox(width: 8),
                    Expanded(child: Text(categoryName(l, e.key))),
                    MoneyText(e.value, style: const TextStyle(fontSize: 13)),
                    SizedBox(width: 44, child: Text(categorySharePercent(e.value, totalCats), textAlign: TextAlign.right, style: TextStyle(fontSize: 12, color: fam.text2))),
                  ]),
                ),
            ]),
          ),

        if (offset == 0) ...[
          SectionHeader(l.forecastTitle),
          AppCard(child: _forecastBody(context, state, l, fam)),
        ],

        SectionHeader(l.capital, action: l.details, onAction: () => onOpenTab(3)),
        Builder(builder: (context) {
          final nw = state.ledger.netWorth();
          final history = state.netWorthHistory(6);
          final changed = history.length < 2 ? null : nw.capital - history.first.capital;
          return AppCard(
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(l.netCapital, style: TextStyle(fontSize: 12, color: fam.text2)),
                  MoneyText(nw.capital, style: const TextStyle(fontSize: 20)),
                ]),
              ),
              if (changed != null && changed != 0)
                Text(
                  '${changed > 0 ? '↑' : '↓'} ${formatMoney(changed.abs())}',
                  style: TextStyle(color: changed > 0 ? fam.income : fam.expense, fontWeight: FontWeight.w600, fontSize: 13),
                ),
            ]),
          );
        }),

        Builder(builder: (context) {
          final notes = observations(context, state, month);
          if (notes.isEmpty) return const SizedBox.shrink();
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SectionHeader(l.observations),
            AppCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (final n in notes)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('•  ', style: TextStyle(color: fam.text2)),
                      Expanded(child: Text(n, style: TextStyle(fontSize: 13, color: fam.text2))),
                    ]),
                  ),
              ]),
            ),
          ]);
        }),
      ],
    );
  }

  Widget _kv(BuildContext context, String label, int value, Color color) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: TextStyle(fontSize: 12, color: context.fam.text2)),
        MoneyText(value, color: color, sign: true, style: const TextStyle(fontSize: 18)),
      ]);

  Widget _row(BuildContext context, String label, int value, {bool sign = false, bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Expanded(child: Text(label, style: TextStyle(color: bold ? null : context.fam.text2, fontWeight: bold ? FontWeight.w600 : null))),
          MoneyText(value, sign: sign, style: bold ? const TextStyle(fontSize: 16) : null),
        ]),
      );

  Widget _text(BuildContext context, String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [Expanded(child: Text(label, style: TextStyle(color: context.fam.text2))), Text(value, style: const TextStyle(fontWeight: FontWeight.w600))]),
      );

  Widget _legendDot(Color c, String label) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 11)),
      ]);

  Widget _legendLine(Color c, String label) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 12, height: 2, color: c),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 11)),
      ]);

  Widget _budgetSummary(BuildContext context, dynamic state, dynamic l, FamColors fam) {
    final used = state.budgetUsedPercent as double?;
    final elapsed = state.monthElapsedPercent as double;
    if (used == null) return Text(l.noLimitsShort, style: TextStyle(fontSize: 13, color: fam.text2));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      UsageBar(value: used.round(), max: 100, color: used > elapsed ? fam.warn : context.scheme.primary),
      const SizedBox(height: 6),
      Text(l.budgetUsedVsElapsed(used.round(), elapsed.round()), style: TextStyle(fontSize: 12, color: fam.text2)),
    ]);
  }

  Widget _forecastBody(BuildContext context, dynamic state, dynamic l, FamColors fam) {
    final f = state.monthEndForecast as MonthForecast;
    final negative = f.estimate < 0;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text(l.forecastEstimate, style: TextStyle(color: fam.text2))),
        MoneyText(f.estimate, color: negative ? fam.expense : null, style: const TextStyle(fontSize: 18)),
      ]),
      const SizedBox(height: 4),
      Text(l.forecastRange(formatMoney(f.rangeLow), formatMoney(f.rangeHigh)), style: TextStyle(fontSize: 12, color: fam.text2)),
      const SizedBox(height: 8),
      Text('${l.forecastObligations}: −${formatMoney(f.remainingObligations)}', style: TextStyle(fontSize: 12, color: fam.text2)),
      Text('${l.forecastSpend}: ≈−${formatMoney(f.expectedRegularSpend)}', style: TextStyle(fontSize: 12, color: fam.text2)),
      if (f.expectedIncome > 0) Text('${l.forecastIncome}: +${formatMoney(f.expectedIncome)}', style: TextStyle(fontSize: 12, color: fam.text2)),
    ]);
  }
}
