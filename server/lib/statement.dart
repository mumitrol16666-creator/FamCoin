/// Выписка Kaspi Gold: из слов PDF — в строки операций (D94).
///
/// Выписка — таблица «Дата · Сумма · Операция · Детали» и блок итогов над ней
/// («Доступно на …», «Пополнения», «Покупки» …). Таблица собирается по
/// координатам слов: строка начинается с даты в левой колонке, длинные ячейки
/// переносятся на соседние строки и возвращаются в свою операцию.
///
/// Разбор проверяет себя сам: остаток на начало плюс все операции должен дать
/// остаток на конец. Не сошлось — выписка не принимается вовсе: записать
/// половину операций «как получилось» хуже, чем не записать ничего.
library;

import 'dart:math';

import 'package:famcoin_core/famcoin_core.dart';

import 'pdf_words.dart';

/// Вид операции — как его называет сама выписка.
enum RowKind {
  /// Покупка; с плюсом — возврат покупки.
  purchase,

  /// Перевод другому человеку.
  transfer,

  /// Пополнение: перевод от человека, с карты другого банка, через банкомат.
  topup,

  /// Снятие наличных.
  withdrawal,

  /// «Разное»: комиссии и прочие служебные операции.
  other,

  /// Перевод на свой счёт (депозит) — не расход.
  ownOut,

  /// Поступление со своего счёта — не доход.
  ownIn,

  /// Зачисление кредита — не доход.
  credit,

  /// Название операции не узнано (выписка на другом языке).
  unknown,
}

class StatementRow {
  const StatementRow(this.date, this.amount, this.kind, this.operation, this.details);

  factory StatementRow.fromJson(List<dynamic> j) =>
      StatementRow(dateFromJson(j[0]), parseMinor(j[1]), RowKind.values.byName(j[2] as String), j[3] as String, j[4] as String);

  final DateTime date;

  /// В тиынах со знаком: минус — деньги ушли со счёта.
  final int amount;
  final RowKind kind;

  /// Название операции и детали — как в выписке.
  final String operation;
  final String details;

  List<Object?> toJson() => [dateToJson(date), amount.toString(), kind.name, operation, details];
}

class BankStatement {
  const BankStatement({required this.rows, required this.from, required this.to, this.opening, this.closing, this.language = 'ru'});

  factory BankStatement.fromJson(Map<String, dynamic> j) => BankStatement(
        rows: [for (final r in j['rows'] as List) StatementRow.fromJson(r as List)],
        from: dateFromJson(j['from']),
        to: dateFromJson(j['to']),
        opening: j['opening'] == null ? null : parseMinor(j['opening']),
        closing: j['closing'] == null ? null : parseMinor(j['closing']),
        language: j['language'] as String? ?? 'ru',
      );

  /// Операции от старых к новым.
  final List<StatementRow> rows;

  /// Период выписки, обе даты включительно.
  final DateTime from;
  final DateTime to;

  /// Остатки на начало и на конец периода по выписке; заданы только вместе
  /// и только когда сошлись с операциями. `null` — блока итогов не нашлось.
  final int? opening;
  final int? closing;

  /// Язык выписки по заголовку таблицы: `ru`, `kk`, `en`.
  final String language;

  /// Итоги выписки сошлись с её операциями — ей можно верить до тиына.
  bool get balanced => opening != null && closing != null;

  Map<String, Object?> toJson() => {
        'rows': [for (final r in rows) r.toJson()],
        'from': dateToJson(from),
        'to': dateToJson(to),
        if (opening != null) 'opening': opening.toString(),
        if (closing != null) 'closing': closing.toString(),
        'language': language,
      };
}

/// Файл не разобран. [code]: `noTable` — это не выписка Kaspi Gold; `noRows`
/// — в таблице нет операций; `badRows` — часть строк не прочиталась;
/// `mismatch` — операции не сошлись с итогами выписки; `tooMany` — слишком
/// длинный период; `currency` — счёт не в тенге.
class StatementError implements Exception {
  const StatementError(this.code, {this.detail = ''});
  final String code;
  final String detail;
  @override
  String toString() => 'StatementError($code${detail.isEmpty ? '' : ': $detail'})';
}

// ---------------------------------------------------------------- слова

/// Неразрывные и узкие пробелы; типографские минус и тире.
final _spaces = RegExp('[\u00a0\u2007\u2009\u202f]');
final _dashes = RegExp('[\u2212\u2012\u2013\u2014]');

