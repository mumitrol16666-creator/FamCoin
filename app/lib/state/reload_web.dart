/// Перезагрузка страницы через помощник `window.famcoinReload` из web/index.html.
library;

import 'dart:js_interop';

@JS('famcoinReload')
external void _reload();

void reloadApp() => _reload();
