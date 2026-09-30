import 'package:flutter/material.dart';

import '../../state/app_scope.dart';
import '../../state/app_state.dart';
import '../../state/push.dart';
import '../../theme/app_theme.dart';
import 'common.dart';

/// Включить push на этом устройстве: разрешение запрашивается сразу по
/// нажатию (иначе iOS его не покажет), подписка уходит на сервер.
/// `true` — запрос прошёл (разрешение могло быть и отклонено — это видно по
/// `pushStatus()` после), `false` — ошибка сети или сервера, уже показана.
Future<bool> enablePushNotifications(BuildContext context, AppState state) => runAction(context, () async {
      final key = await state.api.pushKey(state.token);
      final sub = await pushEnable(key);
      if (sub != null) await state.api.pushSubscribe(state.token, sub);
    });

/// Состояние push на устройстве и кнопка «Включить» (D76). Используется в
/// анкете первого входа; сам узнаёт статус и обновляет его после нажатия.
class PushEnableSection extends StatefulWidget {
  const PushEnableSection({super.key, this.onChanged});

  /// Статус изменился (например, стал `on`) — для тех, кто рядом что-то показывает.
  final ValueChanged<String>? onChanged;

  @override
  State<PushEnableSection> createState() => _PushEnableSectionState();
}

class _PushEnableSectionState extends State<PushEnableSection> {
  String? _status;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final s = await pushStatus();
    if (!mounted) return;
    setState(() => _status = s);
    widget.onChanged?.call(s);
  }

  Future<void> _enable() async {
    final state = AppScope.of(context).state;
    await enablePushNotifications(context, state);
    if (mounted) await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final fam = context.fam;
    final status = _status;
    if (status == null) return const SizedBox.shrink();
    final Widget body = switch (status) {
      'on' => Row(children: [
          Icon(Icons.check_circle, color: fam.income, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(l.pushOnDesc, style: TextStyle(fontSize: 13, color: fam.text2))),
        ]),
      'off' => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(l.obPushOff, style: TextStyle(fontSize: 13, color: fam.text2)),
          const SizedBox(height: 8),
          FilledButton.tonal(onPressed: _enable, child: Text(l.pushEnable)),
        ]),
      'needs-install' => InfoBanner(l.pushNeedsInstall),
      'denied' => Text(l.pushDenied, style: TextStyle(fontSize: 13, color: fam.text2)),
      _ => Text(l.pushUnsupportedShort, style: TextStyle(fontSize: 13, color: fam.text2)),
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Icon(Icons.notifications_active_outlined, size: 20),
        const SizedBox(width: 8),
        Expanded(child: Text(l.pushTitle, style: const TextStyle(fontWeight: FontWeight.w600))),
        if (status == 'on') Text(l.pushOn, style: TextStyle(color: fam.income, fontWeight: FontWeight.w600)),
      ]),
      const SizedBox(height: 8),
      body,
    ]);
  }
}
