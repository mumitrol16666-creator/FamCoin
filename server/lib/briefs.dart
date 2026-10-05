/// Тексты утренней сводки и вечернего отчёта.
///
/// Цифры считает ядро `famcoin_core` по журналу владельца; обязательства и
/// лимиты берутся из справочников так же, как в приложении.
library;

import 'package:famcoin_core/famcoin_core.dart';

import 'chat_entry.dart';

class Brief {
  const Brief(this.title, this.body);
  final String title;
  final String body;
}

String _period(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}';

int _minor(Object? v) => v == null ? 0 : parseMinor(v);

/// Плановые платежи и разовые покупки, не оплаченные и попадающие в [from, until].
List<(Map<String, dynamic>, DateTime)> _due(List<Map<String, dynamic>> planned, DateTime from, DateTime until) {
  final out = <(Map<String, dynamic>, DateTime)>[];
  // Сроки считает ядро: ежемесячные, недельные, годовые и разовые покупки (D88).
  final horizon = DateTime(from.year, from.month + 3, 0);
  for (final p in planned) {
    final paid = ((p['paid'] as List?) ?? const []).cast<String>();
    final end = until.isBefore(horizon) ? until : horizon;
    for (final o in PaySchedule.fromJson(p).occurrences(from, end)) {
      if (paid.contains(o.period)) continue;
      out.add((p, o.date));
    }
  }
  out.sort((a, b) => a.$2.compareTo(b.$2));
  return out;
}

class BriefInput {
  BriefInput({required this.ledger, required this.today, required this.profile, required this.planned, required this.limits, required this.locale, this.categories = const {}, this.monthRemindersEnabled = true});
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

  String categoryName(String id) => chatCategoryName(id, locale, categories);
}

String _kzt(int minor) => formatMoney(minor);

Brief morningBrief(BriefInput i) {
  final kk = i.locale == 'kk';
  final today = i.today;
  // D48/D50: никаких «до зарплаты» — остаток на счетах и лимит владельца.
  final limit = i.profile['dailyLimit'] == null ? null : parseMinor(i.profile['dailyLimit']);
  final dueToday = _due(i.planned, today, today);

  final lines = <String>[
    kk ? 'Шоттарда: <b>${_kzt(i.ledger.liquid())}</b>.' : 'На счетах: <b>${_kzt(i.ledger.liquid())}</b>.',
    if (limit != null) kk ? 'Бүгінгі лимит: ${_kzt(limit)}.' : 'Лимит на сегодня: ${_kzt(limit)}.',
  ];
  if (dueToday.isNotEmpty) {
    lines.add(kk ? 'Бүгін төлеу керек:' : 'Сегодня к оплате:');
    for (final (p, _) in dueToday) {
      lines.add('• ${p['name']} — ${_kzt(_minor(p['amount']))}');
    }
  }
  final soon = _due(i.planned, today.add(const Duration(days: 1)), today.add(const Duration(days: 3)));
  if (soon.isNotEmpty) {
    lines.add(kk ? 'Жақын 3 күнде: ${soon.map((e) => '${e.$1['name']} (${e.$2.day}.${e.$2.month.toString().padLeft(2, '0')})').join(', ')}.' : 'В ближайшие 3 дня: ${soon.map((e) => '${e.$1['name']} (${e.$2.day}.${e.$2.month.toString().padLeft(2, '0')})').join(', ')}.');
  }
  // Совет дня (D97): тот же набор, что на главной приложения; один на всех,
  // меняется каждый день.
  lines.add('💡 ${kk ? 'Кеңес' : 'Совет'}: ${moneyTipOfDay(today).text(i.locale)}');
  return Brief(kk ? 'Қайырлы таң' : 'Доброе утро', lines.join('\n'));
}

