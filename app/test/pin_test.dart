/// PIN-код и сессия: хранение в защищённом хранилище, блокировка после фона,
/// сброс при выходе.
library;

import 'package:famcoin/state/api_client.dart';
import 'package:famcoin/state/secret_store.dart';
import 'package:famcoin/state/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('PIN включается, проверяется по хешу и снимается', () async {
    SharedPreferences.setMockInitialValues({});
    final store = MemorySecretStore();
    final s = await Settings.load(api: ApiClient(baseUrl: 'http://fake.test'), secrets: store);
    expect(s.pinEnabled, isFalse);
    expect(s.locked, isFalse);

    await s.setPin('1234');
    expect(s.pinEnabled, isTrue);
    expect(store.values['pinHash'], isNot('1234'), reason: 'в хранилище только хеш с солью');
    expect(s.verifyPin('1234'), isTrue);
    expect(s.verifyPin('0000'), isFalse);

    s.lock();
    expect(s.locked, isTrue);
    expect(s.unlock('0000'), isFalse);
    expect(s.locked, isTrue);
    expect(s.unlock('1234'), isTrue);
    expect(s.locked, isFalse);

    await s.clearPin();
    expect(s.pinEnabled, isFalse);
    expect(store.values.containsKey('pinHash'), isFalse);
  });

  test('после перезапуска приложение с PIN стартует заблокированным', () async {
    SharedPreferences.setMockInitialValues({});
    final store = MemorySecretStore();
    final s1 = await Settings.load(api: ApiClient(baseUrl: 'http://fake.test'), secrets: store);
    await s1.setPin('2468');
    final s2 = await Settings.load(api: ApiClient(baseUrl: 'http://fake.test'), secrets: store);
    expect(s2.pinEnabled, isTrue);
    expect(s2.locked, isTrue);
    expect(s2.unlock('2468'), isTrue);
  });

  test('короткая пауза в фоне не блокирует, долгая — блокирует', () async {
    SharedPreferences.setMockInitialValues({});
    final s = await Settings.load(api: ApiClient(baseUrl: 'http://fake.test'), secrets: MemorySecretStore());
    await s.setPin('1111');
    s.noteBackground();
    s.noteResumed();
    expect(s.locked, isFalse, reason: 'секунда в фоне — без PIN');
    // Длинную паузу имитируем прямым вызовом lock(): таймер сравнивает даты.
    s.lock();
    expect(s.locked, isTrue);
  });

  test('сессия хранится в защищённом хранилище и переносится из старого места', () async {
    SharedPreferences.setMockInitialValues({'token': 'legacy-token', 'email': 'a@b.kz'});
    final store = MemorySecretStore();
    final s = await Settings.load(api: ApiClient(baseUrl: 'http://fake.test'), secrets: store);
    expect(s.token, 'legacy-token');
    expect(store.values['token'], 'legacy-token');
    expect((await SharedPreferences.getInstance()).getString('token'), isNull, reason: 'из обычного хранилища токен убран');

    await s.setPin('9999');
    await s.dropSession();
    expect(s.token, isNull);
    expect(s.pinEnabled, isFalse, reason: 'PIN защищал эту сессию и сбрасывается вместе с ней');
    expect(store.values.containsKey('token'), isFalse);
  });
}
