import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../state/app_scope.dart';
import '../../theme/app_theme.dart';
import '../widgets/common.dart';

/// S34 — уведомления: утренняя сводка и вечерний отчёт, доставка в Telegram.
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  List<Map<String, dynamic>>? _items;
  Map<String, dynamic>? _settings;
  String? _code;
  bool _loadingCode = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_items == null) _load();
  }

  Future<void> _load() async {
    final state = AppScope.of(context).state;
    try {
      final items = await state.api.notifications(state.token);
      final settings = await state.api.notificationSettings(state.token);
      if (!mounted) return;
      setState(() {
        _items = items;
        _settings = settings;
      });
      if (items.any((i) => i['read'] != true)) await state.api.markNotificationsRead(state.token);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorText(context.l10n, e))));
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
                ]),
              ),
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
            ],
            SectionHeader(l.notificationsHistory),
            if (_items == null)
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
