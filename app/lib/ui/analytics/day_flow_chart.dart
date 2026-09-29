import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// График «доход/расход по дням» (редизайн 29.09.2026): доход — зелёные
/// столбики вверх от нуля, расход — красные вниз, линия — накопленный за
/// месяц остаток (доход минус расход с начала месяца, а не баланс счёта).
/// Каждый день — своя область нажатия и подпись для экранного диктора,
/// это уже проверялось аудитом (F09) и не должно вернуться в редизайне.
class DayFlowChart extends StatelessWidget {
  const DayFlowChart({
    super.key,
    required this.income,
    required this.expense,
    required this.selectedDay,
    required this.onSelect,
    required this.dayLabel,
    this.todayIndex,
    this.height = 180,
  });

  final List<int> income;
  final List<int> expense;
  final int? selectedDay;
  final ValueChanged<int?> onSelect;

  /// Подпись для экранного диктора: `дата: доход X, расход Y`.
  final String Function(int index) dayLabel;

  /// Индекс сегодняшнего дня в этом месяце; `null` — показан не текущий месяц.
  final int? todayIndex;
  final double height;

  @override
  Widget build(BuildContext context) {
    final fam = context.fam;
    final running = <int>[];
    var acc = 0;
    for (var i = 0; i < income.length; i++) {
      acc += income[i] - expense[i];
      running.add(acc);
    }
    final maxUp = income.fold(0, (m, v) => v > m ? v : m);
    // Возврат внутри месяца может дать отрицательный расход дня — берём
    // модуль, иначе такой день занижает шкалу (повторный аудит, F05).
    final maxDown = expense.fold(0, (m, v) => v.abs() > m ? v.abs() : m);
    final maxRunning = running.fold(0, (m, v) => v.abs() > m ? v.abs() : m);
    // Единая шкала на столбики и линию, иначе линия либо теряется, либо
    // выходит за пределы графика.
    final scale = [maxUp, maxDown, maxRunning].fold(1, (m, v) => v > m ? v : m);

    return SizedBox(
      height: height,
      child: Stack(children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < income.length; i++)
              Expanded(
                child: Semantics(
                  // Будущий день текущего месяца нельзя выбрать (повторный
                  // аудит, F06) — иначе календарь получает initialDate позже
                  // lastDate и нарушает свой контракт.
                  button: todayIndex == null || i <= todayIndex!,
                  selected: selectedDay == i,
                  label: dayLabel(i),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: (todayIndex == null || i <= todayIndex!) ? () => onSelect(selectedDay == i ? null : i) : null,
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Expanded(
                        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                          Expanded(child: Align(
                            alignment: Alignment.bottomCenter,
                            child: Container(
                              key: ValueKey('day-$i-income'),
                              margin: const EdgeInsets.symmetric(horizontal: 1),
                              height: income[i] <= 0 ? 0 : (4 + (height / 2 - 6) * income[i] / scale).clamp(0, height / 2 - 2).toDouble(),
                              decoration: BoxDecoration(color: fam.income.withValues(alpha: selectedDay == i || todayIndex == i ? 1 : .55),
                                  borderRadius: const BorderRadius.vertical(top: Radius.circular(2))),
                            ),
                          )),
                          if (expense[i] < 0)
                            Expanded(child: Align(
                              alignment: Alignment.bottomCenter,
                              child: Container(
                                key: ValueKey('day-$i-refund'),
                                margin: const EdgeInsets.symmetric(horizontal: 1),
                                height: (4 + (height / 2 - 6) * -expense[i] / scale).clamp(0, height / 2 - 2).toDouble(),
                                decoration: BoxDecoration(color: fam.accent,
                                    borderRadius: const BorderRadius.vertical(top: Radius.circular(2))),
                              ),
                            )),
                        ]),
                      ),
                      Expanded(
                        child: Align(
                          alignment: Alignment.topCenter,
                          child: Container(
                            margin: const EdgeInsets.symmetric(horizontal: 1),
                            // Only positive net expense points down. Net refunds
                            // have their own upward series in the top half.
                            key: ValueKey('day-$i-expense'),
                            height: expense[i] <= 0 ? 0 : (4 + (height / 2 - 6) * expense[i] / scale).clamp(0, height / 2 - 2).toDouble(),
                            decoration: BoxDecoration(
                              color: selectedDay == i ? fam.accent : fam.expense.withValues(alpha: todayIndex == i ? 1 : .55),
                              borderRadius: const BorderRadius.vertical(bottom: Radius.circular(2)),
                            ),
                          ),
                        ),
                      ),
                    ]),
                  ),
                ),
              ),
          ],
        ),
        IgnorePointer(
          child: CustomPaint(
            size: Size.infinite,
            painter: _RunningLinePainter(running: running, scale: scale, color: context.scheme.primary),
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: Container(height: 1, color: fam.line),
        ),
      ]),
    );
  }
}

/// Линия накопленного остатка поверх столбиков; ноль — по центру высоты,
/// та же шкала, что у столбиков.
class _RunningLinePainter extends CustomPainter {
  _RunningLinePainter({required this.running, required this.scale, required this.color});
  final List<int> running;
  final int scale;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (running.isEmpty || size.width <= 0) return;
    final mid = size.height / 2;
    final usable = size.height / 2 - 4;
    final step = size.width / running.length;
    final path = Path();
    for (var i = 0; i < running.length; i++) {
      final x = step * (i + 0.5);
      final y = mid - (running[i] / scale) * usable;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeJoin = StrokeJoin.round);
  }

  @override
  bool shouldRepaint(covariant _RunningLinePainter old) => old.running != running || old.scale != scale || old.color != color;
}
