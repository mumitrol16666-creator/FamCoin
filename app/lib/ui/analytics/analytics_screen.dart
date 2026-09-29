import 'package:flutter/material.dart';

import '../../state/app_scope.dart';
import '../widgets/common.dart';
import 'budget_tab.dart';
import 'capital_tab.dart';
import 'expenses_tab.dart';
import 'history_tab.dart';
import 'overview_tab.dart';

/// S23 — аналитика (редизайн 29.09.2026, D66): пять вкладок вместо одной
/// длинной ленты. Аналитика периода (Обзор/Расходы/Бюджет) и капитал на
/// текущий момент (Капитал/История) больше не смешиваются на одном экране —
/// это разные вопросы: «что происходит в этом месяце» и «что у меня есть
/// сейчас», у них разные единицы отсчёта и их нельзя складывать визуально.
class AnalyticsScreen extends StatefulWidget {
  const AnalyticsScreen({super.key});

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> with SingleTickerProviderStateMixin {
  late final _tab = TabController(length: 5, vsync: this);

  /// Общий для «Обзора» и «Расходов»: это один и тот же месяц, разъезжаться
  /// при переключении вкладок он не должен.
  int _offset = 0;
  int? _selectedDay;

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  void _openTab(int i) => setState(() => _tab.index = i);

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final state = AppScope.of(context).state;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: Text(l.analytics),
          bottom: TabBar(
            controller: _tab,
            // Фиксированные вкладки: все пять видны сразу, без прокрутки —
            // «Капитал» и «История» не должны прятаться за краем экрана.
            labelPadding: const EdgeInsets.symmetric(horizontal: 2),
            tabs: [Tab(text: l.tabOverview), Tab(text: l.tabExpenses), Tab(text: l.tabBudget), Tab(text: l.tabCapital), Tab(text: l.tabHistory)],
          ),
        ),
        body: TabBarView(controller: _tab, children: [
          OverviewTab(
            offset: _offset,
            onOffset: (o) => setState(() {
              _offset = o;
              _selectedDay = null;
            }),
            selectedDay: _selectedDay,
            onSelectDay: (d) => setState(() => _selectedDay = d),
            onOpenTab: _openTab,
          ),
          ExpensesTab(offset: _offset, onOffset: (o) => setState(() => _offset = o)),
          const BudgetTab(),
          const CapitalTab(),
          const HistoryTab(),
        ]),
      ),
    );
  }
}
