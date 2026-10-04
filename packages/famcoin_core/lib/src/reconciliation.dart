import 'ledger.dart';
import 'serialization.dart';

DateTime reconciliationEnd(DateTime month) =>
    DateTime(month.year, month.month + 1, 0);

bool canReconcileMonth(DateTime month, DateTime today) =>
    DateTime(month.year, month.month, 1)
        .isBefore(DateTime(today.year, today.month, 1));

/// Остатки восстанавливаются по дате проводок, поэтому запись первого числа
/// не меняет прошлый месяц. Включены архивные счета, существовавшие к той дате.
Map<String, int> reconciliationBalances(Ledger ledger, DateTime month) {
  final until = DateTime(month.year, month.month + 1, 1);
  final balances = <String, int>{};
  final money = {
    for (final a in ledger.accounts)
      if (a.isMoney) a.id
  };
  for (final tx in ledger.transactions) {
    if (!tx.date.isBefore(until)) continue;
    for (final posting in tx.postings) {
      if (money.contains(posting.accountId)) {
        balances.update(posting.accountId, (v) => v + posting.amount,
            ifAbsent: () => posting.amount);
      }
    }
  }
  return balances;
}

/// Снимок, который сервер сохраняет при подтверждении сверки. Деньги строками
/// в тиынах — тот же формат, что у остального журнала.
Map<String, dynamic> reconciliationSnapshot(Ledger ledger, DateTime month) {
  final start = DateTime(month.year, month.month, 1);
  final report = ledger.report(start, DateTime(start.year, start.month + 1, 1));
  return {
    'asOf': dateToJson(reconciliationEnd(start)),
    'balances': {
      for (final e in reconciliationBalances(ledger, start).entries)
        e.key: e.value.toString()
    },
    'income': report.income.toString(),
    'expense': report.total.toString(),
    'cashFlow': report.cashFlow.toString(),
  };
}

/// Новая проводка задним числом затрагивает и последующие остатки. Дата
/// отмены совпадает с исходной записью, поэтому правка и удаление тоже видны.
DateTime? earliestPostingDate(Iterable<Transaction> transactions) {
  DateTime? earliest;
  for (final tx in transactions) {
    if (tx.postings.isEmpty) continue;
    if (earliest == null || tx.date.isBefore(earliest)) earliest = tx.date;
  }
  return earliest;
}
