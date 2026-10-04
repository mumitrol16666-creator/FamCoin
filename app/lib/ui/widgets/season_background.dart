import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../state/app_scope.dart';
import '../../theme/app_theme.dart';
import 'spring_art.dart';

/// Сезонный фон под основными вкладками (D46): два пятна света в углах и
/// растительные формы весной, осенью листья, зимой снег. Рисуется кодом,
/// одинаково работает в обеих темах. При «уменьшить движение» — статичен.
class SeasonBackground extends StatelessWidget {
  const SeasonBackground({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final fam = context.fam;
    if (fam.season == Season.none) return child;
    return Stack(children: [
      Positioned.fill(
        child: IgnorePointer(
          child: RepaintBoundary(
            child: CustomPaint(painter: _GlowPainter(fam.glowA, fam.glowB, Theme.of(context).scaffoldBackgroundColor)),
          ),
        ),
      ),
      Positioned.fill(child: IgnorePointer(child: ExcludeSemantics(child: RepaintBoundary(
        child: fam.season == Season.spring
            ? CustomPaint(painter: SpringBackdropPainter(dark: Theme.of(context).brightness == Brightness.dark))
            : _Particles(season: fam.season),
      )))),
      child,
    ]);
  }
}

class _GlowPainter extends CustomPainter {
  const _GlowPainter(this.a, this.b, this.bg);
  final Color a;
  final Color b;
  final Color bg;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = bg);
    void glow(Offset center, double r, Color c) {
      canvas.drawCircle(
        center,
        r,
        Paint()
          ..shader = RadialGradient(colors: [c, c.withValues(alpha: c.a * .6), c.withValues(alpha: 0)], stops: const [0, .3, 1])
              .createShader(Rect.fromCircle(center: center, radius: r)),
      );
    }
    glow(Offset(size.width * .1, size.height * .04), size.width * .85, a);
    glow(Offset(size.width * .95, size.height * .36), size.width * .7, b);
  }

  @override
  bool shouldRepaint(_GlowPainter old) => old.a != a || old.b != b || old.bg != bg;
}

/// Частицы: свой тикер на ~30 кадров/с (Safari на телефоне благодарен),
/// останавливается, пока поверх открыт другой экран или лист.
class _Particles extends StatefulWidget {
  const _Particles({required this.season});
  final Season season;

  @override
  State<_Particles> createState() => _ParticlesState();
}

class _ParticlesState extends State<_Particles> with SingleTickerProviderStateMixin, RouteAware {
  static const _period = Duration(seconds: 12);
  static const _frame = Duration(milliseconds: 33);
  late final Ticker _ticker = createTicker(_onTick);
  Duration _last = Duration.zero;
  double _t = 0;
  bool _covered = false;

  @override
  void initState() {
    super.initState();
    _ticker.start();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) routeObserver.subscribe(this, route);
  }

  @override
  void didPushNext() => _pause(true);

  @override
  void didPopNext() => _pause(false);

  void _pause(bool covered) {
    _covered = covered;
    if (covered) {
      _ticker.stop();
    } else if (!_ticker.isActive) {
      _ticker.start();
    }
  }

  void _onTick(Duration elapsed) {
    if (elapsed - _last < _frame) return;
    _last = elapsed;
    setState(() => _t = (elapsed.inMilliseconds % _period.inMilliseconds) / _period.inMilliseconds);
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context) || _covered;
    final fam = context.fam;
    final t = still ? .3 : _t;
    return CustomPaint(
      painter: widget.season == Season.autumn ? _LeavesPainter(t, fam.accent, fam.expense) : _SnowPainter(t),
    );
  }
}

class _LeavesPainter extends CustomPainter {
  const _LeavesPainter(this.t, this.a, this.b);
  final double t;
  final Color a;
  final Color b;

  static const _leaves = [
    (.72, .05, 26.0, .60, 0.0), (.86, .17, 18.0, .45, .33), (.12, .33, 16.0, .35, .66), (.40, .12, 12.0, .30, .5),
    (.05, .10, 20.0, .40, .2), (.60, .28, 14.0, .30, .8), (.93, .40, 22.0, .45, .1), (.30, .46, 12.0, .25, .45), (.78, .55, 16.0, .30, .7),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    for (final (fx, fy, s, op, ph) in _leaves) {
      final w = math.sin((t + ph) * 2 * math.pi);
      final dx = size.width * fx + 10 * w;
      final dy = size.height * fy + 14 * w * w;
      canvas.save();
      canvas.translate(dx, dy);
      canvas.rotate(.35 * w);
      final k = s / 24;
      final path = Path()
        ..moveTo(4 * k, 20 * k)
        ..cubicTo(6 * k, 10 * k, 12 * k, 5 * k, 21 * k, 4 * k)
        ..cubicTo(20 * k, 13 * k, 15 * k, 19 * k, 6 * k, 20 * k)
        ..close();
      canvas.drawPath(path, Paint()..color = (ph > .4 ? b : a).withValues(alpha: op));
      canvas.drawLine(Offset(5 * k, 19 * k), Offset(19 * k, 5 * k), Paint()
        ..color = b.withValues(alpha: op * .8)
        ..strokeWidth = 1);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_LeavesPainter old) => old.t != t;
}

class _SnowPainter extends CustomPainter {
  const _SnowPainter(this.t);
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = const Color(0xFFEAF6FF);
    for (var i = 0; i < 14; i++) {
      final fx = (i * .073 + .05) % 1;
      final speed = .6 + (i % 3) * .2;
      final p = (t * speed + i * .17) % 1;
      final y = p * size.height * .45;
      final x = size.width * fx + 6 * math.sin((p + i) * 2 * math.pi);
      final fade = p < .15 ? p / .15 : (1 - p);
      canvas.drawCircle(Offset(x, y), 1.5 + (i % 3) * .8, paint..color = paint.color.withValues(alpha: .7 * fade));
    }
  }

  @override
  bool shouldRepaint(_SnowPainter old) => old.t != t;
}
