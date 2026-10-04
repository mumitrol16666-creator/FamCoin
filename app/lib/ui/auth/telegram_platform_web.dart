import 'dart:js_interop';

@JS('navigator.userAgent')
external JSString get _userAgent;

@JS('navigator.platform')
external JSString get _platform;

@JS('navigator.maxTouchPoints')
external JSNumber get _maxTouchPoints;

// iPad в режиме настольного сайта сообщает MacIntel. Проверяем также
// сенсорный экран; системная тема Flutter здесь не определяет браузер.
bool get isIosBrowser => RegExp(r'iPad|iPhone|iPod').hasMatch(_userAgent.toDart) ||
    (_platform.toDart == 'MacIntel' && _maxTouchPoints.toDartDouble > 1);
