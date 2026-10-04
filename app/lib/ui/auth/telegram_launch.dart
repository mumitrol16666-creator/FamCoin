import 'package:url_launcher/url_launcher.dart';

import 'telegram_platform_stub.dart'
    if (dart.library.js_interop) 'telegram_platform_web.dart' as platform;

bool get isIosTelegramWeb => platform.isIosBrowser;

/// Telegram принимает тот же start-параметр через собственную схему.
/// Не превращаем произвольные ссылки в команды Telegram.
Uri telegramAppLink(Uri url) {
  final start = url.queryParameters['start'];
  if (url.scheme != 'https' || url.host != 't.me' || url.pathSegments.length != 1 ||
      !RegExp(r'^[A-Za-z0-9_]+$').hasMatch(url.pathSegments.single) ||
      start == null || !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(start)) {
    return url;
  }
  return Uri(scheme: 'tg', host: 'resolve', queryParameters: {
    'domain': url.pathSegments.single,
    'start': start,
  });
}

Future<bool> launchTelegram(Uri url, {bool browserFallback = false}) {
  final direct = isIosTelegramWeb && !browserFallback;
  // На iPhone новая вкладка t.me остаётся пустым окном с крестиком после
  // перехода в Telegram. Схема tg: в текущем окне передаётся приложению,
  // не заменяя страницу FamCoin промежуточным сайтом.
  return launchUrl(
    direct ? telegramAppLink(url) : url,
    mode: LaunchMode.externalApplication,
    webOnlyWindowName: direct ? '_top' : null,
  );
}
