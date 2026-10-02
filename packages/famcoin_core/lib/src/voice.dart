/// Разбор голосовой фразы в черновик операции (раздел 10 карты продукта).
///
/// Только правила и словарь, без ИИ: сумма, тип, категория, счёт, дата,
/// человек. Всё неоднозначное остаётся пустым — пользователь видит черновик
/// и подтверждает его перед записью. Ничего не проводится автоматически.
library;

import 'money.dart';

enum VoiceKind { expense, income, transfer, lendOut, borrow, repaymentReceived, repaymentMade }

class VoiceDraft {
  const VoiceDraft({
    required this.kind,
    this.amount,
    this.category,
    this.accountId,
    this.toAccountId,
    this.date,
    this.person,
    this.note = '',
    this.items = const [],
    this.warnings = const [],
  });

  final VoiceKind kind;

  /// В тиынах; `null`, если сумма не найдена.
  final int? amount;
  final String? category;
  final String? accountId;
  final String? toAccountId;

  /// Смещение в днях от сегодня: 0, −1, −2; `null` — не указано.
  final int? date;
  final String? person;
  final String note;

  /// Несколько позиций в одной фразе: «молоко 800, хлеб 250».
  final List<(String, int)> items;
  final List<String> warnings;

  bool get complete => amount != null && amount! > 0;
}

/// Известный пользователю счёт: id и слова, по которым его узнают.
class VoiceAccount {
  const VoiceAccount(this.id, this.aliases);
  final String id;
  final List<String> aliases;
}

// ----------------------------------------------------------- словари

/// Слово → категория. Ключи в нижнем регистре, без окончаний где возможно.
const Map<String, String> _categoryWords = {
  // еда
  'продукт': 'food', 'магазин': 'food', 'магнум': 'food', 'small': 'food', 'смолл': 'food', 'галмарт': 'food',
  'хлеб': 'food', 'молоко': 'food', 'мясо': 'food', 'овощ': 'food', 'фрукт': 'food', 'яйц': 'food', 'сыр': 'food', 'рынок': 'food', 'базар': 'food',
  'нан': 'food', 'сүт': 'food', 'ет': 'food', 'азық': 'food', 'дүкен': 'food', 'көкөніс': 'food', 'жеміс': 'food',
  // кафе
  'кофе': 'cafe', 'кафе': 'cafe', 'ресторан': 'cafe', 'обед': 'cafe', 'ужин': 'cafe', 'завтрак': 'cafe', 'пицц': 'cafe', 'бургер': 'cafe', 'шаурм': 'cafe', 'донер': 'cafe', 'чай': 'cafe', 'столов': 'cafe', 'доставк': 'cafe', 'wolt': 'cafe', 'глово': 'cafe', 'glovo': 'cafe',
  'түскі': 'cafe', 'кешкі ас': 'cafe', 'дәмхана': 'cafe', 'мейрамхана': 'cafe', 'шай': 'cafe',
  // транспорт
  'такси': 'transport', 'яндекс': 'transport', 'indrive': 'transport', 'индрайв': 'transport', 'автобус': 'transport', 'метро': 'transport', 'бензин': 'transport', 'заправк': 'transport', 'парковк': 'transport', 'проезд': 'transport', 'машин': 'transport', 'мойк': 'transport',
  'жанармай': 'transport', 'көлік': 'transport', 'жол': 'transport',
  // здоровье
  'аптек': 'health', 'лекарств': 'health', 'врач': 'health', 'клиник': 'health', 'стоматолог': 'health', 'больниц': 'health', 'анализ': 'health', 'таблетк': 'health',
  'дәріхана': 'health', 'дәрі': 'health', 'дәрігер': 'health', 'емхана': 'health',
  // дети
  'дет': 'kids', 'ребен': 'kids', 'ребён': 'kids', 'школ': 'kids', 'садик': 'kids', 'кружок': 'kids', 'игрушк': 'kids', 'подгузник': 'kids',
  'бала': 'kids', 'мектеп': 'kids', 'балабақша': 'kids', 'ойыншық': 'kids',
  // жильё и коммунальные
  'аренд': 'home', 'квартир': 'home', 'ипотек': 'home', 'ремонт': 'home', 'мебел': 'home',
  'пәтер': 'home', 'жалдау': 'home', 'жөндеу': 'home',
  'коммунал': 'utilities', 'свет': 'utilities', 'электр': 'utilities', 'вода': 'utilities', 'газ': 'utilities', 'отоплен': 'utilities', 'ксик': 'utilities', 'алсеко': 'utilities',
  'жарық': 'utilities', 'су': 'utilities', 'жылу': 'utilities',
  // связь и подписки
  'связь': 'phone', 'телефон': 'phone', 'билайн': 'phone', 'beeline': 'phone', 'теле2': 'phone', 'tele2': 'phone', 'актив': 'phone', 'activ': 'phone', 'kcell': 'phone', 'кселл': 'phone', 'интернет': 'phone', 'мобильн': 'phone',
  'байланыс': 'phone',
  'подписк': 'subscriptions', 'netflix': 'subscriptions', 'нетфликс': 'subscriptions', 'spotify': 'subscriptions', 'ютуб': 'subscriptions', 'youtube': 'subscriptions', 'кинопоиск': 'subscriptions', 'жазылым': 'subscriptions',
  // быт
  'бытов': 'household', 'химия': 'household', 'порошок': 'household', 'шампун': 'household', 'мыло': 'household', 'посуд': 'household', 'сабын': 'household', 'тұрмыс': 'household',
  // развлечения
  'кино': 'fun', 'театр': 'fun', 'концерт': 'fun', 'игр': 'fun', 'развлеч': 'fun', 'бар': 'fun', 'клуб': 'fun', 'ойын-сауық': 'fun', 'сауық': 'fun',
  // одежда
  'одежд': 'clothes', 'обув': 'clothes', 'куртк': 'clothes', 'кроссовк': 'clothes', 'джинс': 'clothes', 'платье': 'clothes', 'киім': 'clothes', 'аяқ киім': 'clothes',
  // образование и подарки
  'курс': 'education', 'учеб': 'education', 'книг': 'education', 'репетитор': 'education', 'оқу': 'education', 'кітап': 'education',
  'подар': 'gifts', 'сыйлық': 'gifts', 'той': 'gifts', 'свадьб': 'gifts',
};

