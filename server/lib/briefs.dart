/// Тексты утренней сводки и вечернего отчёта.
///
/// Цифры считает ядро `famcoin_core` по журналу владельца; обязательства и
/// лимиты берутся из справочников так же, как в приложении.
library;

import 'package:famcoin_core/famcoin_core.dart';

import 'chat_entry.dart';

class Brief {
  const Brief(this.title, this.body, {this.buttons});
  final String title;
  final String body;

  /// Inline-кнопки Telegram под сообщением (D167): например, быстрые
  /// операции в вечернем отчёте пустого дня. В приложение и push не идут.
  final List<List<Map<String, String>>>? buttons;
}

String _period(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}';

int _minor(Object? v) => v == null ? 0 : parseMinor(v);

/// Плановые платежи и разовые покупки, не оплаченные и попадающие в [from, until].
/// В каждой записи — `period` срока (ключ отметки «оплачено»), `name` и
/// `amount` к оплате; напоминания о платежах (D167, часть 3) строят по ним кнопки.
/// [keepBefore] — оставить и сроки раньше [from], которые попали в просмотр
/// (с начала платежа): так утренняя сводка видит просрочку (D167). Без него
/// прошедшие сроки только забирают свою часть остатка рассрочки (FV-C04).
List<(Map<String, dynamic>, DateTime)> dueWindow(Ledger ledger, List<Map<String, dynamic>> planned, DateTime from, DateTime until, {String locale = 'ru', Map<String, Map<String, dynamic>> debts = const {}, bool keepBefore = false}) {
  final out = <(Map<String, dynamic>, DateTime)>[];
  // Сроки считает ядро: ежемесячные, недельные, годовые и разовые покупки (D88).
  // Просроченные сроки (D167) попадают сюда же, если [from] раньше сегодня:
  // остаток рассрочки распределяется по срокам в одном проходе (FV-C04),
  // поэтому просрочку и будущее считают одним вызовом и делят по датам.
  for (final p in planned) {
    // Погашенный кредит больше не требует оплаты — то же правило, что в приложении (R04).
    final person = p['person'] as String?;
    if (!plannedDebtActive(ledger, p['debtId'] as String?, person: person)) continue;
    final paid = ((p['paid'] as List?) ?? const []).cast<String>();
    for (final o in PaySchedule.fromJson(p).occurrences(PaySchedule.fromJson(p).scanFrom(from), until)) {
      if (paid.contains(o.period)) continue;
      // Срок возврата личного долга (D133): сумма — сколько осталось внести к
      // нему (за вычетом частей, N01), название — «Долг: имя».
      if (person != null) {
        final left = personDueLeft(ledger, planId: '${p['id'] ?? ''}', person: person, amount: _minor(p['amount']), period: o.period);
        if (left <= 0) continue;
        out.add(({...p, 'name': '${locale == 'kk' ? 'Қарыз' : 'Долг'}: $person', 'amount': '$left', 'period': o.period}, o.date));
        continue;
      }
      out.add(({...p, 'period': o.period}, o.date));
    }
  }
  out.sort((a, b) {
    final date = a.$2.compareTo(b.$2);
    return date == 0 ? '${a.$1['id']}'.compareTo('${b.$1['id']}') : date;
  });
  final budget = DebtDueBudget(ledger);
  final result = <(Map<String, dynamic>, DateTime)>[];
  for (final (p, date) in out) {
    final debtId = p['debtId'] as String?;
    final debt = debts[debtId];
    var amount = _minor(p['amount']);
    if (debt != null && p['person'] == null) {
      amount = budget.take(debtId: debtId!, amount: amount, kind: '${debt['kind'] ?? 'loan'}', rate: (debt['rate'] as num?)?.toDouble() ?? 0);
    }
    if (amount > 0 && (keepBefore || !date.isBefore(from))) result.add(({...p, 'amount': '$amount'}, date));
  }
  return result;
}

