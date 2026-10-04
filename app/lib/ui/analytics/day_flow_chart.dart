import 'dart:math' as math;

import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat, NumberFormat;

import '../../theme/app_theme.dart';
import '../widgets/common.dart';

/// По семь дней: столбики не сливаются на телефоне. Шкала общая для всего
/// месяца. Отрицательные расходы (возвраты) рисуются ниже нуля, без модуля.
class DayFlowChart extends StatefulWidget {
  const DayFlowChart({
    super.key,
    required this.month,
    required this.income,
    required this.expense,
    required this.selectedDay,
    required this.onSelect,
    required this.dayLabel,
    this.todayIndex,
    this.height = 208,
  });

  final DateTime month;
  final List<int> income;
  final List<int> expense;
  final int? selectedDay;
  final ValueChanged<int?> onSelect;
  final String Function(int index) dayLabel;
  final int? todayIndex;
  final double height;

  @override
  State<DayFlowChart> createState() => _DayFlowChartState();
}

class _DayFlowChartState extends State<DayFlowChart> {
  late int _start = _initialStart();

  int get _lastAllowed => math.min(widget.todayIndex ?? widget.income.length - 1, widget.income.length - 1);
  int _initialStart() {
    final latestEntry = widget.income.asMap().entries.where((e) => e.value != 0 || widget.expense[e.key] != 0).lastOrNull?.key;
    final focus = widget.selectedDay ?? widget.todayIndex ?? latestEntry ?? 0;
    return (focus.clamp(0, math.max(0, _lastAllowed)) ~/ 7) * 7;
  }

  @override
  void didUpdateWidget(covariant DayFlowChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.month != widget.month || (oldWidget.todayIndex != widget.todayIndex && widget.selectedDay == null)) {
      _start = _initialStart();
    } else if (widget.selectedDay != null && widget.selectedDay != oldWidget.selectedDay) {
      _start = _initialStart();
    }
    _start = _start.clamp(0, math.max(0, _lastAllowed ~/ 7 * 7));
  }

  void _changeWeek(int delta) {
    setState(() => _start = (_start + delta * 7).clamp(0, _lastAllowed ~/ 7 * 7));
    widget.onSelect(null);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.income.isEmpty) return const SizedBox.shrink();
    final l = context.l10n;
    final fam = context.fam;
    final end = math.min(_start + 7, widget.income.length);
    final locale = Localizations.localeOf(context).toString();
    final date = DateFormat.MMMd(locale).format(DateTime(widget.month.year, widget.month.month, end));
    final maxValue = [...widget.income, ...widget.expense].fold(0, math.max);
    final minValue = [...widget.income, ...widget.expense].fold(0, math.min);
    final upper = maxValue > 0 ? _niceBound(maxValue) : minValue < 0 ? 0.0 : minorPerUnit.toDouble();
    final lower = minValue < 0 ? -_niceBound(-minValue) : 0.0;
    final scale = math.max(upper, -lower);
    final divisor = scale >= minorPerUnit * 1000000
        ? minorPerUnit * 1000000
        : scale >= minorPerUnit * 1000
        ? minorPerUnit * 1000
        : minorPerUnit;
    final unit = divisor == minorPerUnit
        ? '₸'
        : divisor == minorPerUnit * 1000
        ? l.chartThousands
        : l.chartMillions;
    final ticks = lower == 0
        ? [upper, upper / 2, 0]
        : upper == 0
        ? [0, lower / 2, lower]
        : [if (upper / (upper - lower) >= .15) upper, 0, if (-lower / (upper - lower) >= .15) lower];
    final formatter = NumberFormat('0.##', locale);
    final labels = [for (final tick in ticks) formatter.format(tick / divisor)];
    final textScaler = MediaQuery.textScalerOf(context);
    final textStyle = TextStyle(fontSize: 11, color: fam.text2);
    final direction = Directionality.of(context);
    final painters = [
      for (final label in labels)
        TextPainter(
          text: TextSpan(text: label, style: textStyle),
          textDirection: direction,
          textScaler: textScaler,
        )..layout(),
    ];
    final left = painters.fold(0.0, (width, p) => math.max(width, p.width)) + 10;
    final labelHeight = painters.first.height;
    final plotTop = labelHeight / 2 + 4;
    final plotBottom = widget.height - labelHeight - 18;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton(tooltip: l.chartPrevWeek, onPressed: _start == 0 ? null : () => _changeWeek(-1), icon: const Icon(Icons.chevron_left)),
            Expanded(
              child: Text('${_start + 1}–$date', textAlign: TextAlign.center, style: const TextStyle(fontSize: 13)),
            ),
            IconButton(tooltip: l.chartNextWeek, onPressed: _start + 7 > _lastAllowed ? null : () => _changeWeek(1), icon: const Icon(Icons.chevron_right)),
          ],
        ),
        Text(unit, style: TextStyle(fontSize: 11, color: fam.text2)),
        const SizedBox(height: 4),
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final step = math.max(0.0, width - left - 4) / (end - _start);
            return SizedBox(
              height: widget.height,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: ExcludeSemantics(
                      child: CustomPaint(
                        painter: _FlowPainter(
                          income: widget.income,
                          expense: widget.expense,
                          start: _start,
                          end: end,
                          upper: upper,
                          lower: lower,
                          left: left,
                          top: plotTop,
                          bottom: plotBottom,
                          ticks: ticks,
                          labels: labels,
                          textStyle: textStyle,
                          textScaler: textScaler,
                          direction: direction,
                          incomeColor: fam.income,
                          expenseColor: fam.expense,
                          gridColor: fam.line,
                          selectedDay: widget.selectedDay,
                          todayIndex: widget.todayIndex,
                        ),
                      ),
                    ),
                  ),
                  for (var i = _start; i < end; i++)
                    Positioned(
                      left: left + (i - _start) * step,
                      top: 0,
                      bottom: 0,
                      width: step,
                      child: Semantics(
                        button: i <= _lastAllowed,
                        enabled: i <= _lastAllowed,
                        selected: widget.selectedDay == i,
                        label: widget.dayLabel(i),
                        excludeSemantics: true,
                        onTap: i <= _lastAllowed ? () => widget.onSelect(widget.selectedDay == i ? null : i) : null,
                        child: InkWell(
                          key: ValueKey('flow-day-$i'),
                          excludeFromSemantics: true,
                          onTap: i <= _lastAllowed ? () => widget.onSelect(widget.selectedDay == i ? null : i) : null,
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      if (widget.expense.any((value) => value < 0))
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(l.chartNegativeDays, style: TextStyle(fontSize: 12, color: fam.text2)),
          ),
      ],
    );
  }

  double _niceBound(int amount) {
    if (amount <= 0) return minorPerUnit.toDouble();
    final step = math.pow(10, (math.log(amount) / math.ln10).floor()).toDouble();
    return (amount / step).ceil() * step;
  }
}

