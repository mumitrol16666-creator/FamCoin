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
import '../widgets/common.dart';

/// Тиыны → тенге: целое, если копеек нет.
num _t(int minor) => minor % minorPerUnit == 0 ? minor ~/ minorPerUnit : minor / minorPerUnit;

double? _round1(double? v) => v == null ? null : (v * 10).round() / 10;

String _month(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}';

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

  return {
    'today': dateToJson(s.today),
    'period': {'month': _month(month), 'todayDay': s.today.day, 'daysInMonth': s.daysInMonth},
    'thisMonth': {'income': _t(r.income), 'expense': _t(r.expense), 'incomeMinusExpense': _t(r.result), 'cashFlow': _t(r.cashFlow)},
    'previousMonth': hasPrev ? {'month': _month(prevMonth), 'income': _t(pr.income), 'expense': _t(pr.expense)} : null,
    'money': {
      'onAccounts': _t(ex.liquid),
      'reservedForGoals': _t(ex.reserves),
      'accounts': [
        for (final a in s.activeAccounts) {'name': a.name, 'balance': _t(s.ledger.balance(a.id))},
      ],
    },
    'dailyLimit': s.dailyLimit == null
        ? null
        : {
            'perDay': _t(s.dailyLimit!),
            'spentToday': _t(ex.spent),
            'carryFromPreviousDays': s.dailyLimitCarryOn ? _t(ex.carry) : null,
            'availableToday': _t(ex.available ?? 0),
            'limitedByMoneyOnAccounts': ex.capped,
          },
    'paymentsUntilMonthEnd': {
      'unpaidTotal': _t(due.fold(0, (sum, d) => sum + d.planned.amount)),
      'overdueTotal': _t(due.where((d) => d.date.isBefore(s.today)).fold(0, (sum, d) => sum + d.planned.amount)),
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
    'expenseByType': _types(s, month),
    'monthEndBalanceForecast': {
      'estimate': _t(forecast.estimate),
      'rangeLow': _t(forecast.rangeLow),
      'rangeHigh': _t(forecast.rangeHigh),
      'note': 'Оценка свободных денег на конец месяца; диапазон — сценарий, а не вероятность',
    },
    'capital': {'money': _t(worth.money), 'owedToMe': _t(worth.receivables), 'debts': _t(worth.liabilities), 'capital': _t(worth.capital)},
    'bankDebts': debt.totalDebt == 0
        ? null
        : {'totalDebt': _t(debt.totalDebt), 'monthlyPayments': _t(debt.monthlyPayments), 'shareOfIncomePercent': _round1(debt.incomeSharePercent)},
    'goals': goals.isEmpty
        ? null
        : [
            for (final g in goals)
              {'name': g.name, 'target': _t(g.target), 'saved': _t(s.goalSaved(g)), 'deadline': g.deadline == null ? null : dateToJson(g.deadline!)},
          ],
    'observations': {
      'eveningShareOfDiscretionaryPercent': _round1(s.eveningDiscretionaryShare(month)),
      'largeExpensesWithoutLimit': s.unplannedLargeExpenses(month).length,
      'incomeDaySpendRatio': _round1(s.paydaySpendRatio()),
      'recurringPaymentsShareOfIncomePercent': _round1(s.recurringShareOfIncome),
    },
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
