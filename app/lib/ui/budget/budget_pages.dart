import 'package:famcoin_core/famcoin_core.dart' show everyYear;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../state/app_scope.dart';
import '../../state/models.dart';
import '../../theme/app_theme.dart';
import '../onboarding/onboarding_screen.dart' show scheduleLabel;
import '../ops/add_transaction_sheet.dart';
import '../widgets/common.dart';
import 'budget_forecast_card.dart';
import 'calendar_screen.dart';
import 'debt_screens.dart';
import 'goal_card.dart';
import 'limits_section.dart';
import 'sheets.dart';

/// Отдельные экраны направлений «Бюджета» (D135): лимиты, платежи, покупки,
/// цели, долги, прогноз. Раньше всё это шло одной длинной лентой; теперь «Бюджет»
/// — набор кнопок-направлений, а содержимое каждого лежит на своём экране.

/// Общая оболочка страницы направления: заголовок и прокручиваемое содержимое.
/// Заголовок раздела внутри списка пустой: название уже в шапке экрана, а справа
/// остаётся кнопка «Добавить».
class _BudgetPage extends StatelessWidget {
  const _BudgetPage({required this.title, required this.builder});
  final String title;
  final List<Widget> Function(BuildContext context) builder;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context).state;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: Text(title)),
        body: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: builder(context)),
      ),
    );
  }
}

/// Лимиты по категориям: сводка, первые строки, «Все лимиты».
class BudgetLimitsPage extends StatelessWidget {
  const BudgetLimitsPage({super.key});
  @override
  Widget build(BuildContext context) => _BudgetPage(title: context.l10n.limits, builder: (_) => const [LimitsSection()]);
}

/// Обязательные платежи: список, календарь, «Добавить платёж».
class BudgetPaymentsPage extends StatelessWidget {
  const BudgetPaymentsPage({super.key});
  @override
  Widget build(BuildContext context) => _BudgetPage(
        title: context.l10n.planned,
        builder: (context) {
          final l = context.l10n;
          final state = AppScope.of(context).state;
          final fam = context.fam;
          final locale = Localizations.localeOf(context).toString();
          final nextDue = state.dueItems(state.today.add(const Duration(days: 62)));
          return [
              SectionHeader('', action: l.calendar, onAction: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CalendarScreen()))),
              if (state.planned.every((p) => p.once != null || p.person != null))
                EmptyHint(l.noPlanned, icon: Icons.event_repeat_outlined)
              else
                AppCard(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Column(children: [
                    for (final p in state.planned.where((p) => p.once == null && p.person == null))
                      Builder(builder: (context) {
                        final next = nextDue.where((d) => d.planned.id == p.id).firstOrNull;
                        final paidNow = state.paidThisPeriod(p);
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: CategoryAvatar.of(categoryById(p.debtId != null ? debtsCategory : p.category)),
                          title: Text(p.name),
                          subtitle: Text(
                            [
                              scheduleLabel(l, locale, p.every, p.day, p.weekday, p.monthOfYear),
                              if (paidNow) (p.every == everyYear ? l.paidThisYear : l.paidThisMonth),
                              if (next != null) '${l.nextPayment}: ${DateFormat.MMMMd(locale).format(next.date)}',
                            ].join(' · '),
                            style: TextStyle(fontSize: 12, color: paidNow ? fam.income : fam.text2),
                          ),
                          trailing: MoneyText(p.amount),
                          // Нет ближайшего срока (всё оплачено) — нажатие открывает правку.
                          onTap: () => next == null ? editPlannedFlow(context, p) : showPayDueSheet(context, next),
                          onLongPress: () => deletePlannedFlow(context, p),
                        );
                      }),
                  ]),
                ),
              OutlinedButton.icon(onPressed: () => addPlannedFlow(context), icon: const Icon(Icons.add), label: Text(l.addPayment)),
          ];
        },
      );
}

/// Разовые покупки: колёса к зиме, страховка, отпуск.
class BudgetPurchasesPage extends StatelessWidget {
  const BudgetPurchasesPage({super.key});
  @override
  Widget build(BuildContext context) => _BudgetPage(
        title: context.l10n.purchases,
        builder: (context) {
          final l = context.l10n;
          final state = AppScope.of(context).state;
          final fam = context.fam;
          final locale = Localizations.localeOf(context).toString();
          return [
              // Разовые покупки (D88): колёса к зиме, страховка, отпуск — не
              // ежемесячный платёж и не обязательно копилка, а «в марте уйдёт 100 000».
              SectionHeader('', action: l.add, onAction: () => addPurchaseFlow(context)),
              if (state.purchases.isEmpty)
                EmptyHint(l.noPurchases, icon: Icons.shopping_bag_outlined)
              else
                AppCard(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Column(children: [
                    for (final p in state.purchases)
                      Builder(builder: (context) {
                        final m = p.onceMonth!;
                        final name = toBeginningOfSentenceCase(DateFormat.yMMMM(locale).format(m));
                        final overdue = m.isBefore(state.monthStart);
                        final saving = state.purchaseGoal(p) != null;
                        final saved = state.purchaseSaved(p);
                        final monthly = state.purchaseMonthly(p);
                        final when = overdue
                            ? l.purchaseOverdue(name)
                            : m == state.monthStart
                                ? l.purchaseThisMonth(name)
                                : saving
                                    ? name
                                    : l.purchaseBy(name, moneyInText(monthly));
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: CategoryAvatar.of(categoryById(p.category)),
                          title: Text(p.name),
                          subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(when, style: TextStyle(fontSize: 12, color: overdue ? fam.expense : fam.text2)),
                            // Копят в копилку (D90): сколько уже есть и сколько осталось откладывать.
                            if (saving) ...[
                              Text(
                                '${l.purchaseProgress(moneyInText(saved), moneyInText(p.amount))} · ${monthly == 0 ? l.purchaseReady : l.purchaseMore(moneyInText(monthly))}',
                                style: TextStyle(fontSize: 12, color: fam.text2),
                              ),
                              const SizedBox(height: 4),
                              UsageBar(value: saved, max: p.amount, color: context.scheme.primary),
                            ],
                          ]),
                          trailing: MoneyText(p.amount),
                          onTap: () => showPurchaseSheet(context, p),
                        );
                      }),
                  ]),
                ),
          ];
        },
      );
}

