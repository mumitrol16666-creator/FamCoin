/// Push-уведомления: веб-реализация через `window.famcoinPush`, иначе заглушка.
library;

import 'push_stub.dart' if (dart.library.js_interop) 'push_web.dart' as impl;

export 'push_stub.dart' if (dart.library.js_interop) 'push_web.dart' show pushDisable;

/// Для тестов: подменяет ответ [pushStatus] (`off`, `needs-install`, …),
/// чтобы проверить карточки и кнопки, которых в заглушке не бывает.
String? debugPushStatusOverride;
Future<String> Function()? debugPushPermissionOverride;
Future<Map<String, dynamic>?> Function(String)? debugPushEnableOverride;
void Function()? debugPushConfirmOverride;

/// `unsupported`, `needs-install`, `denied`, `off` или `on`.
Future<String> pushStatus() => debugPushStatusOverride != null ? Future.value(debugPushStatusOverride) : impl.pushStatus();

/// Вызывается прямо из обработчика нажатия, до первого сетевого ожидания.
Future<String> pushRequestPermission() => (debugPushPermissionOverride ?? impl.pushRequestPermission)();

Future<Map<String, dynamic>?> pushEnable(String key) => (debugPushEnableOverride ?? impl.pushEnable)(key);

void pushConfirmEnabled() => (debugPushConfirmOverride ?? impl.pushConfirmEnabled)();