const Map<String, String> _incomeWords = {
  'зарплат': 'salary', 'аванс': 'salary', 'оклад': 'salary', 'жалақы': 'salary', 'айлық': 'salary',
  'подработк': 'side', 'халтур': 'side', 'фриланс': 'side', 'заказ': 'side', 'қосымша': 'side',
  'кешбэк': 'cashback', 'кэшбек': 'cashback', 'кешбек': 'cashback', 'бонус': 'cashback',
  'процент': 'interestIncome', 'пайыз': 'interestIncome', 'вклад': 'interestIncome', 'депозит': 'interestIncome',
};

const _incomeVerbs = ['получил', 'получила', 'пришл', 'зачисл', 'доход', 'кіріс', 'түсті', 'алдым'];
const _transferVerbs = ['перевел', 'перевёл', 'перевела', 'перекинул', 'перекинула', 'перевод', 'аудардым', 'аударым'];
const _lendVerbs = ['дал в долг', 'дала в долг', 'одолжил', 'одолжила', 'занял ему', 'қарыз бердім', 'в долг'];
const _borrowVerbs = ['взял в долг', 'взяла в долг', 'занял у', 'заняла у', 'занял', 'қарыз алдым'];
const _repayReceivedVerbs = ['вернул мне', 'вернула мне', 'мне вернул', 'мне вернула', 'отдал мне', 'отдала мне', 'қайтарды'];
const _repayMadeVerbs = ['вернул долг', 'вернула долг', 'отдал долг', 'отдала долг', 'вернул', 'вернула', 'қайтардым'];

/// Слова фразы о долге, которые не могут быть именем человека.
const _debtWords = 'дал|дала|взял|взяла|в|долг|долга|одолжил|одолжила|занял|заняла|у|вернул|вернула|отдал|отдала|мне|ему|ей|'
    'қарыз|бердім|алдым|қайтарды|қайтардым|тенге|теңге|тг|с|со|на|из|и|вчера|сегодня|позавчера';

