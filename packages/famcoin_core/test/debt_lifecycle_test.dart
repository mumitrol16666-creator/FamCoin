import 'dart:convert';

import 'package:famcoin_core/famcoin_core.dart';
import 'package:test/test.dart';

final day = DateTime(2026, 9, 10);

Ledger debt({bool receivable = true}) {
  final l = Ledger()
    ..addMoneyAccount('cash')
    ..openingBalance(id: 'opening', date: day, account: 'cash', amount: kzt(100000));
  if (receivable) {
    l.lendOut(id: 'debt', date: day, account: 'cash', person: 'Друг', amount: kzt(50000));
  } else {
    l.borrow(id: 'debt', date: day, account: 'cash', person: 'Друг', amount: kzt(50000));
  }
  return l;
}

void rejectRestore(Ledger l, String code) {
  String snapshot() => jsonEncode({
    'accounts': l.accounts.map(accountToJson).toList(),
    'transactions': l.transactions.map(transactionToJson).toList(),
  });
  final before = snapshot();
  expect(() => applyLedgerCommand(l, {'type': 'restore', 'txId': 'old', 'id': 'restored'}),
      throwsA(isA<LedgerException>().having((e) => e.code, 'code', code)));
  expect(snapshot(), before, reason: 'Отказ не меняет ни журнал, ни счета');
  expect(l.byId('restored'), isNull);
}

void main() {
  lifecycleC03();
  test('C02/T03 старый возврат не восстанавливается сверх оставшегося требования', () {
    for (final left in [0, kzt(10000)]) {
      final l = debt();
      l.repaymentReceived(id: 'old', date: day, account: 'cash', person: 'Друг', principal: kzt(50000));
      l.reverse('old', newId: 'delete');
      l.repaymentReceived(id: 'new', date: day, account: 'cash', person: 'Друг', principal: kzt(50000) - left);
      rejectRestore(l, 'repaymentExceeds');
      expect(l.balance(receivableAccount('Друг')), left);
      expect(l.balance('cash'), kzt(100000) - left);
    }
  });

  test('C02/T04 списание требования нельзя восстановить после другого закрытия', () {
    for (final viaPayment in [false, true]) {
      final l = debt();
      l.writeOff(id: 'old', date: day, person: 'Друг', amount: kzt(50000), receivable: true);
      l.reverse('old', newId: 'delete');
      if (viaPayment) {
        l.repaymentReceived(id: 'new', date: day, account: 'cash', person: 'Друг', principal: kzt(50000));
      } else {
        l.writeOff(id: 'new', date: day, person: 'Друг', amount: kzt(50000), receivable: true);
      }
      rejectRestore(l, 'writeOffExceeds');
      expect(l.balance(receivableAccount('Друг')), 0);
      // Списание — не расход (D124): в отчёте отдельная строка, один раз.
      expect(l.report(day, DateTime(2026, 10)).expense, 0);
      expect(l.report(day, DateTime(2026, 10)).writtenOff, viaPayment ? 0 : kzt(50000));
    }
  });

  test('C02/T05 списание обязательства нельзя восстановить после другого закрытия', () {
    for (final viaPayment in [false, true]) {
      final l = debt(receivable: false);
      l.writeOff(id: 'old', date: day, person: 'Друг', amount: kzt(50000), receivable: false);
      l.reverse('old', newId: 'delete');
      if (viaPayment) {
        l.repaymentMade(id: 'new', date: day, account: 'cash', person: 'Друг', principal: kzt(50000));
      } else {
        l.writeOff(id: 'new', date: day, person: 'Друг', amount: kzt(50000), receivable: false);
      }
      rejectRestore(l, 'writeOffExceeds');
      expect(l.balance(liabilityAccount('Друг')), 0);
      expect(l.report(day, DateTime(2026, 10)).income, 0);
      expect(l.report(day, DateTime(2026, 10)).forgiven, viaPayment ? 0 : kzt(50000));
    }
  });

  test('C02/T06 частичное восстановление ровно на остаток допустимо, проценты отдельно', () {
    for (final kind in ['repayment', 'receivable', 'liability']) {
      final l = debt(receivable: kind != 'liability');
      if (kind == 'repayment') {
        l.repaymentReceived(id: 'old', date: day, account: 'cash', person: 'Друг',
            principal: kzt(20000), interest: kzt(2000));
      } else {
        l.writeOff(id: 'old', date: day, person: 'Друг', amount: kzt(20000), receivable: kind == 'receivable');
      }
      l.reverse('old', newId: 'delete');
      if (kind == 'repayment') {
        l.repaymentReceived(id: 'new', date: day, account: 'cash', person: 'Друг', principal: kzt(30000));
      } else {
        l.writeOff(id: 'new', date: day, person: 'Друг', amount: kzt(30000), receivable: kind == 'receivable');
      }
      final loaded = ledgerFromSnapshot(accounts: l.accounts.map(accountToJson),
          transactions: l.transactions.map(transactionToJson));
      applyLedgerCommand(loaded, {'type': 'restore', 'txId': 'old', 'id': 'restored'});
      expect(loaded.balance(kind == 'liability' ? liabilityAccount('Друг') : receivableAccount('Друг')), 0);
      expect(loaded.balance('cash'), kzt(kind == 'repayment' ? 102000 : kind == 'liability' ? 150000 : 50000));
      final r = loaded.report(day, DateTime(2026, 10));
      expect(r.income, kzt(kind == 'repayment' ? 2000 : 0), reason: 'списание и прощение — не доход (D124)');
      expect(r.expense, 0, reason: 'списание — не расход');
      expect(r.writtenOff, kind == 'receivable' ? kzt(50000) : 0);
      expect(r.forgiven, kind == 'liability' ? kzt(50000) : 0);
    }
  });
}

