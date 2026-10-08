import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../state/app_scope.dart';
import '../../theme/app_theme.dart';
import '../ops/transaction_tile.dart';
import '../widgets/common.dart';
import 'analytics_common.dart';
import 'category_chart.dart';
import 'category_screen.dart';
import 'day_flow_chart.dart';

/// «Месяц» (D136): вместо трёх вкладок («Обзор», «Расходы», «История») — один
/// экран, который отвечает на вопросы человека по порядку: сколько осталось и
/// как это по сравнению с прошлым месяцем; откуда пришло и куда ушло; как шёл
/// месяц по дням; что было, кроме доходов и расходов; как выглядели прошлые
/// месяцы.
class MonthTab extends StatefulWidget {
  const MonthTab({
    super.key,
    required this.offset,
    required this.onOffset,
    required this.selectedDay,
    required this.onSelectDay,
    this.months = 6,
  });

  final int offset;
  final ValueChanged<int> onOffset;
  final int? selectedDay;
  final ValueChanged<int?> onSelectDay;

  /// Сколько месяцев в сравнении внизу.
  final int months;

  @override
  State<MonthTab> createState() => _MonthTabState();
}

class _MonthTabState extends State<MonthTab> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Выбор месяца из сравнения внизу: открыть его и вернуться наверх.
  void _openMonth(int offset) {
    widget.onOffset(offset);
    if (_scroll.hasClients) _scroll.animateTo(0, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final fam = context.fam;
    final state = AppScope.of(context).state;
    final locale = Localizations.localeOf(context).toString();
    final offset = widget.offset;

    final month = state.monthOf(offset);
    final report = state.reportFor(month);
    final prev = state.reportFor(state.monthOf(offset - 1));
    final income = state.dailyIncome(month);
    final expense = state.dailyExpense(month);
    final elapsed = offset == 0 ? state.today.day : expense.length;
    final avgDay = elapsed == 0 ? 0 : expense.take(elapsed).fold<int>(0, (s, v) => s + v) ~/ elapsed ~/ minorPerUnit * minorPerUnit;
    final adjustments = state.adjustmentsFor(month);
    // До начала учёта прошлый месяц — не нулевая база (UI06).
    final comparable = state.hasComparablePrev(month);
    final compare = comparable ? monthCompareText(l, report: report, prev: prev) : '';

    final cats = state.categoriesFor(month);
    final byWho = state.expenseByWho(month);
    final split = state.expenseTypeSplit(month);
    final typeAmounts = [split.mandatory, split.regular, split.discretionary];
    final positiveTypes = typeAmounts.where((v) => v > 0).fold(0, (sum, v) => sum + v);
    final hasNegativeType = typeAmounts.any((v) => v < 0);
    final unexpected = state.unexpectedFor(month);

    String dayLabel(int i) => l.dayFlow(
          DateFormat.MMMMd(locale).format(DateTime(month.year, month.month, i + 1)),
          formatMoney(income[i]),
          formatMoney(expense[i]),
        );

    // Движения денег, которые не доходы и не расходы: одной сворачиваемой строкой.
    final moves = <(String, int)>[
      if (report.borrowed > 0) (l.movesBorrowed, report.borrowed),
      if (report.lent > 0) (l.movesLent, report.lent),
      if (report.returnedToMe > 0) (l.movesReturnedToMe, report.returnedToMe),
      if (report.debtPayments > 0) (l.movesDebtPayments, report.debtPayments),
      if (report.writtenOff > 0) (l.movesWrittenOff, report.writtenOff),
      if (report.forgiven > 0) (l.movesForgiven, report.forgiven),
      if (adjustments != 0) (l.adjustments, adjustments),
    ];

    return ListView(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        MonthNav(month: month, offset: offset, onOffset: widget.onOffset),

        // Главная цифра месяца и контекст к ней.
        AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(l.incomeMinusExpense, style: TextStyle(fontSize: 13, color: fam.text2))),
              InfoTip(l.reportHelpBody, title: l.reportHelpTitle),
            ]),
            MoneyText(report.result, sign: true, color: report.result < 0 ? fam.expense : fam.income, style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w700)),
            if (compare.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text(compare, style: TextStyle(fontSize: 12, color: fam.text2))),
            if (!comparable) Padding(padding: const EdgeInsets.only(top: 4), child: Text(l.noPrevMonthData, style: TextStyle(fontSize: 12, color: fam.text2))),
            if (offset == 0 && compare.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 2), child: Text(l.monthInProgress, style: TextStyle(fontSize: 11, color: fam.text2))),
            const Divider(height: 24),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: _kv(context, l.reportIncome, report.income, fam.income, delta: comparable ? _delta(l, report.income, prev.income) : null)),
              const SizedBox(width: 12),
              Expanded(child: _kv(context, l.reportExpense, -report.total, fam.expense, delta: comparable ? _delta(l, report.total, prev.total) : null)),
            ]),
            const SizedBox(height: 10),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (report.income > 0) Expanded(child: _stat(context, l.savingsRate, '${(report.result * 100 / report.income).round()}%')),
              Expanded(child: _stat(context, l.avgPerDay, formatMoney(avgDay))),
            ]),
          ]),
        ),

        // Куда ушли деньги.
        SectionHeader(l.monthWhere),
        if (cats.isEmpty)
          EmptyHint(l.noExpensesMonth)
        else
          CategoryChart(
            categories: cats,
            previousCategories: comparable ? state.categoriesFor(state.monthOf(offset - 1)) : const [],
            onOpenCategory: (id) => Navigator.push(context, MaterialPageRoute(builder: (_) => CategoryScreen(category: id, month: month))),
          ),

        if (split.total > 0) ...[
          SectionHeader(l.byThreeTypes),
          AppCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (hasNegativeType) Text(l.chartNetTotal, style: TextStyle(fontSize: 12, color: fam.text2)),
              MoneyText(split.total, style: const TextStyle(fontSize: 20)),
              const SizedBox(height: 10),
              _typeRow(context, l.typeMandatory, split.mandatory, positiveTypes, fam.expense),
              _typeRow(context, l.typeRegular, split.regular, positiveTypes, fam.warn),
              _typeRow(context, l.typeDiscretionary, split.discretionary, positiveTypes, context.scheme.primary),
              if (hasNegativeType) Padding(padding: const EdgeInsets.only(top: 8), child: Text(l.chartPositiveSharesNote, style: TextStyle(fontSize: 12, color: fam.text2))),
            ]),
          ),
        ],

        // Непредвиденные траты месяца (D101): ориентир для резерва.
        if (unexpected > 0) ...[
          SectionHeader(l.unexpectedTitle),
          AppCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              MoneyText(unexpected, style: const TextStyle(fontSize: 20)),
              const SizedBox(height: 4),
              Text(l.unexpectedNote, style: TextStyle(fontSize: 12, color: fam.text2)),
            ]),
          ),
        ],

        if (state.familyMode && byWho.isNotEmpty) ...[
          SectionHeader(l.family),
          AppCard(
            child: Column(children: [
              for (final e in byWho.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(children: [
                    Expanded(
                      child: Text(
                        e.key == 'me' ? l.me : e.key == 'shared' ? l.shared : state.members.where((m) => m.id == e.key).firstOrNull?.name ?? '—',
                        style: TextStyle(color: fam.text2),
                      ),
                    ),
                    MoneyText(e.value),
                  ]),
                ),
            ]),
          ),
        ],

        // Как шёл месяц по дням.
        SectionHeader(l.moneyFlow),
        AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            DayFlowChart(
              month: month,
              income: income,
              expense: expense,
              selectedDay: widget.selectedDay,
              onSelect: widget.onSelectDay,
              dayLabel: dayLabel,
              todayIndex: offset == 0 ? state.today.day - 1 : null,
            ),
            const SizedBox(height: 8),
            Wrap(spacing: 12, runSpacing: 4, children: [
              _legendDot(fam.income, l.reportIncome),
              _legendDot(fam.expense, l.reportExpense),
            ]),
            const SizedBox(height: 6),
            Text(widget.selectedDay == null ? l.tapDayHint : dayLabel(widget.selectedDay!), style: TextStyle(fontSize: 12, color: fam.text2)),
            Align(
              alignment: Alignment.centerRight,
              // Столбик пальцем не всегда попадёшь — точный выбор календарём (F09).
              child: ActionChip(
                avatar: const Icon(Icons.calendar_month_outlined, size: 16),
                label: Text(l.pickDay),
                onPressed: () async {
                  final last = DateTime(month.year, month.month, expense.length);
                  final lastAllowed = last.isAfter(state.today) ? state.today : last;
                  final wanted = widget.selectedDay == null ? lastAllowed : DateTime(month.year, month.month, widget.selectedDay! + 1);
                  // Выбранный день теоретически может быть будущим (повторный аудит, F06):
                  // initialDate не должен выходить за lastDate.
                  final initial = wanted.isAfter(lastAllowed) ? lastAllowed : wanted;
                  final picked = await showDatePicker(context: context, initialDate: initial, firstDate: month, lastDate: lastAllowed);
                  if (picked != null) widget.onSelectDay(picked.day - 1);
                },
              ),
            ),
          ]),
        ),
        if (widget.selectedDay != null)
          for (final t in state.transactionsOnDay(DateTime(month.year, month.month, widget.selectedDay! + 1)))
            Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: TransactionTile(t)),

        // Движения, не доходы и не расходы: займы, возвраты, списания, уточнения.
        // Свёрнуто — это нужно не каждому и не каждый месяц.
        if (moves.isNotEmpty || report.cashFlow != 0) ...[
          const SizedBox(height: 8),
          AppCard(
            padding: EdgeInsets.zero,
            child: Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: const EdgeInsets.symmetric(horizontal: 16),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                title: Text(l.monthMoves, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(l.monthMovesNote, style: TextStyle(fontSize: 12, color: fam.text2)),
                children: [
                  for (final (label, value) in moves) _movesRow(context, label, value, sign: label == l.adjustments),
                  _movesRow(context, l.cashFlow, report.cashFlow, sign: true),
                ],
              ),
            ),
          ),
        ],

        // Прошлые месяцы: сравнение и переход к любому.
        SectionHeader(l.monthsCompare),
        AppCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Column(children: [
            for (var k = 0; k < widget.months; k++)
              Builder(builder: (context) {
                final m = state.monthOf(-k);
                final r = state.reportFor(m);
                final selected = -k == offset;
                return InkWell(
                  onTap: () => _openMonth(-k),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(child: Text(toBeginningOfSentenceCase(DateFormat.yMMMM(locale).format(m)), style: TextStyle(fontWeight: FontWeight.w600, color: selected ? context.scheme.primary : null))),
                        if (r.income > 0) Text('${(r.result * 100 / r.income).round()}%', style: TextStyle(color: fam.text2, fontSize: 12)),
                        const Icon(Icons.chevron_right, size: 18),
                      ]),
                      const SizedBox(height: 4),
                      Row(children: [
                        Expanded(child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: MoneyText(r.income, sign: true, color: fam.income, style: const TextStyle(fontSize: 13)))),
                        Expanded(child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: MoneyText(-r.total, sign: true, color: fam.expense, style: const TextStyle(fontSize: 13)))),
                      ]),
                      if (k < widget.months - 1) const Divider(height: 16),
                    ]),
                  ),
                );
              }),
          ]),
        ),
      ],
    );
  }

  /// «↑ 12% к прошлому месяцу»; пусто, если прошлый месяц пуст или изменения нет.
  String? _delta(dynamic l, int now, int before) {
    if (before <= 0) return null;
    final pct = ((now - before) / before * 100).round();
    if (pct == 0) return null;
    return l.deltaVsPrev(pct > 0 ? '↑' : '↓', pct.abs()) as String;
  }

  Widget _kv(BuildContext context, String label, int value, Color color, {String? delta}) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: TextStyle(fontSize: 12, color: context.fam.text2)),
        MoneyText(value, color: color, sign: true, style: const TextStyle(fontSize: 18)),
        if (delta != null) Text(delta, style: TextStyle(fontSize: 11, color: context.fam.text2)),
      ]);

  Widget _stat(BuildContext context, String label, String value) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: TextStyle(fontSize: 12, color: context.fam.text2)),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
      ]);

  Widget _movesRow(BuildContext context, String label, int value, {bool sign = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Expanded(child: Text(label, style: TextStyle(fontSize: 13, color: context.fam.text2))),
          _fit(MoneyText(value, sign: sign, style: const TextStyle(fontSize: 13))),
        ]),
      );

  Widget _typeRow(BuildContext context, String label, int value, int total, Color color) {
    final fam = context.fam;
    final pct = categorySharePercent(value, total);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Container(width: 10, height: 10, margin: const EdgeInsets.only(right: 8), decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        Expanded(child: Text(label)),
        _fit(MoneyText(value, style: const TextStyle(fontSize: 13))),
        SizedBox(width: 44, child: Text(pct, textAlign: TextAlign.right, style: TextStyle(fontSize: 12, color: fam.text2))),
      ]),
    );
  }

  Widget _legendDot(Color c, String label) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 11)),
      ]);

  /// Сумма в строке с подписью: на узком экране и крупном шрифте сжимается, а не вылезает.
  Widget _fit(Widget amount) => Flexible(child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerRight, child: amount));
}