const Map<String, int> _numberWords = {
  'ноль': 0, 'один': 1, 'одна': 1, 'одну': 1, 'два': 2, 'две': 2, 'три': 3, 'четыре': 4, 'пять': 5, 'шесть': 6, 'семь': 7, 'восемь': 8, 'девять': 9,
  'десять': 10, 'одиннадцать': 11, 'двенадцать': 12, 'тринадцать': 13, 'четырнадцать': 14, 'пятнадцать': 15, 'шестнадцать': 16, 'семнадцать': 17, 'восемнадцать': 18, 'девятнадцать': 19,
  'двадцать': 20, 'тридцать': 30, 'сорок': 40, 'пятьдесят': 50, 'шестьдесят': 60, 'семьдесят': 70, 'восемьдесят': 80, 'девяносто': 90,
  'сто': 100, 'двести': 200, 'триста': 300, 'четыреста': 400, 'пятьсот': 500, 'шестьсот': 600, 'семьсот': 700, 'восемьсот': 800, 'девятьсот': 900,
  'бір': 1, 'екі': 2, 'үш': 3, 'төрт': 4, 'бес': 5, 'алты': 6, 'жеті': 7, 'сегіз': 8, 'тоғыз': 9, 'он': 10,
  'жиырма': 20, 'отыз': 30, 'қырық': 40, 'елу': 50, 'алпыс': 60, 'жетпіс': 70, 'сексен': 80, 'тоқсан': 90, 'жүз': 100,
};

const _thousandWords = ['тысяч', 'тысячи', 'тысяча', 'тыс', 'тыщ', 'к', 'k', 'мың'];
const _millionWords = ['миллион', 'миллиона', 'миллионов', 'млн'];
const _halfWords = ['полторы', 'полтора', 'бір жарым'];

/// «Тысяча» в любой форме: тысячи, тысячу, тыщи, тыщу, тыс, к, мың.
bool _isThousand(String w) => _thousandWords.contains(w) || w.startsWith('тысяч') || w.startsWith('тыщ');

// ------------------------------------------------------------- разбор

/// Граница слова для кириллицы: `\b` в Dart работает только с латиницей.
RegExp _word(String w) => RegExp('(?<!\\p{L})(?:$w)(?!\\p{L})', unicode: true);

