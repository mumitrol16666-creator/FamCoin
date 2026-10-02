/// Проверка сумм в ответе консультанта кодом (D91, D93).
///
/// Правило «любое число — из данных приложения» записано в подсказке модели,
/// но подсказка — не гарантия. Здесь оно проверяется. Сумма из ответа
/// подтверждена, только если выполняется одно из двух:
///
///  1. ровно такое число модель видела — оно есть в сводке, в вопросе или в
///     прошлых репликах;
///  2. модель указала, как сумма получена (`calc` — путь к полю данных или
///     арифметическое выражение из таких путей), и сервер, посчитав выражение
///     сам, получил то же число.
///
/// Угадываний больше нет: раньше круглое число проходило, если случайно
/// совпадало с суммой двух любых чисел из данных. Теперь расчёт должен быть
/// предъявлен, а считает его код. Что проверка не ловит: модель может взять
/// настоящее число не из того поля — смысл фразы код не проверяет.
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

/// Все числа из данных как они есть: значения полей и числа внутри названий
/// и заметок («Ремонт 30000»).
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
    for (final item in node) {
      _collect(item, into);
    }
  }
}

/// Как модель объясняет сумму: [text] — как она написана в ответе, [calc] —
/// путь к полю данных или выражение.
class DeclaredNumber {
  const DeclaredNumber(this.text, this.calc);
  final String text;
  final String calc;

  Map<String, String> toJson() => {'text': text, 'calc': calc};
}

// ------------------------------------------------------------- выражения

class _CalcError implements Exception {
  const _CalcError(this.reason);
  final String reason;
}

final _token = RegExp(
  r'\s*(?:'
  r'(\d{1,3}(?:[   ]\d{3})+(?:[.,]\d+)?|\d+(?:[.,]\d+)?)' // 1: число
  r'|([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*|\[[^\]]*\])*)' // 2: путь
  r'|([-+−–*×·/÷:()])' // 3: знак
  r')',
);

/// Разбор и вычисление выражения из путей, чисел и знаков `+ - * / ( )`,
/// плюс `sum(список.поле)`.
class _Calc {
  _Calc(this.source, this.context, this.inData);

  final String source;
  final Map<String, dynamic> context;

  /// Есть ли число, написанное в выражении прямо, в данных или в вопросе.
  /// Иначе допустимы только небольшие целые — количества и проценты: модель
  /// не должна «проводить» через расчёт сумму, которой нигде нет.
  final bool Function(double) inData;

  /// Сколько раз выражение обратилось к данным (поле или число из данных).
  var _grounded = 0;

  late final List<Match> _tokens = _scan();
  var _i = 0;

  List<Match> _scan() {
    // Знаки денег в выражении — не ошибка, просто лишние.
    final text = source.replaceAll(RegExp(r'₸|тенге|теңге', caseSensitive: false), ' ').trim();
    final out = <Match>[];
    var at = 0;
    while (at < text.length) {
      final m = _token.matchAsPrefix(text, at);
      if (m == null || m.end == at) throw const _CalcError('непонятный знак');
      out.add(m);
      at = m.end;
      while (at < text.length && text[at].trim().isEmpty) {
        at++;
      }
    }
    return out;
  }

  String? get _sign => _i < _tokens.length ? _tokens[_i].group(3) : null;

  double run() {
    if (_tokens.isEmpty) throw const _CalcError('пусто');
    final v = _sum();
    if (_i != _tokens.length) throw const _CalcError('лишнее в конце');
    // «100 * 350» — арифметика без единого числа из данных: это не расчёт
    // по данным, а способ получить любое число.
    if (_grounded == 0) throw const _CalcError('расчёт не опирается на данные');
    return v;
  }

  double _sum() {
    var v = _product();
    while (_sign != null && '+-−–'.contains(_sign!)) {
      final minus = _sign != '+';
      _i++;
      final r = _product();
      v = minus ? v - r : v + r;
    }
    return v;
  }

  double _product() {
    var v = _unary();
    while (_sign != null && '*×·/÷:'.contains(_sign!)) {
      final divide = '/÷:'.contains(_sign!);
      _i++;
      final r = _unary();
      if (divide && r == 0) throw const _CalcError('деление на ноль');
      v = divide ? v / r : v * r;
    }
    return v;
  }

  double _unary() {
    if (_sign != null && '-−–'.contains(_sign!)) {
      _i++;
      return -_unary();
    }
    return _atom();
  }

  double _atom() {
    if (_i >= _tokens.length) throw const _CalcError('оборвано');
    final t = _tokens[_i];
    if (t.group(3) == '(') {
      _i++;
      final v = _sum();
      if (_sign != ')') throw const _CalcError('нет закрывающей скобки');
      _i++;
      return v;
    }
    final number = t.group(1);
    if (number != null) {
      _i++;
      final v = double.parse(number.replaceAll(RegExp(r'[   ]'), '').replaceAll(',', '.'));
      if (inData(v)) {
        _grounded++;
      } else if (!((v == v.roundToDouble() && v <= 366) || v == 1000)) {
        // Небольшие целые — количества (месяцев, дней) и проценты; 1000 —
        // перевод «тысяч» в тенге. Остальное должно быть в данных.
        throw const _CalcError('число не из данных');
      }
      return v;
    }
    final path = t.group(2);
    if (path == null) throw const _CalcError('ожидалось число или поле');
    _i++;
    if (path == 'sum') {
      if (_sign != '(') throw const _CalcError('sum без скобок');
      _i++;
      final inner = _i < _tokens.length ? _tokens[_i].group(2) : null;
      if (inner == null) throw const _CalcError('sum без списка');
      _i++;
      if (_sign != ')') throw const _CalcError('нет закрывающей скобки');
      _i++;
      final values = _resolve(inner);
      if (values is! List<double>) throw const _CalcError('sum не по списку');
      _grounded++;
      return values.fold(0, (a, b) => a + b);
    }
    final v = _resolve(path);
    if (v is! double) throw const _CalcError('поле — список, а не число');
    _grounded++;
    return v;
  }