class BriefInput {
  BriefInput({required this.ledger, required this.today, required this.profile, required this.planned, required this.limits, required this.locale, this.categories = const {}, this.debts = const {}, this.monthRemindersEnabled = true, this.quickButtons = const [], this.goals = const {}, this.quietNudges = true});
  final Ledger ledger;
  final DateTime today;
  final Map<String, dynamic> profile;
  final List<Map<String, dynamic>> planned;
  final List<Map<String, dynamic>> limits;
  final String locale;
  final bool monthRemindersEnabled;

  /// Свои категории владельца: id → данные (`name`). Встроенные называются
  /// тем же словарём, что и в боте, — в сводке не бывает `food` или id.
  final Map<String, Map<String, dynamic>> categories;

  /// Банковские долги владельца: id → данные (`kind`, `rate`) — сумма срока
  /// рассрочки и кредита считается как в приложении (CS03).
  final Map<String, Map<String, dynamic>> debts;

  /// Кнопки быстрых операций владельца для пустого вечера (D167); пусто —
  /// плиток нет, тогда отчёт подсказывает записать сообщением боту.
  final List<List<Map<String, String>>> quickButtons;

  /// Цели владельца: id → данные (`name`, `account` копилки) — для строки
  /// «отложено на цели» в итогах недели (часть 5).
  final Map<String, Map<String, dynamic>> goals;

  /// Напоминать ли записать в пустой вечер (часть 6, выключатель «quiet»);
  /// при выключенном пустые вечера молчат, кроме подготовки к сверке и
  /// воскресных итогов недели.
  final bool quietNudges;

  String categoryName(String id) => chatCategoryName(id, locale, categories);
}

String _kzt(int minor) => formatMoney(minor);

/// С какого дня просматривать сроки ради просрочки (платёж без даты начала
/// смотрится с этого месяца, с датой — с неё) и на сколько дней вперёд
/// смотреть ближайшие платежи (D167).
const overdueLookbackDays = 60;
const upcomingDays = 14;

String _dm(DateTime d) => '${d.day}.${d.month.toString().padLeft(2, '0')}';

