/// Тексты утренней сводки и вечернего отчёта.
///
/// Цифры считает ядро `famcoin_core` по журналу владельца; обязательства и
/// лимиты берутся из справочников так же, как в приложении.
library;

import 'package:famcoin_core/famcoin_core.dart';

class Brief {
  const Brief(this.title, this.body);
  final String title;
  final String body;
}

DateTime _onDay(int year, int month, int day) {
  final last = DateTime(year, month + 1, 0).day;
  return DateTime(year, month, day.clamp(1, last));
}

String _period(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}';

int _minor(Object? v) => v == null ? 0 : parseMinor(v);

/// Плановые платежи, не оплаченные и попадающие в [from, until].
List<(Map<String, dynamic>, DateTime)> _due(List<Map<String, dynamic>> planned, DateTime from, DateTime until) {
  final out = <(Map<String, dynamic>, DateTime)>[];
  for (final p in planned) {
    final day = (p['day'] as num?)?.toInt() ?? 1;
    final paid = ((p['paid'] as List?) ?? const []).cast<String>();
    final start = p['start'] == null ? null : dateFromJson(p['start']);
    for (var m = 0; m <= 2; m++) {
      final d = _onDay(from.year, from.month + m, day);
      if (d.isBefore(from) || d.isAfter(until)) continue;
      if (start != null && d.isBefore(start)) continue;
      if (paid.contains(_period(d))) continue;
      out.add((p, d));
    }
  }
  out.sort((a, b) => a.$2.compareTo(b.$2));
  return out;
}

class BriefInput {
  BriefInput({required this.ledger, required this.today, required this.profile, required this.planned, required this.limits, required this.locale});
  final Ledger ledger;
  final DateTime today;
  final Map<String, dynamic> profile;
  final List<Map<String, dynamic>> planned;
  final List<Map<String, dynamic>> limits;
  final String locale;
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
  for (final tx in i.ledger.transactions) {
    if (tx.date != today || tx.type != EventType.expense || i.ledger.isReversed(tx.id)) continue;
    for (final p in tx.postings) {
      if (i.ledger.account(p.accountId).kind == LedgerKind.expense) {
        spentToday += p.amount;
        byCat.update(p.accountId.substring(8), (v) => v + p.amount, ifAbsent: () => p.amount);
      }
    }
  }
  final top = byCat.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  final report = i.ledger.report(monthStart, monthEnd);

  final lines = <String>[];
  lines.add(spentToday == 0
      ? (kk ? 'Бүгін шығыс жазылмады.' : 'Сегодня расходов не записано.')
      : (kk ? 'Бүгін жұмсалды: <b>${_kzt(spentToday)}</b>.' : 'Сегодня потрачено: <b>${_kzt(spentToday)}</b>.'));
  for (final e in top.take(3)) {
    lines.add('• ${e.key}: ${_kzt(e.value)}');
  }
  lines.add(kk ? 'Ай басынан: кіріс ${_kzt(report.income)}, шығыс ${_kzt(report.expense)}.' : 'С начала месяца: доходы ${_kzt(report.income)}, расходы ${_kzt(report.expense)}.');

  final spentByCat = i.ledger.expenseByCategory(monthStart, monthEnd);
  final elapsed = today.day;
  final daysInMonth = monthEnd.difference(monthStart).inDays;
  for (final lim in i.limits) {
    final cat = lim['category'] as String? ?? '';
    final st = limitStatus(spent: spentByCat[expenseAccount(cat)] ?? 0, limit: _minor(lim['amount']), elapsedFullDays: elapsed, periodDays: daysInMonth);
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
  return Brief(kk ? 'Кешкі есеп' : 'Вечерний отчёт', lines.join('\n'));
}
