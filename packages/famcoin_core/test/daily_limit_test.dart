/// Дневной лимит (D48, D64, D71, D73, D74, D81) — расчёт в ядре, общий для
/// приложения и бота.
library;

import 'package:famcoin_core/famcoin_core.dart';
import 'package:test/test.dart';

Ledger _ledger(List<Map<String, dynamic>> commands) {
  final l = Ledger();
  for (final c in [
    {'type': 'addMoneyAccount', 'accountId': 'card'},
    {'type': 'opening', 'id': 'o1', 'date': '2026-09-01', 'account': 'card', 'amount': '${kzt(100000)}'},
    ...commands,
  ]) {
    applyLedgerCommand(l, c);
  }
  return l;
}

Map<String, dynamic> _expense(String id, String date, int tenge, String category, {Map<String, Object?> meta = const {}}) =>
    {'type': 'expense', 'id': id, 'date': date, 'account': 'card', 'splits': {category: '${kzt(tenge)}'}, 'meta': {'who': 'me', ...meta}};

final _today = DateTime(2026, 10, 3);

void main() {
  test('траты дня: запланированное отдельно, возврат — по дню покупки, отменённое не считается', () {
    final l = _ledger([
      _expense('e1', '2026-10-03', 1500, 'cafe'),
      _expense('e2', '2026-10-03', 3000, 'food'),
      _expense('e3', '2026-10-03', 90000, 'home', meta: {'plannedPurchase': true}),
      _expense('e4', '2026-10-02', 4000, 'food'),
      {'type': 'refund', 'id': 'r1', 'date': '2026-10-03', 'category': 'food', 'amount': '${kzt(1000)}', 'toAccount': 'card', 'meta': {'refundOf': 'e4'}},
      _expense('e5', '2026-10-03', 700, 'fun'),
      {'type': 'reverse', 'txId': 'e5', 'id': 'x5'},
    ]);
    final day = spendBetween(l, _today, _today);
    expect(day.everyday, kzt(4500));
    expect(day.planned, kzt(90000));
    expect(day.byCategory, {'cafe': kzt(1500), 'food': kzt(3000)});
    expect(spendBetween(l, DateTime(2026, 10, 2), DateTime(2026, 10, 2)).everyday, kzt(3000));
    expect(spendBetween(l, DateTime(2026, 10, 2), _today).everyday, kzt(7500));
  });

  test('лимит не задан — доступного нет', () {
    final s = dailyLimitState(_ledger([_expense('e1', '2026-10-03', 1500, 'cafe')]), const {}, _today);
    expect((s.limit, s.planned, s.available, s.carry, s.spentToday), (null, null, null, 0, kzt(1500)));
  });

  test('без переноса: лимит минус сегодняшние траты; перерасход остаётся отрицательным', () {
    final profile = {'dailyLimit': '${kzt(5000)}'};
    final l = _ledger([_expense('e0', '2026-10-02', 9000, 'food'), _expense('e1', '2026-10-03', 1500, 'cafe')]);
    final s = dailyLimitState(l, profile, _today);
    expect((s.planned, s.available, s.carry, s.capped), (kzt(3500), kzt(3500), 0, false));
    applyLedgerCommand(l, _expense('e2', '2026-10-03', 6000, 'food'));
    expect(dailyLimitState(l, profile, _today).available, -kzt(2500));
  });

  test('с переносом: прошлые дни добавляют или отнимают, история сумм не пересчитывает прошлое', () {
    final profile = {
      'dailyLimit': '${kzt(8000)}',
      'dailyLimitCarry': true,
      'dailyLimitSince': '2026-10-01',
      'dailyLimitHistory': [
        {'from': '2026-10-01', 'amount': '${kzt(5000)}'},
        {'from': '2026-10-03', 'amount': '${kzt(8000)}'},
      ],
    };
    // 1-го потрачено 2 000 из 5 000, 2-го — 5 293 из 5 000, сегодня — 3 180 из 8 000.
    final l = _ledger([
      _expense('a', '2026-10-01', 2000, 'food'),
      _expense('b', '2026-10-02', 5293, 'food'),
      _expense('c', '2026-10-03', 3180, 'cafe'),
    ]);
    final s = dailyLimitState(l, profile, _today);
    expect(s.planned, kzt(5000 + 5000 + 8000 - 2000 - 5293 - 3180));
    expect(s.carry, kzt(3000 - 293));
    expect(s.available, s.planned);
    expect(limitGranted(dailyLimitHistoryOf(profile), DateTime(2026, 10, 1), _today, kzt(8000)), kzt(18000));
    expect(limitGranted(const [], DateTime(2026, 10, 1), _today, kzt(8000)), kzt(24000), reason: 'профиль без истории — по текущей сумме');
  });

  test('доступное не больше денег на счетах, а отложенное на цели не считается', () {
    final profile = {'dailyLimit': '${kzt(5000)}'};
    final l = _ledger([_expense('big', '2026-10-01', 97000, 'home', meta: {'plannedPurchase': true})]);
    final s = dailyLimitState(l, profile, _today);
    expect((s.planned, s.available, s.capped), (kzt(5000), kzt(3000), true));
    applyLedgerCommand(l, {'type': 'reserve', 'goalId': 'trip', 'accountId': 'card', 'amount': '${kzt(2500)}'});
    expect(dailyLimitState(l, profile, _today).available, kzt(500));
  });
}
