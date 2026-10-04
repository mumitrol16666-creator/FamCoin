/// Web Push через помощник `window.famcoinPush` из web/index.html.
library;

import 'dart:convert';
import 'dart:js_interop';

@JS('famcoinPush.status')
external JSPromise<JSString> _status();

@JS('famcoinPush.enable')
external JSPromise<JSString> _enable(JSString key);

@JS('famcoinPush.requestPermission')
external JSPromise<JSString> _requestPermission();

@JS('famcoinPush.confirmEnabled')
external void _confirmEnabled();

@JS('famcoinPush.disable')
external JSPromise<JSString> _disable();

/// `unsupported`, `needs-install`, `denied`, `off` или `on`.
Future<String> pushStatus() async {
  try {
    return (await _status().toDart).toDart;
  } catch (_) {
    return 'unsupported';
  }
}

Future<String> pushRequestPermission() async => (await _requestPermission().toDart).toDart;

void pushConfirmEnabled() => _confirmEnabled();

/// Подписывает после разрешения; `null` — разрешение не дано.
Future<Map<String, dynamic>?> pushEnable(String vapidKey) async {
  final json = (await _enable(vapidKey.toJS).toDart.timeout(const Duration(seconds: 30))).toDart;
  return json.isEmpty ? null : jsonDecode(json) as Map<String, dynamic>;
}

/// Отписывает устройство; возвращает адрес подписки или пустую строку.
Future<String> pushDisable() async => (await _disable().toDart).toDart;
