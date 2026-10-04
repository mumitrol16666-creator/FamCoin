/// Снимок показателей для ИИ-консультанта (D82).
///
/// Ничего не считается специально для ИИ: это те же числа, что рисуют экраны,
/// взятые из `AppState`. Модель получает их готовыми и только объясняет.
/// Суммы — в тенге (не в тиынах), чтобы модели не приходилось делить на сто.
/// Чего приложение не знает — передаётся как `null`, а не как ноль.
library;

import 'package:famcoin_core/famcoin_core.dart';
import 'package:intl/intl.dart';

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

/// «2 октября 2026» на языке интерфейса.
String _dayText(DateTime d, AppLocalizations l) => DateFormat('d MMMM y', l.localeName).format(d);

/// «октябрь 2026» на языке интерфейса.
String _monthText(DateTime d, AppLocalizations l) => DateFormat('LLLL y', l.localeName).format(d);

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
  'операции старше прошлого месяца и мелкие операции сверх списков',
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
/// Переводы, долги и исправления сюда не входят. Операции разложены по дням
/// (D91): сегодня, вчера, позавчера и раньше. Пустой список прямо говорит «за
/// этот день ничего нет» — считать дни в уме модель умеет плохо и вчерашнюю
/// операцию называла позавчерашней.
Map<String, Object?> _operations(AppState s, AppLocalizations l) {
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

  Map<String, Object?> row(Transaction t, {required bool dated}) {
    final expense = t.type == EventType.expense;
    final kind = expense ? LedgerKind.expense : LedgerKind.income;
    final categories = {
      for (final p in t.postings)
        if (s.ledger.account(p.accountId).kind == kind) categoryName(l, p.accountId.substring(p.accountId.indexOf(':') + 1)),
    };
    final account = t.postings.map((p) => s.accountInfo(p.accountId)).whereType<AccountInfo>().firstOrNull;
    final note = '${t.meta['note'] ?? ''}'.trim();
    return {
      if (dated) 'date': _dayText(t.date, l),
      'type': expense ? 'expense' : 'income',
      'amount': _t(amount(t)),
      'category': categories.join(', '),
      if (account != null) 'account': account.name,
      if (note.isNotEmpty) 'note': note.length > _noteLength ? '${note.substring(0, _noteLength)}…' : note,
      if (t.meta['unexpected'] == true) 'unexpected': true else if (t.meta['planned'] != null || t.meta['plannedPurchase'] == true) 'planned': true,
    };
  }

  final shown = [for (final t in all) if (chosen.contains(t)) t];
  // Доходы — отдельным списком (D100): в общем списке за день модель
  // перечисляла «подработку» и «уроки» среди того, на что ушли деньги.
  final spends = [for (final t in shown) if (t.type == EventType.expense) t];
  final incomes = [for (final t in shown) if (t.type == EventType.income) t];
  List<Map<String, Object?>> on(int daysAgo) => [for (final t in spends) if (daysBetween(t.date, s.today) == daysAgo) row(t, dated: false)];
  return {
    'operationsToday': on(0),
    'operationsYesterday': on(1),
    'operationsDayBeforeYesterday': on(2),
    'operationsEarlier': [
      for (final t in spends)
        if (daysBetween(t.date, s.today) case final d when d > 2 || d < 0) row(t, dated: true),
    ],
    'incomes': [for (final t in incomes) row(t, dated: true)],
  };
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
  return r.income != 0 || r.total != 0;
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
    // Даты — готовыми словами («2 октября»): считать дни и переводить числа
    // в названия месяцев модель умеет плохо.
    'today': _dayText(s.today, l),
    'yesterday': _dayText(DateTime(s.today.year, s.today.month, s.today.day - 1), l),
    'dayBeforeYesterday': _dayText(DateTime(s.today.year, s.today.month, s.today.day - 2), l),
    'tracking': {
      // С какого дня ведётся учёт: до этой даты «нет данных», а не «было 0».
      'recordedFrom': trackedFrom == null ? null : _dayText(trackedFrom, l),
      'daysOfHistory': trackedFrom == null ? 0 : s.today.difference(trackedFrom).inDays + 1,
      'notIncludedInThisSummary': _notIncluded,
    },
    'period': {'month': _month(month), 'monthText': _monthText(month, l), 'todayDay': s.today.day, 'daysInMonth': s.daysInMonth},
    'thisMonth': {
      // Доходы — всё, что пришло, включая взятое в долг (D105); earned — заработанное.
      'income': _t(r.income),
      'earned': _t(r.earned),
      // Расходы — всё, что ушло, включая кредиты и долги (D98).
      'expense': _t(r.total),
      // Сколько из них владелец отметил непредвиденными (D101).
      'unexpected': _t(s.unexpectedFor(month)),
      'ofWhichBorrowed': _t(r.borrowed),
      'incomeNote': 'income — всё, что пришло на счета за месяц: earned (заработанное) плюс ofWhichBorrowed (взято в долг деньгами). Возврат долгов — в expense строкой «Кредиты и долги». Для прогнозов и «хватит ли дохода» бери earned',
      'ofWhichDebtPayments': _t(r.debtPayments),
      'expenseNote': 'expense включает платежи по кредитам и долгам (ofWhichDebtPayments); в expenseByCategory они строкой «Кредиты и долги»',
      'incomeMinusExpense': _t(r.result),
      'cashFlow': _t(r.cashFlow),
      // Месяц идёт: суммы — «на сегодня», сравнивать их с целым прошлым месяцем нельзя.
      'monthInProgress': true,
      'daysElapsed': s.today.day,
    },
    'previousMonth': hasPrev
        ? {
            'month': _monthText(prevMonth, l),
            'income': _t(pr.income),
            'earned': _t(pr.earned),
            'ofWhichBorrowed': _t(pr.borrowed),
            'expense': _t(pr.total),
            'ofWhichDebtPayments': _t(pr.debtPayments),
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
            'carryCountedSince': s.dailyLimitCarryOn && s.dailyLimitSince != null ? _dayText(s.dailyLimitSince!, l) : null,
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
        for (final d in due.take(10)) {'name': d.planned.name, 'amount': _t(d.planned.amount), 'date': _dayText(d.date, l)},
      ],
    },
    // Лимиты категорий — плоским списком с готовым остатком: чем меньше
    // модели приходится считать самой, тем меньше ей есть где ошибиться.
    'categoryLimits': limits.isEmpty
        ? null
        : [
            for (final x in limits)
              {'name': categoryName(l, x.def.category), 'limit': _t(x.status.limit), 'spent': _t(x.status.spent), 'left': _t(x.status.remaining)},
          ],
    'categoryLimitsTotal': limits.isEmpty ? null : {'usedPercent': _round1(s.budgetUsedPercent), 'monthElapsedPercent': _round1(s.monthElapsedPercent)},
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
    // Разовые покупки впереди (D88): что, сколько, в каком месяце и сколько
    // откладывать в месяц, чтобы успеть.
    'plannedPurchases': s.purchases.isEmpty
        ? null
        : [
            for (final p in s.purchases)
              {
                'name': p.name,
                'amount': _t(p.amount),
                'month': _monthText(p.onceMonth!, l),
                // Копилка под покупку (D90): `null` — человек её не заводил.
                'savedInPiggy': s.purchaseGoal(p) == null ? null : _t(s.purchaseSaved(p)),
                'toSavePerMonth': _t(s.purchaseMonthly(p)),
              },
          ],
    'goals': goals.isEmpty
        ? null
        : [
            for (final g in goals)
              {'name': g.name, 'target': _t(g.target), 'saved': _t(s.goalSaved(g)), 'deadline': g.deadline == null ? null : _dayText(g.deadline!, l)},
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
    ..._operations(s, l),
    'operationsNote': 'operationsToday, operationsYesterday, operationsDayBeforeYesterday, operationsEarlier — только траты (расходы) по дням; incomes — только доходы, с датой. У траты с полем unexpected: true человек отметил её непредвиденной, с planned: true — запланированной; обе не входят в дневной лимит. Из операций этого и прошлого месяца взяты последние $_recentOperations и $_largestOperations самых крупных. Пустой список — за этот день трат нет. Заметки написал сам человек.',
    'familyMode': s.familyMode,
  };
}

/// Снимок для разбора закрытого месяца [month]: только его итоги.
Map<String, Object?> aiReviewContext(AppState s, AppLocalizations l, DateTime month) {
  final sum = s.monthSummary(month);
  final prevMonth = DateTime(month.year, month.month - 1, 1);
  final hasPrev = _hasData(s, prevMonth);
  return {
    'period': {'month': _month(month), 'monthText': _monthText(month, l), 'daysInMonth': sum.days},
    'month': {'income': _t(sum.income), 'expense': _t(sum.expense), 'ofWhichDebtPayments': _t(sum.debtPayments), 'incomeMinusExpense': _t(sum.income - sum.expense)},
    'previousMonth': hasPrev ? {'month': _monthText(prevMonth, l), 'income': _t(sum.prevIncome), 'expense': _t(sum.prevExpense)} : null,
    'expenseByCategory': _categories(s, l, sum.month, withPrevious: hasPrev),
    'expenseByType': _types(s, sum.month),
    'averageEverydaySpendPerDay': _t(sum.avgDaily),
    'plannedPayments': {'paid': sum.paymentsPaid, 'total': sum.paymentsTotal},
    'balanceCorrections': _t(sum.adjustments),
    'monthClosedByOwner': s.isMonthClosed(month),
  };
}
