/// Пакет А из docs/ux-gaps-2026-10-05.md: списание долга (Ж6), «снял /
/// положил» в голосе (Ж3), заметка у покупки в рассрочку (Ж1).
library;

import 'package:famcoin_core/famcoin_core.dart';
import 'package:test/test.dart';

const accounts = [
  VoiceAccount('kaspi', ['Kaspi Gold', 'каспи', 'kaspi']),
  VoiceAccount('halyk', ['Halyk', 'халык', 'народный']),
  VoiceAccount('cash', ['наличные', 'нал', 'қолма-қол'], isCash: true),
];

void main() {
  final september = DateTime(2026, 9), october = DateTime(2026, 10);
  Ledger base() => Ledger()
    ..addMoneyAccount('cash')
    ..openingBalance(id: 'opening', date: september, account: 'cash', amount: kzt(100000));

  group('Ж6 списание долга', () {
    test('«мне должны» списывается в расход «Прочее», долг закрывается, деньги не меняются', () {
      final l = base();
      l.lendOut(id: 'lend', date: september, account: 'cash', person: 'Друг', amount: kzt(50000));
      expect(l.balance(receivableAccount('Друг')), kzt(50000));
      applyLedgerCommand(l, {'type': 'writeOff', 'id': 'wo', 'date': '2026-09-20', 'person': 'Друг', 'amount': '${kzt(50000)}', 'side': 'receivable', 'meta': {'note': 'не вернёт'}});
      expect(l.balance(receivableAccount('Друг')), 0);
      expect(l.balance('cash'), kzt(50000));
      final r = l.report(september, october);
      expect(r.expense, kzt(50000));
      expect(r.income, 0);
      expect(r.cashFlow, -kzt(50000), reason: 'деньги ушли, когда давали в долг');
      final tx = l.byId('wo')!;
      expect(tx.type, EventType.writeOff);
      expect(tx.meta['person'], 'Друг');
      expect(tx.meta['note'], 'не вернёт');
    });

    test('«я должен» прощён — доход «Прочий доход», долг закрыт', () {
      final l = base();
      l.borrow(id: 'borrow', date: september, account: 'cash', person: 'Брат', amount: kzt(30000));
      applyLedgerCommand(l, {'type': 'writeOff', 'id': 'wo', 'date': '2026-09-20', 'person': 'Брат', 'amount': '${kzt(30000)}', 'side': 'liability'});
      expect(l.balance(liabilityAccount('Брат')), 0);
      expect(l.balance('cash'), kzt(130000));
      final r = l.report(september, october);
      expect(r.income, kzt(30000));
      expect(r.expense, 0);
      expect(r.borrowed, kzt(30000));
    });

    test('частичное списание и запрет списать больше остатка', () {
      final l = base();
      l.lendOut(id: 'lend', date: september, account: 'cash', person: 'Друг', amount: kzt(50000));
      l.writeOff(id: 'wo1', date: september, person: 'Друг', amount: kzt(20000), receivable: true);
      expect(l.balance(receivableAccount('Друг')), kzt(30000));
      expect(
        () => l.writeOff(id: 'wo2', date: september, person: 'Друг', amount: kzt(40000), receivable: true),
        throwsA(isA<LedgerException>().having((e) => e.code, 'code', 'writeOffExceeds')),
      );
      expect(l.balance(receivableAccount('Друг')), kzt(30000), reason: 'ошибка не меняет журнал');
    });

    test('списание отменяется как любая запись', () {
      final l = base();
      l.lendOut(id: 'lend', date: september, account: 'cash', person: 'Друг', amount: kzt(50000));
      l.writeOff(id: 'wo', date: september, person: 'Друг', amount: kzt(50000), receivable: true);
      l.reverse('wo', newId: 'rev');
      expect(l.balance(receivableAccount('Друг')), kzt(50000));
      expect(l.report(september, october).expense, 0);
    });
  });

  group('Ж3 снял / положил — перевод', () {
    VoiceDraft p(String s) => parseVoice(s, accounts: accounts);

    test('«Снял 20 тысяч с каспи» — перевод Kaspi → наличные', () {
      final d = p('Снял 20 тысяч с каспи');
      expect(d.kind, VoiceKind.transfer);
      expect(d.amount, kzt(20000));
      expect(d.accountId, 'kaspi');
      expect(d.toAccountId, 'cash');
    });

    test('«Снял наличные 50000» без счёта — в наличные, откуда — не известно', () {
      final d = p('Снял наличные 50000');
      expect(d.kind, VoiceKind.transfer);
      expect(d.toAccountId, 'cash');
      expect(d.accountId, isNull);
    });

    test('«Снял 20 тысяч наличными с каспи» — счета не путаются', () {
      final d = p('Снял 20 тысяч наличными с каспи');
      expect(d.accountId, 'kaspi');
      expect(d.toAccountId, 'cash');
    });

    test('«Положил 30000 на каспи» — наличные → Kaspi', () {
      final d = p('Положил 30000 на каспи');
      expect(d.kind, VoiceKind.transfer);
      expect(d.accountId, 'cash');
      expect(d.toAccountId, 'kaspi');
    });

    test('«Пополнил халык 15000 с каспи» — Kaspi → Halyk (первый названный)', () {
      final d = p('Пополнил халык 15000');
      expect(d.kind, VoiceKind.transfer);
      expect(d.toAccountId, 'halyk');
    });

    test('«Снял квартиру 150000» — расход, не перевод', () {
      final d = p('Снял квартиру 150000');
      expect(d.kind, VoiceKind.expense);
      expect(d.amount, kzt(150000));
    });

    test('«Положил ключи 500» — расход: ни денег, ни счёта рядом', () {
      expect(p('Положил ключи 500').kind, VoiceKind.expense);
    });

    test('без счёта наличных — перевод с названного счёта, получатель пуст', () {
      final d = parseVoice('Снял 10000 с каспи', accounts: const [VoiceAccount('kaspi', ['каспи'])]);
      expect(d.kind, VoiceKind.transfer);
      expect(d.accountId, 'kaspi');
      expect(d.toAccountId, isNull);
    });
  });

  group('Ж1 покупка в рассрочку', () {
    test('заметка и время попадают в запись, расход в месяце покупки, долг на остаток', () {
      final l = base();
      applyLedgerCommand(l, {'type': 'creditPurchase', 'id': 'buy', 'date': '2026-09-10', 'debtId': 'phone', 'splits': {'other': '${kzt(300000)}'}, 'downPaymentAccount': 'cash', 'downPayment': '${kzt(60000)}', 'meta': {'note': 'iPhone', 'time': '14:05'}});
      final tx = l.byId('buy')!;
      expect(tx.meta['note'], 'iPhone');
      expect(tx.meta['time'], '14:05');
      expect(l.report(september, october).expense, kzt(300000));
      expect(l.balance(liabilityAccount('phone')), kzt(240000));
      expect(l.balance('cash'), kzt(40000));
    });
  });
}
