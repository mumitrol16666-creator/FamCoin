/// Команды и сериализация: одинаковый результат в приложении и на сервере.
library;

import 'dart:convert';

import 'package:famcoin_core/famcoin_core.dart';
import 'package:test/test.dart';

void main() {
  occurrenceTests();
  List<Map<String, dynamic>> commands() => [
        {'type': 'addMoneyAccount', 'accountId': 'kaspi'},
        {'type': 'opening', 'id': 'o1', 'date': '2026-09-01', 'account': 'kaspi', 'amount': '10000000'},
        {'type': 'expense', 'id': 'e1', 'date': '2026-09-02', 'account': 'kaspi', 'splits': {'food': '600000', 'household': '400000'}, 'meta': {'who': 'shared'}},
        {'type': 'lendOut', 'id': 'l1', 'date': '2026-09-03', 'account': 'kaspi', 'person': 'Асхат', 'amount': '3000000'},
        {'type': 'openingDebt', 'id': 'd1', 'date': '2026-09-01', 'debtId': 'red', 'amount': '20000000'},
        {'type': 'loanPayment', 'id': 'p1', 'date': '2026-09-05', 'account': 'kaspi', 'debtId': 'red', 'principal': '4000000', 'interest': '1200000'},
        {'type': 'reserve', 'goalId': 'trip', 'accountId': 'kaspi', 'amount': '500000'},
        {'type': 'reverse', 'txId': 'e1', 'id': 'e1-rev'},
      ];

  test('команды применяются и журнал восстанавливается из JSON без потерь', () {
    final l = Ledger();
    for (final c in commands()) {
      applyLedgerCommand(l, c);
    }
    expect(l.balance('kaspi'), kzt(100000 - 30000 - 52000));
    expect(l.isReversed('e1'), isTrue);
    expect(l.reserved(goalId: 'trip'), kzt(5000));

    // Через JSON, как по сети.
    final snapshot = jsonDecode(jsonEncode({
      'accounts': [for (final a in l.accounts) accountToJson(a)],
      'transactions': [for (final t in l.transactions) transactionToJson(t)],
      'reservations': reservationsToJson(l),
    })) as Map<String, dynamic>;
    final restored = ledgerFromSnapshot(
      accounts: (snapshot['accounts'] as List).cast(),
      transactions: (snapshot['transactions'] as List).cast(),
      reservations: (snapshot['reservations'] as List).cast(),
    );
    expect(restored.balance('kaspi'), l.balance('kaspi'));
    expect(restored.netWorth().capital, l.netWorth().capital);
    expect(restored.isReversed('e1'), isTrue);
    expect(restored.freeLiquid(), l.freeLiquid());
    expect(restored.transactions.length, l.transactions.length);
  });

  test('операция с несуществующего или не денежного счёта отклоняется', () {
    final l = Ledger();
    for (final c in commands().take(4)) {
      applyLedgerCommand(l, c);
    }
    expect(
      () => applyLedgerCommand(l, {'type': 'expense', 'id': 'x', 'date': '2026-09-04', 'account': 'receivable:Асхат', 'splits': {'food': '100'}}),
      throwsA(isA<LedgerException>()),
    );
    expect(
      () => applyLedgerCommand(l, {'type': 'expense', 'id': 'x', 'date': '2026-09-04', 'account': 'nope', 'splits': {'food': '100'}}),
      throwsA(isA<LedgerException>()),
    );
  });

  test('операция с архивного счёта отклоняется, история остаётся', () {
    final l = Ledger();
    for (final c in commands().take(2)) {
      applyLedgerCommand(l, c);
    }
    applyLedgerCommand(l, {'type': 'archiveAccount', 'accountId': 'kaspi'});
    expect(l.balance('kaspi'), kzt(100000));
    expect(
      () => applyLedgerCommand(l, {'type': 'expense', 'id': 'x', 'date': '2026-09-04', 'account': 'kaspi', 'splits': {'food': '100'}}),
      throwsA(isA<LedgerException>()),
    );
  });

  test('C08/T14 архивный счёт возвращается из архива: остаток и история целы, операции снова принимаются', () {
    final l = Ledger();
    for (final c in commands().take(2)) {
      applyLedgerCommand(l, c);
    }
    applyLedgerCommand(l, {'type': 'archiveAccount', 'accountId': 'kaspi'});
    applyLedgerCommand(l, {'type': 'archiveAccount', 'accountId': 'kaspi', 'archived': false});
    expect(l.account('kaspi').archived, isFalse);
    expect(l.balance('kaspi'), kzt(100000));
    expect(l.transactions, hasLength(1));
    applyLedgerCommand(l, {'type': 'expense', 'id': 'x', 'date': '2026-09-04', 'account': 'kaspi', 'splits': {'food': '10000'}});
    expect(l.balance('kaspi'), kzt(100000) - 10000);
    // Не денежный счёт и несуществующий не разархивируются.
    expect(() => applyLedgerCommand(l, {'type': 'archiveAccount', 'accountId': 'nope', 'archived': false}), throwsA(isA<LedgerException>()));
    expect(() => applyLedgerCommand(l, {'type': 'archiveAccount', 'accountId': 'expense:food', 'archived': false}), throwsA(isA<LedgerException>().having((e) => e.code, 'code', 'accountNotMoney')));
  });

  test('C06/T15 освобождение резерва: ноль, минус и слишком большая сумма отклоняются без изменений', () {
    final l = Ledger();
    for (final c in commands().take(2)) {
      applyLedgerCommand(l, c);
    }
    applyLedgerCommand(l, {'type': 'reserve', 'goalId': 'trip', 'accountId': 'kaspi', 'amount': '5000000'});
    for (final bad in ['-10000000', '0', '1000000000000001']) {
      expect(
        () => applyLedgerCommand(l, {'type': 'release', 'goalId': 'trip', 'accountId': 'kaspi', 'amount': bad}),
        throwsA(isA<LedgerException>().having((e) => e.code, 'code', 'invalidAmount')),
        reason: bad,
      );
      expect(l.reserved(goalId: 'trip'), kzt(50000), reason: 'резерв не меняется после $bad');
    }
    applyLedgerCommand(l, {'type': 'release', 'goalId': 'trip', 'accountId': 'kaspi', 'amount': '1000000'});
    expect(l.reserved(goalId: 'trip'), kzt(40000));
  });

  test('некорректные данные — ошибка учёта, а не падение', () {
    final l = Ledger()..addMoneyAccount('kaspi');
    for (final bad in [
      {'type': 'expense', 'id': 'x', 'date': '2026-02-30', 'account': 'kaspi', 'splits': {'food': '100'}},
      {'type': 'expense', 'id': 'x', 'date': '2026-09-01', 'account': 'kaspi', 'splits': {'food': 'abc'}},
      {'type': 'expense', 'id': 'x', 'date': '2026-09-01', 'account': 'kaspi', 'splits': {'food': '-100'}},
      {'type': 'income', 'id': 'x', 'date': '2026-09-01', 'account': 'kaspi', 'source': 'salary', 'amount': '99999999999999999'},
      {'type': 'expense', 'id': 'x', 'date': '2026-09-01', 'account': 'kaspi', 'splits': {'food': '500', 'other': '-100'}},
      {'type': 'unknown'},
      {'type': 'expense', 'date': '2026-09-01', 'account': 'kaspi', 'splits': {'food': '100'}},
    ]) {
      expect(() => applyLedgerCommand(l, bad), throwsA(isA<LedgerException>()), reason: '$bad');
    }
    expect(l.transactions, isEmpty);
  });

  test('корректировка остатка: капитал меняется, доход и расход — нет, причина обязательна', () {
    final l = Ledger();
    applyLedgerCommand(l, {'type': 'addMoneyAccount', 'accountId': 'cash'});
    applyLedgerCommand(l, {'type': 'opening', 'id': 'o', 'date': '2026-09-01', 'account': 'cash', 'amount': '5000000'});
    applyLedgerCommand(l, {'type': 'adjustment', 'id': 'adj', 'date': '2026-09-10', 'account': 'cash', 'delta': '-150000', 'reason': 'Пересчитал наличные'});
    expect(l.balance('cash'), kzt(48500));
    final r = l.report(DateTime(2026, 9, 1), DateTime(2026, 10, 1));
    expect(r.income, 0);
    expect(r.expense, 0);
    expect(l.adjustmentsFor(DateTime(2026, 9, 1), DateTime(2026, 10, 1)), -kzt(1500));
    expect(l.netWorth().capital, kzt(48500));
    expect(l.byId('adj')!.meta['reason'], 'Пересчитал наличные');
    expect(
      () => applyLedgerCommand(l, {'type': 'adjustment', 'id': 'x', 'date': '2026-09-10', 'account': 'cash', 'delta': '100', 'reason': ''}),
      throwsA(isA<LedgerException>()),
    );
  });

  test('начальный остаток заменяется как правка: прежний не лежит в корзине и не восстанавливается (D94)', () {
    final l = Ledger()..addMoneyAccount('kaspi');
    applyLedgerCommand(l, {'type': 'opening', 'id': 'o1', 'date': '2026-09-20', 'account': 'kaspi', 'amount': '5000000'});
    applyLedgerCommand(l, {'type': 'reverse', 'txId': 'o1', 'id': 'o1-rev'});
    applyLedgerCommand(l, {'type': 'opening', 'id': 'o2', 'date': '2026-09-01', 'account': 'kaspi', 'amount': '8000000', 'meta': {'edited': 'o1'}});
    expect(l.balance('kaspi'), kzt(80000));
    expect(l.byId('o2')!.meta['edited'], 'o1');
    expect(l.isDeleted('o1'), isFalse);
    expect(() => l.restore('o1', newId: 'x'), throwsA(isA<LedgerException>().having((e) => e.code, 'code', 'restoreSuperseded')));
    // Замена начального остатка — не поток месяца: ни прежняя запись, ни её отмена.
    expect(l.report(DateTime(2026, 9), DateTime(2026, 10)).cashFlow, 0);
    // Без меты команда работает как раньше.
    applyLedgerCommand(l, {'type': 'addMoneyAccount', 'accountId': 'cash'});
    applyLedgerCommand(l, {'type': 'opening', 'id': 'o3', 'date': '2026-09-01', 'account': 'cash', 'amount': '100'});
    expect(l.byId('o3')!.meta, isEmpty);
  });
}

