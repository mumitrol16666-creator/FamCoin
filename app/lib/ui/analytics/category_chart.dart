import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../theme/app_theme.dart';
import '../widgets/common.dart';
import 'chart_colors.dart';

/// Отрицательный остаток категории после возвратов не является сектором.
/// Мелкие категории объединяются только на диаграмме, их операции доступны.
class CategoryChartData {
  CategoryChartData(List<MapEntry<String, int>> categories) {
    positive = categories.where((e) => e.value > 0).toList()..sort((a, b) => b.value.compareTo(a.value));
    negative = categories.where((e) => e.value < 0).toList();
  }
  late final List<MapEntry<String, int>> positive;
  late final List<MapEntry<String, int>> negative;
  int get positiveTotal => positive.fold(0, (sum, e) => sum + e.value);
  int get refundBalance => negative.fold(0, (sum, e) => sum + e.value);
  int get netTotal => positiveTotal + refundBalance;
  List<MapEntry<String, int>> get main => positive.length <= 6 ? positive : positive.take(5).toList();
  List<MapEntry<String, int>> get other => positive.length <= 6 ? const [] : positive.skip(5).toList();
  int get otherTotal => other.fold(0, (sum, e) => sum + e.value);
}

class CategoryChart extends StatefulWidget {
  const CategoryChart({super.key, required this.categories, required this.onOpenCategory, this.previousCategories = const []});
  final List<MapEntry<String, int>> categories;
  final List<MapEntry<String, int>> previousCategories;
  final ValueChanged<String> onOpenCategory;

  @override
  State<CategoryChart> createState() => _CategoryChartState();
}

