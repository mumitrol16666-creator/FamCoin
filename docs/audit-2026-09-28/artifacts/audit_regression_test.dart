// Audit-only regression probes. Run from app/:
// flutter test --no-pub ../docs/audit-2026-09-28/artifacts/audit_regression_test.dart
import 'dart:convert';
import 'package:famcoin/state/api_client.dart';
import 'package:famcoin/state/app_state.dart';
import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class Fixture {
  DateTime now = DateTime(2026, 9, 28);
  bool offline = false;
  int revision = 0;
  late final state = AppState(
    token: 'test-only', clock: () => now,
    api: ApiClient(baseUrl: 'http://audit.test', client: MockClient((req) async {
      if (offline) throw http.ClientException('offline');
      if (req.url.path == '/state') return http.Response(jsonEncode({
        'revision': revision, 'plan': 'free', 'email': 'audit@example.test',
        'accounts': [], 'transactions': [], 'reservations': [], 'entities': [], 'profile': {},
      }), 200);
      return http.Response(jsonEncode({'revision': ++revision}), 200);
    })),
  );
  Future<void> init() async {
    await state.load();
    await state.sendBatch([
      {'type': 'addMoneyAccount', 'accountId': 'cash'},
      {'type': 'opening', 'id': 'opening', 'date': '2026-09-28', 'account': 'cash', 'amount': '10000000'},
    ]);
  }
  Future<void> plan() => state.upsert('planned', 'rent', {
    'name': 'Rent', 'amount': '1000000', 'day': 10, 'category': 'home', 'paid': [], 'start': '2026-09-01',
  });
}

void main() {
  test('F02: editing a refunded purchase must preserve its refunded amount', () async {
    final f = Fixture(); await f.init(); final s = f.state;
    await s.addExpense(amount: kzt(2500), category: 'cafe', account: 'cash', date: s.today);
    final old = s.userTransactions.firstWhere((t) => t.type == EventType.expense);
    await s.refund(old, category: 'cafe', amount: kzt(2500), account: 'cash');
    await s.editExpense(old, splits: {'cafe': kzt(2500)}, account: 'cash', date: old.date, who: 'me', note: 'note only');
    final edited = s.userTransactions.firstWhere((t) => t.type == EventType.expense);
    expect(s.refundedFor(edited.id, 'cafe'), kzt(2500));
  });

  test('F03: reversing a scheduled payment must reopen the unpaid occurrence', () async {
    final f = Fixture(); await f.init(); await f.plan(); final s = f.state;
    final due = s.upcoming.firstWhere((d) => d.period == '2026-09');
    await s.payDue(due, account: 'cash', amount: kzt(10000));
    final payment = s.userTransactions.firstWhere((t) => t.type == EventType.expense);
    await s.deleteTransaction(payment.id);
    expect(s.planned.single.paid.contains('2026-09'), isFalse);
  });

  test('F04: unpaid September bill must remain overdue in October', () async {
    final f = Fixture(); await f.init(); await f.plan();
    expect(f.state.upcoming.any((d) => d.period == '2026-09'), isTrue);
    f.now = DateTime(2026, 10, 1);
    expect(f.state.upcoming.any((d) => d.period == '2026-09'), isTrue);
  });

  test('F05: network failure must not leave a confirmed-looking phantom balance', () async {
    final f = Fixture(); await f.init(); final s = f.state;
    f.offline = true;
    await expectLater(s.addIncome(amount: kzt(777), source: 'salary', account: 'cash', date: s.today), throwsA(isA<ApiException>()));
    expect(s.busy, isFalse);
    expect(s.ledger.balance('cash'), kzt(100000));
  });
}
