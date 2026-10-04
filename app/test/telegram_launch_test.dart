import 'package:famcoin/ui/auth/telegram_launch.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('прямая ссылка Telegram сохраняет бота и одноразовый start-код', () {
    final link = telegramAppLink(Uri.parse('https://t.me/famcoin_test_bot?start=login_aB09_-'));
    expect(link.scheme, 'tg');
    expect(link.host, 'resolve');
    expect(link.queryParameters, {'domain': 'famcoin_test_bot', 'start': 'login_aB09_-'});
    expect(link.path, isEmpty);
  });

  test('обычные, чужие и некорректные ссылки не превращаются в команды Telegram', () {
    for (final value in [
      'https://example.test/famcoin_bot?start=login_code',
      'https://t.me/famcoin_bot',
      'https://t.me/famcoin_bot/123?start=login_code',
      'https://t.me/famcoin_bot?start=',
      'https://t.me/famcoin_bot?start=login_%26admin',
      'http://t.me/famcoin_bot?start=login_code',
    ]) {
      final link = Uri.parse(value);
      expect(telegramAppLink(link), link, reason: value);
    }
  });
}
