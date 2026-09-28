import 'package:flutter/material.dart';

import '../state/app_scope.dart';
import '../theme/app_theme.dart';
import 'budget/budget_screen.dart';
import 'home/home_screen.dart';
import 'more/more_screen.dart';
import 'ops/add_transaction_sheet.dart';
import 'ops/voice_sheet.dart';
import 'ops/journal_screen.dart';
import 'widgets/common.dart';
import 'widgets/season_background.dart';

/// Оболочка с нижней панелью: Главная · Операции · ＋ · Бюджет · Ещё.
/// «＋» открывает форму, не переключает вкладку (раздел 3 карты).
class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _tab = 0;

  void _openAdd() => showAddTransactionSheet(context);

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final fam = context.fam;
    final scheme = context.scheme;

    Widget item(int index, IconData icon, String label) {
      final on = _tab == index;
      return Expanded(
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => setState(() => _tab = index),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, color: on ? scheme.primary : fam.text2),
              const SizedBox(height: 2),
              Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 10.5, color: on ? scheme.primary : fam.text2, fontWeight: on ? FontWeight.w600 : FontWeight.w400)),
            ]),
          ),
        ),
      );
    }

    final theme = Theme.of(context);
    final state = AppScope.of(context).state;
    final tabs = <Widget>[
      HomeScreen(onOpenJournal: () => setState(() => _tab = 1), onOpenBudget: () => setState(() => _tab = 2), onAdd: _openAdd),
      const JournalScreen(),
      const BudgetScreen(),
      const MoreScreen(),
    ];
    return Scaffold(
      // Сезонный фон живёт под вкладками; их Scaffold и AppBar здесь прозрачные.
      // Экраны, открываемые поверх, остаются непрозрачными — иначе при переходе
      // просвечивала бы предыдущая страница.
      body: SeasonBackground(
        child: Theme(
          data: theme.copyWith(
            scaffoldBackgroundColor: Colors.transparent,
            appBarTheme: theme.appBarTheme.copyWith(backgroundColor: Colors.transparent),
          ),
          child: Stack(children: [
            // Вкладки живут одновременно (состояние не теряется), активная
            // проявляется коротким затуханием вместо резкой смены.
            for (final (i, w) in tabs.indexed)
              IgnorePointer(
                ignoring: _tab != i,
                child: ExcludeSemantics(
                  excluding: _tab != i,
                  child: AnimatedOpacity(opacity: _tab == i ? 1 : 0, duration: const Duration(milliseconds: 180), curve: Curves.easeOut, child: w),
                ),
              ),
            // Запрос в полёте: тонкая полоска под статус-баром, экран не блокируется.
            Positioned(
              top: MediaQuery.paddingOf(context).top,
              left: 0,
              right: 0,
              child: ListenableBuilder(
                listenable: state,
                builder: (_, __) => AnimatedOpacity(
                  opacity: state.busy ? 1 : 0,
                  duration: const Duration(milliseconds: 150),
                  child: LinearProgressIndicator(minHeight: 2, backgroundColor: Colors.transparent, color: fam.accent),
                ),
              ),
            ),
          ]),
        ),
      ),
      // Кнопка живёт у Scaffold, а не внутри панели: так вся её площадь
      // нажимается, включая часть, выступающую над панелью.
      floatingActionButton: Material(
        color: fam.accent,
        borderRadius: BorderRadius.circular(20),
        elevation: 6,
        shadowColor: fam.accent.withValues(alpha: .5),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: _openAdd,
          // Долгое нажатие — сразу голосом (раздел 3: дополнительный путь, не единственный).
          onLongPress: () => showVoiceSheet(context),
          child: Semantics(
            button: true,
            label: l.add,
            child: SizedBox(width: 60, height: 60, child: Icon(Icons.add, size: 32, color: fam.onAccent)),
          ),
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      bottomNavigationBar: Material(
        color: scheme.surface,
        child: SafeArea(
          top: false,
          child: Container(
            decoration: BoxDecoration(border: Border(top: BorderSide(color: fam.line))),
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
            child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              item(0, Icons.home_outlined, l.navHome),
              item(1, Icons.list_alt_outlined, l.navOps),
              // Подпись под кнопкой «＋»; сама кнопка нарисована поверх панели.
              SizedBox(
                width: 84,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(l.add, textAlign: TextAlign.center, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                ),
              ),
              item(2, Icons.pie_chart_outline, l.navBudget),
              item(3, Icons.more_horiz, l.navMore),
            ]),
          ),
        ),
      ),
    );
  }
}
