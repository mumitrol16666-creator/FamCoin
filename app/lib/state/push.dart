/// Push-уведомления: веб-реализация через `window.famcoinPush`, иначе заглушка.
library;

import 'push_stub.dart' if (dart.library.js_interop) 'push_web.dart' as impl;

export 'push_stub.dart' if (dart.library.js_interop) 'push_web.dart' show pushEnable, pushDisable;

/// Для тестов: подменяет ответ [pushStatus] (`off`, `needs-install`, …),
/// чтобы проверить карточки и кнопки, которых в заглушке не бывает.
String? debugPushStatusOverride;

/// `unsupported`, `needs-install`, `denied`, `off` или `on`.
Future<String> pushStatus() => debugPushStatusOverride != null ? Future.value(debugPushStatusOverride) : impl.pushStatus();
