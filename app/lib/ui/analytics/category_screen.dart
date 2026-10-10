import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../state/app_scope.dart';
import '../../theme/app_theme.dart';
import '../ops/transaction_tile.dart';
import '../widgets/common.dart';

/// S24 — категория в деталях: сумма месяца и составляющие её операции.
class CategoryScreen extends StatelessWidget {
  const CategoryScreen({super.key, required this.category, required this.month, this.income = false});
  final String category;

  /// Категория дохода (D165): сумма и операции берутся из доходов, лимита нет.
  final bool income;
  final DateTime month;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final state = AppScope.of(context).state;
    final fam = context.fam;
    final locale = Localizations.localeOf(context).toString();
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final total = (income ? state.incomeCategoriesFor(month) : state.categoriesFor(month)).where((e) => e.key == category).firstOrNull?.value ?? 0;
        final txs = state.categoryTransactions(category, month, income: income);
        final limit = income ? null : state.limits.where((x) => x.category == category).firstOrNull;
        return Scaffold(
          appBar: AppBar(title: Text(categoryName(l, category))),
          body: TransactionHistoryList(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            header: [
              AppCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(toBeginningOfSentenceCase(DateFormat.yMMMM(locale).format(month)), style: TextStyle(fontSize: 12, color: fam.text2)),
                  BigMoney(total),
                  Text(l.operationsCount(txs.length), style: TextStyle(fontSize: 12, color: fam.text2)),
                  if (limit != null) ...[
                    const SizedBox(height: 8),
                    UsageBar(value: total, max: limit.amount),
                    const SizedBox(height: 4),
                    Text('${l.limit}: ${formatMoney(limit.amount)}', style: TextStyle(fontSize: 12, color: fam.text2)),
                  ],
                ]),
              ),
              if (txs.isEmpty) EmptyHint(l.noOperations),
            ],
            transactions: txs,
          ),
        );
      },
    );
  }
}
