import 'package:flutter/material.dart';

import '../../state/app_scope.dart';
import '../../theme/app_theme.dart';
import '../widgets/common.dart';
import 'analytics_common.dart';
import 'category_screen.dart';
import 'category_chart.dart';

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
    final cats = state.categoriesFor(month);
    final byWho = state.expenseByWho(month);
    final split = state.expenseTypeSplit(month);
    final typeAmounts = [split.mandatory, split.regular, split.discretionary];
    final positiveTypes = typeAmounts.where((v) => v > 0).fold(0, (sum, v) => sum + v);
    final hasNegativeType = typeAmounts.any((v) => v < 0);
    final unexpected = state.unexpectedFor(month);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        MonthNav(month: month, offset: offset, onOffset: onOffset),

        SectionHeader(l.byCategories),
        if (cats.isEmpty)
          EmptyHint(l.noExpensesMonth)
        else
          CategoryChart(
            categories: cats,
            previousCategories: state.categoriesFor(state.monthOf(offset - 1)),
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

        // Непредвиденные траты месяца (D101): сколько ушло на внезапное —
        // ориентир для резерва.
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
      ],
    );
  }

  Widget _typeRow(BuildContext context, String label, int value, int total, Color color) {
    final fam = context.fam;
    final pct = categorySharePercent(value, total);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Container(width: 10, height: 10, margin: const EdgeInsets.only(right: 8), decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        Expanded(child: Text(label)),
        MoneyText(value, style: const TextStyle(fontSize: 13)),
        SizedBox(width: 44, child: Text(pct, textAlign: TextAlign.right, style: TextStyle(fontSize: 12, color: fam.text2))),
      ]),
    );
  }
}
