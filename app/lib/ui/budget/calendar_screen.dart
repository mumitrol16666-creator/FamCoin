import 'package:famcoin_core/famcoin_core.dart' show everyMonth;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../state/app_scope.dart';
import '../../state/models.dart';
import '../../theme/app_theme.dart';
import '../home/home_screen.dart';
import '../widgets/common.dart';
import 'sheets.dart';

/// S15 — календарь платежей: сроки месяца, отметки об оплате, день зарплаты.
class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  int _offset = 0;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final state = AppScope.of(context).state;
    final fam = context.fam;
    final locale = Localizations.localeOf(context).toString();

    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final month = state.monthOf(_offset);
        final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
        final period = '${month.year}-${month.month.toString().padLeft(2, '0')}';
        // Сроки этого месяца: оплаченные и нет. Недельный платёж даёт несколько
        // сроков, годовой — один в своём месяце; ключ срока у каждого свой.
        final items = <(PlannedInfo, DateTime, bool, String)>[];
        final monthEnd = DateTime(month.year, month.month, daysInMonth);
        for (final p in state.planned) {
          // Погашенный кредит больше не требует оплаты (R04); оплаченные сроки
          // прошлого остаются в истории.
          final active = state.isPlannedActive(p);
          for (final o in p.schedule.occurrences(month, monthEnd)) {
            final isPaid = p.paid.contains(o.period);
            if (isPaid || active) items.add((p, o.date, isPaid, o.period));
          }
          // Оплаченный срок до даты добавления платежа (отмечали задним числом)
          // остаётся виден: в расписание он не входит из-за `start`.
          if (p.start != null && p.start!.isAfter(month) && p.once == null && p.every == everyMonth && p.paid.contains(period)) {
            final d = DateTime(month.year, month.month, p.day.clamp(1, daysInMonth));
            if (d.isBefore(p.start!)) items.add((p, d, true, period));
          }
        }
        items.sort((a, b) => a.$2.compareTo(b.$2));
        final byDay = <int, List<(PlannedInfo, DateTime, bool, String)>>{};
        for (final i in items) {
          byDay.putIfAbsent(i.$2.day, () => []).add(i);
        }
        final total = items.fold<int>(0, (s, i) => s + i.$1.amount);
        final paid = items.where((i) => i.$3).fold<int>(0, (s, i) => s + i.$1.amount);
        final firstWeekday = month.weekday; // 1 = понедельник
        final weekdays = [for (var d = 0; d < 7; d++) DateFormat.E(locale).format(DateTime(2024, 1, 1 + d))];

        return Scaffold(
          appBar: AppBar(title: Text(l.calendar)),
          floatingActionButton: FloatingActionButton(onPressed: () => addPlannedFlow(context), child: const Icon(Icons.add)),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
            children: [
              Row(children: [
                IconButton(tooltip: l.prevMonth, onPressed: _offset <= -12 ? null : () => setState(() => _offset--), icon: const Icon(Icons.chevron_left)),
                Expanded(child: Text(toBeginningOfSentenceCase(DateFormat.yMMMM(locale).format(month)), textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge)),
                IconButton(tooltip: l.nextMonth, onPressed: _offset >= 12 ? null : () => setState(() => _offset++), icon: const Icon(Icons.chevron_right)),
              ]),
              AppCard(
                child: Column(children: [
                  Row(children: [for (final w in weekdays) Expanded(child: Text(w, textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: fam.text2)))]),
                  const SizedBox(height: 6),
                  GridView.count(
                    crossAxisCount: 7,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: 4,
                    crossAxisSpacing: 4,
                    children: [
                      for (var i = 1; i < firstWeekday; i++) const SizedBox(),
                      for (var d = 1; d <= daysInMonth; d++)
                        Builder(builder: (context) {
                          final list = byDay[d] ?? const [];
                          final isToday = DateTime(month.year, month.month, d) == state.today;
                          final allPaid = list.isNotEmpty && list.every((x) => x.$3);
                          return Container(
                            decoration: BoxDecoration(
                              color: list.isEmpty
                                  ? null
                                  : allPaid
                                      ? fam.incomeBg
                                      : fam.warnBg,
                              borderRadius: BorderRadius.circular(8),
                              border: isToday ? Border.all(color: context.scheme.primary, width: 2) : null,
                            ),
                            alignment: Alignment.center,
                            child: Text('$d', style: TextStyle(fontSize: 13, fontWeight: list.isNotEmpty ? FontWeight.w700 : null)),
                          );
                        }),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Wrap(spacing: 12, runSpacing: 4, children: [
                    _legend(context, fam.warnBg, l.toPay),
                    _legend(context, fam.incomeBg, l.paidOrIncome),
                  ]),
                ]),
              ),
              AppCard(
                child: Column(children: [
                  Row(children: [Expanded(child: Text(l.monthlyObligations, style: TextStyle(color: fam.text2))), MoneyText(total)]),
                  const SizedBox(height: 6),
                  Row(children: [Expanded(child: Text(l.paidAlready, style: TextStyle(color: fam.text2))), MoneyText(paid, color: fam.income)]),
                  const SizedBox(height: 6),
                  UsageBar(value: paid, max: total, color: fam.income),
                ]),
              ),
              if (items.isEmpty)
                EmptyHint(l.noPlanned, icon: Icons.event_repeat_outlined)
              else
                AppCard(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Column(children: [
                    for (final (p, d, isPaid, itemPeriod) in items)
                      isPaid
                          ? ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: CategoryAvatar.of(categoryById(p.debtId != null ? debtsCategory : p.category)),
                              title: Text(p.name),
                              subtitle: Text('${DateFormat.MMMMd(locale).format(d)} · ${l.paidThisMonth}', style: TextStyle(fontSize: 12, color: fam.income)),
                              trailing: MoneyText(p.amount, color: fam.text2),
                            )
                          : DueTile(due: DueItem(p, d, itemPeriod), locale: locale),
                  ]),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _legend(BuildContext context, Color color, String text) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 12, height: 12, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3))),
        const SizedBox(width: 6),
        Flexible(child: Text(text, style: TextStyle(fontSize: 12, color: context.fam.text2))),
      ]);
}
