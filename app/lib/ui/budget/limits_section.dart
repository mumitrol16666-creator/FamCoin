import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../state/app_scope.dart';
import '../../state/models.dart';
import '../../theme/app_theme.dart';
import '../analytics/category_screen.dart';
import '../analytics/chart_colors.dart';
import '../widgets/common.dart';
import 'sheets.dart';

/// Краткий обзор: не более трёх строк при любом количестве лимитов.
class LimitsSection extends StatelessWidget {
  const LimitsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context).state;
    final l = context.l10n;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final limits = state.limits;
        final items = state.currentLimitStatuses;
        final preview = items.take(3).toList();
        final exceeded = items.where((item) => item.status.remaining < 0).length;
        final planned = items.fold(0, (sum, item) => sum + item.status.limit);
        final spent = items.fold(0, (sum, item) => sum + item.status.spent);
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SectionHeader(l.limits, action: l.add, onAction: () => addLimitFlow(context)),
          if (items.isEmpty)
            EmptyHint(l.noLimits, icon: Icons.speed_outlined)
          else ...[
            AppCard(
              key: const ValueKey('limits-summary'),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(l.limitsScope, style: TextStyle(fontSize: 12, color: context.fam.text2)),
                const SizedBox(height: 8),
                _Amount(label: l.limitsTotal, amount: planned, size: 24),
                const SizedBox(height: 12),
                LinearProgressIndicator(
                  value: planned > 0 ? (spent / planned).clamp(0.0, 1.0) : spent > 0 ? 1 : 0,
                  minHeight: 9,
                  borderRadius: BorderRadius.circular(8),
                  color: spent > planned ? context.fam.expense : context.fam.income,
                  backgroundColor: context.scheme.surfaceContainerHighest,
                  semanticsLabel: '${l.planVsFact}. ${moneyInText(spent)} ${l.ofLimit} ${moneyInText(planned)}',
                ),
                const SizedBox(height: 12),
                _AdaptivePair(
                  leading: _Amount(label: l.limitSpent, amount: spent),
                  trailing: _Amount(
                    label: planned - spent < 0 ? l.limitOver : l.limitsRemaining,
                    amount: (planned - spent).abs(),
                    color: planned - spent < 0 ? context.fam.expense : null,
                  ),
                ),
                if (exceeded > 0) ...[
                  const SizedBox(height: 8),
                  TextButton.icon(
                    key: const ValueKey('limits-exceeded'),
                    onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const LimitsScreen(initialFilter: LimitFilter.exceeded))),
                    icon: const Icon(Icons.error_outline, size: 18),
                    label: Text(l.limitsExceededCount(exceeded)),
                    style: TextButton.styleFrom(foregroundColor: context.fam.expense),
                  ),
                ],
              ]),
            ),
            Card(
              clipBehavior: Clip.antiAlias,
              child: Column(children: [
                for (var i = 0; i < preview.length; i++) ...[
                  if (i > 0) Divider(height: 1, indent: 16, endIndent: 16, color: context.fam.line),
                  _LimitRow(key: ValueKey('limit-${preview[i].def.id}'), def: preview[i].def, status: preview[i].status),
                ],
              ]),
            ),
            if (items.length > preview.length)
              Text(l.limitsPreview(preview.length, items.length), style: TextStyle(fontSize: 12, color: context.fam.text2)),
            OutlinedButton.icon(
              key: const ValueKey('all-limits'),
              onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const LimitsScreen())),
              icon: const Icon(Icons.list_alt_outlined),
              label: Text(l.allLimitsCount(items.length)),
            ),
          ],
          if (!state.pro)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('${l.limitFreeNote}: ${limits.length} / 2', style: TextStyle(fontSize: 12, color: context.fam.text2)),
            ),
        ]);
      },
    );
  }
}

enum LimitFilter { all, near, exceeded, unused }

bool _matchesFilter(LimitStatus status, LimitFilter filter) => switch (filter) {
  LimitFilter.all => true,
  LimitFilter.near => status.limit > 0 && status.warn80 && status.remaining >= 0,
  LimitFilter.exceeded => status.remaining < 0,
  LimitFilter.unused => status.spent == 0,
};

/// Полный список строит только видимые строки. Поиск и фильтр не меняют
/// справочник и сохраняются при возврате из подробностей или операций.
class LimitsScreen extends StatefulWidget {
  const LimitsScreen({super.key, this.initialFilter = LimitFilter.all});
  final LimitFilter initialFilter;

  @override
  State<LimitsScreen> createState() => _LimitsScreenState();
}

