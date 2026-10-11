/// Веб: «монетка» через `window.famcoinSound` из web/index.html.
library;

import 'dart:js_interop';

@JS('famcoinSound.arm')
external void _arm();

@JS('famcoinSound.coin')
external void _coin();

void armRecordSound() {
  try {
    _arm();
  } catch (_) {}
}

void playRecordSound() {
  try {
    _coin();
  } catch (_) {}
}
