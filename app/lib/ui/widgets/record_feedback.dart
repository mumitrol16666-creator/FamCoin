/// Отклик на записанную операцию (D166): лёгкая вибрация и звук «монетки».
/// Выключается в настройках («Звук при записи»). [armRecordFeedback] — в
/// самом жесте нажатия, [recordedFeedback] — после ответа сервера.
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../state/app_scope.dart';
import '../../state/sound.dart';

/// Для тестов: что сыграло бы устройство.
@visibleForTesting
final recordFeedbackLog = <String>[];

void armRecordFeedback(BuildContext context) {
  if (!AppScope.of(context).settings.recordSound) return;
  armRecordSound();
}

void recordedFeedback(BuildContext context) {
  if (!AppScope.of(context).settings.recordSound) return;
  recordFeedbackLog.add('coin');
  HapticFeedback.lightImpact();
  playRecordSound();
}
