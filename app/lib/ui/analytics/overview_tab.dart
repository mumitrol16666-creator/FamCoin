import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../state/app_scope.dart';
import '../../theme/app_theme.dart';
import '../ops/transaction_tile.dart';
import '../widgets/common.dart';
import 'analytics_common.dart';
import 'day_flow_chart.dart';

/// Итоги выбранного месяца и движение денег по дням.
class OverviewTab extends StatelessWidget {
  const OverviewTab({
    super.key,
    required this.offset,
    required this.onOffset,
    required this.selectedDay,
    required this.onSelectDay,
  });

  final int offset;
  final ValueChanged<int> onOffset;
  final int? selectedDay;
  final ValueChanged<int?> onSelectDay;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final fam = context.fam;
    final state = AppScope.of(context).state;
    final locale = Localizations.localeOf(context).toString();

    final month = state.monthOf(offset);
    final report = state.reportFor(month);
    final income = state.dailyIncome(month);
    final expense = state.dailyExpense(month);
    final elapsed = offset == 0 ? state.today.day : expense.length;
    final avgDay = elapsed == 0 ? 0 : expense.take(elapsed).fold<int>(0, (s, v) => s + v) ~/ elapsed ~/ minorPerUnit * minorPerUnit;
    final adjustments = state.adjustmentsFor(month);

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
              Expanded(child: _kv(context, l.reportExpense, -report.total, fam.expense)),
            ]),
            if (report.debtPayments > 0) Text(l.reportIncludesDebts(moneyInText(report.debtPayments)), style: TextStyle(fontSize: 12, color: fam.text2)),
            if (report.borrowed > 0) Text(l.reportBorrowed(moneyInText(report.borrowed)), style: TextStyle(fontSize: 12, color: fam.text2)),
            const Divider(height: 20),
            _row(context, l.incomeMinusExpense, report.result, sign: true, bold: true),
            _row(context, l.cashFlow, report.cashFlow, sign: true),
            if (adjustments != 0) _row(context, l.adjustments, adjustments, sign: true),
            if (report.income > 0) _text(context, l.savingsRate, '${(report.result * 100 / report.income).round()}%'),
            _text(context, l.avgPerDay, formatMoney(avgDay)),
          ]),
        ),

        SectionHeader(l.moneyFlow),
        AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            DayFlowChart(
              month: month,
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
            ]),
            const SizedBox(height: 6),
            Text(
              selectedDay == null ? l.tapDayHint : dayLabel(selectedDay!),
              style: TextStyle(fontSize: 12, color: fam.text2),
            ),
            Align(alignment: Alignment.centerRight, child:
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
            ),
          ]),
        ),
        if (selectedDay != null)
          for (final t in state.transactionsOnDay(DateTime(month.year, month.month, selectedDay! + 1)))
            Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: TransactionTile(t)),

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

}