void lifecycleC03() {
  group('C03 удаление исходного долга не оставляет отрицательный долг', () {
    void rejectReverse(Ledger l, String id) {
      String snapshot() => jsonEncode({
        'accounts': l.accounts.map(accountToJson).toList(),
        'transactions': l.transactions.map(transactionToJson).toList(),
      });
      final before = snapshot();
      expect(() => l.reverse(id, newId: 'rev-$id'),
          throwsA(isA<LedgerException>().having((e) => e.code, 'code', 'reverseBreaksDebt')));
      expect(snapshot(), before, reason: 'отказ не меняет журнал');
    }

    test('C03/T07 получение долга нельзя удалить после возврата', () {
      final l = debt(receivable: false);
      l.repaymentMade(id: 'back', date: day, account: 'cash', person: 'Друг', principal: kzt(50000));
      rejectReverse(l, 'debt');
      expect(l.balance('cash'), kzt(100000));
      expect(l.balance(liabilityAccount('Друг')), 0);
      // Сначала удаляется погашение — тогда исходную запись удалить можно.
      l.reverse('back', newId: 'rev-back');
      l.reverse('debt', newId: 'rev-debt');
      expect(l.balance(liabilityAccount('Друг')), 0);
      expect(l.balance('cash'), kzt(100000));
    });

    test('C03/T08 выдачу в долг нельзя удалить после возврата мне', () {
      final l = debt();
      l.repaymentReceived(id: 'back', date: day, account: 'cash', person: 'Друг', principal: kzt(20000));
      rejectReverse(l, 'debt');
      expect(l.balance(receivableAccount('Друг')), kzt(30000));
    });

    test('C03/T09 покупку в рассрочку нельзя удалить после платежа по ней', () {
      final l = Ledger()
        ..addMoneyAccount('cash')
        ..openingBalance(id: 'o', date: day, account: 'cash', amount: kzt(100000));
      l.creditPurchase(id: 'buy', date: day, debtId: 'phone', splits: {'other': kzt(60000)});
      l.loanPayment(id: 'pay', date: day, account: 'cash', debtId: 'phone', principal: kzt(10000));
      rejectReverse(l, 'buy');
      expect(l.balance(liabilityAccount('phone')), kzt(50000));
    });

    test('удаление погашения или обычного расхода по-прежнему разрешено', () {
      final l = debt();
      l.repaymentReceived(id: 'back', date: day, account: 'cash', person: 'Друг', principal: kzt(20000));
      l.reverse('back', newId: 'rev');
      expect(l.balance(receivableAccount('Друг')), kzt(50000));
      l.expense(id: 'e', date: day, account: 'cash', splits: {'food': kzt(1000)});
      l.reverse('e', newId: 'rev-e');
    });
  });
}
