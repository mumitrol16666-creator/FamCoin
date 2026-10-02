/// Снимок показателей для ИИ-консультанта (D82).
///
/// Ничего не считается специально для ИИ: это те же числа, что рисуют экраны,
/// взятые из `AppState`. Модель получает их готовыми и только объясняет.
/// Суммы — в тенге (не в тиынах), чтобы модели не приходилось делить на сто.
/// Чего приложение не знает — передаётся как `null`, а не как ноль.
library;

import 'package:famcoin_core/famcoin_core.dart';

import '../../l10n/app_localizations.dart';
import '../../state/app_state.dart';
import '../../state/models.dart';
import '../widgets/common.dart';

/// Тиыны → тенге: целое, если копеек нет.
num _t(int minor) => minor % minorPerUnit == 0 ? minor ~/ minorPerUnit : minor / minorPerUnit;

double? _round1(double? v) => v == null ? null : (v * 10).round() / 10;

/// Доля от дохода в процентах; больше 100 % — не показатель, а признак того,
/// что доходы записаны не полностью: такую долю не передаём (D83).
double? _share(double? v) => v == null || v > 100 ? null : _round1(v);

String _month(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}';

/// День первой записанной траты или дохода: с него начинается учёт.
DateTime? _trackedFrom(AppState s) {
  DateTime? first;
  for (final t in s.ledger.transactions) {
    if (t.type != EventType.expense && t.type != EventType.income) continue;
    if (first == null || t.date.isBefore(first)) first = t.date;
  }
  return first;
}

/// Сколько доходов записано за последние три месяца: по одному-двум
/// «траты в дни дохода» не закономерность, а случайность.
int _recentIncomes(AppState s) {
  final from = s.monthOf(-2);
  return s.ledger.transactions.where((t) => t.type == EventType.income && !s.ledger.isReversed(t.id) && !t.date.isBefore(from)).length;
}

/// Чего в сводке нет — чтобы консультант говорил «не вижу», а не домысливал.
const _notIncluded = [
  'операции старше прошлого месяца и мелкие операции сверх списка operations',
  'разбивка по членам семьи',
  'месяцы раньше прошлого',
  'категории и платежи сверх показанных в списках',
];

/// Сколько последних и сколько самых крупных операций видит консультант.
const _recentOperations = 30;
const _largestOperations = 10;
const _noteLength = 80;

/// Расходы и доходы этого и прошлого месяца для консультанта (D86): последние
/// по времени плюс самые крупные — с категорией, счётом и заметкой владельца.
/// Переводы, долги и исправления сюда не входят.
List<Map<String, Object?>> _operations(AppState s, AppLocalizations l) {
  final from = s.monthOf(-1);
  final all = [
    for (final t in s.userTransactions)
      if ((t.type == EventType.expense || t.type == EventType.income) && !t.date.isBefore(from)) t,
  ]; // уже по убыванию даты
  int amount(Transaction t) {
    final kind = t.type == EventType.expense ? LedgerKind.expense : LedgerKind.income;
    return t.postings.where((p) => s.ledger.account(p.accountId).kind == kind).fold(0, (sum, p) => sum + p.amount.abs());
  }

  final chosen = {...all.take(_recentOperations)};
  final bySize = [...all]..sort((a, b) => amount(b).compareTo(amount(a)));
  chosen.addAll(bySize.take(_largestOperations));

  return [
    for (final t in all)
      if (chosen.contains(t))
        () {
          final expense = t.type == EventType.expense;
          final kind = expense ? LedgerKind.expense : LedgerKind.income;
          final categories = {
            for (final p in t.postings)
              if (s.ledger.account(p.accountId).kind == kind) categoryName(l, p.accountId.substring(p.accountId.indexOf(':') + 1)),
          };
          final account = t.postings.map((p) => s.accountInfo(p.accountId)).whereType<AccountInfo>().firstOrNull;
          final note = '${t.meta['note'] ?? ''}'.trim();
          return <String, Object?>{
            'date': dateToJson(t.date),
            // «Сегодня / вчера / позавчера» — готовым словом: дни модель путает.
            if (s.today.difference(t.date).inDays case final d when d >= 0 && d <= 2) 'when': const ['сегодня', 'вчера', 'позавчера'][d],
            'type': expense ? 'expense' : 'income',
            'amount': _t(amount(t)),
            'category': categories.join(', '),
            if (account != null) 'account': account.name,
            if (note.isNotEmpty) 'note': note.length > _noteLength ? '${note.substring(0, _noteLength)}…' : note,
            if (t.meta['planned'] != null || t.meta['plannedPurchase'] == true) 'planned': true,
          };
        }(),
  ];
}