Brief morningBrief(BriefInput i) {
  final kk = i.locale == 'kk';
  final today = i.today;
  final yesterday = today.subtract(const Duration(days: 1));
  final l = i.ledger;
  final limit = i.profile['dailyLimit'] == null ? null : parseMinor(i.profile['dailyLimit']);
  final lines = <String>[];

  // Вчера: повседневные траты против дневного лимита (D167). Запланированные
  // и непредвиденные в лимит не входят (D74, D101) — как на главной.
  final hadRecords = l.transactions.any((t) => t.date == yesterday && !l.isReversed(t.id) && t.type != EventType.reversal);
  final spentYesterday = spendBetween(l, yesterday, yesterday).everyday;
  final quiet = hadRecords ? 0 : quietDays(l, yesterday);
  if (quiet > 1) {
    lines.add(kk ? '$quiet күн бойы жазба жоқ.' : 'Записей нет уже $quiet ${_daysRu(quiet)}.');
  } else if (!hadRecords) {
    lines.add(kk ? 'Кеше жазба болмады.' : 'Вчера записей не было.');
  } else if (limit == null || limit <= 0) {
    lines.add(kk ? 'Кеше жұмсалды: <b>${_kzt(spentYesterday)}</b>.' : 'Вчера потрачено: <b>${_kzt(spentYesterday)}</b>.');
  } else if (spentYesterday <= limit) {
    lines.add(kk
        ? 'Кеше: <b>${_kzt(spentYesterday)}</b>, лимит ${_kzt(limit)} — сыйдыңыз ✅'
        : 'Вчера: <b>${_kzt(spentYesterday)}</b> при лимите ${_kzt(limit)} — уложились ✅');
  } else {
    lines.add(kk
        ? 'Кеше: <b>${_kzt(spentYesterday)}</b>, лимит ${_kzt(limit)} — ${_kzt(spentYesterday - limit)} артық ⚠'
        : 'Вчера: <b>${_kzt(spentYesterday)}</b> при лимите ${_kzt(limit)} — на ${_kzt(spentYesterday - limit)} больше ⚠');
  }

  // Деньги и доступное сегодня — по тому же расчёту, что карточка на главной.
  final daily = dailyLimitState(l, i.profile, today);
  lines.add(kk ? 'Шоттарда: <b>${_kzt(l.liquid())}</b>.' : 'На счетах: <b>${_kzt(l.liquid())}</b>.');
  if (daily.available != null) {
    final capped = daily.capped ? (kk ? ' (шоттағы ақшамен шектелген)' : ' (ограничено деньгами на счетах)') : '';
    lines.add(kk ? 'Бүгін қолжетімді: ${_kzt(daily.available!)}$capped.' : 'Доступно сегодня: ${_kzt(daily.available!)}$capped.');
  }

  // Сроки одним проходом: просрочено, сегодня, ближайшие две недели.
  final window = dueWindow(l, i.planned, today.subtract(const Duration(days: overdueLookbackDays)), today.add(const Duration(days: upcomingDays)), locale: i.locale, debts: i.debts, keepBefore: true);
  // Просрочка — по одному сроку на платёж, самому свежему: оплату мимо
  // приложения часто не отмечают, и список старых месяцев был бы шумом.
  final latestOverdue = <String, (Map<String, dynamic>, DateTime)>{};
  for (final d in window) {
    if (d.$2.isBefore(today)) latestOverdue['${d.$1['id'] ?? d.$1['name']}'] = d;
  }
  final overdue = latestOverdue.values.toList()..sort((a, b) => a.$2.compareTo(b.$2));
  final dueToday = [for (final d in window) if (d.$2 == today) d];
  final soon = [for (final d in window) if (d.$2.isAfter(today)) d];
  int sum(List<(Map<String, dynamic>, DateTime)> xs) => xs.fold(0, (a, d) => a + _minor(d.$1['amount']));

  if (overdue.isNotEmpty) {
    lines.add(kk ? '⚠ Мерзімі өткен:' : '⚠ Просрочено:');
    for (final (p, date) in overdue) {
      lines.add('• ${p['name']} — ${_kzt(_minor(p['amount']))} (${kk ? 'мерзімі' : 'срок'} ${_dm(date)})');
    }
  }
  if (dueToday.isNotEmpty) {
    lines.add(kk ? 'Бүгін төлеу керек:' : 'Сегодня к оплате:');
    for (final (p, _) in dueToday) {
      lines.add('• ${p['name']} — ${_kzt(_minor(p['amount']))}');
    }
  }
  if (soon.isNotEmpty) {
    lines.add(kk ? 'Алдағы $upcomingDays күнде:' : 'В ближайшие $upcomingDays дней:');
    for (final (p, date) in soon.take(5)) {
      lines.add('• ${p['name']} — ${_kzt(_minor(p['amount']))} (${_dm(date)})');
    }
    if (soon.length > 5) lines.add(kk ? '• … тағы ${soon.length - 5}' : '• … ещё ${soon.length - 5}');
  }
  // Кассовый разрыв (D167): всё, что надо заплатить до конца окна, против
  // денег на счетах. Отложенное на цели не трогаем — это не деньги на платежи.
  final need = sum(overdue) + sum(dueToday) + sum(soon);
  final money = l.freeLiquid();
  if (need > 0 && need > money) {
    final until = soon.isNotEmpty ? soon.last.$2 : today;
    lines.add(kk
        ? '❗ ${_dm(until)} дейінгі төлемдерге ${_kzt(need - (money < 0 ? 0 : money))} жетпейді: төлеу керек ${_kzt(need)}, шоттарда ${_kzt(money < 0 ? 0 : money)}.'
        : '❗ Не хватает ${_kzt(need - (money < 0 ? 0 : money))} на платежи до ${_dm(until)}: к оплате ${_kzt(need)}, свободно на счетах ${_kzt(money < 0 ? 0 : money)}.');
  } else if (need > 0) {
    lines.add(kk ? 'Төлемдерге ақша жетеді ✅' : 'На платежи денег хватает ✅');
  }
  // Совет дня (D97): тот же набор, что на главной приложения; один на всех,
  // меняется каждый день.
  lines.add('💡 ${kk ? 'Кеңес' : 'Совет'}: ${moneyTipOfDay(today).text(i.locale)}');
  return Brief(kk ? 'Қайырлы таң' : 'Доброе утро', lines.join('\n'));
}

