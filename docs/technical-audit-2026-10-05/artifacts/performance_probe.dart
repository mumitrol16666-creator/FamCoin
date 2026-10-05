// Run from repository root:
// dart --packages=packages/famcoin_core/.dart_tool/package_config.json docs/technical-audit-2026-10-05/artifacts/performance_probe.dart
// Synthetic read-only probe. No DB, network, app services or user data.
import 'dart:convert';
import 'dart:io';

import 'package:famcoin_core/famcoin_core.dart';

Object? _sink;

Ledger synthetic(int count) {
  final l = Ledger();
  for (var i = 0; i < 3; i++) {
    l.addMoneyAccount('money$i');
    l.openingBalance(id: 'opening$i', date: DateTime(2022, 1, 1), account: 'money$i', amount: kzt(100000000));
  }
  for (var i = 0; i < count - 3; i++) {
    final day = DateTime(2022, 1, 1 + i ~/ 20);
    final id = i.toRadixString(16).padLeft(32, '0');
    final amount = kzt(1000 + i % 9000);
    final meta = <String, Object?>{'note': 'Тестовая операция $i', 'who': i.isEven ? 'shared' : 'me', 'time': '12:30'};
    if (i % 20 == 19) {
      l.transfer(id: id, date: day, from: 'money${i % 3}', to: 'money${(i + 1) % 3}', amount: amount, meta: meta);
    } else if (i % 20 >= 16) {
      l.income(id: id, date: day, account: 'money${i % 3}', source: 'source${i % 2}', amount: amount * 8, meta: meta);
    } else {
      l.expense(id: id, date: day, account: 'money${i % 3}', splits: {'category${i % 8}': amount}, meta: meta);
    }
  }
  return l;
}

Map<String, Object?> snapshot(Ledger l) => {
  'accounts': [for (final a in l.accounts) accountToJson(a)],
  'transactions': [for (final t in l.transactions) transactionToJson(t)],
  'reservations': reservationsToJson(l),
};

Ledger restore(Map<String, dynamic> j) => ledgerFromSnapshot(
  accounts: (j['accounts'] as List).cast<Map<String, dynamic>>(),
  transactions: (j['transactions'] as List).cast<Map<String, dynamic>>(),
  reservations: (j['reservations'] as List).cast<Map<String, dynamic>>(),
);

Map<String, Object?> measure(Object? Function() f, Stopwatch budget) {
  final values = <double>[];
  for (var i = 0; i < 7 && budget.elapsedMilliseconds < 15000; i++) {
    final w = Stopwatch()..start();
    _sink = f();
    w.stop();
    values.add(w.elapsedMicroseconds / 1000);
  }
  if (values.isEmpty) return {'skipped': '15-second scenario budget'};
  values.sort();
  return {'samples': values.length, 'median_ms': values[values.length ~/ 2], 'min_ms': values.first, 'max_ms': values.last};
}

void main() {
  // Warm the same code paths before reporting; this is not a cold startup benchmark.
  final warm = synthetic(1000);
  final warmJson = jsonEncode(snapshot(warm));
  for (var i = 0; i < 5; i++) {
    _sink = warm.balance('money0');
    _sink = warm.report(DateTime(2022, 1), DateTime(2022, 3));
    _sink = DailyTotals.rebuild(warm);
    _sink = restore(jsonDecode(warmJson) as Map<String, dynamic>);
  }
  print(jsonEncode({'environment': {'dart': Platform.version, 'os': Platform.operatingSystem, 'processors': Platform.numberOfProcessors},
    'method': 'warmed Dart VM JIT, 7 samples, median/min/max in ms; 20 transactions/day, 3 money accounts, 8 expense categories, 2 income sources; 80% expense/15% income/5% transfer; <=15s per scenario'}));
  for (final count in [1000, 10000, 30000]) {
    final budget = Stopwatch()..start();
    final l = synthetic(count);
    final j = snapshot(l);
    final encoded = jsonEncode(j);
    final decoded = jsonDecode(encoded) as Map<String, dynamic>;
    final end = l.transactions.last.date.add(const Duration(days: 1));
    final start = end.subtract(const Duration(days: 31));
    final metrics = <String, Object?>{
      'balance_one_account': measure(() => l.balance('money0'), budget),
      'report_latest_31_days': measure(() => l.report(start, end), budget),
      'daily_totals_full_rebuild': measure(() => DailyTotals.rebuild(l), budget),
      'serialize_projection_and_json': measure(() => jsonEncode(snapshot(l)), budget),
      'json_decode_only': measure(() => jsonDecode(encoded), budget),
      'snapshot_replay_only': measure(() => restore(decoded), budget),
      'full_json_decode_and_replay': measure(() => restore(jsonDecode(encoded) as Map<String, dynamic>), budget),
    };
    final reloaded = restore(decoded);
    if (reloaded.balance('money0') != l.balance('money0') || reloaded.report(start, end).expense != l.report(start, end).expense) {
      throw StateError('Unexpected loss of financial totals during replay');
    }
    print(jsonEncode({'transactions': l.transactions.length, 'accounts': l.accounts.length,
      'postings': l.transactions.fold(0, (n, t) => n + t.postings.length),
      'json_utf8_bytes': utf8.encode(encoded).length,
      'json_gzip_bytes': gzip.encode(utf8.encode(encoded)).length,
      'history_days': end.difference(DateTime(2022, 1, 1)).inDays,
      'elapsed_scenario_ms': budget.elapsedMilliseconds, 'metrics': metrics}));
  }
  // Retain measured results so the VM has observable work to execute.
  if (_sink == null) throw StateError('No benchmark work');
}
