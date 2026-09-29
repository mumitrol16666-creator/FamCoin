import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../l10n/app_localizations.dart';
import '../../state/app_state.dart';
import '../widgets/common.dart';

/// Переключатель месяца — общий для вкладок «Обзор» и «Расходы»: они должны
/// показывать один и тот же месяц, а не разъезжаться при переключении вкладок.
class MonthNav extends StatelessWidget {
  const MonthNav({super.key, required this.month, required this.offset, required this.onOffset});
  final DateTime month;
  final int offset;
  final ValueChanged<int> onOffset;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final locale = Localizations.localeOf(context).toString();
    return Row(children: [
      IconButton(tooltip: l.prevMonth, onPressed: () => onOffset(offset - 1), icon: const Icon(Icons.chevron_left)),
      Expanded(
        child: Text(toBeginningOfSentenceCase(DateFormat.yMMMM(locale).format(month)), textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
      ),
      IconButton(tooltip: l.nextMonth, onPressed: offset >= 0 ? null : () => onOffset(offset + 1), icon: const Icon(Icons.chevron_right)),
    ]);
  }
}

/// Не просто цифра — контекст цифры (владелец, 29.09.2026): расход/доход/
/// свободные деньги в сравнении с прошлым месяцем, одной строкой.
String monthCompareText(AppLocalizations l, {required PeriodReport report, required PeriodReport prev}) {
  final parts = <String>[];
  if (prev.expense > 0) {
    final pct = ((report.expense - prev.expense) / prev.expense.abs() * 100).round();
    if (pct != 0) parts.add(l.expenseVsPrev(pct > 0 ? '↑' : '↓', pct.abs()));
  }
  if (prev.income > 0) {
    final pct = ((report.income - prev.income) / prev.income.abs() * 100).round();
    if (pct != 0) parts.add(l.incomeVsPrev(pct > 0 ? '↑' : '↓', pct.abs()));
  }
  final freeDelta = report.result - prev.result;
  if (freeDelta != 0) parts.add(l.freeCashVsPrev(freeDelta > 0 ? '+' : '−', formatMoney(freeDelta.abs())));
  return parts.join(' · ');
}

/// Доля категории от общей положительной базы расходов (F14). Категория с
/// нулевым или отрицательным чистым расходом (обычно из-за возврата) не
/// получает процент — знак и сумма уже видны рядом в `MoneyText`, а деление
/// на базу из только положительных категорий дало бы бессмысленное
/// отрицательное или сильно завышенное число.
String categorySharePercent(int value, int totalPositive) {
  if (totalPositive <= 0 || value <= 0) return '';
  return '${(value * 100 / totalPositive).round()}%';
}

/// Наблюдения (раздел 9.12): закономерность, а не оценка — без «слишком
/// много». Показываются, только если сигнал достаточно заметный, иначе
/// список остаётся пустым, а не заполняется шумом ради заполнения.
List<String> observations(BuildContext context, AppState state, DateTime month) {
  final l = context.l10n;
  final notes = <String>[];

  final evening = state.eveningDiscretionaryShare(month);
  if (evening != null && evening >= 20) notes.add(l.obsEveningShare(evening.round()));

  final big = state.unplannedLargeExpenses(month);
  if (big.isNotEmpty) notes.add(l.obsUnplanned(big.length));

  final ratio = state.paydaySpendRatio();
  if (ratio != null && ratio >= 1.3) notes.add(l.obsPayday(ratio.toStringAsFixed(1)));

  final share = state.recurringShareOfIncome;
  if (share != null && share >= 30) notes.add(l.obsRecurringShare(share.round()));

  final prevMonth = DateTime(month.year, month.month - 1, 1);
  final cats = state.categoriesFor(month);
  final prevCats = {for (final e in state.categoriesFor(prevMonth)) e.key: e.value};
  MapEntry<String, int>? biggest;
  var biggestPct = 0;
  for (final e in cats) {
    final before = prevCats[e.key];
    if (before == null || before <= 0) continue;
    final pct = ((e.value - before) / before * 100).round();
    if (pct.abs() > biggestPct.abs()) {
      biggestPct = pct;
      biggest = e;
    }
  }
  if (biggest != null && biggestPct.abs() >= 20) {
    notes.add(l.obsCategoryChange(categoryName(l, biggest.key), biggestPct > 0 ? '↑' : '↓', biggestPct.abs()));
  }

  return notes;
}
