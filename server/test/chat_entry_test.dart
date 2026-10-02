import 'package:famcoin_core/famcoin_core.dart';
import 'package:famcoin_server/chat_entry.dart';
import 'package:famcoin_server/ledger_service.dart';
import 'package:test/test.dart';

/// Владелец с двумя счетами (карта и наличные), своей категорией «Собака»
/// и дневным лимитом 10 000 ₸.
LedgerView _view({String locale = 'ru', List<Map<String, dynamic>> commands = const [], Map<String, dynamic> profile = const {}}) {
  final l = Ledger();
  for (final c in [
    {'type': 'addMoneyAccount', 'accountId': 'kaspi'},
    {'type': 'addMoneyAccount', 'accountId': 'cash'},
    {'type': 'opening', 'id': 'o1', 'date': '2026-09-01', 'account': 'kaspi', 'amount': '${kzt(200000)}'},
    {'type': 'opening', 'id': 'o2', 'date': '2026-09-01', 'account': 'cash', 'amount': '${kzt(20000)}'},
    ...commands,
  ]) {
    applyLedgerCommand(l, c);
  }
  return LedgerView(
    ledger: l,
    profile: {'onboarded': true, 'dailyLimit': '${kzt(10000)}', ...profile},
    locale: locale,
    entities: {
      'account': {
        'kaspi': {'name': 'Kaspi Gold', 'type': 'card'},
        'cash': {'name': 'Кошелёк', 'type': 'cash'},
      },
      'category': {
        'c1': {'name': 'Собака', 'icon': 1, 'income': false},
      },
    },
  );
}

final _now = DateTime.utc(2026, 10, 1, 14, 5);

Map<String, dynamic> _expense(String id, String date, int tenge, String category, {String account = 'kaspi', Map<String, Object?> meta = const {}}) =>
    {'type': 'expense', 'id': id, 'date': date, 'account': account, 'splits': {category: '${kzt(tenge)}'}, 'meta': {'who': 'me', ...meta}};

