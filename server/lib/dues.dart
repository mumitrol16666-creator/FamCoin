/// Напоминания о платежах (D167, часть 3): в день срока в 12:00 и повтор в
/// 18:00, если срок не отмечен; просроченные — раз в три дня. Под сообщением
/// кнопка «Оплатил» для сроков, которые можно закрыть одним нажатием: платёж
/// записывается со счёта, которым его платили раньше, срок закрывается.
/// Чистые функции; выполнение нажатия — в `chat_entry.dart`.
library;

import 'dart:convert';

import 'package:famcoin_core/famcoin_core.dart';

import 'briefs.dart';
import 'chat_entry.dart';

/// Стадии напоминания: полдень (сегодня и просрочка) и вечер (только сегодня).
const dueNoonHour = 12;
const dueEveningHour = 18;
const overdueEveryDays = 3;

/// Предел Telegram на `callback_data` — 64 байта.
const _callbackLimit = 64;

class DueEntry {
  const DueEntry({required this.plan, required this.date, required this.period, required this.amount, required this.name, this.account, this.reason});
  final Map<String, dynamic> plan;
  final DateTime date;
  final String period;
  final int amount;
  final String name;

  /// Счёт, с которого платёж можно записать одним нажатием; `null` — нельзя,
  /// причина в [reason].
  final ChatAccount? account;
  final String? reason;

  String get id => '${plan['id']}';
  bool get quick => account != null;
  String get callback => 'p:$id:$period';
  bool get buttonFits => utf8.encode(callback).length <= _callbackLimit;
}

/// Счёт для оплаты срока: тот, с которого этот платёж уже платили, иначе
/// первый ликвидный — как `payAccountFor` в приложении.
ChatAccount? payAccountFor(Ledger ledger, String planId, List<ChatAccount> accounts) {
  final byId = {for (final a in accounts) a.id: a};
  for (final t in ledger.transactions.reversed) {
    if (t.meta['planned'] != planId || ledger.isReversed(t.id)) continue;
    for (final p in t.postings) {
      final a = byId[p.accountId];
      if (a != null) return a;
    }
  }
  return accounts.where((a) => a.liquid).firstOrNull ?? accounts.firstOrNull;
}

/// Сроки [window] с решением, можно ли закрыть каждый одним нажатием: не
/// разовая покупка, не кредит с процентами, на счёте хватает — то же правило,
/// что у «Списалось» в приложении (`canQuickPay`).
List<DueEntry> dueEntries(Ledger ledger, List<(Map<String, dynamic>, DateTime)> window, List<ChatAccount> accounts, Map<String, Map<String, dynamic>> debts, {required String locale}) {
  final kk = locale == 'kk';
  final out = <DueEntry>[];
  for (final (p, date) in window) {
    final amount = parseMinor(p['amount']);
    final id = '${p['id'] ?? ''}';
    String? reason;
    ChatAccount? account;
    final debt = p['debtId'] == null ? null : debts['${p['debtId']}'];
    if (id.isEmpty || p['once'] != null) {
      reason = kk ? 'қолданбада' : 'в приложении';
    } else if (p['debtId'] != null && (debt == null || (debt['kind'] != 'installment' && ((debt['rate'] as num?)?.toDouble() ?? 0) > 0))) {
      reason = kk ? 'қолданбада (пайызды несие)' : 'в приложении (кредит с процентами)';
    } else {
      final a = payAccountFor(ledger, id, accounts);
      if (a == null) {
        reason = kk ? 'шот жоқ' : 'нет счёта';
      } else if (ledger.balance(a.id) < amount) {
        reason = kk ? '«${a.name}» шотында жетпейді' : 'на счёте «${a.name}» не хватает';
      } else {
        account = a;
      }
    }
    out.add(DueEntry(plan: p, date: date, period: '${p['period'] ?? ''}', amount: amount, name: '${p['name']}', account: account, reason: reason));
  }
  return out;
}

String _dm(DateTime d) => '${d.day}.${d.month.toString().padLeft(2, '0')}';

