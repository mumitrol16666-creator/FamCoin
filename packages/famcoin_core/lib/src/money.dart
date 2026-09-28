/// Деньги: целые минимальные единицы валюты.
///
/// Для KZT минимальная единица — тиын, 100 тиын = 1 ₸. Дробные числа
/// в учёте не используются, поэтому суммы не расходятся при сложении.
library;

/// Число минимальных единиц в одной единице валюты.
const int minorPerUnit = 100;

/// Перевод тенге в тиыны: `kzt(1250) == 125000`.
int kzt(num tenge) => (tenge * minorPerUnit).round();

/// Округление половины вверх, единое для всех расчётов ядра.
int roundHalfUp(double value) {
  if (value >= 0) return (value + 0.5).floor();
  return -((-value + 0.5).floor());
}

/// Краткая форма для вставки в текст: `formatMoneyPlain(kzt(1250)) == '1 250 ₸'`.
String formatMoneyPlain(int minor) => formatMoney(minor);

/// Форматирует сумму как `1 250 000 ₸`. Дробная часть показывается только
/// когда она значима (`showMinorIfZero == false`), как требует раздел 12.
String formatMoney(
  int minor, {
  String symbol = '₸',
  String groupSeparator = ' ',
  String decimalSeparator = ',',
  bool showMinorIfZero = false,
}) {
  final negative = minor < 0;
  final abs = minor.abs();
  final units = abs ~/ minorPerUnit;
  final fraction = abs % minorPerUnit;

  final digits = units.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    final fromEnd = digits.length - i;
    buffer.write(digits[i]);
    if (fromEnd > 1 && fromEnd % 3 == 1) buffer.write(groupSeparator);
  }

  if (fraction != 0 || showMinorIfZero) {
    buffer
      ..write(decimalSeparator)
      ..write(fraction.toString().padLeft(2, '0'));
  }
  if (symbol.isNotEmpty) buffer.write(' $symbol');
  return (negative ? '−' : '') + buffer.toString();
}