class _LimitsScreenState extends State<LimitsScreen> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  late LimitFilter _filter = widget.initialFilter;

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _refresh() {
    setState(() {});
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context).state;
    final l = context.l10n;
    final locale = Localizations.localeOf(context).toString();
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final items = state.currentLimitStatuses;
        final query = _search.text.trim().toLowerCase();
        final searched = items.where((item) => categoryName(l, item.def.category).toLowerCase().contains(query)).toList();
        final visible = searched.where((item) => _matchesFilter(item.status, _filter)).toList();
        final labels = {
          LimitFilter.all: l.all,
          LimitFilter.near: l.limitsFilterNear,
          LimitFilter.exceeded: l.limitsFilterExceeded,
          LimitFilter.unused: l.limitsFilterUnused,
        };
        return Scaffold(
          appBar: AppBar(
            title: Text(l.limits),
            actions: [IconButton(tooltip: l.addLimit, onPressed: () => addLimitFlow(context), icon: const Icon(Icons.add))],
          ),
          body: CustomScrollView(
            controller: _scroll,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                sliver: SliverToBoxAdapter(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text(toBeginningOfSentenceCase(DateFormat.yMMMM(locale).format(state.today)), style: TextStyle(color: context.fam.text2)),
                  const SizedBox(height: 12),
                  TextField(
                    key: const ValueKey('limits-search'),
                    controller: _search,
                    onChanged: (_) => _refresh(),
                    decoration: InputDecoration(
                      labelText: l.limitsSearch,
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _search.text.isEmpty ? null : IconButton(
                        tooltip: l.limitsClearSearch,
                        onPressed: () { _search.clear(); _refresh(); },
                        icon: const Icon(Icons.close),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(spacing: 8, runSpacing: 4, children: [
                    for (final filter in LimitFilter.values)
                      ChoiceChip(
                        key: ValueKey('limits-filter-${filter.name}'),
                        label: Text('${labels[filter]} · ${searched.where((item) => _matchesFilter(item.status, filter)).length}'),
                        selected: _filter == filter,
                        showCheckmark: false,
                        onSelected: (_) { _filter = filter; _refresh(); },
                      ),
                  ]),
                  const SizedBox(height: 8),
                  Text(l.limitsResults(visible.length, items.length), style: TextStyle(fontSize: 12, color: context.fam.text2)),
                ])),
              ),
              if (visible.isEmpty)
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  sliver: SliverToBoxAdapter(child: EmptyHint(items.isEmpty ? l.noLimits : l.nothingFound, icon: Icons.search_off)),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  sliver: SliverList.builder(
                    itemCount: visible.length,
                    itemBuilder: (context, index) {
                      final item = visible[index];
                      final radius = BorderRadius.vertical(top: Radius.circular(index == 0 ? 18 : 0), bottom: Radius.circular(index == visible.length - 1 ? 18 : 0));
                      return Material(
                        key: ValueKey('limit-list-${item.def.id}'),
                        color: context.scheme.surface,
                        borderRadius: radius,
                        clipBehavior: Clip.antiAlias,
                        child: Column(children: [
                          if (index > 0) Divider(height: 1, indent: 16, endIndent: 16, color: context.fam.line),
                          _LimitRow(key: ValueKey('limit-${item.def.id}'), def: item.def, status: item.status),
                        ]),
                      );
                    },
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _LimitRow extends StatelessWidget {
  const _LimitRow({super.key, required this.def, required this.status});
  final LimitInfo def;
  final LimitStatus status;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final fam = context.fam;
    final name = categoryName(l, def.category);
    final over = status.remaining < 0;
    final color = over ? fam.expense : status.warn80 ? fam.warn : fam.income;
    final ratio = status.limit <= 0 ? (status.spent > 0 ? 1.0 : 0.0) : (status.spent / status.limit).clamp(0.0, 1.0);
    final percentText = status.usedPercent == null ? '—' : '${status.usedPercent!.round()}%';
    final spentText = '${moneyInText(status.spent)} ${l.ofLimit} ${moneyInText(status.limit)}';
    final remainingText = '${l.left}: ${moneyInText(status.remaining)}'
        '${status.remainingPerDay == null ? '' : ' · ≈ ${moneyInText(status.remainingPerDay!)} ${l.perDay}'}';
    void open() => _showLimitDetails(context, def.id);

    return Semantics(
      button: true,
      label: '$name. $percentText. $spentText. $remainingText',
      hint: l.limitDetailsHint,
      onTap: open,
      excludeSemantics: true,
      child: InkWell(
        onTap: open,
        excludeFromSemantics: true,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Icon(categoryById(def.category).icon, size: 20, color: categoryChartColor(context, def.category)),
              const SizedBox(width: 10),
              Expanded(child: Text(name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600))),
              const SizedBox(width: 8),
              Text(percentText, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: over ? fam.expense : status.warn80 ? fam.warn : fam.text2)),
            ]),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(value: ratio, minHeight: 9, color: color, backgroundColor: context.scheme.surfaceContainerHighest),
            ),
            const SizedBox(height: 6),
            Text.rich(
              TextSpan(children: [
                TextSpan(text: moneyInText(status.spent), style: TextStyle(fontWeight: FontWeight.w600, color: context.scheme.onSurface)),
                TextSpan(text: ' ${l.ofLimit} ${moneyInText(status.limit)}'),
              ]),
              style: TextStyle(fontSize: 13, color: fam.text2),
            ),
            const SizedBox(height: 2),
            Text(remainingText, style: TextStyle(fontSize: 12, color: over ? fam.expense : fam.text2)),
            if (over) Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('${l.limitOver}: ${moneyInText(-status.remaining)}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: fam.expense)),
            ),
          ]),
        ),
      ),
    );
  }
}

