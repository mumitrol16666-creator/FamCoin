import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';

import '../../state/app_scope.dart';
import '../../theme/app_theme.dart';
import '../budget/sheets.dart';
import '../ops/transaction_tile.dart';
import '../widgets/common.dart';

/// S08 — счета: остатки, резервы, добавление и архив.
class AccountsScreen extends StatelessWidget {
  const AccountsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final state = AppScope.of(context).state;
    final fam = context.fam;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final nw = state.ledger.netWorth();
        return Scaffold(
          appBar: AppBar(title: Text(l.accounts)),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => addAccountFlow(context),
            icon: const Icon(Icons.add),
            label: Row(children: [Text(l.addAccount), if (!state.pro) ...[const SizedBox(width: 6), const ProBadge()]]),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
            children: [
              AppCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(l.capital, style: TextStyle(fontSize: 12, color: fam.text2)),
                  BigMoney(nw.capital),
                  const SizedBox(height: 6),
                  Text('${l.money} ${formatMoney(nw.money)} · ${l.oweMe} ${formatMoney(nw.receivables)} · ${l.liabilities} ${formatMoney(nw.liabilities)}',
                      style: TextStyle(fontSize: 12, color: fam.text2)),
                ]),
              ),
              for (final a in state.moneyAccounts)
                Card(
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AccountScreen(accountId: a.id))),
                    child: Row(children: [
                      Container(width: 6, height: 72, color: a.archived ? fam.line : a.color),
                      const SizedBox(width: 12),
                      Icon(accountTypeIcon(a.type), color: fam.text2),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(a.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                          Text('${accountTypeName(l, a.type)}${a.archived ? ' · ${l.archived}' : ''}${state.ledger.reserved(accountId: a.id) > 0 ? ' · ${l.reserve} ${formatMoney(state.ledger.reserved(accountId: a.id))}' : ''}',
                              style: TextStyle(fontSize: 12, color: fam.text2)),
                        ]),
                      ),
                      Padding(padding: const EdgeInsets.only(right: 16), child: MoneyText(state.ledger.balance(a.id))),
                    ]),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// S09 — счёт и его история.
class AccountScreen extends StatelessWidget {
  const AccountScreen({super.key, required this.accountId});
  final String accountId;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final state = AppScope.of(context).state;
    final fam = context.fam;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final info = state.accountInfo(accountId);
        if (info == null) return const Scaffold();
        final balance = state.ledger.balance(accountId);
        final reserved = state.ledger.reserved(accountId: accountId);
        final txs = state.userTransactions.where((t) => t.postings.any((p) => p.accountId == accountId)).toList();
        return Scaffold(
          appBar: AppBar(
            title: Text(info.name),
            actions: [
              if (!info.archived)
                PopupMenuButton<String>(
                  onSelected: (_) async {
                    if (await confirm(context, title: l.archiveAccount, message: l.archiveHint, action: l.archive) && context.mounted) {
                      await runAction(context, () => state.send({'type': 'archiveAccount', 'accountId': accountId}));
                    }
                  },
                  itemBuilder: (_) => [PopupMenuItem(value: 'archive', child: Text(l.archive))],
                ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            children: [
              AppCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${accountTypeName(l, info.type)} · KZT${info.archived ? ' · ${l.archived}' : ''}', style: TextStyle(fontSize: 12, color: fam.text2)),
                  BigMoney(balance),
                  if (reserved > 0)
                    Text('${l.reserve}: ${formatMoney(reserved)} · ${l.free}: ${formatMoney(balance - reserved)}', style: TextStyle(fontSize: 12, color: fam.text2)),
                ]),
              ),
              if (!info.archived)
                OutlinedButton.icon(
                  icon: const Icon(Icons.tune),
                  label: Text(l.adjustBalance),
                  onPressed: () => showAdjustBalanceSheet(context, accountId),
                ),
              const SizedBox(height: 8),
              if (txs.isEmpty)
                EmptyHint(l.noOperations)
              else
                AppCard(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Column(children: [for (final t in txs) TransactionTile(t)]),
                ),
            ],
          ),
        );
      },
    );
  }
}