String _normalize(String s) => s
    .toLowerCase()
    .replaceAll('ё', 'е')
    // Запятая и точка между цифрами — десятичный знак, остальные — пунктуация.
    .replaceAll(RegExp(r'(?<!\d)[,.]|[,.](?!\d)'), ' ')
    .replaceAll(RegExp(r'[;:!?()«»"]'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// Извлекает сумму из фразы; возвращает тиыны и текст без суммы.
(int?, String) _extractAmount(String text) {
  var t = ' $text ';
  // 0. Смешанная форма «тыща 590», «две тыщи 300»: слово-тысяча и цифры
  // сотен — склеиваем в одно число, дальше его разберёт цифровая ветка.
  final mixed = RegExp(r'(?:([а-яё]+)\s+)?(тысяч[а-яё]*|тыщ[а-яё]*)\s+(\d{1,3})(?![\s\d]*\d)');
  final mm = mixed.firstMatch(t);
  if (mm != null) {
    final prefix = mm.group(1);
    final thousands = prefix == null
        ? 1.0
        : _halfWords.contains(prefix)
            ? 1.5
            : _numberWords[prefix]?.toDouble();
    // Перед «тыща» не число («кофе тыща 590») — слово остаётся в тексте.
    final start = thousands == null ? mm.start + prefix!.length + 1 : mm.start;
    final value = ((thousands ?? 1.0) * 1000 + int.parse(mm.group(3)!)).round();
    t = t.replaceRange(start, mm.end, ' $value ');
  }
  // 1. Цифры с пробелами-разделителями: «1 200», «450 000», «1200».
  final digitRe = RegExp(r'(?<!\d)(\d{1,3}(?: \d{3})+|\d+)(?:[.,](\d{1,2}))?\s*(тысяч[а-яё]*|тыс|тыщ[а-яё]*|к|k|мың|млн|миллион[а-яё]*)?(?=\s|$)');
  final m = digitRe.firstMatch(t);
  if (m != null) {
    var units = double.parse(m.group(1)!.replaceAll(' ', '') + (m.group(2) != null ? '.${m.group(2)}' : ''));
    final suffix = m.group(3);
    if (suffix != null) {
      if (_millionWords.any((w) => suffix.startsWith(w))) {
        units *= 1000000;
      } else {
        units *= 1000;
      }
    }
    t = t.replaceRange(m.start, m.end, ' ');
    return ((units * minorPerUnit).round(), t.trim());
  }
  // 2. Числа словами: «двести пятьдесят», «полторы тысячи», «бес мың».
  final words = t.trim().split(' ');
  var total = 0.0;
  var current = 0.0;
  var found = false;
  final used = <int>{};
  for (var i = 0; i < words.length; i++) {
    final w = words[i];
    if (_halfWords.contains(w) || (w == 'бір' && i + 1 < words.length && words[i + 1] == 'жарым')) {
      current = 1.5;
      found = true;
      used.add(i);
      if (w == 'бір') used.add(++i);
    } else if (_numberWords.containsKey(w)) {
      current += _numberWords[w]!;
      found = true;
      used.add(i);
    } else if (_isThousand(w) && (found || w.startsWith('тыс') || w.startsWith('тыщ'))) {
      // «тысячу» без числа перед ним — одна тысяча; короткие «к»/«k» —
      // только после числа, иначе «к обеду» стало бы суммой.
      total += (current == 0 ? 1 : current) * 1000;
      current = 0;
      found = true;
      used.add(i);
    } else if (_millionWords.any((mw) => w.startsWith(mw)) && found) {
      total += (current == 0 ? 1 : current) * 1000000;
      current = 0;
      used.add(i);
    } else if (found && current > 0 && w != 'и') {
      // число закончилось
      break;
    }
  }
  if (!found) return (null, text);
  total += current;
  final rest = [for (var i = 0; i < words.length; i++) if (!used.contains(i)) words[i]].join(' ');
  return ((total * minorPerUnit).round(), rest.trim());
}

int? _extractDate(String text) {
  if (_word('позавчера|алдыңғы күні').hasMatch(text)) return -2;
  if (_word('вчера|кеше').hasMatch(text)) return -1;
  if (_word('сегодня|бүгін').hasMatch(text)) return 0;
  return null;
}

String _stripDate(String text) => text.replaceAll(_word('позавчера|вчера|сегодня|кеше|бүгін|алдыңғы күні'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

bool _hasAny(String text, List<String> phrases) => phrases.any((p) => text.contains(p));

// ------------------------------------------------------- названия счетов

/// Слова, которые встречаются в названиях счетов, но счёт не называют:
/// «Карта для покупок» не должна узнаваться по «для».
const _aliasStopWords = {'для', 'под', 'при', 'про', 'или', 'мой', 'моя', 'мое', 'мои', 'наш', 'это', 'the', 'for', 'and'};

/// Названия, которые по-русски пишут не по буквам: «Jusan» — «Жусан».
const Map<String, String> _brandsLatin = {
  'jusan': 'жусан',
  'freedom': 'фридом',
  'home': 'хоум',
  'visa': 'виза',
  'eurasian': 'евразийский',
  'cash': 'кэш',
};

const Map<String, String> _latinPairs = {'sh': 'ш', 'ch': 'ч', 'zh': 'ж', 'kh': 'х', 'ya': 'я', 'yu': 'ю', 'ts': 'ц'};
const Map<String, String> _latinLetters = {
  'a': 'а', 'b': 'б', 'c': 'к', 'd': 'д', 'e': 'е', 'f': 'ф', 'g': 'г', 'h': 'х', 'i': 'и', 'j': 'дж', 'k': 'к', 'l': 'л', 'm': 'м',
  'n': 'н', 'o': 'о', 'p': 'п', 'q': 'к', 'r': 'р', 's': 'с', 't': 'т', 'u': 'у', 'v': 'в', 'w': 'в', 'x': 'кс', 'y': 'ы', 'z': 'з',
};

/// Латинское слово русскими буквами — так его произносят и так его отдаёт
/// распознавание речи: «Kaspi» → «каспи», «Halyk» → «халык».
String _toCyrillic(String word) {
  final brand = _brandsLatin[word];
  if (brand != null) return brand;
  final out = StringBuffer();
  for (var i = 0; i < word.length; i++) {
    final pair = i + 1 < word.length ? _latinPairs[word.substring(i, i + 2)] : null;
    if (pair != null) {
      out.write(pair);
      i++;
    } else {
      out.write(_latinLetters[word[i]] ?? word[i]);
    }
  }
  return out.toString();
}

/// Шаблоны, по которым название счёта ищется во фразе: само название и его
/// запись русскими буквами. Ищется только целое слово — цифра или слог
/// внутри суммы и чужого слова счётом не считается. Длинное слово может
/// стоять в другом падеже («наличными», «с депозита»).
List<String> _aliasPatterns(String alias) {
  final base = _normalize(alias);
  // Меньше трёх букв (цифра, предлог) или служебное слово — не название.
  if (RegExp(r'\p{L}', unicode: true).allMatches(base).length < 3 || _aliasStopWords.contains(base)) return const [];
  final variants = {base};
  if (RegExp('[a-z]').hasMatch(base)) {
    variants.add(base.split(' ').map((w) => RegExp(r'^[a-z]+$').hasMatch(w) ? _toCyrillic(w) : w).join(' '));
  }
  return [
    for (final v in variants)
      () {
        final words = v.split(' ');
        var last = words.last;
        final cyrillic = RegExp(r'^[а-яәіңғүұқөһ]+$').hasMatch(last);
        // Окончание длинного русского слова отбрасывается: «наличные» → «наличн».
        final stem = cyrillic && last.length >= 6 ? last.replaceFirst(RegExp(r'[аеиоуыэюяй]{1,2}$'), '') : last;
        final inflected = cyrillic && last.length >= 5;
        last = stem;
        final body = [...words.take(words.length - 1), last].map(RegExp.escape).join(' ');
        return '(?<![\\p{L}\\p{N}])$body${inflected ? '\\p{L}{0,3}' : ''}(?![\\p{L}\\p{N}])';
      }(),
  ];
}

String? _matchCategory(String text, Map<String, String> dict) {
  String? best;
  var bestLen = 0;
  for (final e in dict.entries) {
    if (text.contains(e.key) && e.key.length > bestLen) {
      best = e.value;
      bestLen = e.key.length;
    }
  }
  return best;
}

/// Разбирает фразу. [accounts] — счета пользователя с их названиями,
/// [people] — известные должники, [userWords] — личный словарь «слово → категория».
VoiceDraft parseVoice(
  String phrase, {
  List<VoiceAccount> accounts = const [],
  List<String> people = const [],
  Map<String, String> userWords = const {},
}) {
  final text = _normalize(phrase);
  final warnings = <String>[];
  if (text.isEmpty) return const VoiceDraft(kind: VoiceKind.expense, warnings: ['empty']);

  // Тип операции по глаголам — до извлечения суммы.
  var kind = VoiceKind.expense;
  if (_hasAny(text, _repayReceivedVerbs)) {
    kind = VoiceKind.repaymentReceived;
  } else if (_hasAny(text, _lendVerbs)) {
    kind = VoiceKind.lendOut;
  } else if (_hasAny(text, _borrowVerbs)) {
    kind = VoiceKind.borrow;
  } else if (_hasAny(text, _repayMadeVerbs)) {
    kind = VoiceKind.repaymentMade;
  } else if (_hasAny(text, _transferVerbs)) {
    kind = VoiceKind.transfer;
  } else if (_matchCategory(text, _incomeWords) != null || _hasAny(text, _incomeVerbs)) {
    kind = VoiceKind.income;
  }

  final date = _extractDate(text);
  var rest = _stripDate(text);

  // Счета: «с каспи», «на халык», «наличными».
  String? account;
  String? toAccount;
  for (final a in accounts) {
    String? pattern;
    RegExpMatch? match;
    for (final p in a.aliases.expand(_aliasPatterns)) {
      match = RegExp(p, unicode: true).firstMatch(rest);
      if (match != null) {
        pattern = p;
        break;
      }
    }
    if (match == null || pattern == null) continue;
    final before = rest.substring(0, match.start).trimRight();
    final isTarget = before.endsWith(' на') || before.endsWith(' в') || before == 'на' || before == 'в' || before.endsWith('-ға') || before.endsWith('-ге');
    if (kind == VoiceKind.transfer && isTarget) {
      toAccount ??= a.id;
    } else {
      account ??= a.id;
    }
    rest = rest.replaceFirst(RegExp('((?<!\\p{L})(с|со|на|в|из)\\s+)?$pattern', unicode: true), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  }
  if (kind == VoiceKind.transfer && toAccount == null && account != null) {
    // «перевёл на депозит» — единственный названный счёт при переводе чаще получатель.
    if (_word('на|в').hasMatch(text)) {
      toAccount = account;
      account = null;
    }
  }

  // Несколько позиций: «молоко 800 хлеб 250 яйца 120».
  final items = <(String, int)>[];
  final itemRe = RegExp(r'([а-яёa-zәіңғүұқөһ\- ]+?)\s+(\d{1,3}(?: \d{3})+|\d+)(?=\s|$)');
  final itemMatches = itemRe.allMatches(rest).toList();
  if (itemMatches.length >= 2) {
    for (final m in itemMatches) {
      final name = m.group(1)!.trim();
      final v = int.parse(m.group(2)!.replaceAll(' ', ''));
      if (name.isNotEmpty && v > 0) items.add((name, v * minorPerUnit));
    }
  }

  final (amount, afterAmount) = items.length >= 2
      ? (items.fold<int>(0, (s, e) => s + e.$2), rest.replaceAll(itemRe, ' ').trim())
      : _extractAmount(rest);
  rest = afterAmount;
  if (amount == null) warnings.add('no_amount');

  // Человек для долга: из списка известных; иначе — единственное слово,
  // оставшееся от фразы без суммы и служебных слов («одолжил марату 5000» —
  // в переписке имена пишут и с маленькой буквы); иначе — первое слово с
  // заглавной в исходной фразе.
  String? person;
  if (kind != VoiceKind.expense && kind != VoiceKind.income && kind != VoiceKind.transfer) {
    for (final p in people) {
      if (text.contains(_normalize(p).replaceAll(RegExp(r'[аеуыи]$'), ''))) {
        person = p;
        break;
      }
    }
    if (person == null) {
      final left = rest.replaceAll(_word(_debtWords), ' ').split(' ').where((w) => RegExp(r'^\p{L}{3,}$', unicode: true).hasMatch(w)).toList();
      if (left.length == 1) person = _capitalize(left.single);
    }
    person ??= RegExp(r'(?<!\p{L})([А-ЯӘІҢҒҮҰҚӨҺ][а-яёәіңғүұқөһ]{2,})', unicode: true)
        .allMatches(phrase)
        .map((m) => m.group(1)!)
        .where((w) => !_word(_debtWords).hasMatch(_normalize(w)))
        .firstOrNull;
    if (person == null) warnings.add('no_person');
  }

  // Категория: личный словарь важнее общего.
  String? category;
  if (kind == VoiceKind.expense) {
    final source = items.length >= 2 ? text : rest;
    category = _matchCategory(source, userWords) ?? _matchCategory(source, _categoryWords);
    if (category == null) warnings.add('no_category');
  } else if (kind == VoiceKind.income) {
    category = _matchCategory(text, _incomeWords) ?? 'otherIncome';
  }

  // Заметка: что осталось от фразы без служебных слов.
  final note = rest
      .replaceAll(_word('тенге|теңге|тг|руб|рублей|за|на|в|с|со|из|и|потратил|потратила|купил|купила|заплатил|заплатила|оплатил|оплатила|жұмсадым|төледім|сатып алдым|дал в долг|взял в долг|вернул|вернула|мне|перевел|перевела|перевод'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  return VoiceDraft(
    kind: kind,
    amount: amount,
    category: category,
    accountId: account,
    toAccountId: toAccount,
    date: date,
    person: person,
    note: items.length >= 2 ? items.map((e) => '${e.$1} ${e.$2 ~/ minorPerUnit}').join(', ') : _capitalize(note),
    items: items,
    warnings: warnings,
  );
}

String _capitalize(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