class _CategoryChartState extends State<CategoryChart> {
  bool _bars = false;
  bool _showOther = false;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final data = CategoryChartData(widget.categories);
    final parts = [
      for (final e in data.main) (amount: e.value, color: categoryChartColor(context, e.key), open: () => widget.onOpenCategory(e.key)),
      if (data.other.isNotEmpty) (amount: data.otherTotal, color: context.fam.text2, open: () => setState(() => _showOther = !_showOther)),
    ];
    Widget total() => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          data.negative.isEmpty ? l.limitSpent : l.chartPositiveTotal,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: context.fam.text2),
        ),
        const SizedBox(height: 4),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: MoneyText(data.positiveTotal, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700)),
        ),
      ],
    );
    return AppCard(
      key: const ValueKey('category-chart'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (data.positive.isNotEmpty) ...[
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 4,
              children: [
                ChoiceChip(
                  label: Text(l.chartRing),
                  avatar: const Icon(Icons.donut_large, size: 17),
                  selected: !_bars,
                  showCheckmark: false,
                  onSelected: (_) => setState(() => _bars = false),
                ),
                ChoiceChip(
                  label: Text(l.chartBars),
                  avatar: const Icon(Icons.bar_chart_rounded, size: 17),
                  selected: _bars,
                  showCheckmark: false,
                  onSelected: (_) => setState(() => _bars = true),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_bars)
              Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: total())
            else
              LayoutBuilder(
                builder: (context, constraints) {
                  final side = math.min(constraints.maxWidth, 252.0);
                  final largeText = MediaQuery.textScalerOf(context).scale(14) > 20;
                  return Column(
                    children: [
                      if (largeText) Padding(padding: const EdgeInsets.only(bottom: 12), child: total()),
                      Center(
                  child: SizedBox.square(
                    key: const ValueKey('category-donut'),
                          dimension: side,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                        Semantics(
                          container: true,
                          image: true,
                                label: '${l.byCategories}: ${moneyInText(data.positiveTotal)}',
                                child: GestureDetector(
                                  excludeFromSemantics: true,
                                  onTapUp: (details) {
                                    final delta = details.localPosition - Offset(side / 2, side / 2);
                                    if (delta.distance < side / 2 - 39 || delta.distance > side / 2) return;
                                    final angle = (math.atan2(delta.dy, delta.dx) + math.pi / 2) % (math.pi * 2);
                                    var accumulated = 0.0;
                                    for (final part in parts) {
                                      accumulated += part.amount / data.positiveTotal * math.pi * 2;
                                      if (angle <= accumulated) {
                                        part.open();
                                        break;
                                      }
                                    }
                                  },
                                  child: CustomPaint(
                                    size: Size.square(side),
                                    painter: _DonutPainter(parts.map((p) => (amount: p.amount, color: p.color)).toList(), data.positiveTotal),
                                  ),
                                ),
                              ),
                              if (!largeText)
                                IgnorePointer(
                                  child: SizedBox(width: side - 86, child: total()),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            const SizedBox(height: 8),
            for (final e in data.main) _categoryRow(e.key, e.value, data.positiveTotal),
            if (data.other.isNotEmpty) ...[
              _row(
                label: l.chartOtherCategories(data.other.length),
                amount: data.otherTotal,
                total: data.positiveTotal,
                color: context.fam.text2,
                onTap: () => setState(() => _showOther = !_showOther),
                icon: _showOther ? Icons.expand_less : Icons.expand_more,
              ),
              if (_showOther)
                for (final e in data.other) _categoryRow(e.key, e.value, data.positiveTotal),
            ],
          ],
          if (data.negative.isNotEmpty) ...[
            if (data.positive.isNotEmpty) const Divider(height: 28),
            Text(l.chartRefundBalance, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(l.chartRefundsNote, style: TextStyle(fontSize: 12, color: context.fam.text2)),
            for (final e in data.negative) _categoryRow(e.key, e.value, 0),
            const Divider(height: 20),
            Text(l.chartNetTotal, style: TextStyle(fontSize: 12, color: context.fam.text2)),
            MoneyText(data.netTotal, style: const TextStyle(fontSize: 22)),
          ],
        ],
      ),
    );
  }

  Widget _categoryRow(String id, int amount, int total) => _row(
    label: categoryName(context.l10n, id),
    amount: amount,
    total: total,
    color: categoryChartColor(context, id),
    onTap: () => widget.onOpenCategory(id),
    rowKey: ValueKey('chart-category-$id'),
    previous: widget.previousCategories.where((e) => e.key == id).firstOrNull?.value,
  );

  Widget _row({
    required String label,
    required int amount,
    required int total,
    required Color color,
    required VoidCallback onTap,
    IconData? icon,
    Key? rowKey,
    int? previous,
  }) {
    final share = amount > 0 && total > 0 ? '${NumberFormat('0.#', Localizations.localeOf(context).toString()).format(amount * 100 / total)}%' : '';
    return Semantics(
      key: rowKey,
      button: true,
      label: '$label. ${moneyInText(amount)}. $share',
      onTap: onTap,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        excludeFromSemantics: true,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final stacked = constraints.maxWidth < 300 || MediaQuery.textScalerOf(context).scale(14) > 18;
              final name = Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Text(label, style: const TextStyle(fontSize: 14))),
                  if (icon != null) Icon(icon, size: 20),
                ],
              );
              final value = Wrap(
                spacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  MoneyText(amount, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  if (share.isNotEmpty) Text(share, style: TextStyle(fontSize: 12, color: context.fam.text2)),
                ],
              );
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (stacked) ...[
                    name,
                    Padding(padding: const EdgeInsets.only(left: 18, top: 4), child: value),
                  ] else
                    Row(
                      children: [
                        Expanded(child: name),
                        const SizedBox(width: 10),
                        value,
                      ],
                    ),
                  if (_bars && amount > 0 && total > 0)
                    Padding(
                      padding: const EdgeInsets.only(left: 18, top: 9),
                      child: LinearProgressIndicator(
                        value: amount / total,
                        minHeight: 7,
                        borderRadius: BorderRadius.circular(8),
                        color: color,
                        backgroundColor: context.scheme.surfaceContainerHighest,
                      ),
                    ),
                  if (previous != null)
                    Padding(
                      padding: const EdgeInsets.only(left: 18, top: 5),
                      child: Text('${context.l10n.vsLastMonth}: ${moneyInText(previous)}', style: TextStyle(fontSize: 12, color: context.fam.text2)),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _DonutPainter extends CustomPainter {
  _DonutPainter(this.parts, this.total);
  final List<({int amount, Color color})> parts;
  final int total;

  @override
  void paint(Canvas canvas, Size size) {
    if (total <= 0) return;
    final rect = (Offset.zero & size).deflate(17);
    var start = -math.pi / 2;
    for (final part in parts) {
      final sweep = part.amount / total * math.pi * 2;
      final gap = parts.length == 1 ? 0.0 : math.min(.025, sweep * .08);
      canvas.drawArc(
        rect,
        start + gap / 2,
        sweep - gap,
        false,
        Paint()
          ..color = part.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 25,
      );
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _DonutPainter oldDelegate) => oldDelegate.total != total || !listEquals(oldDelegate.parts, parts);
}