void main() {
  group('черновик из сообщения', () {
    test('«кофе 1500»: расход, категория по словарю, сегодняшняя дата и время', () {
      final (d, problem) = buildDraft('кофе 1500', _view(), _now);
      expect(problem, isNull);
      expect(d!.income, isFalse);
      expect(d.amount, kzt(1500));
      expect(d.category, 'cafe');
      expect(d.note, 'Кофе');
      expect(d.date, '2026-10-01');
      expect(d.time, '14:05');
      expect(d.who, 'me');
    });

    test('команда журнала — как из формы приложения, и ядро её принимает', () {
      final v = _view();
      final d = buildDraft('такси 2 тысячи вчера', v, _now).$1!;
      expect(d.date, '2026-09-30');
      expect(d.command(), {
        'type': 'expense',
        'id': d.txId,
        'date': '2026-09-30',
        'account': 'kaspi',
        'splits': {'transport': '${kzt(2000)}'},
        'meta': {'who': 'me', 'note': 'Такси', 'time': '14:05'},
      });
      final before = v.ledger.liquid();
      applyLedgerCommand(v.ledger, d.command());
      expect(v.ledger.liquid(), before - kzt(2000));
      applyLedgerCommand(v.ledger, {'type': 'reverse', 'txId': d.txId, 'id': d.undoId});
      expect(v.ledger.liquid(), before);
    });

    test('счёт: названный во фразе, иначе — счёт последней операции', () {
      expect(buildDraft('хлеб 300 наличными', _view(), _now).$1!.account, 'cash');
      expect(buildDraft('хлеб 300 с каспи', _view(), _now).$1!.account, 'kaspi');
      final used = _view(commands: [_expense('e1', '2026-09-30', 500, 'food', account: 'cash')]);
      expect(buildDraft('хлеб 300', used, _now).$1!.account, 'cash');
    });

    test('доход и своя категория узнаются', () {
      final salary = buildDraft('зарплата 350000', _view(), _now).$1!;
      expect(salary.income, isTrue);
      expect(salary.category, 'salary');
      expect(salary.command()['source'], 'salary');
      expect(buildDraft('корм собаке 3000', _view(), _now).$1!.category, 'c1');
      expect(buildDraft('что-то 700', _view(), _now).$1!.category, 'other');
    });

    test('без суммы и без счетов черновика нет', () {
      expect(buildDraft('привет', _view(), _now), (null, DraftProblem.noAmount));
      final empty = LedgerView(ledger: Ledger(), profile: const {}, locale: 'ru', entities: const {});
      expect(buildDraft('кофе 1500', empty, _now), (null, DraftProblem.noAccount));
    });

    test('перевод: откуда и куда по названиям счетов; ядро принимает команду, расходом он не становится', () {
      final v = _view();
      final d = buildDraft('перевёл 20000 с каспи на наличные', v, _now).$1!;
      expect((d.kind, d.account, d.toAccount, d.amount), ('transfer', 'kaspi', 'cash', kzt(20000)));
      expect(d.command(), {'type': 'transfer', 'id': d.txId, 'date': '2026-10-01', 'from': 'kaspi', 'to': 'cash', 'amount': '${kzt(20000)}', 'meta': {'time': '14:05'}});
      applyLedgerCommand(v.ledger, d.command());
      expect((v.ledger.balance('kaspi'), v.ledger.balance('cash')), (kzt(180000), kzt(40000)));
      expect(v.ledger.report(DateTime(2026, 10, 1), DateTime(2026, 11, 1)).expense, 0);

      // Назван только счёт-получатель: откуда — привычный счёт, но не он же.
      final toCash = buildDraft('перевёл 5000 на наличные', _view(), _now).$1!;
      expect((toCash.account, toCash.toAccount), ('kaspi', 'cash'));
      final usedCash = _view(commands: [_expense('e1', '2026-09-30', 500, 'food', account: 'cash')]);
      final fromOther = buildDraft('перевёл 5000 на наличные', usedCash, _now).$1!;
      expect((fromOther.account, fromOther.toAccount), ('kaspi', 'cash'), reason: 'привычный счёт — тот же, куда переводим: берём другой');
      // Счета не названы: с привычного на другой — поправить можно кнопками.
      final blind = buildDraft('перевод 7000', _view(), _now).$1!;
      expect(blind.account, isNot(blind.toAccount));
    });

    test('перевод с одним счётом невозможен', () {
      final l = Ledger();
      applyLedgerCommand(l, {'type': 'addMoneyAccount', 'accountId': 'only'});
      final one = LedgerView(ledger: l, profile: const {}, locale: 'ru', entities: const {});
      expect(buildDraft('перевёл 5000', one, _now), (null, DraftProblem.needSecondAccount));
    });

    test('долги: выдал, взял, вернули, вернул — команды как из приложения', () {
      final v = _view();
      final lend = buildDraft('дал в долг Асхату 5000', v, _now).$1!;
      expect((lend.kind, lend.person, lend.account), ('lendOut', 'Асхату', 'kaspi'));
      expect(lend.command(), {'type': 'lendOut', 'id': lend.txId, 'date': '2026-10-01', 'account': 'kaspi', 'person': 'Асхату', 'amount': '${kzt(5000)}', 'meta': {'time': '14:05'}});
      applyLedgerCommand(v.ledger, lend.command());
      expect(chatPeople(v), ['Асхату']);

      // Человек уже известен — узнаётся в любой форме, возврат гасит его долг.
      final back = buildDraft('асхат вернул мне 2000 наличными', v, _now).$1!;
      expect((back.kind, back.person, back.account), ('repaymentReceived', 'Асхату', 'cash'));
      expect(back.command()['principal'], '${kzt(2000)}');
      applyLedgerCommand(v.ledger, back.command());
      expect(v.ledger.balance('receivable:Асхату'), kzt(3000));

      final borrow = buildDraft('взял в долг у данияра 30 тысяч', v, _now).$1!;
      expect((borrow.kind, borrow.person), ('borrow', 'Данияра'));
      applyLedgerCommand(v.ledger, borrow.command());
      final repay = buildDraft('вернул долг данияру 10000', v, _now).$1!;
      expect((repay.kind, repay.person), ('repaymentMade', 'Данияра'));
      applyLedgerCommand(v.ledger, repay.command());

      expect(buildDraft('взял в долг 20 тысяч', _view(), _now), (null, DraftProblem.noPerson));
    });

    test('в семейном режиме «для кого» берётся по владельцу счёта', () {
      final v = _view(profile: {'mode': 'family'});
      v.entities['account']!['cash']!['owner'] = 'shared';
      expect(buildDraft('хлеб 300 наличными', v, _now).$1!.who, 'shared');
      expect(buildDraft('хлеб 300 с каспи', v, _now).$1!.who, 'me');
    });

    test('черновик переживает сохранение в базу; черновик прежней версии читается', () {
      for (final phrase in ['кофе 1500', 'зарплата 350000', 'перевёл 5000 на наличные', 'дал в долг Асхату 5000']) {
        final d = buildDraft(phrase, _view(), _now).$1!;
        expect(ChatDraft.fromJson(Map<String, dynamic>.from(d.toJson())).command(), d.command(), reason: phrase);
      }
      final old = ChatDraft.fromJson({'income': true, 'amount': '500000', 'category': 'salary', 'account': 'kaspi', 'note': '', 'date': '2026-10-01', 'time': '10:00', 'who': 'me', 'txId': 't', 'undoId': 'u'});
      expect((old.kind, old.command()['type']), ('income', 'income'));
    });
  });

  group('тексты', () {
    test('черновик: сумма, категория, счёт; чужой текст экранируется', () {
      final v = _view();
      final d = buildDraft('кофе <b>1500', v, _now).$1!;
      final text = draftText(d, v, _now);
      expect(text, contains('<b>Расход · 1 500 ₸</b>'));
      expect(text, contains('Категория: Кафе'));
      expect(text, contains('Счёт: Kaspi Gold'));
      expect(text, contains('&lt;b&gt;'));
      expect(text, isNot(contains('Дата')));
      expect(draftText(buildDraft('кофе 1500 вчера', v, _now).$1!, v, _now), contains('Дата: вчера, 30.09'));
    });

    test('после записи — траты дня с учётом новой операции и лимит', () {
      final v = _view(commands: [_expense('e1', '2026-10-01', 3000, 'food')]);
      final d = buildDraft('кофе 1500', v, _now).$1!;
      applyLedgerCommand(v.ledger, d.command());
      final text = savedText(d, v, _now);
      expect(text, contains('Записано'));
      expect(text, contains('Расход 1 500 ₸ · Кафе · Kaspi Gold · Кофе'));
      expect(text, contains('Сегодня потрачено: 4 500 ₸. Доступно сегодня: <b>5 500 ₸</b>.'));
    });

    test('перевод и долг: черновик без категории, после записи — остаток на счетах', () {
      final v = _view();
      final t = buildDraft('перевёл 20000 с каспи на наличные', v, _now).$1!;
      expect(draftText(t, v, _now), '<b>Перевод · 20 000 ₸</b>\nСо счёта: Kaspi Gold\nНа счёт: Кошелёк');
      applyLedgerCommand(v.ledger, t.command());
      expect(savedText(t, v, _now), allOf(contains('Перевод 20 000 ₸ · Kaspi Gold → Кошелёк'), contains('На счетах: 220 000 ₸.')));

      final d = buildDraft('взял в долг у данияра 30 тысяч', v, _now).$1!;
      expect(draftText(d, v, _now), '<b>Взял в долг · 30 000 ₸</b>\nУ кого: Данияра\nСчёт: Kaspi Gold');
    });

    test('счёт уйдёт в минус — черновик предупреждает; приход денег — нет', () {
      final v = _view();
      final big = buildDraft('ремонт 250000 с каспи', v, _now).$1!;
      expect(minusAfter(big, v), kzt(50000));
      expect(draftText(big, v, _now), contains('⚠ После записи счёт «Kaspi Gold» уйдёт в минус на 50 000 ₸.'));
      expect(draftText(buildDraft('перевёл 30000 с наличных на каспи', v, _now).$1!, v, _now), contains('счёт «Кошелёк» уйдёт в минус на 10 000 ₸'));
      expect(draftText(buildDraft('кофе 1500', v, _now).$1!, v, _now), isNot(contains('⚠')));
      expect(minusAfter(buildDraft('зарплата 900000', v, _now).$1!, v), 0);
      expect(minusAfter(buildDraft('взял в долг у данияра 900000', v, _now).$1!, v), 0);
    });

    test('«доступно сегодня» — как в приложении: перенос, перерасход и предел деньгами', () {
      final carry = _view(
        profile: {'dailyLimit': '${kzt(5000)}', 'dailyLimitCarry': true, 'dailyLimitSince': '2026-09-30', 'dailyLimitHistory': [{'from': '2026-09-30', 'amount': '${kzt(5000)}'}]},
        commands: [_expense('a', '2026-09-30', 5293, 'food'), _expense('b', '2026-10-01', 3180, 'cafe')],
      );
      expect(todayText(carry, _now), contains('Доступно сегодня: <b>1 527 ₸</b> · перерасход прошлых дней 293 ₸'));

      final saved = _view(
        profile: {'dailyLimit': '${kzt(5000)}', 'dailyLimitCarry': true, 'dailyLimitSince': '2026-09-30'},
        commands: [_expense('a', '2026-09-30', 2000, 'food')],
      );
      expect(todayText(saved, _now), contains('Доступно сегодня: <b>8 000 ₸</b> · с прошлых дней +3 000 ₸'));

      final over = _view(commands: [_expense('a', '2026-10-01', 12000, 'food')]);
      expect(todayText(over, _now), contains('Перерасход по лимиту: <b>2 000 ₸</b>'));

      // На счетах осталось 3 000 ₸ (крупные покупки были запланированными — лимит они не тратят).
      final poor = _view(commands: [
        _expense('a', '2026-10-01', 197000, 'home', meta: {'plannedPurchase': true}),
        _expense('b', '2026-10-01', 20000, 'home', account: 'cash', meta: {'plannedPurchase': true}),
      ]);
      expect(todayText(poor, _now), contains('Доступно сегодня: <b>3 000 ₸</b> · ограничено деньгами на счетах'));

      expect(todayText(_view(profile: {'dailyLimit': null}), _now), isNot(contains('Доступно')));
    });

    test('/today и /month', () {
      final v = _view(commands: [
        _expense('e1', '2026-10-01', 1500, 'cafe'),
        _expense('e2', '2026-10-01', 3000, 'c1'),
        {'type': 'income', 'id': 'i1', 'date': '2026-10-01', 'account': 'kaspi', 'source': 'salary', 'amount': '${kzt(300000)}'},
      ]);
      final today = todayText(v, _now);
      expect(today, contains('Сегодня, 01.10'));
      expect(today, contains('Потрачено: <b>4 500 ₸</b>'));
      expect(today.indexOf('Собака — 3 000 ₸'), lessThan(today.indexOf('Кафе — 1 500 ₸')));
      expect(today, contains('Лимит на день: 10 000 ₸\nДоступно сегодня: <b>5 500 ₸</b>'));
      expect(today, contains('На счетах: 515 500 ₸'));

      final month = monthText(v, _now);
      expect(month, contains('Октябрь 2026'));
      expect(month, contains('Доходы: 300 000 ₸'));
      expect(month, contains('Расходы: 4 500 ₸'));
      expect(month, contains('+295 500 ₸'));
    });

    test('казахский язык: названия категорий и подписи', () {
      final v = _view(locale: 'kk');
      final d = buildDraft('такси 2000', v, _now).$1!;
      expect(draftText(d, v, _now), allOf(contains('Шығыс'), contains('Санат: Көлік')));
      expect(todayText(v, _now), contains('Бүгін'));
    });
  });

  group('кнопки', () {
    test('данные кнопок укладываются в 64 байта, «Счёт» — только если счетов больше одного', () {
      final v = _view();
      final d = buildDraft('кофе 1500', v, _now).$1!;
      final id = newChatId(6);
      final transfer = buildDraft('перевёл 5000 на наличные', v, _now).$1!;
      final debt = buildDraft('дал в долг Асхату 5000', v, _now).$1!;
      final all = [...draftButtons(id, v, d), ...draftButtons(id, v, transfer), ...categoryButtons(id, d, v), ...accountButtons(id, v), ...accountButtons(id, v, target: true), ...undoButtons(id, false)].expand((r) => r);
      for (final b in all) {
        expect(b['callback_data']!.codeUnits.length, lessThanOrEqualTo(64));
      }
      expect(draftButtons(id, v, d)[1].map((b) => b['text']), ['Категория', 'Счёт', 'Это доход']);
      expect(draftButtons(id, v, d.copyWith(kind: 'income'))[1].last['text'], 'Это расход');
      expect(draftButtons(id, v, transfer)[1].map((b) => b['text']), ['Со счёта', 'На счёт']);
      expect(draftButtons(id, v, debt)[1].map((b) => b['text']), ['Счёт']);
      expect(categoryButtons(id, d, v).expand((r) => r).map((b) => b['text']), containsAll(['Кафе', 'Собака', 'Прочее']));
    });

    test('быстрые операции: только с суммой; черновик — расход с её суммой, категорией и названием', () {
      final v = _view();
      v.entities['quick'] = {
        'q1': {'name': 'Кофе', 'category': 'cafe', 'amount': '${kzt(1500)}'},
        'q2': {'name': 'Такси', 'category': 'transport', 'amount': '0'},
      };
      expect(chatQuicks(v).map((q) => q.id), ['q1']);
      expect(quickButtons(v), [
        [{'text': 'Кофе · 1 500 ₸', 'callback_data': 'q:q1'}],
      ]);
      final d = quickDraft(chatQuicks(v).single, v, _now)!;
      expect(d.command(), {
        'type': 'expense',
        'id': d.txId,
        'date': '2026-10-01',
        'account': 'kaspi',
        'splits': {'cafe': '${kzt(1500)}'},
        'meta': {'who': 'me', 'note': 'Кофе', 'time': '14:05'},
      });
      expect(chatKeyboard(false), [
        ['⚡ Быстрые', '📅 Сегодня'],
      ]);
    });

    test('скрытые категории в выбор не попадают', () {
      final v = _view(profile: {'hiddenCategories': ['kids', 'fun']});
      expect(chatCategories(v, income: false), isNot(contains('kids')));
      expect(chatCategories(v, income: false).last, 'other');
      expect(chatCategories(v, income: true), contains('salary'));
    });
  });
}
