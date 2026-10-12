/// Сигналы по событиям (D167, часть 2): что сказать человеку сразу после
/// записи расхода, а не вечером. Чистые функции — проверка в тестах без базы.
///
/// Каждый сигнал имеет ключ: уникальный индекс `notifications_dedup_idx`
/// не даёт отправить его дважды, поэтому порог «пройден сегодня» не нужно
/// хранить отдельно — второй раз запись просто не вставится.
library;

import 'package:famcoin_core/famcoin_core.dart';

import 'chat_entry.dart';

class Signal {
  const Signal(this.key, this.title, this.body);

  /// `limit80:<категория>:<ГГГГ-ММ>`, `limit100:…`, `daily:<ГГГГ-ММ-ДД>`.
  final String key;
  final String title;
  final String body;
}

class SignalInput {
  SignalInput({required this.ledger, required this.today, required this.profile, required this.limits, required this.locale, this.categories = const {}});
  final Ledger ledger;
  final DateTime today;
  final Map<String, dynamic> profile;
  final List<Map<String, dynamic>> limits;
  final String locale;
  final Map<String, Map<String, dynamic>> categories;

  String categoryName(String id) => chatCategoryName(id, locale, categories);
}

String _period(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}';
String _day(DateTime d) => '${_period(d)}-${d.day.toString().padLeft(2, '0')}';
String _kzt(int minor) => formatMoney(minor);
int _minor(Object? v) => v == null ? 0 : parseMinor(v);

/// Сигналы, актуальные сейчас: лимит категории на 80 % и превышен, дневной
/// лимит исчерпан. Что из этого уже отправлялось, решает ключ при записи.
List<Signal> currentSignals(SignalInput i) {
  final kk = i.locale == 'kk';
  final today = i.today;
  final monthStart = DateTime(today.year, today.month, 1);
  final monthEnd = DateTime(today.year, today.month + 1, 1);
  final daysInMonth = monthEnd.difference(monthStart).inDays;
  final daysLeft = daysInMonth - today.day;
  final out = <Signal>[];

  final spentByCat = i.ledger.expenseByCategory(monthStart, monthEnd);
  for (final lim in i.limits) {
    final id = lim['category'] as String? ?? '';
    final limit = _minor(lim['amount']);
    if (id.isEmpty || limit <= 0) continue;
    final spent = spentByCat[expenseAccount(id)] ?? 0;
    final st = limitStatus(spent: spent, limit: limit, elapsedFullDays: today.day, periodDays: daysInMonth);
    final cat = i.categoryName(id);
    if (st.exceeded) {
      out.add(Signal(
        'limit100:$id:${_period(today)}',
        kk ? '«$cat» лимиті асып кетті' : 'Лимит «$cat» превышен',
        kk
            ? '${_kzt(spent)} / ${_kzt(limit)}, ай соңына дейін $daysLeft күн.'
            : '${_kzt(spent)} из ${_kzt(limit)}, до конца месяца $daysLeft ${_days(daysLeft)}.',
      ));
    } else if (st.warn80) {
      final left = limit - spent;
      out.add(Signal(
        'limit80:$id:${_period(today)}',
        kk ? '«$cat» лимиті: ${st.usedPercent!.round()} %' : 'Лимит «$cat»: ${st.usedPercent!.round()} %',
        kk
            ? '${_kzt(spent)} / ${_kzt(limit)}, ай соңына дейін ${_kzt(left)} қалды ($daysLeft күн).'
            : '${_kzt(spent)} из ${_kzt(limit)}, осталось ${_kzt(left)} на $daysLeft ${_days(daysLeft)}.',
      ));
    }
  }

  final daily = dailyLimitState(i.ledger, i.profile, today);
  if (daily.limit != null && daily.limit! > 0 && daily.planned != null && daily.planned! <= 0 && daily.spentToday > 0) {
    final tail = daily.carryOn
        ? (kk ? 'Артық жұмсалғаны ертеңгі лимитті азайтады.' : 'Перерасход уменьшит завтрашний лимит.')
        : (kk ? 'Ертең қайтадан ${_kzt(daily.limit!)}.' : 'Завтра снова ${_kzt(daily.limit!)}.');
    out.add(Signal(
      'daily:${_day(today)}',
      kk ? 'Күндік лимит таусылды' : 'Дневной лимит исчерпан',
      kk
          ? 'Бүгін күнделікті шығын ${_kzt(daily.spentToday)}, лимит ${_kzt(daily.limit!)}. $tail'
          : 'Сегодня повседневных трат ${_kzt(daily.spentToday)} при лимите ${_kzt(daily.limit!)}. $tail',
    ));
  }
  return out;
}

String _days(int n) {
  final r10 = n % 10, r100 = n % 100;
  if (r100 >= 11 && r100 <= 14) return 'дней';
  if (r10 == 1) return 'день';
  if (r10 >= 2 && r10 <= 4) return 'дня';
  return 'дней';
}

/// Команда, после которой стоит пересчитать сигналы: записан или изменён
/// расход, в том числе внутри пачки. Справочники и переводы сигналов не дают.
bool commandTouchesExpense(Map<String, dynamic> cmd) {
  final type = cmd['type'];
  if (type == 'batch') {
    final items = cmd['commands'];
    return items is List && items.any((c) => c is Map && commandTouchesExpense(Map<String, dynamic>.from(c)));
  }
  return type == 'expense' || type == 'restore';
}