/// Сколько дней подряд, считая [today], владелец ничего не записывал (D167,
/// часть 4). Начальные остатки и отмены записями не считаются; до 60.
int quietDays(Ledger l, DateTime today) {
  final days = <DateTime>{};
  DateTime? first;
  for (final t in l.transactions) {
    final day = DateTime(t.date.year, t.date.month, t.date.day);
    if (first == null || day.isBefore(first)) first = day;
    if (t.type == EventType.opening || t.type == EventType.reversal || l.isReversed(t.id)) continue;
    days.add(day);
  }
  // Раньше первой операции (обычно начального остатка) считать нечего:
  // новый владелец в первый вечер — один тихий день, а не шестьдесят.
  final floor = first == null || first.isAfter(today) ? today : first;
  var n = 0;
  var d = today;
  while (n < 60 && !days.contains(d) && !d.isBefore(floor)) {
    n++;
    d = d.subtract(const Duration(days: 1));
  }
  return n < 1 ? 1 : n;
}

/// Какие вечера тишины стоят сообщения: первые три дня, пятый, седьмой и
/// дальше раз в неделю — чтобы ушедшему не писать каждый день.
bool quietDayWorthNudge(int streak) => streak <= 3 || streak == 5 || streak == 7 || streak % 7 == 0;

String _daysRu(int n) {
  final r10 = n % 10, r100 = n % 100;
  if (r100 >= 11 && r100 <= 14) return 'дней';
  if (r10 == 1) return 'день';
  if (r10 >= 2 && r10 <= 4) return 'дня';
  return 'дней';
}

/// Итоги недели (D167, часть 5): в воскресенье вечером — неделя против
/// прошлой, доходы, три главные категории, отложено на цели. Пусто, если за
/// неделю не было ни одной записи.
List<String> weeklyDigest(BriefInput i) {
  final kk = i.locale == 'kk';
  final l = i.ledger;
  final end = i.today.add(const Duration(days: 1)); // исключительно
  final start = i.today.subtract(const Duration(days: 6));
  final prevStart = start.subtract(const Duration(days: 7));
  if (!l.transactions.any((t) => !t.date.isBefore(start) && t.date.isBefore(end) && t.type != EventType.opening && t.type != EventType.reversal && !l.isReversed(t.id))) return const [];
  final week = l.report(start, end);
  final prev = l.report(prevStart, start);
  final lines = <String>['📊 <b>${kk ? 'Апта қорытындысы' : 'Итоги недели'} (${start.day}–${_dm(i.today)})</b>'];
  String compare() {
    if (prev.total <= 0) return '';
    final diff = week.total - prev.total;
    final pct = (diff.abs() * 100 / prev.total).round();
    if (pct == 0) return kk ? ' (өткен аптадағыдай)' : ' (как на прошлой неделе)';
    return kk
        ? ' (өткен апта ${_kzt(prev.total)}, $pct % ${diff > 0 ? 'артық' : 'кем'})'
        : ' (прошлая неделя ${_kzt(prev.total)}, на $pct % ${diff > 0 ? 'больше' : 'меньше'})';
  }
  lines.add(kk ? 'Жұмсалды: <b>${_kzt(week.total)}</b>${compare()}' : 'Потрачено: <b>${_kzt(week.total)}</b>${compare()}');
  if (week.income > 0) lines.add(kk ? 'Кіріс: ${_kzt(week.income)}' : 'Доходы: ${_kzt(week.income)}');
  final top = l.expenseByCategory(start, end).entries.where((e) => e.value > 0).toList()..sort((a, b) => b.value.compareTo(a.value));
  if (top.isNotEmpty) {
    lines.add('${kk ? 'Ең көп' : 'Больше всего'}: ${top.take(3).map((e) => '${i.categoryName(e.key.substring(8))} ${_kzt(e.value)}').join(', ')}');
  }
  // Отложено на цели: переводы в копилки за неделю, без отменённых.
  final goalByAccount = {for (final e in i.goals.entries) if (e.value['account'] != null) '${e.value['account']}': '${e.value['name'] ?? ''}'};
  var saved = 0;
  final names = <String>{};
  for (final t in l.transactions) {
    if (t.type != EventType.transfer || t.date.isBefore(start) || !t.date.isBefore(end) || l.isReversed(t.id)) continue;
    for (final p in t.postings) {
      if (p.amount > 0 && p.accountId.startsWith('piggy')) {
        saved += p.amount;
        final name = goalByAccount[p.accountId];
        if (name != null && name.isNotEmpty) names.add(name);
      }
    }
  }
  if (saved > 0) {
    final who = names.isEmpty ? '' : ' (${names.join(', ')})';
    lines.add(kk ? 'Мақсаттарға жиналды: ${_kzt(saved)}$who' : 'Отложено на цели: ${_kzt(saved)}$who');
  }
  return lines;
}

