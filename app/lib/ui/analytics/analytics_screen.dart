import 'package:flutter/material.dart';

import '../../state/app_scope.dart';
import '../budget/budget_screen.dart';
import '../widgets/common.dart';
import 'capital_tab.dart';
import 'expenses_tab.dart';
import 'history_tab.dart';
import 'overview_tab.dart';

enum AnalyticsSection { overview, expenses, budget, capital, history }

/// Единый раздел: отчёты о прошлом и отдельная вкладка планирования.
class AnalyticsScreen extends StatefulWidget {
  const AnalyticsScreen({super.key, this.initialSection = AnalyticsSection.overview});
  final AnalyticsSection initialSection;

  @override
  State<AnalyticsScreen> createState() => AnalyticsScreenState();
}

class AnalyticsScreenState extends State<AnalyticsScreen> with SingleTickerProviderStateMixin {
  late final _tab = TabController(length: AnalyticsSection.values.length, initialIndex: widget.initialSection.index, vsync: this);

  void openSection(AnalyticsSection section, {bool currentMonth = false}) {
    if (currentMonth) _onOffset(0);
    _tab.animateTo(section.index);
  }

  /// Общий для «Обзора» и «Расходов»: это один и тот же месяц, разъезжаться
  /// при переключении вкладок он не должен.
  int _offset = 0;
  int? _selectedDay;

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  void _openMonth(int offset) {
    _onOffset(offset);
    _tab.animateTo(0);
  }

  /// Общий обработчик смены месяца для «Обзора» и «Расходов» (F05): выбранный
  /// день сбрасывается всегда, а не только при смене месяца из «Обзора» —
  /// иначе он переживал переход в более короткий месяц и ломал график.
  void _onOffset(int o) => setState(() {
        _offset = o;
        _selectedDay = null;
      });

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
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            labelPadding: const EdgeInsets.symmetric(horizontal: 16),
            tabs: [Tab(text: l.tabOverview), Tab(text: l.tabExpenses), Tab(text: l.navBudget), Tab(text: l.tabCapital), Tab(text: l.tabHistory)],
          ),
        ),
        body: TabBarView(controller: _tab, children: [
          OverviewTab(
            offset: _offset,
            onOffset: _onOffset,
            selectedDay: _selectedDay,
            onSelectDay: (d) => setState(() => _selectedDay = d),
          ),
          ExpensesTab(offset: _offset, onOffset: _onOffset),
          BudgetScreen(embedded: true, onOpenReport: () => _openMonth(0)),
          const CapitalTab(),
          HistoryTab(onOpenMonth: _openMonth),
        ]),
      ),
    );
  }
}
