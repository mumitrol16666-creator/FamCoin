import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../state/app_scope.dart';
import '../../theme/app_theme.dart';
import '../widgets/common.dart';
import 'transaction_tile.dart';

enum _View { active, deleted, all }

/// S10 — журнал операций по дням: поиск, выбор месяца, действующие записи,
/// корзина удалённых (с восстановлением) и полная история с отменами.
class JournalScreen extends StatefulWidget {
  const JournalScreen({super.key});

  @override
  State<JournalScreen> createState() => _JournalScreenState();
}

class _JournalScreenState extends State<JournalScreen> {
  final _query = TextEditingController();
  _View _view = _View.active;

  /// Первый день выбранного месяца; `null` — всё время.
  DateTime? _month;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _pickMonth(BuildContext context, List<DateTime> months, String locale) async {
    final l = context.l10n;
    final picked = await showModalBottomSheet<DateTime>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 24),
        children: [
          ListTile(title: Text(l.allTime), selected: _month == null, onTap: () => Navigator.pop(ctx, DateTime(1900))),
          for (final m in months)
            ListTile(
              title: Text(toBeginningOfSentenceCase(DateFormat.yMMMM(locale).format(m))),
              selected: _month == m,
              onTap: () => Navigator.pop(ctx, m),
            ),
        ],
      ),
    );
    if (picked == null) return;
    setState(() => _month = picked.year == 1900 ? null : picked);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final state = AppScope.of(context).state;
    final locale = Localizations.localeOf(context).toString();
    final fam = context.fam;

    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final q = _query.text.trim().toLowerCase();
        final source = switch (_view) {
          _View.active => state.userTransactions,
          _View.deleted => state.deletedTransactions,
          _View.all => state.fullHistory,
        };
        final months = {for (final t in state.fullHistory) DateTime(t.date.year, t.date.month, 1)}.toList()..sort((a, b) => b.compareTo(a));
        final thisMonth = state.monthStart;
        final prevMonth = state.monthOf(-1);
        final txs = source.where((t) {
          if (_month != null && (t.date.year != _month!.year || t.date.month != _month!.month)) return false;
          if (q.isEmpty) return true;
          final v = TxView.of(state, l, t);
          return '${v.title} ${v.subtitle.join(' ')}'.toLowerCase().contains(q);
        });
        final groups = <DateTime, List<Transaction>>{};
        for (final tx in txs) {
          groups.putIfAbsent(tx.date, () => []).add(tx);
        }
        String dayLabel(DateTime d) {
          if (d == state.today) return l.today;
          if (d == state.today.subtract(const Duration(days: 1))) return l.yesterday;
          return DateFormat.yMMMMd(locale).format(d);
        }

        int spent(List<Transaction> list) {
          var sum = 0;
          for (final t in list) {
            if (t.type != EventType.expense || state.ledger.isReversed(t.id)) continue;
            for (final p in t.postings) {
              if (state.ledger.account(p.accountId).kind == LedgerKind.expense) sum += p.amount;
            }
          }
          return sum;
        }

        String monthChip(DateTime m) => toBeginningOfSentenceCase(m.year == state.today.year ? DateFormat.MMMM(locale).format(m) : DateFormat.yMMMM(locale).format(m));
        final customMonth = _month != null && _month != thisMonth && _month != prevMonth;

        return Scaffold(
          appBar: AppBar(title: Text(l.navOps)),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            children: [
              TextField(
                controller: _query,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: l.search, isDense: true),
              ),
              const SizedBox(height: 10),
              // Период: всё время, этот и прошлый месяц, любой другой из истории.
              Wrap(spacing: 8, runSpacing: 4, children: [
                ChoiceChip(label: Text(l.allTime), selected: _month == null, onSelected: (_) => setState(() => _month = null)),
                ChoiceChip(label: Text(monthChip(thisMonth)), selected: _month == thisMonth, onSelected: (_) => setState(() => _month = thisMonth)),
                ChoiceChip(label: Text(monthChip(prevMonth)), selected: _month == prevMonth, onSelected: (_) => setState(() => _month = prevMonth)),
                ChoiceChip(
                  avatar: customMonth ? null : const Icon(Icons.calendar_month_outlined, size: 16),
                  label: Text(customMonth ? monthChip(_month!) : l.otherMonth),
                  selected: customMonth,
                  onSelected: (_) => _pickMonth(context, months, locale),
                ),
              ]),
              const SizedBox(height: 8),
              SegmentedButton<_View>(
                showSelectedIcon: false,
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                segments: [
                  ButtonSegment(value: _View.active, label: Text(l.viewActive, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis)),
                  ButtonSegment(value: _View.deleted, label: Text(l.viewDeleted, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis)),
                  ButtonSegment(value: _View.all, label: Text(l.viewAll, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis)),
                ],
                selected: {_view},
                onSelectionChanged: (s) => setState(() => _view = s.first),
              ),
              const SizedBox(height: 8),
              if (_view == _View.deleted) InfoBanner(l.restoreNote, icon: Icons.restore_from_trash_outlined),
              if (_view == _View.all) InfoBanner(l.showHistoryNote, icon: Icons.history),
              if (groups.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: EmptyHint(_view == _View.deleted && q.isEmpty ? l.noDeleted : q.isEmpty && _month == null ? l.noOperations : l.nothingFound),
                ),
              for (final e in groups.entries) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(2, 14, 2, 4),
                  child: Row(children: [
                    Expanded(child: Text(dayLabel(e.key), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: fam.text2))),
                    if (spent(e.value) > 0) Text('− ${formatMoney(spent(e.value))}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: fam.text2)),
                  ]),
                ),
                AppCard(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Column(children: [for (final tx in e.value) TransactionTile(tx)]),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