/// Напоминание на [stage] (`noon` или `evening`); `null` — напоминать не о чем.
Brief? dueReminder(BriefInput i, List<ChatAccount> accounts, {required String stage}) {
  final kk = i.locale == 'kk';
  final today = i.today;
  final window = dueWindow(i.ledger, i.planned, today.subtract(const Duration(days: overdueLookbackDays)), today, locale: i.locale, debts: i.debts, keepBefore: true);
  final entries = dueEntries(i.ledger, window, accounts, i.debts, locale: i.locale);
  final todays = [for (final e in entries) if (e.date == today) e];
  // Просрочка: один самый свежий срок на платёж, напоминание на 1-й, 4-й,
  // 7-й… день после срока — только в полдень.
  final latest = <String, DueEntry>{};
  for (final e in entries) {
    if (e.date.isBefore(today)) latest[e.id.isEmpty ? e.name : e.id] = e;
  }
  final overdue = stage == 'noon'
      ? ([for (final e in latest.values) if (today.difference(e.date).inDays % overdueEveryDays == 1) e]..sort((a, b) => a.date.compareTo(b.date)))
      : const <DueEntry>[];
  if (todays.isEmpty && overdue.isEmpty) return null;

  String money(int m) => formatMoney(m);
  String line(DueEntry e, {bool withDate = false}) {
    final when = withDate ? ' (${kk ? 'мерзімі' : 'срок'} ${_dm(e.date)})' : '';
    final how = e.quick ? (kk ? '${e.account!.name} шотынан' : 'со счёта ${e.account!.name}') : e.reason!;
    return '• ${e.name} — ${money(e.amount)}$when · $how';
  }

  final total = todays.fold(0, (a, e) => a + e.amount);
  final String title;
  if (todays.isNotEmpty) {
    if (stage == 'evening') {
      title = todays.length == 1
          ? (kk ? 'Төлем белгіленбеген: ${todays.single.name}' : 'Платёж не отмечен: ${todays.single.name}')
          : (kk ? 'Төлемдер белгіленбеген: ${todays.length}' : 'Платежи не отмечены: ${todays.length}');
    } else {
      title = todays.length == 1
          ? (kk ? 'Бүгін төлем: ${todays.single.name} — ${money(todays.single.amount)}' : 'Сегодня платёж: ${todays.single.name} — ${money(todays.single.amount)}')
          : (kk ? 'Бүгін ${todays.length} төлем, ${money(total)}' : 'Сегодня платежей: ${todays.length} на ${money(total)}');
    }
  } else {
    title = overdue.length == 1
        ? (kk ? 'Мерзімі өткен төлем: ${overdue.single.name} — ${money(overdue.single.amount)}' : 'Просроченный платёж: ${overdue.single.name} — ${money(overdue.single.amount)}')
        : (kk ? 'Мерзімі өткен төлемдер: ${overdue.length}' : 'Просрочено платежей: ${overdue.length}');
  }

  final lines = <String>[];
  if (stage == 'evening') lines.add(kk ? 'Бүгінгі мерзім әлі жабылмаған:' : 'Срок сегодня, оплата ещё не отмечена:');
  for (final e in todays) {
    lines.add(line(e));
  }
  if (overdue.isNotEmpty) {
    lines.add(kk ? 'Мерзімі өткен:' : 'Просрочено:');
    for (final e in overdue) {
      lines.add(line(e, withDate: true));
    }
  }
  final buttons = <List<Map<String, String>>>[
    for (final e in [...todays, ...overdue])
      if (e.quick && e.buttonFits) [{'text': '✅ ${kk ? 'Төледім' : 'Оплатил'}: ${e.name}', 'callback_data': e.callback}],
  ];
  if (buttons.isNotEmpty) {
    lines.add(kk ? '«Төледім» — төлем жазылады, мерзім жабылады.' : 'Нажмите «Оплатил» — платёж запишется и срок закроется.');
  }
  return Brief(title, lines.join('\n'), buttons: buttons.isEmpty ? null : buttons);
}