String _clean(String s) => s.replaceAll(_spaces, ' ').replaceAll(_dashes, '-').trim();

String _lower(String s) => s.toLowerCase().replaceAll('ё', 'е').replaceAll(RegExp(r'\s+'), ' ').trim();

final _dateWord = RegExp(r'^(\d{2})\.(\d{2})\.(\d{4}|\d{2})$');
final _dateInText = RegExp(r'(?<!\d)(\d{2})\.(\d{2})\.(\d{4}|\d{2})(?!\d)');

/// Сумма: «- 11 470,08 ₸», «+ 3 627,58 ₸», «7,66 ₸». Число не может начинаться
/// посреди другого числа или сразу за точкой даты.
const _amountBody = r'(?:([+-])\s?)?(?<![\d.,])(\d{1,3}(?: \d{3})+|\d+),(\d{2})(?!\d)';
final _amount = RegExp(_amountBody);
final _amountAtStart = RegExp('^$_amountBody(?:\\s?(₸|KZT|тг|[^\\s\\p{L}\\p{N}(]{1,2})(?=\\s|\$))?', unicode: true);

/// Сумма в валюте покупки под суммой в тенге: «(- 23,20 USD)».
final _foreign = RegExp(r'\(\s*[+-]?\s?([\d ]+,\d{2})\s*([A-Z]{3})\s*\)');

int _minor(RegExpMatch m) {
  final value = int.parse(m[2]!.replaceAll(' ', '')) * 100 + int.parse(m[3]!);
  return m[1] == '-' ? -value : value;
}

DateTime? _date(RegExpMatch m) {
  final year = m[3]!.length == 2 ? 2000 + int.parse(m[3]!) : int.parse(m[3]!);
  final month = int.parse(m[2]!);
  final day = int.parse(m[1]!);
  final d = DateTime(year, month, day);
  return d.month == month && d.day == day && year >= 2000 && year <= 2200 ? d : null;
}

/// Слова одной строки текста на странице.
class _Line {
  _Line(PdfWord first)
      : page = first.page,
        words = [first],
        y = first.yMid,
        h = first.height;

  final int page;
  final List<PdfWord> words;

  /// Средняя линия и высота строки.
  double y;
  double h;

  /// Слова одной строки стоят на одной линии почти точно; ячейка, перенесённая
  /// на полстроки выше или ниже (выравнивание по середине), — уже другая строка.
  bool fits(PdfWord w) => w.page == page && (w.yMid - y).abs() <= 0.3 * max(2.0, min(h, w.height));

  void add(PdfWord w) {
    words.add(w);
    y += (w.yMid - y) / words.length;
    h = max(h, w.height);
  }

  void sort() => words.sort((a, b) => a.x0.compareTo(b.x0));

  String get text => words.map((w) => w.text).join(' ');
}

List<_Line> _lines(List<PdfWord> words) {
  final sorted = [...words]..sort((a, b) => a.page != b.page ? a.page.compareTo(b.page) : a.yMid.compareTo(b.yMid));
  final lines = <_Line>[];
  for (final w in sorted) {
    if (lines.isNotEmpty && lines.last.fits(w)) {
      lines.last.add(w);
    } else {
      lines.add(_Line(w));
    }
  }
  for (final l in lines) {
    l.sort();
  }
  return lines;
}

// ------------------------------------------------------- заголовок таблицы

const _headDate = {'дата': 'ru', 'date': 'en', 'күні': 'kk'};
const _headAmount = {'сумма', 'amount', 'сомасы'};
const _headOperation = {'операция', 'transaction', 'operation'};
const _headDetails = {'детали', 'details', 'толығырақ'};

class _Header {
  const _Header(this.y, this.h, this.xOperation, this.xDetails, this.language);
  final double y;
  final double h;
  final double xOperation;
  final double xDetails;
  final String language;
}

_Header? _header(_Line line) {
  PdfWord? find(bool Function(String) test, double after) {
    for (final w in line.words) {
      if (w.x0 > after && test(_lower(w.text))) return w;
    }
    return null;
  }

  final date = find(_headDate.containsKey, -1);
  if (date == null) return null;
  final amount = find(_headAmount.contains, date.x0);
  final operation = amount == null ? null : find(_headOperation.contains, amount.x0);
  final details = operation == null ? null : find(_headDetails.contains, operation.x0);
  if (details == null) return null;
  return _Header(line.y, line.h, operation!.x0, details.x0, _headDate[_lower(date.text)]!);
}