/// Цели и копилки.
class BudgetGoalsPage extends StatelessWidget {
  const BudgetGoalsPage({super.key});
  @override
  Widget build(BuildContext context) => _BudgetPage(
        title: context.l10n.goals,
        builder: (context) {
          final l = context.l10n;
          final state = AppScope.of(context).state;
          final purchaseGoals = state.purchases.map((p) => p.goalId).whereType<String>().toSet();
          final standaloneGoals = state.goals.where((g) => !purchaseGoals.contains(g.id)).toList();
          return [
              SectionHeader('', action: l.add, onAction: () => showGoalSheet(context)),
              if (standaloneGoals.isEmpty) EmptyHint(purchaseGoals.isEmpty ? l.noGoals : l.purchaseGoalsNote, icon: Icons.flag_outlined),
              for (final g in standaloneGoals) GoalCard(goal: g),
          ];
        },
      );
}

/// Долги: кредиты, рассрочки, личные долги.
class BudgetDebtsPage extends StatelessWidget {
  const BudgetDebtsPage({super.key});
  @override
  Widget build(BuildContext context) => _BudgetPage(
        title: context.l10n.debts,
        builder: (context) {
          final l = context.l10n;
          final state = AppScope.of(context).state;
          final fam = context.fam;
          final people = state.personDebts;
          return [
              SectionHeader('', action: l.add, onAction: () => _addDebtChoice(context)),
              if (state.bankDebts.isEmpty && people.isEmpty)
                EmptyHint(l.noDebts, icon: Icons.handshake_outlined)
              else
                AppCard(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Column(children: [
                    for (final d in state.bankDebts)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: CategoryAvatar(d.kind == 'creditCard' ? Icons.credit_card_outlined : Icons.account_balance_outlined),
                        title: Text(d.name),
                        subtitle: Text('${debtKindName(l, d.kind)}${d.rate > 0 ? ' · ${d.rate}%' : ''}', style: TextStyle(fontSize: 12, color: fam.text2)),
                        trailing: MoneyText(state.debtBalance(d.id), color: fam.debt),
                        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => BankDebtScreen(debtId: d.id))),
                      ),
                    for (final p in people)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: CircleAvatar(child: Text(p.person.characters.first.toUpperCase())),
                        title: Text(p.person),
                        subtitle: Text(p.oweMe ? l.oweMe : l.iOwe, style: TextStyle(fontSize: 12, color: fam.text2)),
                        trailing: MoneyText(p.amount, color: p.oweMe ? fam.income : fam.expense),
                        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PersonDebtScreen(person: p.person))),
                      ),
                  ]),
                ),
              if (state.bankDebts.where((d) => state.debtBalance(d.id) > 0).length > 1)
                OutlinedButton(
                  onPressed: () => state.pro
                      ? Navigator.push(context, MaterialPageRoute(builder: (_) => const DebtStrategyScreen()))
                      : showProGate(context, l.proGateEarly),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [Text(l.strategy), if (!state.pro) ...[const SizedBox(width: 6), const ProBadge()]]),
                ),
          ];
        },
      );
}

/// Прогноз остатка до конца месяца.
class BudgetForecastPage extends StatelessWidget {
  const BudgetForecastPage({super.key});
  @override
  Widget build(BuildContext context) => _BudgetPage(title: context.l10n.forecastTitle, builder: (_) => const [BudgetForecastCard()]);
}

/// «Добавить» в «Долгах»: кредит и долг человеку — разные вещи (банк с графиком
/// платежей против «взял у друга»), и раньше предлагался только кредит.
Future<void> _addDebtChoice(BuildContext context) {
  final l = context.l10n;
  Widget option(BuildContext ctx, IconData icon, String title, String note, VoidCallback onTap) => ListTile(
        leading: CircleAvatar(child: Icon(icon)),
        title: Text(title),
        subtitle: Text(note),
        onTap: () {
          Navigator.pop(ctx);
          onTap();
        },
      );
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    useSafeArea: true,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 8), child: Align(alignment: Alignment.centerLeft, child: Text(l.debtAddTitle, style: Theme.of(ctx).textTheme.titleLarge))),
        option(ctx, Icons.person_add_alt_1_outlined, l.debtAddBorrow, l.debtAddBorrowNote, () => showAddTransactionSheet(context, kind: FieldsKind.debt, debtKind: 'borrow')),
        option(ctx, Icons.volunteer_activism_outlined, l.debtAddLend, l.debtAddLendNote, () => showAddTransactionSheet(context, kind: FieldsKind.debt, debtKind: 'lendOut')),
        option(ctx, Icons.account_balance_outlined, l.debtAddBank, l.debtAddBankNote, () => addBankDebtFlow(context)),
        const SizedBox(height: 8),
      ]),
    ),
  );
}