/// На узком экране и при увеличенном шрифте суммы остаются целиком видны.
class _AdaptivePair extends StatelessWidget {
  const _AdaptivePair({required this.leading, required this.trailing});
  final Widget leading;
  final Widget trailing;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, constraints) {
    if (constraints.maxWidth < 300 || MediaQuery.textScalerOf(context).scale(14) > 18) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [leading, const SizedBox(height: 12), trailing]);
    }
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: leading), const SizedBox(width: 16), Expanded(child: trailing)]);
  });
}

class _Amount extends StatelessWidget {
  const _Amount({required this.label, required this.amount, this.size = 15, this.color});
  final String label;
  final int amount;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(label, style: TextStyle(fontSize: 12, color: context.fam.text2)),
    const SizedBox(height: 2),
    FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Text(moneyInText(amount), style: TextStyle(fontSize: size, fontWeight: FontWeight.w700, fontFeatures: const [FontFeature.tabularFigures()], color: color)),
    ),
  ]);
}

enum _LimitAction { edit, operations, delete }

Future<void> _showLimitDetails(BuildContext context, String id) async {
  final state = AppScope.of(context).state;
  final def = state.limits.where((limit) => limit.id == id).firstOrNull;
  if (def == null) return;
  final l = context.l10n;
  final locale = Localizations.localeOf(context).toString();
  final action = await showFormSheet<_LimitAction>(
    context,
    title: categoryName(l, def.category),
    builder: (ctx) => ListenableBuilder(
      listenable: state,
      builder: (ctx, _) {
        final current = state.limits.where((limit) => limit.id == id).firstOrNull;
        if (current == null) return const SizedBox.shrink();
        final status = state.limitStatusFor(current);
        final days = state.daysInMonth - state.today.day + 1;
        final percent = status.usedPercent;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(toBeginningOfSentenceCase(DateFormat.yMMMM(locale).format(state.today)), style: TextStyle(color: ctx.fam.text2)),
          const SizedBox(height: 16),
          _AdaptivePair(
            leading: _Amount(label: l.limitSpent, amount: status.spent),
            trailing: _Amount(label: l.limit, amount: status.limit),
          ),
          const SizedBox(height: 16),
          _Amount(label: status.remaining < 0 ? l.limitOver : l.limitRemaining, amount: status.remaining.abs(), color: status.remaining < 0 ? ctx.fam.expense : null),
          const SizedBox(height: 8),
          Text(percent == null ? l.limitNoPercentage : l.limitUsed(NumberFormat('0.#', locale).format(percent)), style: TextStyle(color: ctx.fam.text2)),
          if (status.remaining >= 0 && status.remainingPerDay != null) ...[
            Divider(height: 32, color: ctx.fam.line),
            _Amount(label: l.limitDaily, amount: status.remainingPerDay!),
            const SizedBox(height: 6),
            Text(l.limitDailyBasis(days), style: TextStyle(fontSize: 12, color: ctx.fam.text2)),
          ],
          const SizedBox(height: 20),
          FilledButton.tonalIcon(onPressed: () => Navigator.pop(ctx, _LimitAction.edit), icon: const Icon(Icons.edit_outlined), label: Text(l.limitEditAction)),
          const SizedBox(height: 8),
          OutlinedButton.icon(onPressed: () => Navigator.pop(ctx, _LimitAction.operations), icon: const Icon(Icons.receipt_long_outlined), label: Text(l.limitOperations)),
          const SizedBox(height: 8),
          TextButton.icon(onPressed: () => Navigator.pop(ctx, _LimitAction.delete), icon: const Icon(Icons.delete_outline), label: Text(l.delete), style: TextButton.styleFrom(foregroundColor: ctx.fam.expense)),
        ]);
      },
    ),
  );
  if (action == null || !context.mounted) return;
  final current = state.limits.where((limit) => limit.id == id).firstOrNull;
  if (current == null) return;
  switch (action) {
    case _LimitAction.edit:
      await addLimitFlow(context, initial: current);
    case _LimitAction.operations:
      await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => CategoryScreen(category: current.category, month: state.monthStart)));
    case _LimitAction.delete:
      if (await confirm(context, title: l.deleteLimit, action: l.delete) && context.mounted) {
        await runAction(context, () => state.delete('limit', id));
      }
  }
}
