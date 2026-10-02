/// Проверка сумм в ответе консультанта кодом (D91).
///
/// Правило «любое число — из данных приложения» записано в подсказке модели,
/// но подсказка — не гарантия. Здесь оно проверяется: каждая сумма из ответа
/// должна найтись среди чисел, которые модель видела (сводка, вопрос, прошлые
/// реплики), или получаться сложением либо вычитанием двух таких чисел.
/// Остальное — либо ошибка, либо собственный расчёт модели (умножение,
/// деление, проценты): такие суммы помечаются, и человек видит, что их
/// посчитал консультант, а не приложение.
library;

/// Число с необязательным множителем: «12 500», «1,2 млн», «300 тысяч», «5 мың».
final _number = RegExp(
  r'(\d{1,3}(?:[    ]\d{3})+|\d+)(?:[.,](\d{1,2}))?(?:\s*(тыс\.?|тысяч[а-яё]*|млн\.?|миллион[а-яё]*|мың)(?![а-яё]))?',
  caseSensitive: false,
);

/// Знак денег сразу после числа.
final _currency = RegExp(r'^\s*(₸|тенге|теңге|тг(?![а-яё]))', caseSensitive: false);

/// Слова, после которых сумма названа приблизительно.
final _approx = RegExp(r'(около|примерно|почти|порядка|приблизительно|шамамен|≈|~)\s*$', caseSensitive: false);

class _Mention {
  const _Mention(this.value, this.tolerance, this.text, {required this.grouped, required this.currency, required this.percent});
  final double value;

  /// Насколько число из данных может отличаться: половина последнего
  /// названного разряда («1,2 млн» — это от 1,15 до 1,25 млн).
  final double tolerance;
  final String text;
  final bool grouped;
  final bool currency;

  /// «1 350 %» — доля, а не сумма.
  final bool percent;
}

List<_Mention> _mentions(String text) {
  final out = <_Mention>[];
  for (final m in _number.allMatches(text)) {
    final digits = m.group(1)!.replaceAll(RegExp(r'\D'), '');
    final fraction = m.group(2);
    final word = m.group(3)?.toLowerCase();
    final multiplier = word == null ? 1.0 : (word.startsWith('млн') || word.startsWith('миллион') ? 1000000.0 : 1000.0);
    final value = double.parse(fraction == null ? digits : '$digits.$fraction') * multiplier;
    var tolerance = 0.5 * multiplier / (fraction == null ? 1 : (fraction.length == 1 ? 10 : 100));
    if (_approx.hasMatch(text.substring(0, m.start))) tolerance = tolerance < value * 0.03 ? value * 0.03 : tolerance;
    out.add(_Mention(
      value,
      tolerance,
      text.substring(m.start, m.end).trim(),
      grouped: digits.length > 3 && m.group(1)!.length > digits.length,
      currency: _currency.hasMatch(text.substring(m.end)),
      percent: RegExp(r'^\s*%').hasMatch(text.substring(m.end)),
    ));
  }
  return out;
}

/// Все числа из данных: значения, числа внутри названий и заметок, и суммы
/// по спискам (итог по всем категориям, всем платежам, всем счетам).
void _collect(Object? node, List<double> into) {
  if (node is num) {
    into.add(node.abs().toDouble());
  } else if (node is String) {
    // Даты и периоды («2026-10-25») — не суммы.
    if (RegExp(r'^\d{4}-\d{2}(-\d{2})?$').hasMatch(node)) return;
    into.addAll(_mentions(node).map((m) => m.value));
  } else if (node is Map) {
    for (final v in node.values) {
      _collect(v, into);
    }
  } else if (node is List) {
    final totals = <String, double>{};
    for (final item in node) {
      _collect(item, into);
      if (item is Map) {
        for (final e in item.entries) {
          if (e.value is num) totals.update('${e.key}', (s) => s + (e.value as num), ifAbsent: () => (e.value as num).toDouble());
        }
      }
    }
    into.addAll(totals.values.map((v) => v.abs()));
  }
}

/// Суммы из [answer], которых нет в данных: ни среди чисел [context] и
/// [texts] (вопрос и прошлые реплики), ни как сумма или разность двух из них.
/// Возвращаются в том виде, как написаны в ответе, без повторов.
List<String> unverifiedAmounts(String answer, {required Map<String, dynamic> context, Iterable<String> texts = const []}) {
  final base = <double>[0];
  _collect(context, base);
  for (final t in texts) {
    base.addAll(_mentions(t).map((m) => m.value));
  }
  bool known(_Mention m) {
    bool near(double x) => (x - m.value).abs() <= m.tolerance;
    for (final a in base) {
      if (near(a)) return true;
    }
    for (var i = 0; i < base.length; i++) {
      for (var j = i; j < base.length; j++) {
        if (near(base[i] + base[j]) || near((base[i] - base[j]).abs())) return true;
      }
    }
    return false;
  }

  final out = <String>[];
  for (final m in _mentions(answer)) {
    // Сумма — число со знаком денег или с разбивкой на тысячи («230 439»);
    // годы, проценты, количества и номера дней сюда не попадают.
    if ((!m.currency && !m.grouped) || m.percent) continue;
    if (known(m)) continue;
    final shown = m.currency ? '${m.text} ₸' : m.text;
    if (!out.contains(shown)) out.add(shown);
  }
  return out;
}