/// Вечерний отчёт; `null` — сегодня вечером лучше промолчать (долгая тишина
/// не в тот день, см. [quietDayWorthNudge]). [force] — построить всегда
/// (предпросмотр из приложения).
Brief? eveningBrief(BriefInput i, {bool force = false}) {
  final kk = i.locale == 'kk';
  final today = i.today;
  final tomorrow = today.add(const Duration(days: 1));
  final monthStart = DateTime(today.year, today.month, 1);
  final monthEnd = DateTime(today.year, today.month + 1, 1);

  final byCat = <String, int>{};
  var spentToday = 0;
  var recordsToday = 0;
  // Все проводки по расходным счетам за день, какой бы ни была операция:
  // проценты по кредиту — тоже расход; отмена и отменённая запись гасят
  // друг друга, как в месячном отчёте ядра (D98).
  for (final tx in i.ledger.transactions) {
    if (tx.date != today) continue;
    if (!i.ledger.isReversed(tx.id) && tx.type != EventType.reversal && tx.type != EventType.opening) recordsToday++;
    for (final p in tx.postings) {
      if (i.ledger.account(p.accountId).kind == LedgerKind.expense) {
        spentToday += p.amount;
        byCat.update(p.accountId.substring(8), (v) => v + p.amount, ifAbsent: () => p.amount);
      }
    }
  }
  // Основная сумма долга — отдельное движение денег, без повторной траты.
  final repaidToday = i.ledger.debtPaymentsBetween(today, tomorrow);
  // Категория, где запись и её отмена дали ноль, в отчёт не идёт (D167).
  final top = byCat.entries.where((e) => e.value > 0).toList()..sort((a, b) => b.value.compareTo(a.value));
  final report = i.ledger.report(monthStart, monthEnd);

  final lines = <String>[];
  List<List<Map<String, String>>>? buttons;
  final empty = recordsToday == 0;
  final streak = empty ? quietDays(i.ledger, today) : 0;
  final preparation = monthPreparationDays(today);
  final sunday = today.weekday == DateTime.sunday;
  final keepQuiet = empty && !force && (streak > 1 && !quietDayWorthNudge(streak) || !i.quietNudges);
  if (keepQuiet && !(sunday && streak < 7) && (preparation == null || !i.monthRemindersEnabled)) return null;
  if (empty) {
    // Пустой день (D167): не отчёт, а вопрос — с кнопками быстрых операций,
    // чтобы ответить одним нажатием прямо из Telegram. Несколько дней подряд
    // (часть 4): когда была последняя запись и сходится ли остаток.
    if (streak > 1) {
      final last = today.subtract(Duration(days: streak));
      final hasLast = i.ledger.transactions.any((t) => t.type != EventType.opening);
      lines.add(kk
          ? '$streak күн бойы жазба жоқ${hasLast ? ', соңғысы — ${_dm(last)}' : ''}. Шоттардағы ${_kzt(i.ledger.liquid())} сәйкес келе ме?'
          : '$streak ${_daysRu(streak)} без записей${hasLast ? ', последняя — ${_dm(last)}' : ''}. На счетах ${_kzt(i.ledger.liquid())} — сходится?');
      lines.add(kk ? 'Шығын болса, бір басу:' : 'Если траты были, одно нажатие:');
    } else {
      lines.add(kk ? 'Бүгін ештеңе жазылмады. Шығын болды ма?' : 'Сегодня ничего не записано. Траты были?');
    }
    if (i.quickButtons.isNotEmpty) {
      if (streak <= 1) lines.add(kk ? 'Бір басу — және жазылды:' : 'Одно нажатие — и записано:');
      buttons = i.quickButtons;
    } else {
      lines.add(kk ? 'Ботқа хабарламамен жазыңыз: «кофе 1500».' : 'Напишите боту сообщением: «кофе 1500».');
    }
  } else {
    lines.add(spentToday == 0
        ? (kk ? 'Бүгін шығыс жазылмады.' : 'Сегодня расходов не записано.')
        : (kk ? 'Бүгін жұмсалды: <b>${_kzt(spentToday)}</b>.' : 'Сегодня потрачено: <b>${_kzt(spentToday)}</b>.'));
    for (final e in top.take(3)) {
      lines.add('• ${i.categoryName(e.key)}: ${_kzt(e.value)}');
    }
  }
  if (repaidToday > 0) {
    lines.add(kk ? 'Бүгін қарыз өтелді: ${_kzt(repaidToday)}.' : 'Сегодня погашено долгов: ${_kzt(repaidToday)}.');
  }
  lines.add(kk ? 'Ай басынан: кіріс ${_kzt(report.income)}, шығыс ${_kzt(report.total)}.' : 'С начала месяца: доходы ${_kzt(report.income)}, расходы ${_kzt(report.total)}.');
  if (report.debtPayments > 0) {
    lines.add(kk ? 'Ай басынан қарыз өтелді: ${_kzt(report.debtPayments)}.' : 'С начала месяца погашено долгов: ${_kzt(report.debtPayments)}.');
  }

  if (sunday) {
    final digest = weeklyDigest(i);
    if (digest.isNotEmpty) lines.addAll(['', ...digest]);
  }

  // Лимиты по категориям (D167): превышение и 80 % — в тот вечер, когда
  // порог пройден, а не каждый день; по воскресеньям — сводка всех превышенных.
  final spentByCat = i.ledger.expenseByCategory(monthStart, monthEnd);
  final elapsed = today.day;
  final daysInMonth = monthEnd.difference(monthStart).inDays;
  final weekly = today.weekday == DateTime.sunday;
  for (final lim in i.limits) {
    final id = lim['category'] as String? ?? '';
    final cat = i.categoryName(id);
    final limit = _minor(lim['amount']);
    if (limit <= 0) continue;
    final spent = spentByCat[expenseAccount(id)] ?? 0;
    final before = spent - (byCat[id] ?? 0);
    final st = limitStatus(spent: spent, limit: limit, elapsedFullDays: elapsed, periodDays: daysInMonth);
    if (st.exceeded && (before <= limit || weekly)) {
      lines.add(kk ? '⚠ «$cat» лимиті асып кетті: ${_kzt(st.spent)} / ${_kzt(st.limit)}.' : '⚠ Лимит «$cat» превышен: ${_kzt(st.spent)} из ${_kzt(st.limit)}.');
    } else if (!st.exceeded && st.warn80 && before * 5 < limit * 4) {
      lines.add(kk ? '«$cat» лимиті: ${st.usedPercent?.round()}%.' : 'Лимит «$cat»: ${st.usedPercent?.round()}%.');
    }
  }
  final dueTomorrow = dueWindow(i.ledger, i.planned, tomorrow, tomorrow, locale: i.locale, debts: i.debts);
  if (dueTomorrow.isNotEmpty) {
    lines.add(kk ? 'Ертең төлем: ${dueTomorrow.map((e) => '${e.$1['name']} — ${_kzt(_minor(e.$1['amount']))}').join(', ')}.' : 'Завтра платёж: ${dueTomorrow.map((e) => '${e.$1['name']} — ${_kzt(_minor(e.$1['amount']))}').join(', ')}.');
  }
  if (i.monthRemindersEnabled && preparation != null) {
    final reminder = monthPreparation(month: monthStart, days: preparation, locale: i.locale);
    lines.insertAll(0, ['📅 <b>${reminder.title}</b>', reminder.body, '']);
  }
  final title = !empty
      ? (kk ? 'Кешкі есеп' : 'Вечерний отчёт')
      : streak > 1
          ? (kk ? '$streak күн жазба жоқ' : '$streak ${_daysRu(streak)} без записей')
          : (kk ? 'Бүгін жазба жоқ' : 'Сегодня без записей');
  return Brief(title, lines.join('\n'), buttons: buttons);
}

