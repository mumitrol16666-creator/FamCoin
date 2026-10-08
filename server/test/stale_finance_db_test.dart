import 'dart:io';
import 'package:famcoin_core/famcoin_core.dart';
import 'package:famcoin_server/auth_service.dart';
import 'package:famcoin_server/ledger_service.dart';
import 'package:postgres/postgres.dart';
import 'package:test/test.dart';

void main() {
  Pool? db;
  final owners = <String>[];
  var sequence = 0;
  setUpAll(() async {
    final pool = Pool.withEndpoints([Endpoint(host: '127.0.0.1', port: int.parse(Platform.environment['TEST_DB_PORT'] ?? '5433'), database: 'famcoin', username: 'famcoin', password: 'famcoin')], settings: const PoolSettings(maxConnectionCount: 4, sslMode: SslMode.disable));
    try { await pool.execute('SELECT 1').timeout(const Duration(seconds: 3)); db = pool; }
    catch (_) { await pool.close(); }
  });
  tearDownAll(() async {
    if (db == null) return;
    for (final id in owners) { await deleteUserData(db!, id); }
    await db!.close();
  });
  bool skip() {
    if (db != null) return false;
    if (Platform.environment['TEST_DB_REQUIRED'] == '1') fail('Required database unavailable');
    markTestSkipped('database not running'); return true;
  }
  Future<String> owner() async {
    final rows = await db!.execute(Sql.named("INSERT INTO users (email,password_hash,plan) VALUES (@e,'x','pro') RETURNING id"), parameters: {'e': 'stale-fix-${DateTime.now().microsecondsSinceEpoch}-${sequence++}@example.test'});
    final id = rows.first[0].toString(); owners.add(id); return id;
  }
  Map<String,dynamic> entity(String kind, String id, Map<String,dynamic> data) => {'type':'upsertEntity','kind':kind,'entityId':id,'data':data};
  Map<String,dynamic> due(String date) => {'name':'Друг','amount':'8000000','person':'Друг','onDate':date,'paid':<String>[]};
  Map<String,dynamic> batch(String id, List<Map<String,dynamic>> commands) => {'type':'batch','commandId':id,'commands':commands};
  final conflict = throwsA(isA<ApiError>().having((e) => e.ledgerCode, 'code', 'entityChanged'));

  test('FV-C02: stale replacement rolls back extra borrowing and cannot duplicate agreement', () async {
    if (skip()) return;
    final service = LedgerService(db!); final u = await owner();
    await service.command(u, batch('setup', [
      {'type':'addMoneyAccount','accountId':'cash'},
      {'type':'borrow','id':'borrow','date':'2026-09-10','account':'cash','person':'Друг','amount':'8000000'},
      entity('planned','old',due('2026-09-30')),
    ]));
    await service.command(u, batch('move-a', [
      {'type':'deleteEntity','kind':'planned','entityId':'old'}, entity('planned','new-a',due('2026-10-01')),
    ]));
    final stale = batch('move-b', [
      {'type':'borrow','id':'extra','date':'2026-09-11','account':'cash','person':'Друг','amount':'2000000'},
      {'type':'deleteEntity','kind':'planned','entityId':'old'}, entity('planned','new-b',due('2026-10-02')),
    ]);
    await expectLater(service.command(u, stale), conflict);
    final view = (await service.view(u))!;
    expect(view.of('planned').keys, ['new-a']);
    expect(view.ledger.balance('cash'), 8000000);
    expect(view.ledger.balance(liabilityAccount('Друг')), 8000000);
    expect(view.ledger.byId('extra'), isNull);
    await expectLater(service.command(u, {...batch('stale-cancel', [{'type':'deleteEntity','kind':'planned','entityId':'old'}]), 'expectedRevision': 1}), conflict);
    // Idempotent replay wins over a now-obsolete expectedRevision.
    final cmd = {...batch('cancel', [{'type':'deleteEntity','kind':'planned','entityId':'new-a'}]), 'expectedRevision': 2};
    await service.command(u, cmd);
    expect((await service.command(u, cmd)).repeated, isTrue);
  });

  test('FV-C03: stale purchase cannot overdraw piggy or partially commit its batch', () async {
    if (skip()) return;
    final service = LedgerService(db!); final u = await owner();
    await service.command(u, batch('setup', [
      {'type':'addMoneyAccount','accountId':'cash'}, {'type':'addMoneyAccount','accountId':'piggy-g','liquid':false},
      {'type':'opening','id':'open','date':'2026-09-01','account':'cash','amount':'10000000'},
      entity('goal','g',{'account':'piggy-g','target':'5000000'}),
      entity('purchase','p',{'once':'2026-09','amount':'5000000','goal':'g','day':30,'paid':<String>[]}),
      {'type':'transfer','id':'deposit','date':'2026-09-28','from':'cash','to':'piggy-g','amount':'5000000'},
    ]));
    await service.command(u, batch('withdraw', [{'type':'transfer','id':'withdraw','date':'2026-10-02','from':'piggy-g','to':'cash','amount':'3000000'}]));
    await expectLater(service.command(u, batch('stale', [
      // A preceding mutation must also roll back when the transfer is rejected.
      entity('category','new-category',{'name':'temporary'}),
      {'type':'transfer','id':'stale-return','date':'2026-09-30','from':'piggy-g','to':'cash','amount':'5000000'},
      {'type':'archiveAccount','accountId':'piggy-g'}, {'type':'deleteEntity','kind':'goal','entityId':'g'},
      {'type':'expense','id':'purchase','date':'2026-09-30','account':'cash','splits':{'other':'5000000'}},
      {'type':'setPaid','kind':'purchase','entityId':'p','period':'2026-09','paid':true,'clearGoal':true},
    ])), conflict);
    final view = (await service.view(u))!;
    expect(view.ledger.balance('piggy-g'), 2000000);
    expect(view.ledger.balance('cash'), 8000000);
    expect(view.ledger.account('piggy-g').archived, isFalse);
    expect(view.of('goal'), hasLength(1)); expect(view.of('category'), isEmpty);
    expect(view.of('purchase')['p']!['paid'], isEmpty);
    expect(view.ledger.byId('purchase'), isNull);
  });

  test('FV-C01: replacing reversed partial repayment works and cannot exceed agreement', () async {
    if (skip()) return;
    final service = LedgerService(db!); final u = await owner();
    await service.command(u, batch('setup', [
      {'type':'addMoneyAccount','accountId':'cash'},
      {'type':'borrow','id':'borrow','date':'2026-09-10','account':'cash','person':'Друг','amount':'8000000'},
      entity('planned','p',due('2026-09-30')),
    ]));
    Map<String,dynamic> payment(String id, String amount, {bool part=false}) => {'type':'repaymentMade','id':id,'date':'2026-09-30','account':'cash','person':'Друг','principal':amount,'meta':{'planned':'p','period':'2026-09-30',if(part)'part':true}};
    await service.command(u, batch('pay', [payment('part','3000000',part:true), payment('final','5000000')]));
    await service.command(u, batch('reverse', [{'type':'reverse','id':'rev','txId':'part'}]));
    await service.command(u, batch('replace', [payment('replacement','3000000')]));
    await service.command(u, batch('extra', [{'type':'borrow','id':'extra','date':'2026-10-01','account':'cash','person':'Друг','amount':'1000000'}]));
    await expectLater(service.command(u, batch('over-agreement', [payment('over','1000000')])), throwsA(isA<ApiError>().having((e)=>e.ledgerCode,'code','principalExceeds')));
    expect((await service.view(u))!.ledger.balance(liabilityAccount('Друг')),1000000);
  });
}