// ------------------------------------------------------------- операции

/// Названия операций по убыванию длины: «перевод на свой счет» раньше, чем
/// «перевод». Казахские и английские — как их пишет приложение банка на этих
/// языках, насколько известно; неузнанное название — [RowKind.unknown].
const _operations = <String, RowKind>{
  'поступление со своего счета': RowKind.ownIn,
  'перевод на свой счет': RowKind.ownOut,
  'зачисление кредита': RowKind.credit,
  'пополнение': RowKind.topup,
  'покупка': RowKind.purchase,
  'перевод': RowKind.transfer,
  'снятие': RowKind.withdrawal,
  'разное': RowKind.other,
  'сатып алу': RowKind.purchase,
  'толықтыру': RowKind.topup,
  'аударым': RowKind.transfer,
  'ақша алу': RowKind.withdrawal,
  'әртүрлі': RowKind.other,
  'replenishment': RowKind.topup,
  'withdrawal': RowKind.withdrawal,
  'purchase': RowKind.purchase,
  'transfer': RowKind.transfer,
  'top-up': RowKind.topup,
  'others': RowKind.other,
  'other': RowKind.other,
};

/// Вид операции и остаток текста после её названия (он относится к деталям).
(RowKind, String name, String rest) _operation(String text) {
  final low = _lower(text);
  for (final e in _operations.entries) {
    if (!low.startsWith(e.key)) continue;
    final after = low.length == e.key.length ? '' : low[e.key.length];
    if (after.isNotEmpty && RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(after)) continue;
    // Название и остаток — в исходном написании: длины с `low` совпадают,
    // кроме сжатых пробелов, поэтому режем по словам.
    final count = e.key.split(' ').length;
    final parts = text.trim().split(RegExp(r'\s+'));
    return (e.value, parts.take(count).join(' '), parts.skip(count).join(' '));
  }
  return (RowKind.unknown, text.trim(), '');
}

/// Свои счета на другом языке выписки узнаются по словам названия.
final _ownWords = RegExp(r'(?<!\p{L})(свой|своего|own|өз)(?!\p{L})', unicode: true);

class _Row {
  _Row(this.line, this.dateWord, this.date);
  final _Line line;
  final PdfWord dateWord;
  final DateTime date;

  /// Слова соседних строк, отнесённые к этой операции: (линия, слово).
  final extra = <(double, PdfWord)>[];
}

/// Знаки и коды других валют сразу за суммой: такая выписка — по счёту не в
/// тенге, и её суммы нельзя записывать как тенге.
final _otherCurrency = RegExp(r'^(\$|€|£|¥|₽|USD|EUR|RUB|GBP|CNY|KGS|UZS|TRY|AED)$');

/// Сколько слов в начале строки занимает сумма; `null` — суммы там нет.
(int minor, bool signed, int consumed)? _amountPrefix(List<PdfWord> words) {
  final texts = [for (final w in words) w.text];
  final m = _amountAtStart.firstMatch(texts.join(' '));
  if (m == null) return null;
  var consumed = 0;
  var pos = 0;
  for (final t in texts) {
    if (pos + t.length > m.end) break;
    consumed++;
    pos += t.length + 1;
  }
  // Знак валюты мог прочитаться буквой («T»): одиночный знак вплотную за
  // суммой — это он. Буква поодаль — уже начало деталей («С Kaspi Депозита»).
  final next = consumed < texts.length ? texts[consumed] : '';
  if (_otherCurrency.hasMatch(m[4] ?? next)) throw const StatementError('currency');
  if (m[4] == null && consumed > 0 && next.length == 1) {
    final sign = words[consumed];
    if (sign.x0 - words[consumed - 1].x1 <= sign.height) consumed++;
  }
  return (_minor(m), m[1] != null, consumed);
}

/// Самое частое значение среди близких (в пределах [tolerance]) — начало
/// колонки, выровненной по левому краю. `null` — выраженного значения нет.
double? _commonStart(List<double> xs, int rows, {double tolerance = 2.5}) {
  if (xs.isEmpty) return null;
  xs.sort();
  var bestStart = 0;
  var bestCount = 0;
  var start = 0;
  for (var i = 1; i <= xs.length; i++) {
    if (i < xs.length && xs[i] - xs[i - 1] <= tolerance) continue;
    if (i - start > bestCount) {
      bestCount = i - start;
      bestStart = start;
    }
    start = i;
  }
  if (bestCount < max(2, (rows * 0.4).ceil())) return null;
  return xs[bestStart];
}

