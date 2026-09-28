/// Экспорт данных владельца: CSV журнала и JSON-снимок (резервная копия).
///
/// Сервер не знает языка интерфейса: заголовки столбцов и названия
/// (категорий, счетов, типов операций, статусов) присылает приложение вместе
/// с запросом ссылки. Ссылка одноразовая и живёт 10 минут — так файл можно
/// открыть в браузере телефона без передачи токена сессии в адресе.
library;

import 'dart:convert';
import 'dart:math';

import 'package:famcoin_core/famcoin_core.dart';

class ExportRequest {
  ExportRequest({required this.userId, required this.format, required this.headers, required this.names, required this.expiresAt});

  final String userId;

  /// `csv` или `json`.
  final String format;
  final List<String> headers;
  final Map<String, String> names;
  final DateTime expiresAt;
}

/// Одноразовые ссылки на файл; живут в памяти процесса.
class ExportLinks {
  final _links = <String, ExportRequest>{};

  String create(ExportRequest r) {
    _links.removeWhere((_, v) => v.expiresAt.isBefore(DateTime.now()));
    const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final rnd = Random.secure();
    final token = List.generate(32, (_) => alphabet[rnd.nextInt(alphabet.length)]).join();
    _links[token] = r;
    return token;
  }

  ExportRequest? take(String token) {
    final r = _links.remove(token);
    if (r == null || r.expiresAt.isBefore(DateTime.now())) return null;
    return r;
  }
}

/// Одна строка на операцию: дата, время, тип, категории, счёт, сумма,
/// заметка, для кого, статус, номер. Разделитель `;` и BOM — так файл сразу
/// правильно открывается в Excel с русской/казахской локалью.
String csvJournal(Map<String, Object?> snapshot, {required List<String> headers, required Map<String, String> names}) {
  final accounts = {
    for (final a in (snapshot['accounts'] as List).cast<Map<String, dynamic>>()) a['id'] as String: accountFromJson(a),
  };
  final txs = (snapshot['transactions'] as List).cast<Map<String, dynamic>>().map(transactionFromJson).toList();
  final reversed = {for (final t in txs) if (t.reverses != null) t.reverses!};
  String name(String key, String fallback) => names[key] ?? fallback;

  final rows = <List<String>>[headers];
  for (final t in txs) {
    final cats = <String>[];
    String? money;
    var moneyDelta = 0;
    var firstAmount = 0;
    for (final p in t.postings) {
      final a = accounts[p.accountId];
      if (a == null) continue;
      if (firstAmount == 0) firstAmount = p.amount;
      if (a.isMoney) {
        money ??= p.accountId;
        moneyDelta += p.amount;
      } else if (a.kind == LedgerKind.expense || a.kind == LedgerKind.income) {
        cats.add(name(p.accountId, p.accountId.substring(p.accountId.indexOf(':') + 1)));
      } else if (a.kind != LedgerKind.equity) {
        // Долги и требования — по названию; технический счёт капитала не показываем.
        cats.add(name(p.accountId, p.accountId));
      }
    }
    final status = t.type == EventType.reversal
        ? name('status:reversal', 'reversal')
        : reversed.contains(t.id)
            ? name('status:cancelled', 'cancelled')
            : name('status:active', 'active');
    final who = t.meta['who'];
    rows.add([
      dateToJson(t.date),
      '${t.meta['time'] ?? ''}',
      name('type:${t.type.name}', t.type.name),
      cats.join(', '),
      money == null ? '' : name(money, money),
      _tenge(money == null ? firstAmount : moneyDelta),
      '${t.meta['note'] ?? ''}',
      who is String ? name('who:$who', who) : '',
      status,
      t.id,
    ]);
  }
  final buf = StringBuffer('﻿');
  for (final r in rows) {
    buf.writeln(r.map(_cell).join(';'));
  }
  return buf.toString();
}

/// Тиыны → тенге с запятой в дробной части (как в казахстанском Excel).
String _tenge(int minor) {
  final sign = minor < 0 ? '-' : '';
  final abs = minor.abs();
  final frac = abs % minorPerUnit;
  return frac == 0 ? '$sign${abs ~/ minorPerUnit}' : '$sign${abs ~/ minorPerUnit},${frac.toString().padLeft(2, '0')}';
}

String _cell(String v) {
  final needsQuotes = v.contains(';') || v.contains('"') || v.contains('\n') || v.contains('\r');
  return needsQuotes ? '"${v.replaceAll('"', '""')}"' : v;
}

/// Резервная копия: снимок данных владельца целиком плюс отметка о выпуске.
String jsonBackup(Map<String, Object?> snapshot, {required String email}) => const JsonEncoder.withIndent('  ').convert({
      'app': 'FamCoin',
      'format': 1,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'email': email,
      ...snapshot,
    });
