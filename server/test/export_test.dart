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
    expect(lines.first.substring(1), 'Дата;Время;Тип;Категория;Счёт;Сумма;Заметка;Для кого;Статус;ID;To account;Fee', reason: 'старые 10 столбцов на местах, новые — в конце');
    expect(lines[1].trim(), '2026-09-01;;Начальный остаток;;Kaspi Gold;100000;;;действует;o1;;');
    expect(lines[2].trim(), '2026-09-02;09:15;Расход;Продукты;Kaspi Gold;-1234,50;"хлеб; молоко";Общее;отменена;e1;;');
    expect(lines[3].trim(), startsWith('2026-09-02;;Отмена;Продукты;Kaspi Gold;1234,50;;;отменяющая;e1-rev'));
  });

  // S04: перевод — две денежные проводки, их сумма нулевая, но сумма перевода и второй счёт нужны в файле.
  group('перевод между своими счетами', () {
    const transferHeaders = ['Дата', 'Время', 'Тип', 'Категория', 'Счёт', 'Сумма', 'Заметка', 'Для кого', 'Статус', 'ID', 'На счёт', 'Комиссия'];
    const transferNames = {
      'kaspi': 'Kaspi Gold',
      'cash': 'Наличные',
      'expense:fees': 'Комиссии',
      'type:transfer': 'Перевод',
      'type:reversal': 'Отмена',
      'status:active': 'действует',
      'status:cancelled': 'отменена',
      'status:reversal': 'отменяющая',
    };

    Map<String, Object?> ledgerSnapshot(List<Map<String, dynamic>> commands) {
      final l = Ledger();
      for (final c in [
        {'type': 'addMoneyAccount', 'accountId': 'kaspi'},
        {'type': 'addMoneyAccount', 'accountId': 'cash'},
        {'type': 'opening', 'id': 'o1', 'date': '2026-09-01', 'account': 'kaspi', 'amount': '10000000'},
        ...commands,
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

    List<String> rows(Map<String, Object?> snapshot, {List<String> headers = transferHeaders, Map<String, String> names = transferNames}) =>
        csvJournal(snapshot, headers: headers, names: names).split('\n').where((l) => l.trim().isNotEmpty).map((l) => l.trim()).toList();

    test('T39: перевод без комиссии — сумма перевода и оба счёта; нулевое изменение денег сумму не подменяет', () {
      final lines = rows(ledgerSnapshot([
        {'type': 'transfer', 'id': 'move-1', 'date': '2026-09-12', 'from': 'kaspi', 'to': 'cash', 'amount': '1500000'},
      ]));
      expect(lines.first, 'Дата;Время;Тип;Категория;Счёт;Сумма;Заметка;Для кого;Статус;ID;На счёт;Комиссия');
      expect(lines.last, '2026-09-12;;Перевод;;Kaspi Gold;15000;;;действует;move-1;Наличные;');
    });

    test('T40: перевод с комиссией — сумма и комиссия отдельно, обе проводки сходятся с журналом', () {
      final snapshot = ledgerSnapshot([
        {'type': 'transfer', 'id': 'move-2', 'date': '2026-09-12', 'from': 'kaspi', 'to': 'cash', 'amount': '1500000', 'fee': '15000'},
      ]);
      final line = rows(snapshot).last;
      expect(line, '2026-09-12;;Перевод;Комиссии;Kaspi Gold;15000;;;действует;move-2;Наличные;150');
      // Контроль по журналу: со счёта ушло «сумма + комиссия», на счёт пришла «сумма».
      final l = ledgerFromSnapshot(
        accounts: (snapshot['accounts'] as List).cast<Map<String, dynamic>>(),
        transactions: (snapshot['transactions'] as List).cast<Map<String, dynamic>>(),
      );
      expect(l.balance('kaspi'), 10000000 - 1500000 - 15000);
      expect(l.balance('cash'), 1500000);
    });

    test('T41: удалённый перевод — исходная строка «отменена», отменяющая показывает обратное направление и возврат комиссии', () {
      final lines = rows(ledgerSnapshot([
        {'type': 'transfer', 'id': 'move-3', 'date': '2026-09-12', 'from': 'kaspi', 'to': 'cash', 'amount': '1500000', 'fee': '15000'},
        {'type': 'reverse', 'txId': 'move-3', 'id': 'move-3-rev'},
      ]));
      expect(lines[lines.length - 2], '2026-09-12;;Перевод;Комиссии;Kaspi Gold;15000;;;отменена;move-3;Наличные;150');
      expect(lines.last, '2026-09-12;;Отмена;Комиссии;Наличные;15000;;;отменяющая;move-3-rev;Kaspi Gold;-150');
    });

    test('перевод в обратную сторону и подписи от приложения: направление по знаку проводки', () {
      final lines = rows(ledgerSnapshot([
        {'type': 'transfer', 'id': 'move-4', 'date': '2026-09-12', 'from': 'kaspi', 'to': 'cash', 'amount': '100000'},
        {'type': 'transfer', 'id': 'move-5', 'date': '2026-09-13', 'from': 'cash', 'to': 'kaspi', 'amount': '40000'},
      ]));
      expect(lines.last, '2026-09-13;;Перевод;;Наличные;400;;;действует;move-5;Kaspi Gold;');
    });

    test('десять подписей от старого приложения: новые столбцы получают запасные подписи или названия из карты', () {
      final snapshot = ledgerSnapshot([
        {'type': 'transfer', 'id': 'move-6', 'date': '2026-09-12', 'from': 'kaspi', 'to': 'cash', 'amount': '1500000'},
      ]);
      final old = transferHeaders.take(10).toList();
      expect(rows(snapshot, headers: old).first.split(';').skip(10), ['To account', 'Fee']);
      expect(rows(snapshot, headers: old, names: {...transferNames, 'csv:toAccount': 'На счёт', 'csv:fee': 'Комиссия'}).first.split(';').skip(10), ['На счёт', 'Комиссия']);
    });

    test('расходы, доходы и составные операции не изменились: сумма — суммарное изменение денег', () {
      final lines = rows(ledgerSnapshot([
        {'type': 'expense', 'id': 'e1', 'date': '2026-09-02', 'account': 'kaspi', 'splits': {'food': '123450', 'fees': '5000'}},
      ]));
      expect(lines.last, '2026-09-02;;expense;food, Комиссии;Kaspi Gold;-1284,50;;;действует;e1;;50');
    });
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
