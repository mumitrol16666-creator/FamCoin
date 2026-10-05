/// Кнопки-переходы под ответом консультанта (D108): по id из закрытого списка
/// ядра (`aiActions`) открывается нужный экран, форма или вкладка. Чего нет в
/// списке — не рисуется: сервер и так отбрасывает лишнее, здесь вторая защита.
library;

import 'package:famcoin_core/famcoin_core.dart' show aiActions;
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../state/app_scope.dart';
import '../widgets/common.dart';
import '../analytics/analytics_screen.dart';
import '../budget/calendar_screen.dart';
import '../budget/limits_section.dart';
import '../budget/month_close_screen.dart';
import '../budget/sheets.dart';
import '../home/home_screen.dart';
import '../ops/add_transaction_sheet.dart';
import '../ops/voice_sheet.dart';
import '../shell.dart';
import 'accounts_screen.dart';
import 'categories_screen.dart';
import 'family_screen.dart';
import 'notifications_screen.dart';
import 'security_screen.dart';
import 'settings_screen.dart';
import 'tariff_screen.dart';

/// Подпись кнопки; `null` — приложение такого перехода не знает.
String? aiActionLabel(AppLocalizations l, String id) => switch (id) {
      'add_expense' => l.aiGoAddExpense,
      'voice' => l.aiGoVoice,
      'journal' => l.aiGoJournal,
      'analytics_overview' => l.aiGoOverview,
      'analytics_expenses' => l.aiGoExpenses,
      'analytics_budget' => l.aiGoBudget,
      'debts' => l.aiGoDebts,
      'analytics_capital' => l.aiGoCapital,
      'analytics_history' => l.aiGoHistory,
      'limits' => l.aiGoLimits,
      'add_limit' => l.aiGoAddLimit,
      'daily_limit' => l.aiGoDailyLimit,
      'calendar' => l.aiGoCalendar,
      'add_planned' => l.aiGoAddPlanned,
      'add_purchase' => l.aiGoAddPurchase,
      'add_goal' => l.aiGoAddGoal,
      'add_debt' => l.aiGoAddDebt,
      'accounts' => l.aiGoAccounts,
      'add_account' => l.aiGoAddAccount,
      'month_close' => l.aiGoMonthClose,
      'categories' => l.aiGoCategories,
      'family' => l.aiGoFamily,
      'notifications' => l.aiGoNotifications,
      'tariff' => l.aiGoTariff,
      'settings' => l.aiGoSettings,
      'security' => l.aiGoSecurity,
      _ => null,
    };

/// Известные приложению id в порядке ответа.
List<String> knownActionIds(Iterable<String> ids, AppLocalizations l) => [
      for (final id in ids)
        if (aiActions.containsKey(id) && aiActionLabel(l, id) != null) id,
    ];

/// Выполняет переход. Формы открываются поверх чата (вернуться легко), экраны —
/// тоже поверх, а вкладки нижней панели требуют закрыть чат и переключить оболочку.
Future<void> runAiAction(BuildContext context, String id) async {
  final state = AppScope.of(context).state;
  void push(Widget screen) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
  void tab(void Function() open) {
    Navigator.of(context).popUntil((r) => r.isFirst);
    open();
  }

  switch (id) {
    case 'add_expense':
      await showAddTransactionSheet(context);
    case 'voice':
      await showVoiceSheet(context);
    case 'journal':
      tab(Shell.openJournal);
    case 'analytics_overview':
      tab(() => Shell.openAnalytics(AnalyticsSection.overview));
    case 'analytics_expenses':
      tab(() => Shell.openAnalytics(AnalyticsSection.expenses));
    case 'analytics_budget':
      tab(() => Shell.openAnalytics(AnalyticsSection.budget));
    case 'debts':
      tab(() => Shell.openAnalytics(AnalyticsSection.budget));
    case 'analytics_capital':
      tab(() => Shell.openAnalytics(AnalyticsSection.capital));
    case 'analytics_history':
      tab(() => Shell.openAnalytics(AnalyticsSection.history));
    case 'limits':
      push(const LimitsScreen());
    case 'add_limit':
      await addLimitFlow(context);
    case 'daily_limit':
      HomeScreen.showLimitSheet(context, state);
    case 'calendar':
      push(const CalendarScreen());
    case 'add_planned':
      await addPlannedFlow(context);
    case 'add_purchase':
      await addPurchaseFlow(context);
    case 'add_goal':
      await showGoalSheet(context);
    case 'add_debt':
      await addBankDebtFlow(context);
    case 'accounts':
      push(const AccountsScreen());
    case 'add_account':
      await addAccountFlow(context);
    case 'month_close':
      push(const MonthCloseListScreen());
    case 'categories':
      push(const CategoriesScreen());
    case 'family':
      push(const FamilyScreen());
    case 'notifications':
      push(const NotificationsScreen());
    case 'tariff':
      push(const TariffScreen());
    case 'settings':
      push(const SettingsScreen());
    case 'security':
      push(const SecurityScreen());
  }
}

/// Ряд кнопок под ответом консультанта.
class AiActionChips extends StatelessWidget {
  const AiActionChips(this.ids, {super.key});
  final List<String> ids;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final known = knownActionIds(ids, l);
    if (known.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Wrap(spacing: 8, runSpacing: 6, children: [
        for (final id in known)
          ActionChip(
            avatar: const Icon(Icons.arrow_outward, size: 16),
            label: Text(aiActionLabel(l, id)!),
            onPressed: () => runAiAction(context, id),
          ),
      ]),
    );
  }
}