/// Разбирает выписку из слов PDF. Бросает [StatementError], если это не
/// выписка Kaspi Gold или она не сошлась сама с собой.
BankStatement parseStatement(List<PdfWord> input, {int maxRows = 3000}) {
  final words = [
    for (final w in input)
      if (_clean(w.text).isNotEmpty) PdfWord(w.page, w.x0, w.y0, w.x1, w.y1, _clean(w.text)),
  ];
  final lines = _lines(words);

  final headers = <int, _Header>{};
  for (final line in lines) {
    final h = _header(line);
    if (h != null) headers.putIfAbsent(line.page, () => h);
  }
  if (headers.isEmpty) throw const StatementError('noTable');
  final firstPage = headers.keys.reduce(min);
  final head = headers[firstPage]!;

  // Всё выше заголовка на его странице и страницы до неё — шапка с итогами;
  // ниже — таблица. На следующих страницах заголовок может повторяться.
  final summary = <_Line>[];
  final table = <_Line>[];
  for (final line in lines) {
    final h = headers[line.page];
    if (line.page < firstPage) {
      summary.add(line);
    } else if (h != null && line.y <= h.y + 0.5 * h.h) {
      if (line.page == firstPage && line.y < h.y - 0.5 * h.h) summary.add(line);
    } else {
      table.add(line);
    }
  }

  DateTime? dateOf(_Line l) {
    final w = l.words.first;
    final m = _dateWord.firstMatch(w.text);
    return m == null || w.x0 >= head.xOperation ? null : _date(m);
  }

  final rows = <_Row>[];
  final rowOf = <_Line, _Row>{};
  for (final line in table) {
    final d = dateOf(line);
    if (d == null) continue;
    final row = _Row(line, line.words.first, d);
    rows.add(row);
    rowOf[line] = row;
  }
  if (rows.isEmpty) throw const StatementError('noRows');
  if (rows.length > maxRows) throw const StatementError('tooMany');

  // Где начинаются колонки «Операция» и «Детали» — по самим строкам: у
  // заголовка выравнивание может быть другим, чем у ячеек.
  final opStarts = <double>[];
  final detailStarts = <double>[];
  var heights = 0.0;
  for (final r in rows) {
    heights += r.dateWord.height;
    final rest = r.line.words.sublist(1);
    final a = _amountPrefix(rest);
    if (a == null || a.$3 >= rest.length) continue;
    opStarts.add(rest[a.$3].x0);
    for (var i = a.$3 + 1; i < rest.length; i++) {
      detailStarts.add(rest[i].x0);
    }
  }
  final h = heights / rows.length;
  final tolerance = max(2.0, 0.35 * h);
  var xOperation = _commonStart(opStarts, rows.length) ?? head.xOperation;
  var xDetails = _commonStart(detailStarts.where((x) => x > xOperation + 8).toList(), rows.length) ?? head.xDetails;
  if (xDetails <= xOperation + 8) {
    xOperation = head.xOperation;
    xDetails = head.xDetails;
  }
  final leftOfOperation = xOperation - tolerance;
  final leftOfDetails = xDetails - tolerance;

  // Ячейки бывают выровнены по верху строки (перенос уходит вниз) или по её
  // середине (перенос расходится вверх и вниз от строки с датой). Во втором
  // случае у двухстрочной операции на строке с датой нет её названия.
  // Смотрим только на строки с суммой: строка с одной датой может оказаться
  // не операцией, а подписью под таблицей.
  bool hasOperation(_Line l) => l.words.skip(1).any((w) => w.x0 >= leftOfOperation && w.x0 < leftOfDetails);
  var centered = rows.any((r) => _amountPrefix(r.line.words.sublist(1)) != null && !hasOperation(r.line));
  if (!centered) {
    final firstRow = rows.first.line;
    centered = table.any((l) => l.page == firstRow.page && l.y < firstRow.y && firstRow.y - l.y <= 2.2 * h && l.words.any((w) => w.x0 >= leftOfOperation));
  }

  if (centered) {
    final byPage = <int, List<_Row>>{};
    for (final r in rows) {
      byPage.putIfAbsent(r.line.page, () => []).add(r);
    }
    for (final line in table) {
      if (rowOf.containsKey(line)) continue;
      _Row? nearest;
      var best = double.infinity;
      for (final r in byPage[line.page] ?? const <_Row>[]) {
        final d = (r.line.y - line.y).abs();
        if (d < best) {
          best = d; // при равенстве остаётся верхняя строка: она встретилась раньше
          nearest = r;
        }
      }
      if (nearest != null && best <= 3.5 * h) nearest.extra.addAll([for (final w in line.words) (line.y, w)]);
    }
  } else {
    _Row? current;
    var lastY = 0.0;
    for (final line in table) {
      final row = rowOf[line];
      if (row != null) {
        current = row;
        lastY = line.y;
        continue;
      }
      if (current == null || line.page != current.line.page) {
        current = null;
        continue;
      }
      // Перенос идёт с обычным шагом строк; текст дальше — уже не эта ячейка
      // (подвал страницы, подпись банка).
      if (line.y - lastY > 1.9 * max(line.h, h)) {
        current = null;
        continue;
      }
      current.extra.addAll([for (final w in line.words) (line.y, w)]);
      lastY = line.y;
    }
  }

  final parsed = <StatementRow>[];
  var bad = 0;
  for (final r in rows) {
    final rest = r.line.words.sublist(1);
    final prefix = _amountPrefix(rest);
    final onLine = prefix == null ? rest : rest.sublist(prefix.$3);
    // Слова операции: со строки с датой и с соседних строк, по порядку чтения.
    final cells = [for (final w in onLine) (r.line.y, w), ...r.extra]..sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.x0.compareTo(b.$2.x0));
    final amountWords = <String>[];
    final operationWords = <String>[];
    final detailWords = <String>[];
    for (final (y, w) in cells) {
      if (w.x0 >= leftOfDetails) {
        detailWords.add(w.text);
      } else if (w.x0 >= leftOfOperation || (y == r.line.y && prefix != null)) {
        operationWords.add(w.text);
      } else {
        amountWords.add(w.text);
      }
    }
    final beside = amountWords.join(' ');
    int? amount = prefix?.$1;
    var signed = prefix?.$2 ?? false;
    if (amount == null) {
      // Сумма в две строки (тенге и валюта покупки) при выравнивании по
      // середине: на строке с датой её нет, она рядом.
      final m = _amount.firstMatch(beside.replaceAll(_foreign, ' '));
      if (m != null) {
        amount = _minor(m);
        signed = m[1] != null;
      }
    }
    if (amount == null) {
      bad++;
      continue;
    }
    final operation = operationWords.join(' ');
    var (kind, name, tail) = _operation(operation);
    // Без знака в выписке — по смыслу операции: покупки и переводы уходят.
    if (!signed && amount > 0 && kind != RowKind.topup && kind != RowKind.ownIn && kind != RowKind.credit) amount = -amount;
    if ((kind == RowKind.unknown || kind == RowKind.transfer || kind == RowKind.topup) && _ownWords.hasMatch(_lower(operation))) {
      // «Transfer to own account»: название целиком — про свой счёт.
      kind = amount < 0 ? RowKind.ownOut : RowKind.ownIn;
      name = operation.trim();
      tail = '';
    }
    var details = [tail, detailWords.join(' ')].where((s) => s.isNotEmpty).join(' ');
    final foreign = _foreign.firstMatch(beside);
    if (foreign != null) details = '$details (${foreign[1]!.trim()} ${foreign[2]})'.trim();
    if (amount == 0) continue;
    if (amount.abs() > maxAmount) {
      bad++;
      continue;
    }
    parsed.add(StatementRow(r.date, amount, kind, name, details));
  }
  if (parsed.isEmpty) throw StatementError(bad > 0 ? 'badRows' : 'noRows', detail: bad > 0 ? '$bad из ${rows.length}' : '');

  // Банк печатает новые операции сверху; в журнал они идут от старых к новым.
  final ordered = parsed.first.date.isAfter(parsed.last.date) ? parsed.reversed.toList() : parsed;
  var from = ordered.map((r) => r.date).reduce((a, b) => a.isBefore(b) ? a : b);
  var to = ordered.map((r) => r.date).reduce((a, b) => a.isAfter(b) ? a : b);

  // Шапка: период и остатки «Доступно на <дата>».
  DateTime? periodFrom;
  DateTime? periodTo;
  final balances = <(DateTime, int)>[];
  for (final line in summary) {
    final text = line.text;
    final dates = [for (final m in _dateInText.allMatches(text)) _date(m)].whereType<DateTime>().toList();
    final amounts = _amount.allMatches(text).toList();
    if (amounts.isEmpty) {
      if (periodFrom == null && dates.length >= 2) {
        periodFrom = dates[0].isBefore(dates[1]) ? dates[0] : dates[1];
        periodTo = dates[0].isBefore(dates[1]) ? dates[1] : dates[0];
      }
      continue;
    }
    var start = 0;
    for (final m in amounts) {
      final label = text.substring(start, m.start);
      start = m.end;
      final d = _dateInText.firstMatch(label);
      final date = d == null ? null : _date(d);
      if (date != null) balances.add((date, _minor(m)));
    }
  }
  if (periodFrom != null && !periodFrom.isAfter(from)) from = periodFrom;
  if (periodTo != null && !periodTo.isBefore(to)) to = periodTo;

  // Остатки на начало и на конец — та пара, что сходится с операциями: в
  // шапке бывают и другие суммы с датами. Суммы с датами есть, а пары нет —
  // значит, часть операций прочитана неверно.
  int? opening;
  int? closing;
  final total = ordered.fold<int>(0, (s, r) => s + r.amount);
  search:
  for (var i = 0; i < balances.length; i++) {
    for (var j = 0; j < balances.length; j++) {
      if (i == j || balances[i].$1.isAfter(balances[j].$1) || (balances[i].$1 == balances[j].$1 && i > j)) continue;
      if ((balances[i].$2 + total - balances[j].$2).abs() > 1) continue;
      opening = balances[i].$2;
      closing = balances[j].$2;
      if (balances[i].$1.isBefore(from)) from = balances[i].$1;
      if (balances[j].$1.isAfter(to)) to = balances[j].$1;
      break search;
    }
  }
  if (opening == null && balances.length >= 2) {
    throw StatementError('mismatch', detail: '${balances.first.$2 + total - balances.last.$2}');
  }
  // Строка с датой, но без суммы. Когда итоги сошлись, это не операция, а
  // посторонний текст с датой в начале (подпись, справка о счёте в том же
  // файле): потерянная операция нарушила бы равенство. Без итогов проверить
  // это нечем — такая выписка не принимается.
  if (opening == null && bad > 0) throw StatementError('badRows', detail: '$bad из ${rows.length}');
  return BankStatement(rows: ordered, from: from, to: to, opening: opening, closing: closing, language: head.language);
}

