/// План записи выписки в журнал (D94): что нового, что уже записано, чем
/// станет каждая строка и что будет с остатком счёта. Без базы — журнал в
/// памяти.
library;

import 'package:famcoin_core/famcoin_core.dart';
import 'package:famcoin_server/ledger_service.dart';
import 'package:famcoin_server/statement.dart';
import 'package:famcoin_server/statement_import.dart';
import 'package:famcoin_server/statement_plan.dart';
import 'package:test/test.dart';

const imp = 'aaaaaaaaaaaa';
final today = DateTime(2026, 10, 2);

DateTime d(String s) => dateFromJson(s);

StatementRow row(String date, num tenge, RowKind kind, [String details = '', String operation = '']) => StatementRow(d(date), kzt(tenge), kind, operation, details);

/// Выписка за сентябрь 2026. [opening] в тенге — остаток на начало; без него
/// выписка «без итогов» и сверить её не с чем.
BankStatement statement(List<StatementRow> rows, {num? opening, String from = '2026-09-01', String to = '2026-09-30'}) {
  final sum = rows.fold<int>(0, (s, r) => s + r.amount);
  return BankStatement(rows: rows, from: d(from), to: d(to), opening: opening == null ? null : kzt(opening), closing: opening == null ? null : kzt(opening) + sum);
}

/// Журнал со счётом `kaspi`; [commands] — что уже записано.
Ledger ledgerWith(List<Map<String, dynamic>> commands, {List<String> accounts = const ['kaspi']}) {
  final l = Ledger();
  for (final a in accounts) {
    l.addMoneyAccount(a);
  }
  for (final c in commands) {
    applyLedgerCommand(l, c);
  }
  return l;
}

Map<String, dynamic> opening(String date, num tenge, {String id = 'open', String account = 'kaspi'}) =>
    {'type': 'opening', 'id': id, 'date': date, 'account': account, 'amount': '${kzt(tenge)}'};

Map<String, dynamic> spent(String id, String date, num tenge, {String category = 'food', String? note, String account = 'kaspi'}) => {
      'type': 'expense',
      'id': id,
      'date': date,
      'account': account,
      'splits': {category: '${kzt(tenge)}'},
      'meta': {'who': 'me', if (note != null) 'note': note},
    };

LedgerView view(
  Ledger l, {
  Map<String, dynamic> profile = const {},
  Map<String, Map<String, dynamic>> accounts = const {
    'kaspi': {'name': 'Kaspi Gold', 'type': 'card'},
  },
  Map<String, Map<String, Map<String, dynamic>>> entities = const {},
}) =>
    LedgerView(ledger: l, profile: profile, locale: 'ru', entities: {'account': accounts, ...entities});

/// Проводит план в журнале так же, как это сделает сервер.
void apply(Ledger l, ImportPlan p, BankStatement st) {
  for (final c in [...openingCommands(p, st, 'kaspi', imp), for (final o in p.ops) o.command]) {
    applyLedgerCommand(l, c);
  }
}