const _monthsRu = ['январь', 'февраль', 'март', 'апрель', 'май', 'июнь', 'июль', 'август', 'сентябрь', 'октябрь', 'ноябрь', 'декабрь'];
const _monthsKk = ['қаңтар', 'ақпан', 'наурыз', 'сәуір', 'мамыр', 'маусым', 'шілде', 'тамыз', 'қыркүйек', 'қазан', 'қараша', 'желтоқсан'];

/// Название месяца в именительном падеже (для заголовка уведомления).
String monthName(int month, String locale) => (locale == 'kk' ? _monthsKk : _monthsRu)[month - 1];

/// Ключ месяца `ГГГГ-ММ` — так он записан в `profile.closedMonths`.
String monthKey(DateTime d) => _period(d);

/// Предыдущий календарный месяц (первое число); январь даёт декабрь прошлого года.
DateTime previousMonth(DateTime now) => DateTime(now.year, now.month - 1, 1);

/// Напоминание закрыть месяц (D75): итоги — коротко в тексте, остальное
/// человек увидит в приложении сразу, как откроет.
Brief monthNudge({required DateTime month, required int income, required int expense, required String locale}) {
  final kk = locale == 'kk';
  final name = monthName(month.month, locale);
  return kk
      ? Brief(
          'Айды жабыңыз: $name',
          'Ай аяқталды. Соңғы күннің соңындағы қалдықтарды банк көшірмелерімен салыстырыңыз — 5–10 минут. Кіріс ${_kzt(income)}, шығыс ${_kzt(expense)}. FamCoin-ді ашып, айды жабыңыз.',
        )
      : Brief(
          'Сверьте $name',
          'Месяц закончился. Сравните остатки на его последний день с банковскими выписками — 5–10 минут. Доходы ${_kzt(income)}, расходы ${_kzt(expense)}. Откройте FamCoin и закройте месяц.',
        );
}