/// Категории месяца [month] с суммами прошлого месяца рядом — не больше 12.
List<Map<String, Object?>> _categories(AppState s, AppLocalizations l, DateTime month, {required bool withPrevious}) {
  final prev = {for (final e in s.categoriesFor(DateTime(month.year, month.month - 1, 1))) e.key: e.value};
  return [
    for (final e in s.categoriesFor(month).take(12))
      {'name': categoryName(l, e.key), 'amount': _t(e.value), if (withPrevious) 'previousMonthAmount': _t(prev[e.key] ?? 0)},
  ];
}

Map<String, Object?> _types(AppState s, DateTime month) {
  final split = s.expenseTypeSplit(month);
  return {'mandatory': _t(split.mandatory), 'regular': _t(split.regular), 'discretionary': _t(split.discretionary)};
}

/// Был ли учёт в месяце [month]: без операций «0 ₸» означал бы «нет данных».
bool _hasData(AppState s, DateTime month) {
  final r = s.reportFor(month);
  return r.income != 0 || r.expense != 0;
}

/// Снимок для чата: текущий месяц и состояние на сегодня.
Map<String, Object?> aiChatContext(AppState s, AppLocalizations l) {
  final month = s.monthStart;
  final prevMonth = DateTime(month.year, month.month - 1, 1);
  final hasPrev = _hasData(s, prevMonth);
  final r = s.monthReport;
  final pr = s.reportFor(prevMonth);
  final ex = s.limitExplain;
  final due = s.dueItems(s.monthEnd.subtract(const Duration(days: 1)));
  final forecast = s.monthEndForecast;
  final worth = s.ledger.netWorth();
  final debt = s.debtLoadStatus;
  final limits = s.currentLimitStatuses;
  final goals = s.goals;
  final avgIncome = s.avgMonthlyIncome();

  final firstName = '${s.profile['firstName'] ?? ''}'.trim();
  final trackedFrom = _trackedFrom(s);
  final allCategories = s.categoriesFor(month).length;

  return {
    // Только имя — чтобы консультант мог обратиться по имени; фамилия и дата
    // рождения не передаются.
    'userFirstName': firstName.isEmpty ? null : firstName,
    'today': dateToJson(s.today),
    // Готовые даты: считать дни в уме модель умеет плохо.
    'yesterday': dateToJson(s.today.subtract(const Duration(days: 1))),
    'dayBeforeYesterday': dateToJson(s.today.subtract(const Duration(days: 2))),
    'tracking': {
      // С какого дня ведётся учёт: до этой даты «нет данных», а не «было 0».
      'recordedFrom': trackedFrom == null ? null : dateToJson(trackedFrom),
      'daysOfHistory': trackedFrom == null ? 0 : s.today.difference(trackedFrom).inDays + 1,
      'notIncludedInThisSummary': _notIncluded,
    },
    'period': {'month': _month(month), 'todayDay': s.today.day, 'daysInMonth': s.daysInMonth},
    'thisMonth': {
      'income': _t(r.income),
      'expense': _t(r.expense),
      'incomeMinusExpense': _t(r.result),
      'cashFlow': _t(r.cashFlow),
      // Месяц идёт: суммы — «на сегодня», сравнивать их с целым прошлым месяцем нельзя.
      'monthInProgress': true,
      'daysElapsed': s.today.day,
    },
    'previousMonth': hasPrev
        ? {
            'month': _month(prevMonth),
            'income': _t(pr.income),
            'expense': _t(pr.expense),
            // Учёт начат посреди того месяца — его суммы неполные.
            'incomplete': trackedFrom != null && trackedFrom.isAfter(prevMonth),
          }
        : null,
    'money': {
      'onAccounts': _t(ex.liquid),
      'reservedForGoals': _t(ex.reserves),
      'accounts': [
        for (final a in s.activeAccounts)
          {
            'name': a.name,
            'balance': _t(s.ledger.balance(a.id)),
            // Счёт в минусе: что об этом сказал сам человек (D87); `null` — не пояснял.
            if (s.ledger.balance(a.id) < 0) ...{'inMinus': true, 'ownerExplanation': s.minusNote(a.id)},
          },
      ],
    },
    'dailyLimit': s.dailyLimit == null
        ? null
        : {
            'perDay': _t(s.dailyLimit!),
            'spentToday': _t(ex.spent),
            // Перенос (D64) — двумя положительными числами, чтобы его можно было
            // назвать словами: «не потратили раньше» или «потратили сверх лимита».
            'carryEnabled': s.dailyLimitCarryOn,
            'unspentFromPreviousDays': _t(ex.carry > 0 ? ex.carry : 0),
            'overspentOnPreviousDays': _t(ex.carry < 0 ? -ex.carry : 0),
            'carryCountedSince': s.dailyLimitCarryOn && s.dailyLimitSince != null ? dateToJson(s.dailyLimitSince!) : null,
            'availableToday': _t(ex.available ?? 0),
            'limitedByMoneyOnAccounts': ex.capped,
            'howItIsCalculated': 'availableToday = perDay + unspentFromPreviousDays − overspentOnPreviousDays − spentToday, но не больше денег на счетах',
          },
    'paymentsUntilMonthEnd': {
      'unpaidTotal': _t(due.fold(0, (sum, d) => sum + d.planned.amount)),
      'overdueTotal': _t(due.where((d) => d.date.isBefore(s.today)).fold(0, (sum, d) => sum + d.planned.amount)),
      'overdueNote': 'Просроченным считается платёж, не отмеченный оплаченным в приложении; он мог быть оплачен без отметки',
      'unpaidCount': due.length,
      'notEnoughMoneyNowBy': _t(ex.shortfall),
      'unpaid': [
        for (final d in due.take(10)) {'name': d.planned.name, 'amount': _t(d.planned.amount), 'date': dateToJson(d.date)},
      ],
    },
    'categoryLimits': limits.isEmpty
        ? null
        : {
            'usedPercent': _round1(s.budgetUsedPercent),
            'monthElapsedPercent': _round1(s.monthElapsedPercent),
            'limits': [
              for (final x in limits) {'category': categoryName(l, x.def.category), 'limit': _t(x.status.limit), 'spent': _t(x.status.spent)},
            ],
          },
    'expenseByCategory': _categories(s, l, month, withPrevious: hasPrev),
    'expenseCategoriesTotal': allCategories,
    'expenseByType': _types(s, month),
    'monthEndBalanceForecast': {
      // Средний расход в день взят по прошедшим дням месяца: в первую неделю
      // одна покупка сильно сдвигает оценку.
      'basedOnDays': s.today.day,
      'roughEstimate': s.today.day < 7,
      'estimate': _t(forecast.estimate),
      'rangeLow': _t(forecast.rangeLow),
      'rangeHigh': _t(forecast.rangeHigh),
      'note': 'Оценка свободных денег на конец месяца; диапазон — сценарий, а не вероятность',
    },
    'capital': {'money': _t(worth.money), 'owedToMe': _t(worth.receivables), 'debts': _t(worth.liabilities), 'capital': _t(worth.capital)},
    'bankDebts': debt.totalDebt == 0
        ? null
        : {'totalDebt': _t(debt.totalDebt), 'monthlyPayments': _t(debt.monthlyPayments), 'shareOfIncomePercent': _share(debt.incomeSharePercent)},
    'goals': goals.isEmpty
        ? null
        : [
            for (final g in goals)
              {'name': g.name, 'target': _t(g.target), 'saved': _t(s.goalSaved(g)), 'deadline': g.deadline == null ? null : dateToJson(g.deadline!)},
          ],
    'observations': {
      'eveningShareOfDiscretionaryPercent': _round1(s.eveningDiscretionaryShare(month)),
      'largeExpensesWithoutLimit': s.unplannedLargeExpenses(month).length,
      'incomeDaySpendRatio': _recentIncomes(s) < 3 ? null : _round1(s.paydaySpendRatio()),
      'recurringPaymentsShareOfIncomePercent': _share(s.recurringShareOfIncome),
    },
    'recordedIncome': {
      'averagePerMonth': _t(avgIncome),
      'recurringPaymentsPerMonth': _t(s.recurringMonthly),
      // Платежей больше, чем записано доходов: скорее всего, доходы внесены не все.
      'looksIncomplete': s.recurringMonthly > avgIncome,
    },
    'operations': _operations(s, l),
    'operationsNote': 'Расходы и доходы этого и прошлого месяца: последние $_recentOperations и $_largestOperations самых крупных. Заметки написал сам человек.',
    'familyMode': s.familyMode,
  };
}

/// Снимок для разбора закрытого месяца [month]: только его итоги.
Map<String, Object?> aiReviewContext(AppState s, AppLocalizations l, DateTime month) {
  final sum = s.monthSummary(month);
  final prevMonth = DateTime(month.year, month.month - 1, 1);
  final hasPrev = _hasData(s, prevMonth);
  return {
    'period': {'month': _month(month), 'daysInMonth': sum.days},
    'month': {'income': _t(sum.income), 'expense': _t(sum.expense), 'incomeMinusExpense': _t(sum.income - sum.expense)},
    'previousMonth': hasPrev ? {'month': _month(prevMonth), 'income': _t(sum.prevIncome), 'expense': _t(sum.prevExpense)} : null,
    'expenseByCategory': _categories(s, l, sum.month, withPrevious: hasPrev),
    'expenseByType': _types(s, sum.month),
    'averageEverydaySpendPerDay': _t(sum.avgDaily),
    'plannedPayments': {'paid': sum.paymentsPaid, 'total': sum.paymentsTotal},
    'balanceCorrections': _t(sum.adjustments),
    'monthClosedByOwner': s.isMonthClosed(month),
  };
}
