import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../state/app_scope.dart';
import '../../theme/app_theme.dart';
import '../widgets/common.dart';
import 'transaction_tile.dart';

/// S10 — журнал операций по дням с поиском по заметкам и категориям.
class JournalScreen extends StatefulWidget {
  const JournalScreen({super.key});

  @override
  State<JournalScreen> createState() => _JournalScreenState();
}

class _JournalScreenState extends State<JournalScreen> {
  final _query = TextEditingController();
  bool _showAll = false;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
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
        final txs = (_showAll ? state.fullHistory : state.userTransactions).where((t) {
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
            if (t.type != EventType.expense) continue;
            for (final p in t.postings) {
              if (state.ledger.account(p.accountId).kind == LedgerKind.expense) sum += p.amount;
            }
          }
          return sum;
        }

        return Scaffold(
          appBar: AppBar(
            title: Text(l.navOps),
            actions: [
              IconButton(
                tooltip: l.showHistory,
                isSelected: _showAll,
                icon: const Icon(Icons.history),
                selectedIcon: Icon(Icons.history, color: context.scheme.primary),
                onPressed: () => setState(() => _showAll = !_showAll),
              ),
              const SizedBox(width: 4),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            children: [
              TextField(
                controller: _query,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: l.search, isDense: true),
              ),
              const SizedBox(height: 8),
              if (_showAll) InfoBanner(l.showHistoryNote, icon: Icons.history),
              if (groups.isEmpty) Padding(padding: const EdgeInsets.only(top: 12), child: EmptyHint(q.isEmpty ? l.noOperations : l.nothingFound)),
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
