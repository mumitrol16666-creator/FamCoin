import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../state/app_scope.dart';
import '../../state/models.dart';
import '../../theme/app_theme.dart';
import '../ops/transaction_tile.dart';
import '../widgets/common.dart';

/// S23 — аналитика месяца: доходы, расходы, выплаты, категории, дни,
/// семейный разрез. Сравнение с прошлым месяцем — Pro (F069).
class AnalyticsScreen extends StatefulWidget {
  const AnalyticsScreen({super.key});

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  int _offset = 0;
  int? _selectedDay;

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
        final report = state.reportFor(month);
        final prev = state.reportFor(state.monthOf(_offset - 1));
        final cats = state.categoriesFor(month);
        final prevCats = {for (final e in state.categoriesFor(state.monthOf(_offset - 1))) e.key: e.value};
        final days = state.dailyExpense(month);
        final totalCats = cats.fold<int>(0, (s, e) => s + (e.value > 0 ? e.value : 0));
        final maxDay = days.fold<int>(0, (m, v) => v > m ? v : m);
        final elapsed = _offset == 0 ? state.today.day : days.length;
        final avgDay = elapsed == 0 ? 0 : days.take(elapsed).fold<int>(0, (s, v) => s + v) ~/ elapsed ~/ minorPerUnit * minorPerUnit;
        final byWho = state.expenseByWho(month);

        String delta(int now, int before) {
          if (before == 0) return '';
          final pct = ((now - before) / before.abs() * 100).round();
          return pct == 0 ? ' · 0%' : ' · ${pct > 0 ? '▲' : '▼'} ${pct.abs()}%';
        }

        return Scaffold(
          appBar: AppBar(title: Text(l.analytics)),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            children: [
              Row(children: [
                IconButton(tooltip: l.prevMonth, onPressed: () => setState(() { _offset--; _selectedDay = null; }), icon: const Icon(Icons.chevron_left)),
                Expanded(
                  child: Text(toBeginningOfSentenceCase(DateFormat.yMMMM(locale).format(month)),
                      textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
                ),
                IconButton(tooltip: l.nextMonth, onPressed: _offset >= 0 ? null : () => setState(() { _offset++; _selectedDay = null; }), icon: const Icon(Icons.chevron_right)),
              ]),
              AppCard(
                child: Column(children: [
                  Row(children: [
                    Expanded(child: _kpi(context, l.reportIncome, report.income, fam.income, state.pro ? delta(report.income, prev.income) : '')),
                    Expanded(child: _kpi(context, l.reportExpense, report.expense, fam.expense, state.pro ? delta(report.expense, prev.expense) : '')),
                  ]),
                  const Divider(height: 20),
                  _row(context, l.reportResult, report.result, sign: true),
                  _row(context, l.cashFlow, report.cashFlow, sign: true),
                  if (state.adjustmentsFor(month) != 0) _row(context, l.adjustments, state.adjustmentsFor(month), sign: true),
                  if (report.income > 0)
                    _text(context, l.savingsRate, '${(report.result * 100 / report.income).round()}%'),
                  _text(context, l.avgPerDay, formatMoney(avgDay)),
                ]),
              ),

              SectionHeader(l.byDays),
              AppCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(
                    height: 120,
                    // Область нажатия — вся колонка дня во всю высоту графика,
                    // а не столбик высотой 2 px у пустого дня; для экранного
                    // диктора каждый день — кнопка с датой и суммой.
                    child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      for (var i = 0; i < days.length; i++)
                        Expanded(
                          child: Semantics(
                            button: true,
                            selected: _selectedDay == i,
                            label: l.dayTotal(DateFormat.MMMMd(locale).format(DateTime(month.year, month.month, i + 1)), formatMoney(days[i])),
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () => setState(() => _selectedDay = _selectedDay == i ? null : i),
                              child: Align(
                                alignment: Alignment.bottomCenter,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 1),
                                  child: Container(
                                    height: maxDay == 0 ? 2 : (days[i] <= 0 ? 2 : 4 + 112 * days[i] / maxDay),
                                    decoration: BoxDecoration(
                                      color: _selectedDay == i
                                          ? fam.accent
                                          : (_offset == 0 && i == state.today.day - 1)
                                              ? context.scheme.primary
                                              : context.scheme.primary.withValues(alpha: .45),
                                      borderRadius: BorderRadius.circular(3),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ]),
                  ),
                  const SizedBox(height: 6),
                  Row(children: [
                    Text('1', style: TextStyle(fontSize: 11, color: fam.text2)),
                    const Spacer(),
                    Text('${days.length}', style: TextStyle(fontSize: 11, color: fam.text2)),
                  ]),
                  const SizedBox(height: 6),
                  Row(children: [
                    Expanded(
                      child: Text(
                        _selectedDay == null
                            ? l.tapDayHint
                            : l.dayTotal(DateFormat.MMMMd(locale).format(DateTime(month.year, month.month, _selectedDay! + 1)), formatMoney(days[_selectedDay!])),
                        style: TextStyle(fontSize: 12, color: fam.text2),
                      ),
                    ),
                    // Пальцем узкий столбик выбрать трудно — есть календарь.
                    ActionChip(
                      avatar: const Icon(Icons.calendar_month_outlined, size: 16),
                      label: Text(l.pickDay),
                      onPressed: () async {
                        final last = DateTime(month.year, month.month, days.length);
                        final lastAllowed = last.isAfter(state.today) ? state.today : last;
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: _selectedDay == null ? lastAllowed : DateTime(month.year, month.month, _selectedDay! + 1),
                          firstDate: month,
                          lastDate: lastAllowed,
                        );
                        if (picked != null) setState(() => _selectedDay = picked.day - 1);
                      },
                    ),
                  ]),
                ]),
              ),
              if (_selectedDay != null) ...[
                for (final t in state.userTransactions.where((t) => t.date == DateTime(month.year, month.month, _selectedDay! + 1)))
                  Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: TransactionTile(t)),
              ],

