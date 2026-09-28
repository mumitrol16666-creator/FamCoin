/// JSON-представление журнала для сети и базы.
///
/// Суммы передаются десятичными строками: клиенты с ограниченной точностью
/// чисел (веб) не теряют младшие разряды (архитектура хранения, раздел 3).
library;

import 'ledger.dart';

int parseMinor(Object? v) {
  if (v is int) return v;
  if (v is String) {
    final parsed = int.tryParse(v);
    if (parsed != null) return parsed;
  }
  throw LedgerException('Некорректная сумма', code: 'invalidAmount');
}

String dateToJson(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Дата операции без времени и часового пояса: `2026-09-22`.
DateTime dateFromJson(Object? v) {
  final m = v is String ? RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(v) : null;
  if (m == null) throw LedgerException('Некорректная дата', code: 'invalidDate');
  final d = DateTime(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
  if (d.month != int.parse(m[2]!) || d.year < 2000 || d.year > 2200) {
    throw LedgerException('Некорректная дата', code: 'invalidDate');
  }
  return d;
}

Map<String, Object?> accountToJson(LedgerAccount a) => {
      'id': a.id,
      'kind': a.kind.name,
      'assetClass': a.assetClass?.name,
      'liquid': a.liquid,
      'currency': a.currency,
      'archived': a.archived,
    };

LedgerAccount accountFromJson(Map<String, dynamic> j) => LedgerAccount(
      id: j['id'] as String,
      kind: LedgerKind.values.byName(j['kind'] as String),
      assetClass: j['assetClass'] == null ? null : AssetClass.values.byName(j['assetClass'] as String),
      liquid: j['liquid'] == true,
      currency: j['currency'] as String? ?? 'KZT',
      archived: j['archived'] == true,
    );

Map<String, Object?> transactionToJson(Transaction t) => {
      'id': t.id,
      'date': dateToJson(t.date),
      'type': t.type.name,
      'postings': [
        for (final p in t.postings) {'a': p.accountId, 'v': p.amount.toString()},
      ],
      'meta': t.meta,
      if (t.reverses != null) 'reverses': t.reverses,
    };

Transaction transactionFromJson(Map<String, dynamic> j) => Transaction(
      id: j['id'] as String,
      date: dateFromJson(j['date']),
      type: EventType.values.byName(j['type'] as String),
      postings: [
        for (final p in (j['postings'] as List).cast<Map<String, dynamic>>())
          Posting(p['a'] as String, parseMinor(p['v'])),
      ],
      meta: (j['meta'] as Map?)?.cast<String, Object?>() ?? const {},
      reverses: j['reverses'] as String?,
    );

/// Восстанавливает журнал из сохранённого состояния. Каждая операция
/// повторно проходит проверку баланса.
Ledger ledgerFromSnapshot({
  required Iterable<Map<String, dynamic>> accounts,
  required Iterable<Map<String, dynamic>> transactions,
  Iterable<Map<String, dynamic>> reservations = const [],
}) {
  final ledger = Ledger();
  for (final a in accounts) {
    ledger.addAccount(accountFromJson(a));
  }
  for (final t in transactions) {
    ledger.post(transactionFromJson(t));
  }
  for (final r in reservations) {
    ledger.restoreReservation(r['goalId'] as String, r['accountId'] as String, parseMinor(r['amount']));
  }
  return ledger;
}

List<Map<String, Object?>> reservationsToJson(Ledger ledger) => [
      for (final r in ledger.reservations)
        {'goalId': r.goalId, 'accountId': r.accountId, 'amount': r.amount.toString()},
    ];