Brief eveningBrief(BriefInput i) {
  final kk = i.locale == 'kk';
  final today = i.today;
  final tomorrow = today.add(const Duration(days: 1));
  final monthStart = DateTime(today.year, today.month, 1);
  final monthEnd = DateTime(today.year, today.month + 1, 1);

  final byCat = <String, int>{};
  var spentToday = 0;
  // Все проводки по расходным счетам за день, какой бы ни была операция:
  // проценты по кредиту — тоже расход; отмена и отменённая запись гасят
  // друг друга, как в месячном отчёте ядра (D98).
  for (final tx in i.ledger.transactions) {
    if (tx.date != today) continue;
    for (final p in tx.postings) {
      if (i.ledger.account(p.accountId).kind == LedgerKind.expense) {
        spentToday += p.amount;
        byCat.update(p.accountId.substring(8), (v) => v + p.amount, ifAbsent: () => p.amount);
      }
    }
  }
  // Основная сумма долга — отдельное движение денег, без повторной траты.
  final repaidToday = i.ledger.debtPaymentsBetween(today, tomorrow);
  final top = byCat.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  final report = i.ledger.report(monthStart, monthEnd);

  final lines = <String>[];
  lines.add(spentToday == 0
      ? (kk ? 'Бүгін шығыс жазылмады.' : 'Сегодня расходов не записано.')
      : (kk ? 'Бүгін жұмсалды: <b>${_kzt(spentToday)}</b>.' : 'Сегодня потрачено: <b>${_kzt(spentToday)}</b>.'));
  for (final e in top.take(3)) {
    lines.add('• ${i.categoryName(e.key)}: ${_kzt(e.value)}');
  }
  if (repaidToday > 0) {
    lines.add(kk ? 'Бүгін қарыз өтелді: ${_kzt(repaidToday)}.' : 'Сегодня погашено долгов: ${_kzt(repaidToday)}.');
  }
  lines.add(kk ? 'Ай басынан: кіріс ${_kzt(report.income)}, шығыс ${_kzt(report.total)}.' : 'С начала месяца: доходы ${_kzt(report.income)}, расходы ${_kzt(report.total)}.');
  if (report.debtPayments > 0) {
    lines.add(kk ? 'Ай басынан қарыз өтелді: ${_kzt(report.debtPayments)}.' : 'С начала месяца погашено долгов: ${_kzt(report.debtPayments)}.');
  }

  final spentByCat = i.ledger.expenseByCategory(monthStart, monthEnd);
  final elapsed = today.day;
  final daysInMonth = monthEnd.difference(monthStart).inDays;
  for (final lim in i.limits) {
    final cat = i.categoryName(lim['category'] as String? ?? '');
    final st = limitStatus(spent: spentByCat[expenseAccount(lim['category'] as String? ?? '')] ?? 0, limit: _minor(lim['amount']), elapsedFullDays: elapsed, periodDays: daysInMonth);
    if (st.exceeded) {
      lines.add(kk ? '⚠ «$cat» лимиті асып кетті: ${_kzt(st.spent)} / ${_kzt(st.limit)}.' : '⚠ Лимит «$cat» превышен: ${_kzt(st.spent)} из ${_kzt(st.limit)}.');
    } else if (st.warn80) {
      lines.add(kk ? '«$cat» лимиті: ${st.usedPercent?.round()}%.' : 'Лимит «$cat»: ${st.usedPercent?.round()}%.');
    }
  }
  final dueTomorrow = _due(i.planned, tomorrow, tomorrow);
  if (dueTomorrow.isNotEmpty) {
    lines.add(kk ? 'Ертең төлем: ${dueTomorrow.map((e) => e.$1['name']).join(', ')}.' : 'Завтра платёж: ${dueTomorrow.map((e) => e.$1['name']).join(', ')}.');
  }
  final preparation = monthPreparationDays(today);
  if (i.monthRemindersEnabled && preparation != null) {
    final reminder = monthPreparation(month: monthStart, days: preparation, locale: i.locale);
    lines.insertAll(0, ['📅 <b>${reminder.title}</b>', reminder.body, '']);
  }
  return Brief(kk ? 'Кешкі есеп' : 'Вечерний отчёт', lines.join('\n'));
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
