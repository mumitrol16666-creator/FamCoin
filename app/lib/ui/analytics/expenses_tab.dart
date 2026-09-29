import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';

import '../../state/app_scope.dart';
import '../../state/models.dart';
import '../../theme/app_theme.dart';
import '../widgets/common.dart';
import 'analytics_common.dart';
import 'category_screen.dart';

/// Расходы (D66): категории с сравнением к прошлому месяцу, три типа трат
/// вместо десятков категорий, разбивка по членам семьи.
class ExpensesTab extends StatelessWidget {
  const ExpensesTab({super.key, required this.offset, required this.onOffset});
  final int offset;
  final ValueChanged<int> onOffset;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final fam = context.fam;
    final state = AppScope.of(context).state;

    final month = state.monthOf(offset);
    final prevMonth = state.monthOf(offset - 1);
    final cats = state.categoriesFor(month);
    final prevCats = {for (final e in state.categoriesFor(prevMonth)) e.key: e.value};
    final totalCats = cats.fold<int>(0, (s, e) => s + (e.value > 0 ? e.value : 0));
    final byWho = state.expenseByWho(month);
    final split = state.expenseTypeSplit(month);

    String delta(int now, int before) {
      if (before == 0) return '';
      final pct = ((now - before) / before.abs() * 100).round();
      return pct == 0 ? ' · 0%' : ' · ${pct > 0 ? '▲' : '▼'} ${pct.abs()}%';
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        MonthNav(month: month, offset: offset, onOffset: onOffset),

        if (split.total > 0) ...[
          SectionHeader(l.byThreeTypes),
          AppCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              MoneyText(split.total, style: const TextStyle(fontSize: 20)),
              const SizedBox(height: 10),
              _typeRow(context, l.typeMandatory, split.mandatory, split.total, fam.expense),
              _typeRow(context, l.typeRegular, split.regular, split.total, fam.warn),
              _typeRow(context, l.typeDiscretionary, split.discretionary, split.total, context.scheme.primary),
            ]),
          ),
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
                      if (prevCats[e.key] != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text('${l.vsLastMonth}: ${formatMoney(prevCats[e.key]!)}${delta(e.value, prevCats[e.key]!)}', style: TextStyle(fontSize: 11, color: fam.text2)),
                        ),
                    ]),
                  ),
                ),
            ]),
          ),

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
      ],
    );
  }

  Widget _typeRow(BuildContext context, String label, int value, int total, Color color) {
    final fam = context.fam;
    final pct = total == 0 ? 0 : (value * 100 / total).round();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Container(width: 10, height: 10, margin: const EdgeInsets.only(right: 8), decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        Expanded(child: Text(label)),
        MoneyText(value, style: const TextStyle(fontSize: 13)),
        SizedBox(width: 44, child: Text('$pct%', textAlign: TextAlign.right, style: TextStyle(fontSize: 12, color: fam.text2))),
      ]),
    );
  }
}