// ---------------------------------------------------------- диагностика

const _plainWords = {
  'дата', 'сумма', 'операция', 'детали', 'date', 'amount', 'transaction', 'details', 'күні', 'сомасы', 'толығырақ', //
  'покупка', 'перевод', 'пополнение', 'снятие', 'разное', 'поступление', 'зачисление', 'кредита', 'на', 'свой', 'счет', 'со', 'своего', 'счета', //
  'доступно', 'пополнения', 'переводы', 'покупки', 'снятия', 'выписка', 'по', 'за', 'период', 'с', 'kaspi', 'gold',
};

/// Строение файла без его содержания — для журнала, когда выписка не
/// разобралась: буквы заменены на `x`, цифры на `9`, остаются только общие
/// слова таблицы и положение слов. Имён, сумм и номеров здесь нет.
String maskedLayout(List<PdfWord> input, {int maxLines = 70}) {
  final lines = _lines([
    for (final w in input)
      if (_clean(w.text).isNotEmpty) PdfWord(w.page, w.x0, w.y0, w.x1, w.y1, _clean(w.text)),
  ]);
  var first = lines.indexWhere((l) => _header(l) != null);
  if (first < 0) first = 0;
  final out = <String>[];
  for (final l in lines.skip(max(0, first - 25)).take(maxLines)) {
    final cells = [
      for (final w in l.words)
        '${w.x0.round()}:${_plainWords.contains(_lower(w.text)) ? w.text : w.text.replaceAll(RegExp(r'\p{L}', unicode: true), 'x').replaceAll(RegExp(r'\d'), '9')}',
    ];
    out.add('p${l.page} y${l.y.round()} h${l.h.round()} | ${cells.join(' ')}');
  }
  return out.join('\n');
}
