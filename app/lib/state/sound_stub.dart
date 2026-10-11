/// Не веб: системный звук нажатия; готовить ничего не нужно.
library;

import 'package:flutter/services.dart';

void armRecordSound() {}

void playRecordSound() {
  SystemSound.play(SystemSoundType.click);
}