              SectionHeader(l.byCategories),
              if (cats.isEmpty)
                EmptyHint(l.noExpensesMonth)
              else
                AppCard(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Column(children: [
                    for (final e in cats)
                      InkWell(
                        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => CategoryScreen(category: e.key, month: month))),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Row(children: [
                              Icon(categoryById(e.key).icon, size: 18),
                              const SizedBox(width: 8),
                              Expanded(child: Text(categoryName(l, e.key))),
                              MoneyText(e.value, style: const TextStyle(fontSize: 13)),
                              SizedBox(
                                width: 44,
                                child: Text(totalCats == 0 ? '' : '${(e.value * 100 / totalCats).round()}%', textAlign: TextAlign.right, style: TextStyle(fontSize: 12, color: fam.text2)),
                              ),
                            ]),
                            const SizedBox(height: 4),
                            UsageBar(value: e.value, max: totalCats, color: context.scheme.primary),
                            if (state.pro && prevCats[e.key] != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text('${l.vsLastMonth}: ${formatMoney(prevCats[e.key]!)}${delta(e.value, prevCats[e.key]!)}', style: TextStyle(fontSize: 11, color: fam.text2)),
                              ),
                          ]),
                        ),
                      ),
                  ]),
                ),
              if (!state.pro)
                AppCard(
                  onTap: () => showProGate(context, l.proGateReports),
                  child: Row(children: [
                    Expanded(child: Text(l.compareTeaser, style: TextStyle(fontSize: 13, color: fam.text2))),
                    const ProBadge(),
                  ]),
                ),

              if (state.familyMode && byWho.isNotEmpty) ...[
                SectionHeader(l.family),
                AppCard(
                  child: Column(children: [
                    for (final e in (byWho.entries.toList()..sort((a, b) => b.value.compareTo(a.value))))
                      _row(
                        context,
                        e.key == 'me' ? l.me : e.key == 'shared' ? l.shared : state.members.where((m) => m.id == e.key).firstOrNull?.name ?? '—',
                        e.value,
                      ),
                  ]),
                ),
              ],

              SectionHeader(l.capital),
              Builder(builder: (context) {
                final nw = state.ledger.netWorth();
                return AppCard(
                  child: Column(children: [
                    _row(context, l.money, nw.money),
                    if (nw.receivables > 0) _row(context, l.oweMe, nw.receivables, color: fam.income),
                    if (nw.liabilities > 0) _row(context, l.liabilities, -nw.liabilities, color: fam.debt),
                    const Divider(),
                    _row(context, l.capital, nw.capital),
                  ]),
                );
              }),
            ],
          ),
        );
      },
    );
  }

  Widget _kpi(BuildContext context, String label, int value, Color color, String delta) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('$label$delta', style: TextStyle(fontSize: 12, color: context.fam.text2)),
        MoneyText(value, color: color, style: const TextStyle(fontSize: 18)),
      ]);

  Widget _row(BuildContext context, String label, int value, {Color? color, bool sign = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [Expanded(child: Text(label, style: TextStyle(color: context.fam.text2))), MoneyText(value, color: color, sign: sign)]),
      );

  Widget _text(BuildContext context, String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [Expanded(child: Text(label, style: TextStyle(color: context.fam.text2))), Text(value, style: const TextStyle(fontWeight: FontWeight.w600))]),
      );
}

/// S24 — категория в деталях: сумма месяца и составляющие её операции.
class CategoryScreen extends StatelessWidget {
  const CategoryScreen({super.key, required this.category, required this.month});
  final String category;
  final DateTime month;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final state = AppScope.of(context).state;
    final fam = context.fam;
    final locale = Localizations.localeOf(context).toString();
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final total = state.categoriesFor(month).where((e) => e.key == category).firstOrNull?.value ?? 0;
        final txs = state.categoryTransactions(category, month);
        final limit = state.limits.where((x) => x.category == category).firstOrNull;
        return Scaffold(
          appBar: AppBar(title: Text(categoryName(l, category))),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            children: [
              AppCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(toBeginningOfSentenceCase(DateFormat.yMMMM(locale).format(month)), style: TextStyle(fontSize: 12, color: fam.text2)),
                  BigMoney(total),
                  Text(l.operationsCount(txs.length), style: TextStyle(fontSize: 12, color: fam.text2)),
                  if (limit != null) ...[
                    const SizedBox(height: 8),
                    UsageBar(value: total, max: limit.amount),
                    const SizedBox(height: 4),
                    Text('${l.limit}: ${formatMoney(limit.amount)}', style: TextStyle(fontSize: 12, color: fam.text2)),
                  ],
                ]),
              ),
              if (txs.isEmpty)
                EmptyHint(l.noOperations)
              else
                AppCard(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Column(children: [for (final t in txs) TransactionTile(t)]),
                ),
            ],
          ),
        );
      },
    );
  }
}
