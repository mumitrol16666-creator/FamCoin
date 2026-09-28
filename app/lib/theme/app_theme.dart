/// Дизайн-токены FamCoin (раздел 12 карты продукта) и сезонная тема (D46).
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Сезон меняет только атмосферу: свечение фона, частицы и цвет акцента.
/// Цифры, карточки и логика от него не зависят.
enum Season { none, autumn, winter }

/// `pref`: auto | autumn | winter | none. Авто — по календарю: сентябрь–ноябрь
/// осень, декабрь–февраль зима, остальное пока без темы.
Season resolveSeason(String pref, DateTime now) => switch (pref) {
      'autumn' => Season.autumn,
      'winter' => Season.winter,
      'none' => Season.none,
      _ => switch (now.month) {
          9 || 10 || 11 => Season.autumn,
          12 || 1 || 2 => Season.winter,
          _ => Season.none,
        },
    };

/// Цвета, которых нет в стандартной `ColorScheme`: доход, расход, долг,
/// акцент добавления и вторичный текст.
@immutable
class FamColors extends ThemeExtension<FamColors> {
  const FamColors({
    required this.income,
    required this.expense,
    required this.debt,
    required this.accent,
    required this.onAccent,
    required this.text2,
    required this.warn,
    required this.warnBg,
    required this.incomeBg,
    required this.expenseBg,
    required this.line,
    required this.guideBg,
    required this.guideBad,
    this.season = Season.none,
    this.glowA = Colors.transparent,
    this.glowB = Colors.transparent,
  });

  /// Фон главной карточки и её «плохой» вариант — всегда с белым текстом,
  /// в обеих темах (владелец: чёрный текст на зелёном — нет).
  final Color guideBg;
  final Color guideBad;
  static const onGuide = Colors.white;

  final Color income;
  final Color expense;
  final Color debt;
  final Color accent;
  final Color onAccent;
  final Color text2;
  final Color warn;
  final Color warnBg;
  final Color incomeBg;
  final Color expenseBg;
  final Color line;

  final Season season;

  /// Два пятна света сезонного фона (уже с прозрачностью).
  final Color glowA;
  final Color glowB;

  static const light = FamColors(
    income: Color(0xFF226A44),
    expense: Color(0xFFAA402C),
    debt: Color(0xFF6B4FBB),
    accent: Color(0xFFE0A43A),
    onAccent: Color(0xFF1A1D21),
    text2: Color(0xFF58645F),
    warn: Color(0xFFB7791F),
    warnBg: Color(0xFFFBF0D9),
    incomeBg: Color(0xFFE4F1E9),
    expenseBg: Color(0xFFF7E5E0),
    line: Color(0xFFE3DFD6),
    guideBg: Color(0xFF1F5E4F),
    guideBad: Color(0xFFAA402C),
  );

  static const dark = FamColors(
    income: Color(0xFF70D7A1),
    expense: Color(0xFFFF9789),
    debt: Color(0xFFB9A4F5),
    accent: Color(0xFFF0B955),
    onAccent: Color(0xFF12151A),
    text2: Color(0xFFA8B3AD),
    warn: Color(0xFFF0B955),
    warnBg: Color(0xFF332B1A),
    incomeBg: Color(0xFF1C2E27),
    expenseBg: Color(0xFF33221F),
    line: Color(0xFF2C333E),
    guideBg: Color(0xFF2E6B5B),
    guideBad: Color(0xFF8C3A2C),
  );

  FamColors withSeason(Season s, {required bool isDark}) {
    switch (s) {
      case Season.none:
        return this;
      case Season.autumn:
        return _copy(
          season: s,
          glowA: const Color(0xFFE0A43A).withValues(alpha: isDark ? .38 : .20),
          glowB: const Color(0xFFAA402C).withValues(alpha: isDark ? .26 : .10),
        );
      case Season.winter:
        return _copy(
          season: s,
          accent: isDark ? const Color(0xFF9CD8F0) : const Color(0xFF2F8FBF),
          onAccent: isDark ? const Color(0xFF0C2A3A) : Colors.white,
          guideBg: isDark ? const Color(0xFF2A5B6E) : const Color(0xFF236A85),
          glowA: const Color(0xFF4FA3E0).withValues(alpha: isDark ? .36 : .16),
          glowB: const Color(0xFF8FD3F4).withValues(alpha: isDark ? .20 : .10),
        );
    }
  }

