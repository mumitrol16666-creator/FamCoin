import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// Линия тренда по месяцам (капитал, доход/расход и т.п.): значение может
/// быть отрицательным, поэтому столбики от нуля вводили бы в заблуждение —
/// у растущего (менее отрицательного) капитала столбик тоже растёт.
class TrendChart extends StatelessWidget {
  const TrendChart({super.key, required this.values, required this.labels, this.color, this.height = 110});
  final List<int> values;
  final List<String> labels;
  final Color? color;
  final double height;

  @override
  Widget build(BuildContext context) {
    final fam = context.fam;
    final c = color ?? context.scheme.primary;
    if (values.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(
        height: height,
        child: CustomPaint(painter: _TrendPainter(values: values, color: c, lineColor: fam.line)),
      ),
      const SizedBox(height: 4),
      Row(children: [for (final l in labels) Expanded(child: Text(l, textAlign: TextAlign.center, style: TextStyle(fontSize: 10, color: fam.text2)))]),
    ]);
  }
}

class _TrendPainter extends CustomPainter {
  _TrendPainter({required this.values, required this.color, required this.lineColor});
  final List<int> values;
  final Color color;
  final Color lineColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final minV = values.reduce((a, b) => a < b ? a : b);
    final maxV = values.reduce((a, b) => a > b ? a : b);
    final span = (maxV - minV) == 0 ? 1 : (maxV - minV);
    const pad = 16.0;
    double y(int v) => pad + (size.height - pad * 2) * (1 - (v - minV) / span);
    final step = values.length <= 1 ? 0.0 : size.width / (values.length - 1);

    // Нулевая линия — только если диапазон её действительно пересекает.
    if (minV < 0 && maxV > 0) {
      final zeroY = y(0);
      canvas.drawLine(Offset(0, zeroY), Offset(size.width, zeroY), Paint()
        ..color = lineColor
        ..strokeWidth = 1);
    }

    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final p = Offset(step * i, y(values[i]));
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
    for (var i = 0; i < values.length; i++) {
      canvas.drawCircle(Offset(step * i, y(values[i])), i == values.length - 1 ? 4 : 2.5, Paint()..color = color);
    }

    // Первое и последнее значение — подписью прямо над точкой.
    for (final i in {0, values.length - 1}) {
      final tp = TextPainter(
        text: TextSpan(text: formatMoney(values[i]), style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w600)),
        textDirection: TextDirection.ltr,
      )..layout();
      final x = (step * i - tp.width / 2).clamp(0, size.width - tp.width);
      tp.paint(canvas, Offset(x.toDouble(), (y(values[i]) - tp.height - 4).clamp(0, size.height - tp.height)));
    }
  }

  @override
  bool shouldRepaint(covariant _TrendPainter old) => old.values != values || old.color != color;
}
