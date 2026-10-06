import 'dart:js_interop';

@JS('navigator.userAgent')
external JSString get _userAgent;

@JS('window.matchMedia')
external JSObject _matchMedia(JSString query);

extension on JSObject {
  @JS('matches')
  external JSBoolean get matches;
}

/// Сайт открыт в браузере на Android (не на iPhone и не на компьютере).
bool get isAndroidBrowser => RegExp(r'Android', caseSensitive: false).hasMatch(_userAgent.toDart);

/// Сайт установлен «на экран Домой» и открыт как приложение: ставить уже нечего.
bool get isStandalonePwa {
  try {
    return _matchMedia('(display-mode: standalone)'.toJS).matches.toDart;
  } catch (_) {
    return false;
  }
}
