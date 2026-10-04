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
    // Журнал дописывается, а не переписывается. Позволяет показать записи,
    // появившиеся после подтверждения, включая отмены старых операций.
    'transactionCount': ledger.transactions.length,
  };
}

typedef ReconciliationAmountChange = ({int before, int after});

class ReconciliationChanges {
  const ReconciliationChanges(this.balances, this.totals);
  final Map<String, ReconciliationAmountChange> balances;
  final Map<String, ReconciliationAmountChange> totals;
  bool get isEmpty => balances.isEmpty && totals.isEmpty;
}

/// Сверка подтверждает остатки каждого счёта и денежные итоги месяца.
/// Названия, категории, комментарии, лимиты и число записей сами по себе
/// подтверждения не снимают. Сравнивается результат всей атомарной команды.
ReconciliationChanges reconciliationChanges(Map saved, Map current) {
  final before = saved['balances'] as Map;
  final after = current['balances'] as Map;
  final balances = <String, ReconciliationAmountChange>{};
  for (final id in {...before.keys, ...after.keys}) {
    final oldValue = parseMinor(before[id] ?? '0');
    final newValue = parseMinor(after[id] ?? '0');
    if (oldValue != newValue)
      balances[id as String] = (before: oldValue, after: newValue);
  }
  final totals = <String, ReconciliationAmountChange>{};
  for (final key in ['income', 'expense', 'cashFlow']) {
    final oldValue = parseMinor(saved[key]);
    final newValue = parseMinor(current[key]);
    if (oldValue != newValue) totals[key] = (before: oldValue, after: newValue);
  }
  return ReconciliationChanges(balances, totals);
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
