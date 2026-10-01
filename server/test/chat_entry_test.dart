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

    test('без суммы, перевод, нет счетов — черновика нет', () {
      expect(buildDraft('привет', _view(), _now), (null, DraftProblem.noAmount));
      expect(buildDraft('перевёл 5000 на депозит', _view(), _now), (null, DraftProblem.unsupported));
      expect(buildDraft('дал в долг Асхату 5000', _view(), _now), (null, DraftProblem.unsupported));
      final empty = LedgerView(ledger: Ledger(), profile: const {}, locale: 'ru', entities: const {});
      expect(buildDraft('кофе 1500', empty, _now), (null, DraftProblem.noAccount));
    });

    test('в семейном режиме «для кого» берётся по владельцу счёта', () {
      final v = _view(profile: {'mode': 'family'});
      v.entities['account']!['cash']!['owner'] = 'shared';
      expect(buildDraft('хлеб 300 наличными', v, _now).$1!.who, 'shared');
      expect(buildDraft('хлеб 300 с каспи', v, _now).$1!.who, 'me');
    });

    test('черновик переживает сохранение в базу', () {
      final d = buildDraft('кофе 1500', _view(), _now).$1!;
      expect(ChatDraft.fromJson(Map<String, dynamic>.from(d.toJson())).command(), d.command());
    });
  });

  group('траты дня', () {
    test('запланированная покупка — вне лимита, возврат уменьшает день покупки', () {
      final v = _view(commands: [
        _expense('e1', '2026-10-01', 1500, 'cafe'),
        _expense('e2', '2026-10-01', 3000, 'food'),
        _expense('e3', '2026-10-01', 90000, 'home', meta: {'plannedPurchase': true}),
        _expense('e4', '2026-09-30', 4000, 'food'),
        {'type': 'refund', 'id': 'r1', 'date': '2026-10-01', 'category': 'food', 'amount': '${kzt(1000)}', 'toAccount': 'kaspi', 'meta': {'refundOf': 'e4'}},
        _expense('e5', '2026-10-01', 700, 'fun'),
        {'type': 'reverse', 'txId': 'e5', 'id': 'x5'},
      ]);
      final today = spendOn(v.ledger, DateTime(2026, 10, 1));
      expect(today.everyday, kzt(4500));
      expect(today.planned, kzt(90000));
      expect(today.byCategory, {'cafe': kzt(1500), 'food': kzt(3000)});
      expect(spendOn(v.ledger, DateTime(2026, 9, 30)).everyday, kzt(3000));
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
      expect(text, contains('Сегодня потрачено: 4 500 ₸, лимит на день — 10 000 ₸.'));
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
      expect(today, contains('Лимит на день: 10 000 ₸'));
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
      final all = [...draftButtons(id, v), ...categoryButtons(id, d, v), ...accountButtons(id, v), ...undoButtons(id, false)].expand((r) => r);
      for (final b in all) {
        expect(b['callback_data']!.codeUnits.length, lessThanOrEqualTo(64));
      }
      expect(draftButtons(id, v)[1], hasLength(2));
      expect(categoryButtons(id, d, v).expand((r) => r).map((b) => b['text']), containsAll(['Кафе', 'Собака', 'Прочее']));
    });

    test('скрытые категории в выбор не попадают', () {
      final v = _view(profile: {'hiddenCategories': ['kids', 'fun']});
      expect(chatCategories(v, income: false), isNot(contains('kids')));
      expect(chatCategories(v, income: false).last, 'other');
      expect(chatCategories(v, income: true), contains('salary'));
    });
  });
}