class _FlowPainter extends CustomPainter {
  _FlowPainter({
    required this.income,
    required this.expense,
    required this.start,
    required this.end,
    required this.upper,
    required this.lower,
    required this.left,
    required this.top,
    required this.bottom,
    required this.ticks,
    required this.labels,
    required this.textStyle,
    required this.textScaler,
    required this.direction,
    required this.incomeColor,
    required this.expenseColor,
    required this.gridColor,
    required this.selectedDay,
    required this.todayIndex,
  });
  final List<int> income, expense;
  final int start, end;
  final double upper, lower, left, top, bottom;
  final List<num> ticks;
  final List<String> labels;
  final TextStyle textStyle;
  final TextScaler textScaler;
  final TextDirection direction;
  final Color incomeColor, expenseColor, gridColor;
  final int? selectedDay, todayIndex;

  double y(num value) => bottom - (value - lower) / (upper - lower) * (bottom - top);

  @override
  void paint(Canvas canvas, Size size) {
    final right = size.width - 4;
    final step = (right - left) / (end - start);
    for (var i = 0; i < ticks.length; i++) {
      final pos = y(ticks[i]);
      canvas.drawLine(
        Offset(left, pos),
        Offset(right, pos),
        Paint()
          ..color = gridColor
          ..strokeWidth = 1,
      );
      final label = _text(labels[i]);
      label.paint(canvas, Offset(left - label.width - 8, pos - label.height / 2));
    }
    final zero = y(0);
    final barWidth = math.min(14.0, step * .26);
    for (var i = start; i < end; i++) {
      final x = left + (i - start + .5) * step;
      final future = todayIndex != null && i > todayIndex!;
      if (selectedDay == i) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromLTRB(x - step / 2 + 1, top, x + step / 2 - 1, bottom), const Radius.circular(6)),
          Paint()..color = textStyle.color!.withValues(alpha: .07),
        );
      }
      if (!future) {
        for (final (value, bx, color) in [(income[i], x - barWidth - 1.5, incomeColor), (expense[i], x + 1.5, expenseColor)]) {
          if (value == 0) continue;
          final vy = y(value);
          canvas.drawRRect(
            RRect.fromRectAndRadius(Rect.fromLTRB(bx, math.min(zero, vy), bx + barWidth, math.max(zero, vy)), const Radius.circular(2)),
            Paint()..color = color,
          );
        }
      }
      // При крупном системном шрифте остаются четыре подписи, сами дни
      // доступны через экранный диктор и календарь независимо от подписи.
      if (textScaler.scale(11) <= 16 || (i - start).isEven || i == end - 1) {
        final label = _text('${i + 1}', faded: future);
        label.paint(canvas, Offset(x - label.width / 2, bottom + 8));
      }
    }
  }

  TextPainter _text(String value, {bool faded = false}) => TextPainter(
    text: TextSpan(
      text: value,
      style: faded ? textStyle.copyWith(color: textStyle.color!.withValues(alpha: .5)) : textStyle,
    ),
    textScaler: textScaler,
    textDirection: direction,
  )..layout();

  @override
  bool shouldRepaint(covariant _FlowPainter oldDelegate) => true;
}