void occurrenceTests() {
  group('R01 один срок платежа оплачивается один раз', () {
    Ledger base() => Ledger()
      ..addMoneyAccount('kaspi')
      ..openingBalance(id: 'o', date: DateTime(2026, 9, 1), account: 'kaspi', amount: kzt(100000));
    Map<String, dynamic> pay(String id, {String period = '2026-09'}) => {
          'type': 'expense', 'id': id, 'date': '2026-09-10', 'account': 'kaspi', 'splits': {'home': '${kzt(10000)}'},
          'meta': {'planned': 'rent', 'period': period},
        };

    test('вторая оплата того же срока отклоняется, другой срок и отмена — нет', () {
      final l = base();
      applyLedgerCommand(l, pay('a'));
      expect(() => applyLedgerCommand(l, pay('b')), throwsA(isA<LedgerException>().having((e) => e.code, 'code', 'occurrencePaid')));
      expect(l.balance('kaspi'), kzt(90000));
      applyLedgerCommand(l, pay('c', period: '2026-10'));
      l.reverse('a', newId: 'rev');
      applyLedgerCommand(l, pay('d')); // после удаления оплаты срок снова свободен
      expect(l.balance('kaspi'), kzt(80000));
    });

    test('восстановление удалённой оплаты не создаёт вторую оплату срока', () {
      final l = base();
      applyLedgerCommand(l, pay('a'));
      l.reverse('a', newId: 'rev');
      applyLedgerCommand(l, pay('b'));
      expect(() => applyLedgerCommand(l, {'type': 'restore', 'txId': 'a', 'id': 'r'}), throwsA(isA<LedgerException>()));
      expect(l.balance('kaspi'), kzt(90000));
    });

    test('платёж по кредиту: тот же срок дважды — отказ; без связи со сроком — можно сколько угодно', () {
      final l = base();
      applyLedgerCommand(l, {'type': 'openingDebt', 'id': 'd', 'date': '2026-09-01', 'debtId': 'red', 'amount': '${kzt(50000)}'});
      Map<String, dynamic> loan(String id, [Map<String, Object?>? meta]) => {
            'type': 'loanPayment', 'id': id, 'date': '2026-09-10', 'account': 'kaspi', 'debtId': 'red', 'principal': '${kzt(10000)}',
            if (meta != null) 'meta': meta,
          };
      applyLedgerCommand(l, loan('p1', {'planned': 'red', 'period': '2026-09'}));
      expect(() => applyLedgerCommand(l, loan('p2', {'planned': 'red', 'period': '2026-09'})), throwsA(isA<LedgerException>().having((e) => e.code, 'code', 'occurrencePaid')));
      applyLedgerCommand(l, loan('p3'));
      applyLedgerCommand(l, loan('p4'));
      expect(l.balance(liabilityAccount('red')), kzt(20000));
    });

    test('личный долг: ядро ограничивает остаток тела, сумму договорённости проверяет сервер', () {
      final l = base();
      applyLedgerCommand(l, {'type': 'borrow', 'id': 'b', 'date': '2026-09-02', 'account': 'kaspi', 'person': 'Теща', 'amount': '${kzt(30000)}'});
      Map<String, dynamic> back(String id) => {
            'type': 'repaymentMade', 'id': id, 'date': '2026-09-20', 'account': 'kaspi', 'person': 'Теща', 'principal': '${kzt(10000)}',
            'meta': {'planned': 'pd:Теща', 'period': '2026-09-20'},
          };
      applyLedgerCommand(l, back('r1'));
      applyLedgerCommand(l, back('r2'));
      applyLedgerCommand(l, back('r3'));
      expect(() => applyLedgerCommand(l, back('r4')), throwsA(isA<LedgerException>().having((e) => e.code, 'code', 'principalExceeds')));
      expect(l.balance(liabilityAccount('Теща')), 0);
    });

    test('части возврата личного долга к сроку (N01): несколько частей и закрывающий платёж; повтор части — не дубль; переплата — отказ', () {
      final l = base();
      applyLedgerCommand(l, {'type': 'borrow', 'id': 'b', 'date': '2026-09-02', 'account': 'kaspi', 'person': 'Друг', 'amount': '${kzt(80000)}'});
      Map<String, dynamic> back(String id, num tenge, {bool part = true}) => {
            'type': 'repaymentMade', 'id': id, 'date': '2026-09-20', 'account': 'kaspi', 'person': 'Друг', 'principal': '${kzt(tenge)}',
            'meta': {'planned': 'pd:1', 'period': '2026-09-30', if (part) 'part': true},
          };
      applyLedgerCommand(l, back('p1', 30000));
      applyLedgerCommand(l, back('p1', 30000)); // сетевой повтор той же части
      applyLedgerCommand(l, back('p2', 20000));
      expect(l.balance(liabilityAccount('Друг')), kzt(30000));
      expect(() => applyLedgerCommand(l, back('p3', 40000)), throwsA(isA<LedgerException>()), reason: 'больше остатка долга — отказ');
      applyLedgerCommand(l, back('last', 30000, part: false));
      expect(l.balance(liabilityAccount('Друг')), 0);
      // Переплата запрещена независимо от флага part; отмена части открывает остаток.
      expect(() => applyLedgerCommand(l, back('again', 10000, part: false)), throwsA(isA<LedgerException>().having((e) => e.code, 'code', 'principalExceeds')));
      applyLedgerCommand(l, {'type': 'reverse', 'id': 'undo-part', 'txId': 'p1'});
      applyLedgerCommand(l, back('replace-part', 30000, part: false));
      expect(l.balance(liabilityAccount('Друг')), 0);
    });

    test('повтор той же записи с тем же id остаётся идемпотентным, а не ошибкой срока', () {
      final l = base();
      applyLedgerCommand(l, pay('a'));
      // Повтор команды (тот же id и содержание) — не новая оплата: журнал принимает его как повтор.
      applyLedgerCommand(l, pay('a'));
      expect(l.transactions.where((t) => t.meta['planned'] == 'rent'), hasLength(1));
      expect(l.balance('kaspi'), kzt(90000));
    });
  });
}
