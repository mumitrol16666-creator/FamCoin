import 'package:flutter/material.dart';

import '../../state/app_scope.dart';
import '../../state/app_state.dart';
import '../../state/push.dart';
import '../../theme/app_theme.dart';
import 'common.dart';

enum PushEnableResult { enabled, denied, dismissed, unavailable, failed }

/// Успех — разрешение, подписка браузера и подтверждение сервера.
Future<PushEnableResult> enablePushNotifications(BuildContext context, AppState state) async {
  final settings = AppScope.of(context).settings;
  try {
    // Никакой сети до системного запроса разрешения: сохраняем жест пользователя.
    final permission = await pushRequestPermission();
    if (permission == 'denied') return PushEnableResult.denied;
    if (permission == 'default') return PushEnableResult.dismissed;
    if (permission != 'granted') return PushEnableResult.unavailable;
    final key = await state.api.pushKey(state.token);
    final sub = await pushEnable(key);
    if (sub == null) return PushEnableResult.dismissed;
    await state.api.pushSubscribe(state.token, sub);
    pushConfirmEnabled();
    await settings.dismissPushPrompt();
    return PushEnableResult.enabled;
  } catch (_) {
    return PushEnableResult.failed;
  }
}

/// Один сценарий для главной, анкеты и настроек: процесс, результат, повтор.
class PushEnableButton extends StatefulWidget {
  const PushEnableButton({super.key, this.onResult, this.compact = false});
  final ValueChanged<PushEnableResult>? onResult;
  final bool compact;

  @override
  State<PushEnableButton> createState() => _PushEnableButtonState();
}

class _PushEnableButtonState extends State<PushEnableButton> {
  bool _busy = false;
  PushEnableResult? _result;

  Future<void> _enable() async {
    if (_busy) return;
    final messenger = ScaffoldMessenger.of(context);
    final successMessage = context.l10n.pushEnabledSuccess;
    setState(() { _busy = true; _result = null; });
    final result = await enablePushNotifications(context, AppScope.of(context).state);
    // Главная уже может убрать карточку по изменению settings.
    if (result == PushEnableResult.enabled && messenger.mounted) {
      messenger.showSnackBar(SnackBar(content: Text(successMessage)));
    }
    if (!mounted) return;
    setState(() { _busy = false; _result = result; });
    widget.onResult?.call(result);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final message = switch (_result) {
      PushEnableResult.denied => l.pushDenied,
      PushEnableResult.dismissed => l.pushPermissionNotGranted,
      PushEnableResult.unavailable => l.pushUnsupportedShort,
      PushEnableResult.failed => l.pushEnableFailed,
      _ => null,
    };
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      FilledButton.tonal(
        style: widget.compact ? FilledButton.styleFrom(minimumSize: const Size(0, 44)) : null,
        onPressed: _busy ? null : _enable,
        child: Text(_busy ? l.pushEnabling : l.pushEnable),
      ),
      if (message != null) Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(message, style: TextStyle(fontSize: 13, color: context.fam.text2)),
      ),
    ]);
  }
}

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
          PushEnableButton(onResult: (_) => _refresh()),
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
