import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Статичные растительные формы: не отвлекают от цифр и не требуют анимации.
class SpringBackdropPainter extends CustomPainter {
  const SpringBackdropPainter({required this.dark});
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final green = Color(dark ? 0xFF8CDBAF : 0xFF25956B);
    final peach = Color(dark ? 0xFFEFA5B2 : 0xFFF7A18D);
    final scale = (size.width / 390).clamp(1.0, 1.6);
    canvas.save();
    canvas.translate(size.width - 18, 22);
    canvas.rotate(.2);
    canvas.scale(scale);
    _sprig(canvas, green.withValues(alpha: dark ? .17 : .15));
    _flower(canvas, const Offset(-62, 22), 9, peach.withValues(alpha: dark ? .23 : .42));
    canvas.restore();
    canvas.save();
    canvas.translate(-8, size.height * .7);
    canvas.rotate(-.6);
    canvas.scale(scale * 1.25);
    _sprig(canvas, green.withValues(alpha: dark ? .11 : .10));
    canvas.restore();
  }

  @override
  bool shouldRepaint(SpringBackdropPainter old) => old.dark != dark;
}

/// Фон главной суммы. Даже на светлой теме сохраняет белый текст на тёмном.
class SpringGuidePainter extends CustomPainter {
  const SpringGuidePainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF0D7050), Color(0xFF075B43), Color(0xFF174C3B)],
      ).createShader(Offset.zero & size),
    );
    canvas.save();
    canvas.translate(size.width - 12, size.height * .37);
    canvas.rotate(.35);
    canvas.scale(1.6);
    _sprig(canvas, const Color(0x22D6F584));
    _flower(canvas, const Offset(-54, 14), 9, const Color(0x1FFFFFFF));
    canvas.restore();
  }

  @override
  bool shouldRepaint(SpringGuidePainter old) => false;
}

void _sprig(Canvas canvas, Color color) {
  final stem = Path()..moveTo(5, 92)..cubicTo(-22, 40, -24, -7, -3, -66);
  canvas.drawPath(stem, Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 1.5);
  final paint = Paint()..color = color;
  for (var i = 0; i < 5; i++) {
    final y = -48.0 + i * 28;
    final x = -13.0 - math.sin(i * .6) * 10;
    final direction = i.isEven ? -1 : 1;
    final leaf = Path()
      ..moveTo(x, y + 18)
      ..cubicTo(x + direction * 30, y + 12, x + direction * 43, y - 4, x + direction * 38, y - 20)
      ..cubicTo(x + direction * 12, y - 19, x - direction * 2, y - 2, x, y + 18)
      ..close();
    canvas.drawPath(leaf, paint);
  }
}

void _flower(Canvas canvas, Offset center, double radius, Color color) {
  canvas.save();
  canvas.translate(center.dx, center.dy);
  for (var i = 0; i < 5; i++) {
    canvas.drawOval(Rect.fromCenter(center: Offset(0, -radius * .65), width: radius, height: radius * 1.5), Paint()..color = color);
    canvas.rotate(math.pi * 2 / 5);
  }
  canvas.drawCircle(Offset.zero, radius * .32, Paint()..color = const Color(0xFFD6F584).withValues(alpha: color.a));
  canvas.restore();
}
