/// Сцена «Pro включён» (D110): показывается один раз сразу после того, как
/// сервер подтвердил оплату. Вспышка, бейдж вырастает с пружинкой, конфетти,
/// список того, что открылось, кнопка «Поехали». Без сторонних пакетов:
/// один `AnimationController` и `CustomPainter` для конфетти. При выключенных
/// анимациях (настройки доступности) сцена сразу показывается готовой.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../theme/app_theme.dart';
import '../widgets/common.dart';

/// Показывает сцену поверх всего; закрывается кнопкой или касанием фона.
Future<void> showProCelebration(BuildContext context, {DateTime? until}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Pro',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (ctx, _, __) =>
        ProCelebration(until: until, onDone: () => Navigator.of(ctx).pop()),
    transitionBuilder: (_, anim, __, child) =>
        FadeTransition(opacity: anim, child: child),
  );
}

class ProCelebration extends StatefulWidget {
  const ProCelebration({super.key, this.until, required this.onDone});
  final DateTime? until;
  final VoidCallback onDone;

  @override
  State<ProCelebration> createState() => _ProCelebrationState();
}

class _ProCelebrationState extends State<ProCelebration>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  );
  late final List<_Confetti> _confetti = _Confetti.burst(90, math.Random(7));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (MediaQuery.disableAnimationsOf(context)) {
        _c.value = 1;
      } else {
        _c.forward();
      }
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  /// Кусок общей шкалы [a]–[b] как отдельная кривая 0…1.
  Animation<double> _part(
    double a,
    double b, [
    Curve curve = Curves.easeOutCubic,
  ]) => CurvedAnimation(
    parent: _c,
    curve: Interval(a, b, curve: curve),
  );

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final fam = context.fam;
    final scheme = Theme.of(context).colorScheme;
    final locale = Localizations.localeOf(context).toString();
    final features = [
      l.proFeatAccounts,
      l.proFeatLimits,
      l.proFeatGoals,
      l.proFeatEarly,
      l.proFeatAi,
      l.proFeatImport,
    ];
    final badge = _part(0.05, 0.55, Curves.elasticOut);
    final ring = _part(0.05, 0.7);
    final title = _part(0.35, 0.6);
    final list = _part(0.5, 0.95);
    final button = _part(0.8, 1.0);

    return Material(
      color: Colors.transparent,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final t = _c.value;
          return Stack(
            fit: StackFit.expand,
            children: [
              // Фон: затемнение и тёплая вспышка, которая быстро гаснет. Касание по
              // фону закрывает сцену; кнопки карточки — выше и не спорят с ним.
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onDone,
                child: Container(
                  color: Colors.black.withValues(
                    alpha: 0.72 * Curves.easeOut.transform(t.clamp(0, .2) / .2),
                  ),
                ),
              ),
              Opacity(
                opacity: (1 - _part(0.0, 0.5).value) * 0.55,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      colors: [fam.accent, Colors.transparent],
                      radius: 0.9,
                    ),
                  ),
                ),
              ),
              CustomPaint(
                painter: _ConfettiPainter(
                  _confetti,
                  _part(0.15, 1.0, Curves.linear).value,
                  [fam.accent, fam.income, scheme.primary, Colors.white],
                ),
              ),
              SafeArea(
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 28,
                      vertical: 24,
                    ),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {}, // касание по карточке не закрывает
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 180,
                            height: 180,
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                // Расходящееся кольцо.
                                Transform.scale(
                                  scale: 0.6 + ring.value * 1.6,
                                  child: Container(
                                    width: 140,
                                    height: 140,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: fam.accent.withValues(
                                          alpha: (1 - ring.value) * 0.8,
                                        ),
                                        width: 3,
                                      ),
                                    ),
                                  ),
                                ),
                                Transform.scale(
                                  scale: badge.value.clamp(0.0, 1.3),
                                  child: Container(
                                    width: 128,
                                    height: 128,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      gradient: LinearGradient(
                                        begin: Alignment.topLeft,
                                        end: Alignment.bottomRight,
                                        colors: [
                                          fam.accent,
                                          const Color(0xFFB8781A),
                                        ],
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: fam.accent.withValues(
                                            alpha: 0.55,
                                          ),
                                          blurRadius: 48,
                                          spreadRadius: 4,
                                        ),
                                      ],
                                    ),
                                    child: Center(
                                      child: Text(
                                        'Pro',
                                        style: TextStyle(
                                          color: fam.onAccent,
                                          fontSize: 44,
                                          fontWeight: FontWeight.w900,
                                          letterSpacing: -1,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),
                          _Reveal(
                            progress: title.value,
                            child: Column(
                              children: [
                                Text(
                                  l.proCelebrateTitle,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 34,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: -0.5,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  widget.until == null
                                      ? l.proCelebrateThanks
                                      : l.proCelebrateUntil(
                                          DateFormat.yMMMMd(
                                            locale,
                                          ).format(widget.until!),
                                        ),
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.75),
                                    fontSize: 15,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 26),
                          _Reveal(
                            progress: list.value,
                            child: Text(
                              l.proCelebrateUnlocked,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.6),
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          for (final (i, f) in features.indexed)
                            _Reveal(
                              progress: ((list.value - i * 0.12) / 0.4).clamp(
                                0.0,
                                1.0,
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 5,
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.check_circle,
                                      size: 20,
                                      color: fam.accent,
                                    ),
                                    const SizedBox(width: 10),
                                    Flexible(
                                      child: Text(
                                        f,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          const SizedBox(height: 28),
                          _Reveal(
                            progress: button.value,
                            child: FilledButton(
                              style: FilledButton.styleFrom(
                                backgroundColor: fam.accent,
                                foregroundColor: fam.onAccent,
                                minimumSize: const Size(220, 52),
                              ),
                              onPressed: widget.onDone,
                              child: Text(l.proCelebrateGo),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Появление снизу с проявлением: progress 0 — скрыто, 1 — на месте.
class _Reveal extends StatelessWidget {
  const _Reveal({required this.progress, required this.child});
  final double progress;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = progress.clamp(0.0, 1.0);
    return Opacity(
      opacity: p,
      child: Transform.translate(offset: Offset(0, (1 - p) * 24), child: child),
    );
  }
}

/// Одна частица конфетти: вылетает из центра, падает под тяжестью, крутится.
class _Confetti {
  _Confetti(
    this.angle,
    this.speed,
    this.size,
    this.spin,
    this.colorIndex,
    this.shape,
  );
  final double angle, speed, size, spin;
  final int colorIndex, shape;

  static List<_Confetti> burst(int n, math.Random r) => [
    for (var i = 0; i < n; i++)
      _Confetti(
        -math.pi / 2 + (r.nextDouble() - 0.5) * math.pi * 1.1,
        0.55 + r.nextDouble() * 0.75,
        5 + r.nextDouble() * 7,
        (r.nextDouble() - 0.5) * 14,
        r.nextInt(4),
        r.nextInt(3),
      ),
  ];
}

class _ConfettiPainter extends CustomPainter {
  _ConfettiPainter(this.parts, this.t, this.colors);
  final List<_Confetti> parts;
  final double t; // 0 — старт, 1 — всё упало
  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    if (t <= 0) return;
    final origin = Offset(size.width / 2, size.height * 0.36);
    final paint = Paint();
    for (final p in parts) {
      final dist = p.speed * size.height * 0.9 * t;
      final x = origin.dx + math.cos(p.angle) * dist;
      final y =
          origin.dy +
          math.sin(p.angle) * dist +
          size.height * 1.1 * t * t; // тяжесть
      if (y > size.height + 20) continue;
      paint.color = colors[p.colorIndex].withValues(
        alpha: (1 - t * 0.6).clamp(0.0, 1.0),
      );
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(p.spin * t);
      switch (p.shape) {
        case 0:
          canvas.drawRect(
            Rect.fromCenter(
              center: Offset.zero,
              width: p.size,
              height: p.size * 0.6,
            ),
            paint,
          );
        case 1:
          canvas.drawCircle(Offset.zero, p.size * 0.4, paint);
        default:
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromCenter(
                center: Offset.zero,
                width: p.size * 0.45,
                height: p.size * 1.3,
              ),
              const Radius.circular(2),
            ),
            paint,
          );
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_ConfettiPainter old) => old.t != t;
}
