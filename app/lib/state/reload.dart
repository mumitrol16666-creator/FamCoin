/// Перезагрузка приложения после обновления: только в веб-сборке.
library;

export 'reload_stub.dart' if (dart.library.js_interop) 'reload_web.dart';
