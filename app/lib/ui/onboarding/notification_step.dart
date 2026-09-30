import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../widgets/common.dart';
import '../widgets/push_enable.dart';

/// Ключи настроек уведомлений на сервере (`/notifications/settings`).
const notificationKinds = ['morning', 'evening', 'month'];

/// Шаг анкеты «Уведомления» (D76): что присылать — галочками, и сразу
/// включить push на телефоне, пока человек здесь. Иначе до экрана
/// «Ещё → Уведомления» доходят единицы.
class NotificationStep extends StatelessWidget {
  const NotificationStep({super.key, required this.values, required this.onToggle});

  /// `morning`, `evening`, `month` → включено ли.
  final Map<String, bool> values;
  final void Function(String kind, bool on) onToggle;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final fam = context.fam;
    Widget row(String kind, String title, String subtitle) => CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(title),
          subtitle: Text(subtitle, style: TextStyle(fontSize: 12, color: fam.text2)),
          value: values[kind] ?? true,
          onChanged: (v) => onToggle(kind, v ?? true),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      AppCard(
        child: Column(children: [
          row('morning', l.morningBrief, l.morningBriefDesc),
          row('evening', l.eveningReport, l.eveningReportDesc),
          row('month', l.notifMonthTitle, l.notifMonthDesc),
        ]),
      ),
      const AppCard(child: PushEnableSection()),
      const SizedBox(height: 4),
      Text(l.obNotifLater, style: TextStyle(fontSize: 12, color: fam.text2)),
    ]);
  }
}
