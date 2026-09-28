import 'package:famcoin_core/famcoin_core.dart';
import 'package:famcoin_server/export.dart';
import 'package:test/test.dart';

void main() {
  Map<String, Object?> snapshot() {
    final l = Ledger();
    for (final c in [
      {'type': 'addMoneyAccount', 'accountId': 'kaspi'},
      {'type': 'opening', 'id': 'o1', 'date': '2026-09-01', 'account': 'kaspi', 'amount': '10000000'},
      {'type': 'expense', 'id': 'e1', 'date': '2026-09-02', 'account': 'kaspi', 'splits': {'food': '123450'}, 'meta': {'note': 'хлеб; молоко', 'who': 'shared', 'time': '09:15'}},
      {'type': 'reverse', 'txId': 'e1', 'id': 'e1-rev'},
    ]) {
      applyLedgerCommand(l, c);
    }
    return {
      'accounts': [for (final a in l.accounts) accountToJson(a)],
      'transactions': [for (final t in l.transactions) transactionToJson(t)],
      'reservations': reservationsToJson(l),
      'entities': const [],
      'profile': const {},
    };
  }

  test('CSV: заголовки приложения, названия из карты, суммы в тенге, кавычки при «;»', () {
    final csv = csvJournal(
      snapshot(),
      headers: ['Дата', 'Время', 'Тип', 'Категория', 'Счёт', 'Сумма', 'Заметка', 'Для кого', 'Статус', 'ID'],
      names: {
        'kaspi': 'Kaspi Gold',
        'expense:food': 'Продукты',
        'type:expense': 'Расход',
        'type:opening': 'Начальный остаток',
        'type:reversal': 'Отмена',
        'who:shared': 'Общее',
        'status:active': 'действует',
        'status:cancelled': 'отменена',
        'status:reversal': 'отменяющая',
      },
    );
    final lines = csv.split('\n').where((l) => l.trim().isNotEmpty).toList();
    expect(lines.first.startsWith('﻿'), isTrue, reason: 'BOM для Excel');
    expect(lines.first.substring(1), 'Дата;Время;Тип;Категория;Счёт;Сумма;Заметка;Для кого;Статус;ID');
    expect(lines[1].trim(), '2026-09-01;;Начальный остаток;;Kaspi Gold;100000;;;действует;o1');
    expect(lines[2].trim(), '2026-09-02;09:15;Расход;Продукты;Kaspi Gold;-1234,50;"хлеб; молоко";Общее;отменена;e1');
    expect(lines[3].trim(), startsWith('2026-09-02;;Отмена;Продукты;Kaspi Gold;1234,50;;;отменяющая;e1-rev'));
  });

  test('JSON-копия содержит снимок целиком и отметку о выпуске', () {
    final json = jsonBackup(snapshot(), email: 'a@b.kz');
    expect(json, contains('"app": "FamCoin"'));
    expect(json, contains('"transactions"'));
    expect(json, contains('"e1-rev"'));
  });

  test('одноразовая ссылка выдаётся один раз и не переживает срок', () {
    final links = ExportLinks();
    final t = links.create(ExportRequest(userId: 'u', format: 'csv', headers: const [], names: const {}, expiresAt: DateTime.now().add(const Duration(minutes: 10))));
    expect(links.take(t), isNotNull);
    expect(links.take(t), isNull);
    final old = links.create(ExportRequest(userId: 'u', format: 'csv', headers: const [], names: const {}, expiresAt: DateTime.now().subtract(const Duration(seconds: 1))));
    expect(links.take(old), isNull);
  });
}