/// За 3 дня и за день до первого числа. UTC исключает влияние летнего времени.
int? monthPreparationDays(DateTime today) {
  final days = DateTime.utc(today.year, today.month + 1, 1)
      .difference(DateTime.utc(today.year, today.month, today.day)).inDays;
  return days == 3 || days == 1 ? days : null;
}

Brief monthPreparation({required DateTime month, required int days, required String locale}) {
  final kk = locale == 'kk';
  final name = monthName(month.month, locale);
  final end = reconciliationEnd(month);
  final date = '${end.day}.${end.month.toString().padLeft(2, '0')}.${end.year}';
  return Brief(
    kk ? (days == 1 ? 'Ертең айды тексеру керек' : '3 күннен кейін айды тексеру керек')
       : (days == 1 ? 'Завтра сверка месяца' : 'Через 3 дня сверка месяца'),
    kk ? '$name айын тексеруге 5–10 минут бөліңіз. $date күнінің соңындағы қалдықтар көрсетілген банк көшірмелерін дайындап, қолма-қол ақшаны санаңыз. Тексеру келесі айдың 1-күні ашылады.'
       : 'Выделите 5–10 минут, чтобы сверить $name. В конце $date сохраните остатки из банковских выписок и посчитайте наличные. Сверка откроется 1-го числа.',
  );
}
