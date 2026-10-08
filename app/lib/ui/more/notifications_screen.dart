import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../state/app_scope.dart';
import '../../state/push.dart';
import '../../theme/app_theme.dart';
import '../widgets/common.dart';
import '../widgets/push_enable.dart';

/// S34 — уведомления: утренняя сводка и вечерний отчёт, доставка в Telegram.
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  List<Map<String, dynamic>>? _items;
  Map<String, dynamic>? _settings;

  /// Последняя загрузка не удалась (UI04). Пока данных нет — вместо вечного
  /// индикатора ошибка и «Повторить»; уже показанные данные при ошибке
  /// обновления остаются на экране.
  Object? _error;
  bool _loading = false;
  String? _code;
  bool _loadingCode = false;
  String _push = 'unsupported';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_items == null) _load();
  }

  Future<void> _load() async {
    final state = AppScope.of(context).state;
    // Первая загрузка идёт из didChangeDependencies — там без setState; после
    // ошибки «Повторить» снова показывает индикатор.
    _loading = true;
    if (_error != null) setState(() {});
    try {
      final items = await state.api.notifications(state.token);
      final settings = await state.api.notificationSettings(state.token);
      final push = await pushStatus();
      if (!mounted) return;
      setState(() {
        _items = items;
        _settings = settings;
        _push = push;
        _error = null;
        _loading = false;
      });
      // Подписка есть в браузере, но сервер её потерял (например, удалил как
      // просроченную) — передаём заново, разрешение повторно не спрашивается.
      if (push == 'on' && (settings['pushDevices'] ?? 0) == 0) {
        try {
          final sub = await pushEnable(await state.api.pushKey(state.token));
          if (sub != null) {
            await state.api.pushSubscribe(state.token, sub);
            pushConfirmEnabled();
          }
        } catch (_) {}
      }
      if (items.any((i) => i['read'] != true)) await state.api.markNotificationsRead(state.token);
    } catch (e) {
      if (!mounted) return;
      final hadData = _items != null;
      setState(() {
        _error = e;
        _loading = false;
      });
      // Данные уже на экране — о сбое обновления достаточно короткого сообщения.
      if (hadData) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorText(context.l10n, e))));
    }
  }

  Future<void> _toggle(String key, bool value) async {
    final state = AppScope.of(context).state;
    final ok = await runAction(context, () async {
      final s = await state.api.updateNotificationSettings(state.token, {key: value});
      if (mounted) setState(() => _settings = s);
    });
    if (!ok && mounted) setState(() {});
  }

  Future<void> _disablePush() async {
    final state = AppScope.of(context).state;
    await runAction(context, () async {
      final endpoint = await pushDisable();
      if (endpoint.isNotEmpty) await state.api.pushUnsubscribe(state.token, endpoint);
    });
    if (mounted) _load();
  }

  Widget _pushCard(BuildContext context) {
    final l = context.l10n;
    final fam = context.fam;
    final hint = switch (_push) {
      'on' => l.pushOnDesc,
      'off' => l.pushOffDesc,
      'needs-install' => l.pushNeedsInstall,
      'denied' => l.pushDenied,
      _ => l.pushUnsupported,
    };
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.notifications_active_outlined),
          const SizedBox(width: 10),
          Expanded(child: Text(l.pushTitle, style: const TextStyle(fontWeight: FontWeight.w600))),
          if (_push == 'on') Text(l.pushOn, style: TextStyle(color: fam.income, fontWeight: FontWeight.w600)),
        ]),
        const SizedBox(height: 6),
        Text(hint, style: TextStyle(fontSize: 12, color: fam.text2)),
        if (_push == 'off') ...[
          const SizedBox(height: 8),
          PushEnableButton(onResult: (result) {
            if (result == PushEnableResult.enabled || result == PushEnableResult.denied) _load();
          }),
        ] else if (_push == 'on') ...[
          const SizedBox(height: 8),
          OutlinedButton(onPressed: _disablePush, child: Text(l.pushDisable)),
        ],
      ]),
    );
  }

  Future<void> _link() async {
    final state = AppScope.of(context).state;
    setState(() => _loadingCode = true);
    await runAction(context, () async {
      final code = await state.api.telegramLinkCode(state.token);
      if (mounted) setState(() => _code = code);
    });
    if (mounted) setState(() => _loadingCode = false);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final state = AppScope.of(context).state;
    final fam = context.fam;
    final locale = Localizations.localeOf(context).toString();
    final s = _settings;

    return Scaffold(
      appBar: AppBar(title: Text(l.notifications)),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          children: [
            if (s != null) ...[
              AppCard(
                child: Column(children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(l.morningBrief),
                    subtitle: Text(l.morningBriefDesc, style: TextStyle(fontSize: 12, color: fam.text2)),
                    value: s['morning'] == true,
                    onChanged: (v) => _toggle('morning', v),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(l.eveningReport),
                    subtitle: Text(l.eveningReportDesc, style: TextStyle(fontSize: 12, color: fam.text2)),
                    value: s['evening'] == true,
                    onChanged: (v) => _toggle('evening', v),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(l.notifMonthTitle),
                    subtitle: Text(l.notifMonthDesc, style: TextStyle(fontSize: 12, color: fam.text2)),
                    value: s['month'] != false,
                    onChanged: (v) => _toggle('month', v),
                  ),
                ]),
              ),
              _pushCard(context),
              AppCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    const Icon(Icons.send_outlined),
                    const SizedBox(width: 10),
                    Expanded(child: Text('Telegram', style: const TextStyle(fontWeight: FontWeight.w600))),
                    if (s['telegramLinked'] == true) Text(l.linked, style: TextStyle(color: fam.income, fontWeight: FontWeight.w600)),
                  ]),
                  const SizedBox(height: 6),
                  if (s['telegramAvailable'] != true)
                    Text(l.telegramUnavailable, style: TextStyle(fontSize: 12, color: fam.text2))
                  else if (s['telegramLinked'] == true) ...[
                    Text(l.telegramLinkedDesc, style: TextStyle(fontSize: 12, color: fam.text2)),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: () async {
                        if (await confirm(context, title: l.telegramUnlink, action: l.telegramUnlink) && context.mounted) {
                          await runAction(context, () => state.api.telegramUnlink(state.token));
                          _load();
                        }
                      },
                      child: Text(l.telegramUnlink),
                    ),
                  ] else ...[
                    Text(l.telegramHowTo, style: TextStyle(fontSize: 12, color: fam.text2)),
                    const SizedBox(height: 8),
                    if (_code == null)
                      FilledButton.tonal(onPressed: _loadingCode ? null : _link, child: Text(l.telegramGetCode))
                    else ...[
                      InkWell(
                        onTap: () {
                          Clipboard.setData(ClipboardData(text: '/start $_code'));
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.copied)));
                        },
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(color: context.scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
                          child: Row(children: [
                            Expanded(child: Text('/start $_code', style: const TextStyle(fontFamily: 'monospace', fontSize: 16, fontWeight: FontWeight.w700))),
                            const Icon(Icons.copy, size: 18),
                          ]),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(l.telegramCodeNote, style: TextStyle(fontSize: 12, color: fam.text2)),
                      TextButton(onPressed: _load, child: Text(l.telegramCheck)),
                    ],
                  ],
                ]),
              ),
              Row(children: [
                Expanded(child: OutlinedButton(onPressed: () => _test('morning'), child: Text(l.sendTestMorning))),
                const SizedBox(width: 8),
                Expanded(child: OutlinedButton(onPressed: () => _test('evening'), child: Text(l.sendTestEvening))),
              ]),
              const SizedBox(height: 8),
              SizedBox(width: double.infinity, child: OutlinedButton(onPressed: () => _test('month'), child: Text(l.sendTestMonth))),
            ],
            SectionHeader(l.notificationsHistory),
            if (_items == null && _error != null && !_loading)
              AppCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(errorText(l, _error!)),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(onPressed: _load, icon: const Icon(Icons.refresh), label: Text(l.retry)),
                ]),
              )
            else if (_items == null)
              const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))
            else if (_items!.isEmpty)
              EmptyHint(l.noNotifications, icon: Icons.notifications_none)
            else
              for (final n in _items!)
                AppCard(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Icon(n['kind'] == 'morning' ? Icons.wb_sunny_outlined : n['kind'] == 'evening' ? Icons.nightlight_outlined : Icons.info_outline, size: 18),
                      const SizedBox(width: 8),
                      Expanded(child: Text(n['title'] as String, style: const TextStyle(fontWeight: FontWeight.w600))),
                      Text(DateFormat.MMMd(locale).add_Hm().format(DateTime.parse(n['createdAt'] as String).toLocal()), style: TextStyle(fontSize: 11, color: fam.text2)),
                    ]),
                    const SizedBox(height: 6),
                    Text((n['body'] as String).replaceAll(RegExp(r'</?b>'), ''), style: const TextStyle(fontSize: 13)),
                  ]),
                ),
          ],
        ),
      ),
    );
  }

  Future<void> _test(String kind) async {
    final state = AppScope.of(context).state;
    if (await runAction(context, () => state.api.sendTestNotification(state.token, kind))) _load();
  }
}
