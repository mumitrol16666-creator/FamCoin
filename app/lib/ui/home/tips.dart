/// Советы на главной (D97): один короткий ориентир в день — про деньги или
/// про приложение, а когда есть повод — совет по цифрам владельца.
///
/// Три источника:
/// * [dataTipsFor] — по данным: перебор в категории без лимита, перерыв в
///   записях, крупные незапланированные траты. Показываются вне очереди,
///   один раз за свой период (код совета запоминает [Settings.markTipSeen]).
/// * Подсказки про приложение — пока их условие верно (нет дневного лимита,
///   копилки, платежей…), с кнопкой в нужное место.
/// * Общие советы про деньги — [moneyTips] из ядра, те же, что в утренней
///   сводке бота.
///
/// Подсказки и общие советы идут по очереди, чтобы новичка не заваливало
/// «настройте то, настройте это». Ротация — по номеру ([tipAt]), номер ведёт
/// [Settings.tipCursor].
library;

import 'package:famcoin_core/famcoin_core.dart';
import 'package:intl/intl.dart';

import '../../l10n/app_localizations.dart';
import '../../state/app_state.dart';
import '../widgets/common.dart';

/// Куда ведёт совет; обработчики — в карточке на главной.
enum TipAction { setLimit, addGoal, openCalendar, openLimits, addQuick, voice, telegram, add, openBudget, catchUp }

class Tip {
  const Tip(this.id, this.text, {this.actionLabel, this.action});

  /// Устойчивый код — для тестов, журнала и памяти «уже показан».
  final String id;
  final String text;
  final String? actionLabel;
  final TipAction? action;
}

String _period(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}';

/// Советы по цифрам владельца, от важного к менее важному. Пусто, когда
/// повода нет. Коды включают период, чтобы совет не повторялся каждый день.
List<Tip> dataTipsFor(AppState s, AppLocalizations l) {
  final out = <Tip>[];
  final today = s.today;

  // Перерыв в записях: три дня и больше — данные уже неполные, сравнивать
  // их не с чем. Запись — расход или доход; начальный остаток и переводы
  // учётом не считаются. Только если учёт вообще вёлся.
  final records = s.userTransactions.where((t) => t.type == EventType.expense || t.type == EventType.income);
  if (records.isNotEmpty) {
    final last = records.first.date; // список отсортирован от новых к старым
    final gap = today.difference(last).inDays;
    // Перерыв закрывается сверкой остатка (Ж4): разница запишется тратами,
    // а не пропадёт из отчёта.
    if (gap >= 3) out.add(Tip('dataGap:${dateToJson(last)}', l.adviceDataGap(gap), actionLabel: l.adviceActCatchUp, action: TipAction.catchUp));
  }

  // Категория без лимита, где к этому дню потрачено больше, чем за весь
  // прошлый месяц. Одна, с самым большим перебором.
  final limited = {for (final d in s.limits) d.category};
  ({String cat, int spent, int last})? worst;
  for (final e in s.categoriesFor(s.monthStart)) {
    if (limited.contains(e.key)) continue;
    final last = s.lastMonthSpent(e.key);
    if (last == null || e.value <= last.total) continue;
    if (worst == null || e.value - last.total > worst.spent - worst.last) worst = (cat: e.key, spent: e.value, last: last.total);
  }
  if (worst != null) {
    final month = DateFormat.LLLL(l.localeName).format(s.monthOf(-1));
    out.add(Tip(
      'dataOver:${worst.cat}:${_period(today)}',
      l.adviceDataOver(categoryName(l, worst.cat), moneyInText(worst.spent), month, moneyInText(worst.last)),
      actionLabel: l.adviceActCatLimit,
      action: TipAction.openLimits,
    ));
  }

  // Две и больше крупные незапланированные траты за месяц — повод планировать.
  final large = s.unplannedLargeExpenses(s.monthStart);
  if (large.length >= 2) {
    final sum = large.fold(0, (a, t) => a + t.postings.where((p) => s.ledger.account(p.accountId).kind == LedgerKind.expense).fold(0, (b, p) => b + p.amount));
    out.add(Tip('dataLarge:${_period(today)}', l.adviceDataLarge(large.length, moneyInText(sum)), actionLabel: l.adviceActBudget, action: TipAction.openBudget));
  }
  return out;
}

/// Очередь советов на каждый день. Никогда не пуста: общие есть всегда.
List<Tip> tipsFor(AppState s, AppLocalizations l) {
  final app = <Tip>[
    if (s.dailyLimit == null) Tip('appLimit', l.adviceAppLimit, actionLabel: l.adviceActLimit, action: TipAction.setLimit),
    if (s.goals.isEmpty) Tip('appGoal', l.adviceAppGoal, actionLabel: l.adviceActGoal, action: TipAction.addGoal),
    if (s.planned.isEmpty) Tip('appPlanned', l.adviceAppPlanned, actionLabel: l.adviceActCalendar, action: TipAction.openCalendar),
    if (s.limits.isEmpty) Tip('appCatLimit', l.adviceAppCatLimit, actionLabel: l.adviceActCatLimit, action: TipAction.openLimits),
    if (s.quickActions.isEmpty) Tip('appQuick', l.adviceAppQuick, actionLabel: l.adviceActQuick, action: TipAction.addQuick),
    Tip('appVoice', l.adviceAppVoice, actionLabel: l.adviceActVoice, action: TipAction.voice),
    Tip('appTelegram', l.adviceAppTelegram, actionLabel: l.adviceActTelegram, action: TipAction.telegram),
    Tip('appNote', l.adviceAppNote),
    Tip('appMonthClose', l.adviceAppMonthClose),
  ];
  final money = [for (final t in moneyTips) Tip(t.id, t.text(l.localeName))];
  return [
    for (var i = 0; i < app.length || i < money.length; i++) ...[
      if (i < app.length) app[i],
      if (i < money.length) money[i],
    ],
  ];
}

/// Совет под номером [cursor]: список зациклен, номер растёт без ограничений.
Tip? tipAt(List<Tip> pool, int cursor) => pool.isEmpty ? null : pool[cursor % pool.length];
