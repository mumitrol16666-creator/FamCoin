/// Обязательный CI не теряет проверки с базой и восстановления (CS04).
///
/// Раньше integration запускал ручной список DB-файлов: пять новых файлов
/// (19 тестов) в него не попали, а без базы такие тесты тихо пропускались.
/// Здесь проверяется, что каждый тест с базой входит в обязательный прогон,
/// что недоступная база делает прогон красным, и что восстановление из копии
/// запускается отдельным job без права на пропуск.
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

Map<String, dynamic> _workflow() {
  final f = File('../.github/workflows/ci.yml');
  return Map<String, dynamic>.from(loadYaml(f.readAsStringSync()) as Map);
}

List<Map> _steps(Map<String, dynamic> wf, String job) =>
    ((wf['jobs'] as Map)[job]['steps'] as List).cast<Map>();

void main() {
  test('каждый тест с базой назван *_db_test.dart, падает без базы при TEST_DB_REQUIRED=1 и входит в integration', () {
    final step = _steps(_workflow(), 'integration').firstWhere(
      (s) => '${s['run']}'.contains('dart test') && '${s['run']}'.contains('_db_test'),
      orElse: () => fail('в integration нет шага с DB-тестами'),
    );
    expect((step['env'] as Map?)?['TEST_DB_REQUIRED'], '1', reason: 'без него недоступная база даёт пропуск');
    final args = '${step['run']}'.split(RegExp(r'\s+')).where((a) => a.startsWith('test/')).toList();
    final byGlob = args.contains('test/*_db_test.dart');

    final dbFiles = Directory('test')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart') && !f.path.endsWith('ci_config_test.dart'))
        .where((f) => f.readAsStringSync().contains("Platform.environment['TEST_DB_PORT']"))
        .toList();
    expect(dbFiles, isNotEmpty);
    for (final f in dbFiles) {
      final name = f.uri.pathSegments.last;
      expect(name, endsWith('_db_test.dart'), reason: '$name ходит в базу, но не попадёт под шаблон integration');
      expect(byGlob || args.contains('test/$name'), isTrue, reason: '$name не запускается в integration');
      expect(
        RegExp(r"TEST_DB_REQUIRED'\]\s*==\s*'1'\)\s*fail\(").hasMatch(f.readAsStringSync()),
        isTrue,
        reason: '$name без базы пропустится даже в обязательном прогоне',
      );
    }
  });

  test('восстановление из копии — отдельный обязательный job', () {
    final steps = _steps(_workflow(), 'restore');
    final run = steps.firstWhere((s) => '${s['run']}'.contains('deploy/restore_test.py'), orElse: () => fail('нет запуска restore_test.py'));
    expect((run['env'] as Map?)?['RESTORE_TEST_REQUIRED'], '1');
    expect(File('../deploy/restore_test.py').readAsStringSync(), contains("os.environ.get('RESTORE_TEST_REQUIRED') == '1'"));
  });

  test('недоступная база с TEST_DB_REQUIRED=1 делает прогон красным, а не зелёным с пропуском', () async {
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final closedPort = probe.port;
    await probe.close();
    final r = await Process.run(
      Platform.resolvedExecutable,
      ['test', 'test/admin_users_db_test.dart'],
      environment: {'TEST_DB_REQUIRED': '1', 'TEST_DB_PORT': '$closedPort'},
    );
    expect(r.exitCode, isNot(0), reason: '${r.stdout}');
    expect('${r.stdout}', contains('TEST_DB_REQUIRED=1, а база недоступна'));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