  FamColors _copy({Season? season, Color? accent, Color? onAccent, Color? glowA, Color? glowB, Color? guideBg}) => FamColors(
        income: income,
        expense: expense,
        debt: debt,
        accent: accent ?? this.accent,
        onAccent: onAccent ?? this.onAccent,
        text2: text2,
        warn: warn,
        warnBg: warnBg,
        incomeBg: incomeBg,
        expenseBg: expenseBg,
        line: line,
        guideBg: guideBg ?? this.guideBg,
        guideBad: guideBad,
        season: season ?? this.season,
        glowA: glowA ?? this.glowA,
        glowB: glowB ?? this.glowB,
      );

  @override
  FamColors copyWith({Color? income, Color? expense}) => this;

  @override
  FamColors lerp(FamColors? other, double t) => t < 0.5 ? this : (other ?? this);
}

extension FamTheme on BuildContext {
  FamColors get fam => Theme.of(this).extension<FamColors>()!;
  ColorScheme get scheme => Theme.of(this).colorScheme;
}

ThemeData buildTheme(Brightness brightness, {Season season = Season.none}) {
  final isDark = brightness == Brightness.dark;
  final fam = (isDark ? FamColors.dark : FamColors.light).withSeason(season, isDark: isDark);

  // Зимой основной цвет холоднее; осенью остаётся фирменный зелёный.
  final primary = switch (season) {
    Season.winter => isDark ? const Color(0xFF4F9FC0) : const Color(0xFF236A85),
    _ => isDark ? const Color(0xFF4FB39A) : const Color(0xFF1F5E4F),
  };

  final scheme = ColorScheme(
    brightness: brightness,
    primary: primary,
    onPrimary: isDark ? const Color(0xFF12151A) : Colors.white,
    secondary: fam.accent,
    onSecondary: fam.onAccent,
    error: fam.expense,
    onError: Colors.white,
    surface: isDark ? const Color(0xFF1B2028) : Colors.white,
    onSurface: isDark ? const Color(0xFFECEEF1) : const Color(0xFF1A1D21),
    surfaceContainerHighest: isDark ? const Color(0xFF232A34) : const Color(0xFFEEEBE4),
    outline: fam.line,
  );
  final background = isDark ? const Color(0xFF12151A) : const Color(0xFFF5F3EE);

  final base = ThemeData(brightness: brightness, colorScheme: scheme, useMaterial3: true);
  final body = GoogleFonts.notoSansTextTheme(base.textTheme).apply(
    bodyColor: scheme.onSurface,
    displayColor: scheme.onSurface,
  );
  final heading = GoogleFonts.manrope(fontWeight: FontWeight.w800, color: scheme.onSurface);

  return base.copyWith(
    scaffoldBackgroundColor: background,
    extensions: [fam],
    textTheme: body.copyWith(
      displayMedium: heading.copyWith(fontSize: 34, letterSpacing: -0.5),
      headlineSmall: heading.copyWith(fontSize: 22),
      titleLarge: heading.copyWith(fontSize: 18, fontWeight: FontWeight.w700),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: background,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: heading.copyWith(fontSize: 22, fontWeight: FontWeight.w700),
    ),
    cardTheme: CardThemeData(
      color: scheme.surface,
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surface,
      // Подсказка-пример заметно бледнее введённого текста — иначе кажется,
      // что поле уже заполнено (замечание владельца 28.09.2026).
      hintStyle: TextStyle(color: fam.text2.withValues(alpha: .55)),
      // Название поля (labelText) без своего стиля наследует основной цвет
      // текста и выглядит как уже введённое значение, а не как подпись.
      labelStyle: TextStyle(color: fam.text2),
      floatingLabelStyle: TextStyle(color: fam.text2),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: fam.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: fam.line),
      ),
    ),
    chipTheme: ChipThemeData(
      shape: const StadiumBorder(),
      side: BorderSide(color: fam.line),
      backgroundColor: scheme.surface,
      selectedColor: scheme.primary,
      labelStyle: TextStyle(color: scheme.onSurface, fontSize: 13),
      secondaryLabelStyle: TextStyle(color: scheme.onPrimary, fontSize: 13),
      showCheckmark: false,
    ),
    dividerColor: fam.line,
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? scheme.primary : scheme.surface),
        foregroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? scheme.onPrimary : scheme.onSurface),
        side: WidgetStatePropertyAll(BorderSide(color: fam.line)),
      ),
    ),
  );
}
