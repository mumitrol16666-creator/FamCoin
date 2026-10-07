import 'package:flutter/material.dart';

import '../../state/app_scope.dart';
import '../budget/budget_screen.dart';
import '../widgets/common.dart';
import 'money_tab.dart';
import 'month_tab.dart';

/// Разделы старые (их знают подсказки консультанта и ссылки из приложения), вкладок
/// три (D136): обзор, расходы и история — это «Месяц», капитал — «Деньги».
enum AnalyticsSection {
  overview,
  expenses,
  budget,
  capital,
  history;

  /// Номер вкладки: Месяц, Деньги, Бюджет.
  int get tabIndex => switch (this) {
        overview || expenses || history => 0,
        capital => 1,
        budget => 2,
      };
}

/// Единый раздел: отчёты о прошлом и отдельная вкладка планирования.
class AnalyticsScreen extends StatefulWidget {
  const AnalyticsScreen({super.key, this.initialSection = AnalyticsSection.overview});
  final AnalyticsSection initialSection;

  @override
  State<AnalyticsScreen> createState() => AnalyticsScreenState();
}

class AnalyticsScreenState extends State<AnalyticsScreen> with SingleTickerProviderStateMixin {
  late final _tab = TabController(length: 3, initialIndex: widget.initialSection.tabIndex, vsync: this);

  void openSection(AnalyticsSection section, {bool currentMonth = false}) {
    if (currentMonth) _onOffset(0);
    _tab.animateTo(section.tabIndex);
  }

  /// Месяц, выбранный на вкладке «Месяц».
  int _offset = 0;
  int? _selectedDay;

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  /// Смена месяца (F05): выбранный день сбрасывается всегда, иначе он переживал переход в более короткий месяц и ломал график.
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
                        tabs: [Tab(text: l.tabMonth), Tab(text: l.tabMoney), Tab(text: l.navBudget)],
          ),
        ),
        body: TabBarView(controller: _tab, children: [
          MonthTab(
            offset: _offset,
            onOffset: _onOffset,
            selectedDay: _selectedDay,
            onSelectDay: (d) => setState(() => _selectedDay = d),
          ),
          MoneyTab(),
          const BudgetScreen(embedded: true),
        ]),
      ),
    );
  }
}
