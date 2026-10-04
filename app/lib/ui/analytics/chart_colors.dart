import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

/// Цвет привязан к категории, а не к её месту в рейтинге месяца.
Color categoryChartColor(BuildContext context, String id) {
  const known = {
    'food': 0,
    'home': 1,
    'transport': 2,
    'fun': 3,
    'cafe': 4,
    'health': 5,
    'debts': 6,
    'interest': 7,
    'clothes': 8,
    'utilities': 9,
    'household': 10,
    'phone': 11,
    'kids': 12,
    'education': 13,
    'subscriptions': 14,
    'gifts': 15,
    'fees': 16,
    'other': 17,
  };
  const light = [
    0xFF367A60,
    0xFF507FAB,
    0xFFBD8B31,
    0xFF8B6FB4,
    0xFFB36651,
    0xFF3F8C91,
    0xFF7273AF,
    0xFF858477,
    0xFFAB648B,
    0xFF92713C,
    0xFF7A8B42,
    0xFF5F91A7,
    0xFFB67684,
    0xFF52639F,
    0xFF97689B,
    0xFF9B7462,
    0xFF437F79,
    0xFF7C8890,
  ];
  const dark = [
    0xFF7ED4AC,
    0xFF81B0DA,
    0xFFE4B65F,
    0xFFBCA2D9,
    0xFFE59D86,
    0xFF79C7CD,
    0xFFA6A8E0,
    0xFFB8B6A5,
    0xFFD898BF,
    0xFFC4A575,
    0xFFB0C66F,
    0xFF92C6DA,
    0xFFE5ABBA,
    0xFF8D9DD6,
    0xFFCAA0CC,
    0xFFCDA895,
    0xFF81B8B2,
    0xFFB2BFC9,
  ];
  const spring = [
    0xFF209869, 0xFF548BE2, 0xFFF4B947, 0xFFAB7DDE,
    0xFFED8D68, 0xFF24ABA4, 0xFF7E69D6, 0xFFCB8196,
    0xFFDE709C, 0xFFB58D38, 0xFF82A93D, 0xFF45A7CA,
    0xFFEBA3AF, 0xFF607AD7, 0xFFB367BE, 0xFFE69F62,
    0xFF51B395, 0xFF849D8D,
  ];
  var hash = 0;
  for (final code in id.codeUnits) {
    hash = (hash * 31 + code) & 0x7fffffff;
  }
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final isSpring = context.fam.season == Season.spring;
  final index = known[id];
  if (index == null) return HSLColor.fromAHSL(1, (hash % 360).toDouble(), isSpring ? .6 : .42, isDark ? .7 : .43).toColor();
  if (isSpring) {
    final color = Color(spring[index]);
    return isDark ? Color.lerp(color, Colors.white, .2)! : color;
  }
  return Color((isDark ? dark : light)[index]);
}
