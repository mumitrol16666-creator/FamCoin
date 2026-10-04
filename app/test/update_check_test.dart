// Проверка обновлений (D103): сайт сравнивает метку сборки, APK — версию;
// «Позже» помнится до следующей версии; ошибки сети не беспокоят.
import 'dart:convert';

import 'package:famcoin/state/update_check.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('сравнение версий: номер сборки важнее, потом части версии', () {
    expect(isNewerVersion('0.1.3+4', '0.1.2+3'), isTrue);
    expect(isNewerVersion('0.1.2+3', '0.1.3+4'), isFalse);
    expect(isNewerVersion('0.1.3+4', '0.1.3+4'), isFalse);
    expect(isNewerVersion('0.2.0', '0.1.9'), isTrue);
    expect(isNewerVersion('1.0', '0.9.9'), isTrue);
    expect(isNewerVersion('', '0.1.0'), isFalse);
    expect(isNewerVersion('0.1.0', ''), isFalse);
  });

  group('сайт', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    UpdateCheck make(String served, {List<Uri>? seen, int status = 200}) => UpdateCheck(
          site: 'https://coin.test',
          web: true,
          currentBuild: 'b1',
          client: MockClient((r) async {
            seen?.add(r.url);
            return http.Response(served, status);
          }),
        );

    test('та же метка — обновления нет; новая — есть, «Позже» прячет до следующей', () async {
      final seen = <Uri>[];
      final same = make(jsonEncode({'buildId': 'b1', 'version': '0.1.3+4'}), seen: seen);
      await same.check();
      expect(same.available, isNull);
      expect(seen.single.path, '/build.json');

      final fresh = make(jsonEncode({'buildId': 'b2', 'version': '0.1.4+5'}));
      await fresh.check();
      expect(fresh.show, isTrue);
      expect(fresh.available!.version, '0.1.4+5');
      expect(fresh.available!.isDownload, isFalse);

      await fresh.dismiss();
      expect(fresh.show, isFalse);
      // Новый экземпляр (перезапуск приложения) помнит «Позже» для той же метки…
      final again = make(jsonEncode({'buildId': 'b2', 'version': '0.1.4+5'}));
      await again.check();
      expect(again.show, isFalse);
      // …но следующая сборка снова показывается.
      final next = make(jsonEncode({'buildId': 'b3', 'version': '0.1.5+6'}));
      await next.check();
      expect(next.show, isTrue);
    });

    test('ошибка сервера или не JSON — тихо', () async {
      final bad = make('<html>', status: 500);
      await bad.check();
      expect(bad.available, isNull);
      final junk = make('not json');
      await junk.check();
      expect(junk.available, isNull);
    });

    test('без зашитой метки (отладка) проверки нет', () async {
      final seen = <Uri>[];
      final c = UpdateCheck(site: 'https://coin.test', web: true, currentBuild: '', client: MockClient((r) async {
        seen.add(r.url);
        return http.Response('{}', 200);
      }));
      await c.check();
      expect(seen, isEmpty);
    });
  });

  test('APK: версия новее — ссылка на файл; та же или старее — ничего', () async {
    SharedPreferences.setMockInitialValues({});
    UpdateCheck make(Map<String, Object> served) => UpdateCheck(
          site: 'https://coin.test',
          web: false,
          currentVersion: '0.1.3+4',
          client: MockClient((r) async {
            expect(r.url.path, '/download/android.json');
            return http.Response(jsonEncode(served), 200);
          }),
        );
    final newer = make({'version': '0.1.4+5', 'url': 'https://coin.test/download/famcoin.apk'});
    await newer.check();
    expect(newer.show, isTrue);
    expect(newer.available!.url, 'https://coin.test/download/famcoin.apk');
    final same = make({'version': '0.1.3+4', 'url': 'https://coin.test/download/famcoin.apk'});
    await same.check();
    expect(same.available, isNull);
    final older = make({'version': '0.1.2+3', 'url': 'https://coin.test/download/famcoin.apk'});
    await older.check();
    expect(older.available, isNull);
  });
}