void main() {
  group('начальный остаток', () {
    final st = statement([
      row('2026-09-05', -30000, RowKind.purchase, 'MAGNUM'),
      row('2026-09-25', -10000, RowKind.purchase, 'SMALL'),
    ], opening: 80000);

    test('счёт заведён посреди периода выписки: начало учёта переносится на её первый день', () {
      final l = ledgerWith([opening('2026-09-20', 50000)]);
      final p = planImport(st, view(l), 'kaspi', imp, today);
      expect(p.ops.length, 2);
      expect(p.beforeStart, isEmpty);
      expect(p.changesOpening, isTrue);
      expect(p.newOpening, kzt(80000));
      expect(p.oldOpenings.single.id, 'open');
      expect(p.balanceAfter, kzt(40000), reason: 'как в банке: 80 000 − 30 000 − 10 000');
      expect(p.gap, 0);

      apply(l, p, st);
      expect(l.balance('kaspi'), kzt(40000));
      expect(l.balance('kaspi', asOf: d('2026-09-10')), kzt(50000), reason: 'история с первого дня выписки');
      expect(l.isDeleted('open'), isFalse, reason: 'прежний остаток заменён, а не удалён: в корзине его нет');
      expect(l.byId(importOpeningId(imp))!.meta['edited'], 'open');
      expect(() => l.restore('open', newId: 'x'), throwsA(isA<LedgerException>()), reason: 'восстановить прежний остаток отдельно нельзя — он задвоил бы деньги');
    });

    test('счёт без начального остатка: он ставится по выписке', () {
      final l = ledgerWith([]);
      final p = planImport(st, view(l), 'kaspi', imp, today);
      expect((p.changesOpening, p.newOpening), (true, kzt(80000)));
      expect(p.oldOpenings, isEmpty);
      apply(l, p, st);
      expect(l.balance('kaspi'), kzt(40000));
    });

    test('остаток уже стоит на первый день выписки и равен ей — не трогаем', () {
      final l = ledgerWith([opening('2026-09-01', 80000)]);
      final p = planImport(st, view(l), 'kaspi', imp, today);
      expect(p.changesOpening, isFalse);
      expect(p.ops.length, 2);
      expect(p.gap, 0);
    });

    test('по счёту есть операции раньше выписки: остаток не трогаем, расхождение видно', () {
      final l = ledgerWith([opening('2026-08-01', 70000), spent('m0', '2026-08-15', 5000)]);
      final p = planImport(st, view(l), 'kaspi', imp, today);
      expect(p.changesOpening, isFalse);
      expect(p.ops.length, 2);
      expect(p.balanceAtEnd, kzt(25000));
      expect(p.gap, kzt(15000), reason: 'в банке 40 000, в журнале вышло бы 25 000');
    });

    test('выписка без итогов: строки до начала учёта не пишутся — они уже в начальном остатке', () {
      final loose = statement(st.rows);
      final l = ledgerWith([opening('2026-09-20', 50000)]);
      final p = planImport(loose, view(l), 'kaspi', imp, today);
      expect(p.changesOpening, isFalse);
      expect(p.beforeStart, [0]);
      expect(p.ops.single.n, 1);
      expect(p.gap, isNull);
      expect(p.startDate, d('2026-09-20'));
    });

    test('день начального остатка, введённого вручную, считается уже учтённым; поставленного выпиской — нет', () {
      final loose = statement([row('2026-09-20', -1000, RowKind.purchase), row('2026-09-21', -2000, RowKind.purchase)]);
      final manual = planImport(loose, view(ledgerWith([opening('2026-09-20', 50000)])), 'kaspi', imp, today);
      expect(manual.beforeStart, [0]);
      expect(manual.ops.map((o) => o.n), [1]);
      final imported = planImport(loose, view(ledgerWith([opening('2026-09-20', 50000, id: 'ibbbbbbbbbbbb-open')])), 'kaspi', imp, today);
      expect(imported.beforeStart, isEmpty);
      expect(imported.ops.map((o) => o.n), [0, 1]);
    });

    test('выписка целиком раньше начала учёта с пробелом: ничего не пишется', () {
      final l = ledgerWith([opening('2026-10-20', 50000)]);
      final p = planImport(st, view(l), 'kaspi', imp, DateTime(2026, 11, 1));
      expect(p.ops, isEmpty);
      expect(p.beforeStart, [0, 1]);
      expect(p.changesOpening, isFalse);
    });

    test('выписка кончается накануне начала учёта и сходится с ним: история продлевается назад', () {
      final l = ledgerWith([opening('2026-10-01', 40000, id: 'ibbbbbbbbbbbb-open'), spent('m1', '2026-10-01', 1000)]);
      final p = planImport(st, view(l), 'kaspi', imp, today);
      expect(p.changesOpening, isTrue);
      expect(p.ops.length, 2);
      apply(l, p, st);
      expect(l.balance('kaspi'), kzt(39000), reason: 'сегодняшний остаток не изменился: 40 000 − 1 000');
      expect(l.balance('kaspi', asOf: d('2026-09-30')), kzt(40000));
      // Не сходится с началом учёта — между выпиской и учётом что-то было.
      final other = ledgerWith([opening('2026-10-01', 45000)]);
      expect(planImport(st, view(other), 'kaspi', imp, today).ops, isEmpty);
    });
  });

  group('что уже записано', () {
    test('совпадение по дню и сумме; соседний день — тоже; одна запись закрывает одну строку', () {
      final st = statement([
        row('2026-09-05', -1500, RowKind.purchase, 'COFFEE'),
        row('2026-09-05', -1500, RowKind.purchase, 'COFFEE'),
        row('2026-09-10', -7000, RowKind.purchase, 'MAGNUM'),
        row('2026-09-12', 20000, RowKind.topup, 'Алексей А.'),
      ], opening: 100000);
      final l = ledgerWith([
        opening('2026-09-01', 100000),
        spent('m1', '2026-09-05', 1500, category: 'cafe'),
        spent('m2', '2026-09-11', 7000), // записано на день позже
        {'type': 'income', 'id': 'm3', 'date': '2026-09-12', 'account': 'kaspi', 'source': 'salary', 'amount': '${kzt(20000)}'},
      ]);
      final p = planImport(st, view(l), 'kaspi', imp, today);
      expect(p.present, [0, 2, 3]);
      expect(p.ops.single.n, 1, reason: 'вторая покупка на ту же сумму в тот же день — новая');
      expect(p.gap, 0);
    });

    test('записанное вручную, чего нет в выписке, даёт расхождение с банком', () {
      final st = statement([row('2026-09-05', -1500, RowKind.purchase, 'COFFEE')], opening: 100000);
      final l = ledgerWith([opening('2026-09-01', 100000), spent('m1', '2026-09-07', 5000)]);
      final p = planImport(st, view(l), 'kaspi', imp, today);
      expect(p.ops.length, 1);
      expect(p.gap, kzt(5000), reason: 'в журнале на 5 000 меньше, чем в банке');
    });

    test('операцию прошлого импорта удалили вручную — она не возвращается; отменённый импорт пишется заново', () {
      final st = statement([row('2026-09-05', -1500, RowKind.purchase, 'COFFEE')], opening: 100000);
      final byHand = ledgerWith([
        opening('2026-09-01', 100000),
        spent('ibbbbbbbbbbbb-0', '2026-09-05', 1500),
        {'type': 'reverse', 'txId': 'ibbbbbbbbbbbb-0', 'id': 'trash-1'},
      ]);
      final a = planImport(st, view(byHand), 'kaspi', imp, today);
      expect(a.removed, [0]);
      expect(a.ops, isEmpty);

      final undone = ledgerWith([
        opening('2026-09-01', 100000),
        spent('ibbbbbbbbbbbb-0', '2026-09-05', 1500),
        {'type': 'reverse', 'txId': 'ibbbbbbbbbbbb-0', 'id': importUndoId('bbbbbbbbbbbb', 0)},
      ]);
      final b = planImport(st, view(undone), 'kaspi', imp, today);
      expect(b.removed, isEmpty);
      expect(b.ops.length, 1);
    });

    test('повтор после сбоя: уже записанные этим импортом строки не пишутся второй раз', () {
      final st = statement([row('2026-09-05', -1500, RowKind.purchase, 'COFFEE'), row('2026-09-06', -2500, RowKind.purchase, 'COFFEE')], opening: 100000);
      final l = ledgerWith([opening('2026-09-01', 100000), spent(importRowId(imp, 0), '2026-09-05', 1500)]);
      final p = planImport(st, view(l), 'kaspi', imp, today);
      expect(p.written, [0]);
      expect(p.present, isEmpty);
      expect(p.ops.single.n, 1);
    });
  });

  group('чем становится строка', () {
    final rows = [
      row('2026-09-02', -1500, RowKind.purchase, 'MAGNUM AF51'),
      row('2026-09-03', 1500, RowKind.purchase, 'MAGNUM AF51'),
      row('2026-09-04', -20000, RowKind.transfer, 'Айгуль К.'),
      row('2026-09-05', 50000, RowKind.topup, 'Алексей А.'),
      row('2026-09-06', -10000, RowKind.withdrawal, 'Банкомат Kaspi'),
      row('2026-09-07', -30000, RowKind.ownOut, 'На Kaspi Депозит', 'Перевод на свой счет'),
      row('2026-09-08', 15000, RowKind.ownIn, 'С Kaspi Депозита', 'Поступление со своего счета'),
      row('2026-09-09', -250, RowKind.other, 'Комиссия за перевод'),
      row('2026-09-10', 300000, RowKind.credit, 'Kaspi Кредит', 'Зачисление кредита'),
      row('2026-09-11', 350000, RowKind.topup, 'Зарплата ТОО Ромашка'),
      row('2026-09-12', 5000, RowKind.topup, 'Через банкомат'),
      row('2026-09-13', -700, RowKind.unknown, 'Kaspi Депозитке', 'Жаңа операция'),
      row('2026-09-14', -900, RowKind.unknown, 'Бірдеңе', 'Жаңа операция'),
      row('2026-09-15', 120, RowKind.other, 'Кешбэк'),
    ];
    final st = statement(rows, opening: 100000);

    test('один счёт: покупки, переводы людям и снятия — расходы; свои счета и кредит — корректировки', () {
      final l = ledgerWith([opening('2026-09-01', 100000)]);
      final p = planImport(st, view(l), 'kaspi', imp, today);
      final c = [for (final o in p.ops) o.command];
      expect(p.ops.map((o) => o.group), [
        PlanGroup.purchase,
        PlanGroup.refund,
        PlanGroup.transferOut,
        PlanGroup.income,
        PlanGroup.withdrawal,
        PlanGroup.adjust,
        PlanGroup.adjust,
        PlanGroup.otherExpense,
        PlanGroup.adjust,
        PlanGroup.income,
        PlanGroup.income,
        PlanGroup.adjust,
        PlanGroup.otherExpense,
        PlanGroup.income,
      ]);
      expect(c[0], containsPair('splits', {'food': '${kzt(1500)}'}));
      expect((c[0]['meta'] as Map)['note'], 'MAGNUM AF51');
      expect((c[1]['type'], c[1]['category'], c[1]['toAccount']), ('refund', 'food', 'kaspi'));
      expect(c[2]['splits'], {'other': '${kzt(20000)}'});
      expect((c[2]['meta'] as Map)['note'], 'Перевод: Айгуль К.');
      expect((c[3]['source'], (c[3]['meta'] as Map)['note']), ('otherIncome', 'Пополнение: Алексей А.'));
      expect((c[4]['type'], (c[4]['meta'] as Map)['note']), ('expense', 'Снятие наличных: Банкомат Kaspi'));
      expect((c[5]['type'], c[5]['delta'], c[5]['reason']), ('adjustment', '${-kzt(30000)}', 'Перевод на свой счёт, которого нет в FamCoin: На Kaspi Депозит'));
      expect((c[6]['delta'], c[6]['reason']), ('${kzt(15000)}', 'Поступление со своего счёта, которого нет в FamCoin: С Kaspi Депозита'));
      expect(c[7]['splits'], {'fees': '${kzt(250)}'});
      expect((c[8]['type'], c[8]['delta']), ('adjustment', '${kzt(300000)}'), reason: 'кредит — не доход');
      expect(c[9]['source'], 'salary');
      expect(c[10]['type'], 'income', reason: 'наличные не ведутся — пополнение через банкомат остаётся доходом');
      expect(c[11]['type'], 'adjustment', reason: 'название операции не узнано, но это депозит');
      expect((c[12]['type'], (c[12]['meta'] as Map)['note']), ('expense', 'Жаңа операция: Бірдеңе'));
      expect(c[13]['source'], 'cashback');
      expect(p.ops.map((o) => o.amount), rows.map((r) => r.amount), reason: 'каждая операция меняет остаток ровно на сумму строки');

      apply(l, p, st);
      expect(l.balance('kaspi'), st.closing, reason: 'после записи остаток счёта — как в банке');
      expect(p.gap, 0);
      final r = l.report(d('2026-09-01'), d('2026-10-01'));
      expect(r.income, kzt(50000 + 350000 + 5000 + 120), reason: 'свои счета и кредит в доходы не попали');
      expect(r.expense, kzt(1500 - 1500 + 20000 + 10000 + 250 + 900));
    });

    test('ведутся наличные и депозит: снятия и свои счета — переводы между счетами', () {
      final l = ledgerWith([opening('2026-09-01', 100000)], accounts: ['kaspi', 'cash', 'dep']);
      final v = view(l, accounts: {
        'kaspi': {'name': 'Kaspi Gold', 'type': 'card'},
        'cash': {'name': 'Наличные', 'type': 'cash'},
        'dep': {'name': 'Kaspi Депозит', 'type': 'deposit'},
      });
      final p = planImport(st, v, 'kaspi', imp, today);
      final c = [for (final o in p.ops) o.command];
      expect((c[4]['type'], c[4]['from'], c[4]['to']), ('transfer', 'kaspi', 'cash'));
      expect((c[5]['type'], c[5]['from'], c[5]['to']), ('transfer', 'kaspi', 'dep'));
      expect((c[6]['type'], c[6]['from'], c[6]['to']), ('transfer', 'dep', 'kaspi'));
      expect((c[10]['type'], c[10]['from'], c[10]['to']), ('transfer', 'cash', 'kaspi'), reason: 'пополнение через банкомат — из наличных');
      expect((c[11]['type'], c[11]['to']), ('transfer', 'dep'));
      expect(c[8]['type'], 'adjustment', reason: 'кредит остаётся корректировкой');
      apply(l, p, st);
      expect(l.balance('kaspi'), st.closing);
      expect(l.balance('dep'), kzt(30000 - 15000 + 700));
      expect(l.balance('cash'), kzt(10000 - 5000));
    });

    test('категория: как человек уже записывал такую же заметку; скрытая категория не используется', () {
      final one = statement([row('2026-09-02', -1500, RowKind.purchase, 'MAGNUM AF51'), row('2026-09-03', -900, RowKind.purchase, 'KINOPARK 7')], opening: 100000);
      final l = ledgerWith([opening('2026-09-01', 100000), spent('m1', '2026-08-30', 3000, category: 'household', note: 'Magnum AF51', account: 'kaspi')]);
      // m1 раньше выписки — начальный остаток не трогаем, но категорию берём.
      final p = planImport(one, view(l, profile: {'hiddenCategories': ['fun']}), 'kaspi', imp, today);
      expect(p.ops[0].command['splits'], {'household': '${kzt(1500)}'});
      expect(p.ops[1].command['splits'], {'other': '${kzt(900)}'}, reason: '«Развлечения» скрыты владельцем');
      expect(p.ops[0].label, 'Бытовые покупки');
    });

    test('семейный режим: «для кого» — по владельцу счёта', () {
      final one = statement([row('2026-09-02', -1500, RowKind.purchase, 'MAGNUM')], opening: 100000);
      final l = ledgerWith([opening('2026-09-01', 100000)]);
      final v = view(l, profile: {'mode': 'family'}, accounts: {
        'kaspi': {'name': 'Kaspi Gold', 'type': 'card', 'owner': 'm2'},
      });
      expect((planImport(one, v, 'kaspi', imp, today).ops.single.command['meta'] as Map)['who'], 'm2');
    });
  });

  group('плановые платежи', () {
    final internet = {'name': 'Интернет', 'amount': '${kzt(5000)}', 'day': 10, 'category': 'phone', 'paid': <String>[], 'start': '2026-09-01'};
    final loan = {'name': 'Kaspi Кредит', 'amount': '${kzt(45000)}', 'day': 15, 'category': 'other', 'debtId': 'red', 'paid': <String>[], 'start': '2026-09-01'};

    test('списание на сумму платежа около его срока: расход в категорию платежа, срок отмечается оплаченным', () {
      final st = statement([
        row('2026-09-12', -5000, RowKind.purchase, 'KAZAKHTELECOM'),
        row('2026-09-13', -5000, RowKind.purchase, 'SMALL'), // второй такой же суммы — уже обычная покупка
        row('2026-10-09', -5000, RowKind.transfer, 'Айгуль К.'),
      ], opening: 100000, to: '2026-10-31');
      final l = ledgerWith([opening('2026-09-01', 100000)]);
      final v = view(l, profile: {'dailyLimit': '500000', 'dailyLimitCarry': true, 'dailyLimitSince': '2026-09-01'}, entities: {
        'planned': {'p1': internet},
      });
      final p = planImport(st, v, 'kaspi', imp, DateTime(2026, 11, 2));
      expect(p.ops.map((o) => o.group), [PlanGroup.planned, PlanGroup.purchase, PlanGroup.planned]);
      expect(p.ops[0].command['splits'], {'phone': '${kzt(5000)}'});
      expect(p.ops[0].command['meta'], {'who': 'shared', 'note': 'Интернет', 'planned': 'p1', 'period': '2026-09', 'src': 'kaspi'});
      expect(p.ops[0].mark, (kind: 'planned', id: 'p1', period: '2026-09'));
      expect(p.ops[2].mark, (kind: 'planned', id: 'p1', period: '2026-10'));
      expect(p.restartCarry, isTrue, reason: 'обычная покупка 13.09 попала в окно переноса');

      // Отметки копятся: вторая команда несёт оба периода.
      final paid = <String, Set<String>>{};
      expect((markCommand(p.ops[0].mark!, v, paid)['data'] as Map)['paid'], ['2026-09']);
      final second = markCommand(p.ops[2].mark!, v, paid);
      expect((second['kind'], second['entityId']), ('planned', 'p1'));
      expect((second['data'] as Map)['paid'], ['2026-09', '2026-10']);
      expect((second['data'] as Map)['name'], 'Интернет', reason: 'остальные поля платежа не теряются');

      // Плановая трата — вне дневного лимита, как при оплате из приложения.
      apply(l, p, st);
      expect(spendBetween(l, d('2026-09-12'), d('2026-09-12')).planned, kzt(5000));
      expect(spendBetween(l, d('2026-09-12'), d('2026-09-12')).everyday, 0);
    });

    test('только плановые траты в окне переноса — перенос лимита не трогаем', () {
      final st = statement([row('2026-09-12', -5000, RowKind.purchase, 'KAZAKHTELECOM')], opening: 100000);
      final l = ledgerWith([opening('2026-09-01', 100000)]);
      final v = view(l, profile: {'dailyLimit': '500000', 'dailyLimitCarry': true, 'dailyLimitSince': '2026-09-01'}, entities: {
        'planned': {'p1': internet},
      });
      expect(planImport(st, v, 'kaspi', imp, today).restartCarry, isFalse);
    });

    test('другая сумма, оплаченный срок, далеко от срока, платёж начат позже — обычный расход', () {
      final l = ledgerWith([opening('2026-09-01', 100000)]);
      PlanGroup group(StatementRow r, Map<String, dynamic> planned) =>
          planImport(statement([r], opening: 100000), view(l, entities: {'planned': {'p1': planned}}), 'kaspi', imp, today).ops.single.group;
      expect(group(row('2026-09-12', -5200, RowKind.purchase, 'KAZAKHTELECOM'), internet), PlanGroup.purchase);
      expect(group(row('2026-09-12', -5000, RowKind.purchase, 'KAZAKHTELECOM'), {...internet, 'paid': ['2026-09']}), PlanGroup.purchase);
      expect(group(row('2026-09-25', -5000, RowKind.purchase, 'KAZAKHTELECOM'), internet), PlanGroup.purchase);
      expect(group(row('2026-09-12', -5000, RowKind.purchase, 'KAZAKHTELECOM'), {...internet, 'start': '2026-10-01'}), PlanGroup.purchase);
      expect(group(row('2026-09-12', -5000, RowKind.withdrawal, 'Банкомат'), internet), PlanGroup.withdrawal, reason: 'снятие наличных — не оплата платежа');
      expect(group(row('2026-09-12', -5000, RowKind.purchase, 'KAZAKHTELECOM'), internet), PlanGroup.planned);
    });

    test('платёж уже отмечен в приложении позже списания — строка выписки не задваивает его', () {
      final st = statement([row('2026-09-10', -5000, RowKind.purchase, 'KAZAKHTELECOM')], opening: 100000);
      final l = ledgerWith([
        opening('2026-09-01', 100000),
        {'type': 'expense', 'id': 'pay1', 'date': '2026-09-28', 'account': 'kaspi', 'splits': {'phone': '${kzt(5000)}'}, 'meta': {'who': 'shared', 'note': 'Интернет', 'planned': 'p1', 'period': '2026-09'}},
      ]);
      final v = view(l, entities: {
        'planned': {'p1': {...internet, 'paid': ['2026-09']}},
      });
      final p = planImport(st, v, 'kaspi', imp, today);
      expect(p.present, [0]);
      expect(p.ops, isEmpty);
      // Обычная трата на ту же сумму через 18 дней — не «та же запись».
      final plain = ledgerWith([opening('2026-09-01', 100000), spent('m1', '2026-09-28', 5000)]);
      expect(planImport(st, view(plain), 'kaspi', imp, today).ops.length, 1);
    });

    test('платёж по кредиту не пишется: его делит на долг и проценты сам человек', () {
      final st = statement([row('2026-09-15', -45000, RowKind.transfer, 'Kaspi Кредит'), row('2026-09-16', -1000, RowKind.purchase, 'SMALL')], opening: 100000);
      final l = ledgerWith([
        opening('2026-09-01', 100000),
        {'type': 'openingDebt', 'id': 'd1', 'date': '2026-09-01', 'debtId': 'red', 'amount': '${kzt(300000)}'},
      ]);
      final entities = {
        'planned': {'p2': loan},
        'debt': {'red': {'name': 'Kaspi Кредит', 'kind': 'loan'}},
      };
      final p = planImport(st, view(l, entities: entities), 'kaspi', imp, today);
      expect(p.loans.single, (n: 0, name: 'Kaspi Кредит'));
      expect(p.ops.single.n, 1);
      expect(p.gap, isNull, reason: 'пока платёж не отмечен, остаток с банком не сравниваем');

      // Долг уже закрыт — платёж не действует, строка пишется обычным расходом.
      final closed = ledgerWith([opening('2026-09-01', 100000)]);
      final q = planImport(st, view(closed, entities: entities), 'kaspi', imp, today);
      expect(q.loans, isEmpty);
      expect(q.ops.length, 2);
    });

    test('разовая покупка: без копилки — отмечается купленной, с копилкой — обычный расход', () {
      final st = statement([row('2026-09-20', -100000, RowKind.purchase, 'TIRE SHOP')], opening: 200000);
      final l = ledgerWith([opening('2026-09-01', 200000)]);
      final wheels = {'name': 'Колёса', 'amount': '${kzt(100000)}', 'day': 28, 'category': 'transport', 'paid': <String>[], 'once': '2026-09'};
      final a = planImport(st, view(l, entities: {'purchase': {'w': wheels}}), 'kaspi', imp, today);
      expect(a.ops.single.mark, (kind: 'purchase', id: 'w', period: '2026-09'));
      expect(a.ops.single.command['splits'], {'transport': '${kzt(100000)}'});
      final b = planImport(st, view(l, entities: {'purchase': {'w': {...wheels, 'goal': 'g1'}}}), 'kaspi', imp, today);
      expect(b.ops.single.mark, isNull);
    });
  });

  group('копилки целей', () {
    final st = statement([row('2026-09-05', -1500, RowKind.purchase, 'COFFEE')], opening: 100000);
    Map<String, dynamic> toPiggy(String id, String date, num tenge, {bool back = false}) =>
        {'type': 'transfer', 'id': id, 'date': date, 'from': back ? 'piggy-g1' : 'kaspi', 'to': back ? 'kaspi' : 'piggy-g1', 'amount': '${kzt(tenge)}'};
    const accounts = {
      'kaspi': {'name': 'Kaspi Gold', 'type': 'card'},
      'piggy-g1': {'name': 'На отпуск', 'type': 'piggy'},
    };

    test('отложенное в копилку переводом, которого нет в выписке, считается отдельно от расхождения', () {
      final l = ledgerWith([
        opening('2026-09-01', 100000),
        toPiggy('t1', '2026-09-10', 20000),
        toPiggy('t2', '2026-09-20', 5000, back: true),
        toPiggy('t3', '2026-10-01', 7000), // после периода выписки — не в счёт
      ], accounts: ['kaspi', 'piggy-g1']);
      final p = planImport(st, view(l, accounts: accounts), 'kaspi', imp, today);
      expect(p.piggyHeld, kzt(15000));
      expect(p.gap, kzt(15000), reason: 'в банке на 15 000 больше, чем на счёте: это деньги копилки');
    });

    test('перевод в копилку есть в выписке (копилка — настоящий депозит): он совпал со строкой и в «отложенное» не идёт', () {
      final real = statement([row('2026-09-10', -20000, RowKind.ownOut, 'На Kaspi Депозит', 'Перевод на свой счет')], opening: 100000);
      final l = ledgerWith([opening('2026-09-01', 100000), toPiggy('t1', '2026-09-10', 20000)], accounts: ['kaspi', 'piggy-g1']);
      final p = planImport(real, view(l, accounts: accounts), 'kaspi', imp, today);
      expect(p.present, [0]);
      expect(p.piggyHeld, 0);
      expect(p.gap, 0);
    });
  });

  group('сводка перед записью', () {
    test('выписка «по сегодня» и расхождение: подсказка про операции, записанные после её формирования', () {
      final st = statement([row('2026-09-05', -1500, RowKind.purchase, 'COFFEE')], opening: 100000);
      final l = ledgerWith([opening('2026-09-01', 100000), spent('m1', '2026-09-30', 700)]);
      final v = view(l);
      final p = planImport(st, v, 'kaspi', imp, d('2026-09-30'));
      expect(p.gap, kzt(700));
      expect(importSummaryText(st, p, v, 'kaspi', today: d('2026-09-30')), contains('после формирования выписки'));
      expect(importSummaryText(st, p, v, 'kaspi', today: d('2026-10-02')), isNot(contains('после формирования выписки')));
    });

    test('названия и заметки из выписки и справочников не ломают разметку сообщения и его длину', () {
      final long = 'A&B <b>${'очень длинное название ' * 30}</b>';
      final st = statement([
        for (var i = 0; i < 60; i++) row('2026-09-05', -1500 - i, RowKind.purchase, long),
        row('2026-09-12', -5000, RowKind.purchase, 'KAZAKHTELECOM'),
      ], opening: 1000000);
      final l = ledgerWith([opening('2026-09-01', 1000000)]);
      final v = view(l, accounts: {
        'kaspi': {'name': long, 'type': 'card'},
      }, entities: {
        'planned': {'p1': {'name': long, 'amount': '${kzt(5000)}', 'day': 10, 'category': 'phone', 'paid': <String>[]}},
      });
      final p = planImport(st, v, 'kaspi', imp, today);
      for (final text in [importSummaryText(st, p, v, 'kaspi'), importListText(st, p, v)]) {
        expect(text.length, lessThan(4096));
        expect(text, isNot(contains('<b>очень')));
        expect(text, contains('A&amp;B &lt;b&gt;'));
      }
    });
  });

  group('магазин → категория', () {
    test('по началу слова; короткие названия — только целым словом', () {
      expect(merchantCategory('MAGNUM AF51'), 'food');
      expect(merchantCategory('ИП НУРЛАНОВ МАГАЗИН У ДОМА'), 'food');
      expect(merchantCategory('Yandex.Go'), 'transport');
      expect(merchantCategory('YANDEX.EDA'), 'cafe');
      expect(merchantCategory('APPLE.COM/BILL'), 'subscriptions');
      expect(merchantCategory('Аптека №5'), 'health');
      expect(merchantCategory('PUBG MOBILE'), isNull, reason: '«pub» — только отдельным словом');
      expect(merchantCategory('IRISH PUB'), 'cafe');
      expect(merchantCategory('ТОО БАРАТОВ И К'), isNull);
      expect(merchantCategory('Айгуль К.'), isNull);
    });
  });

  group('перенос дневного лимита', () {
    final st = statement([row('2026-09-25', -4000, RowKind.purchase, 'MAGNUM'), row('2026-09-28', 9000, RowKind.topup, 'Алексей А.')], opening: 100000);
    final limit = {'dailyLimit': '500000', 'dailyLimitCarry': true, 'dailyLimitSince': '2026-09-20'};

    test('выписка добавляет траты прошлых дней внутри переноса — он начинается заново', () {
      final l = ledgerWith([opening('2026-09-01', 100000)]);
      expect(planImport(st, view(l, profile: limit), 'kaspi', imp, today).restartCarry, isTrue);
    });

    test('без переноса, без лимита или если траты раньше начала переноса — не трогаем', () {
      final l = ledgerWith([opening('2026-09-01', 100000)]);
      expect(planImport(st, view(l, profile: {...limit, 'dailyLimitCarry': false}), 'kaspi', imp, today).restartCarry, isFalse);
      expect(planImport(st, view(l, profile: {...limit, 'dailyLimit': null}), 'kaspi', imp, today).restartCarry, isFalse);
      expect(planImport(st, view(l, profile: {...limit, 'dailyLimitSince': '2026-09-26'}), 'kaspi', imp, today).restartCarry, isFalse);
      // Сегодняшняя трата из выписки идёт в сегодняшний лимит как обычно.
      final now = statement([row('2026-10-02', -4000, RowKind.purchase, 'MAGNUM')], opening: 100000, to: '2026-10-02');
      expect(planImport(now, view(l, profile: limit), 'kaspi', imp, today).restartCarry, isFalse);
    });
  });
}