  /// Значение по пути: число или (если путь идёт через список без номера)
  /// список чисел — для `sum(...)`.
  Object _resolve(String path) {
    Object? node = context;
    var many = false; // прошли через список без выбора элемента
    for (final seg in RegExp(r'\.?([A-Za-z_][A-Za-z0-9_]*)|\[([^\]]*)\]').allMatches(path)) {
      final key = seg.group(1);
      if (key != null) {
        if (many) {
          node = [for (final item in node as List) item is Map ? item[key] : null];
        } else if (node is Map) {
          node = node[key];
        } else if (node is List) {
          many = true;
          node = [for (final item in node) item is Map ? item[key] : null];
        } else {
          throw _CalcError('нет поля $key');
        }
        continue;
      }
      final selector = seg.group(2)!.trim();
      // «categoryLimits[name=Продукты]», когда список лежит на уровень глубже
      // и он там один: модель часто пропускает такой промежуточный ключ.
      if (!many && node is Map) {
        final lists = node.values.whereType<List>().toList();
        if (lists.length == 1) node = lists.single;
      }
      if (many || node is! List) throw const _CalcError('номер не у списка');
      final index = int.tryParse(selector);
      if (index != null) {
        if (index < 0 || index >= node.length) throw const _CalcError('нет такого номера в списке');
        node = node[index];
      } else {
        // «[name=Продукты]» или просто «[Продукты]». Модель не всегда помнит,
        // как называется поле с названием (name, category…), поэтому, если по
        // указанному полю строки нет, ищем это название в любом текстовом поле.
        final eq = selector.indexOf('=');
        final field = eq > 0 ? selector.substring(0, eq).trim() : null;
        final wanted = selector.substring(eq + 1).trim().replaceAll(RegExp('^["\'«]|["\'»]\$'), '').toLowerCase();
        if (wanted.isEmpty) throw const _CalcError('непонятный выбор из списка');
        bool same(Object? v) => v is String && v.trim().toLowerCase() == wanted;
        var found = field == null ? const <dynamic>[] : node.where((item) => item is Map && same(item[field])).toList();
        if (found.isEmpty) found = node.where((item) => item is Map && item.values.any(same)).toList();
        if (found.isEmpty) throw const _CalcError('в списке нет такой строки');
        node = found.first;
      }
    }
    if (many) {
      final list = node as List;
      if (list.any((x) => x is! num)) throw const _CalcError('в списке не только числа');
      return [for (final x in list) (x as num).toDouble()];
    }
    if (node is! num) throw const _CalcError('поле пустое или не число');
    return node.toDouble();
  }
}

/// Считает [calc] по [context]. `null` — выражение не разобрать, поля нет или
/// в нём число, которого нет ни в данных, ни в [extra] (числа из вопроса).
double? evaluateCalc(String calc, Map<String, dynamic> context, {Iterable<double> extra = const []}) {
  final known = <double>[...extra];
  _collect(context, known);
  try {
    return _Calc(calc, context, (v) => known.any((k) => (k - v).abs() < 0.005)).run();
  } on _CalcError {
    return null;
  } on FormatException {
    return null;
  }
}

/// Суммы из [answer], которые не подтверждены: такого числа нет ни в
/// [context], ни в [texts] (вопрос и прошлые реплики), и ни одно объяснение
/// из [numbers] не даёт его при пересчёте. Возвращаются в том виде, как
/// написаны в ответе, без повторов.
List<String> unverifiedAmounts(String answer, {required Map<String, dynamic> context, Iterable<String> texts = const [], List<DeclaredNumber> numbers = const []}) {
  final fromTexts = [for (final t in texts) ..._mentions(t).map((m) => m.value)];
  final known = <double>[0, ...fromTexts];
  _collect(context, known);
  final computed = [
    for (final n in numbers)
      if (evaluateCalc(n.calc, context, extra: fromTexts) case final v?) v.abs(),
  ];

  final out = <String>[];
  for (final m in _mentions(answer)) {
    // Сумма — число со знаком денег или с разбивкой на тысячи («230 439»);
    // годы, проценты, количества и номера дней сюда не попадают.
    if ((!m.currency && !m.grouped) || m.percent) continue;
    bool near(double x) => (x - m.value).abs() <= m.tolerance;
    if (known.any(near) || computed.any(near)) continue;
    final shown = m.currency ? '${m.text} ₸' : m.text;
    if (!out.contains(shown)) out.add(shown);
  }
  return out;
}
