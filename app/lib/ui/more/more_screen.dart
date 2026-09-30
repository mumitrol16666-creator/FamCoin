import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../widgets/common.dart';
import '../analytics/analytics_screen.dart';
import '../budget/calendar_screen.dart';
import '../ops/voice_sheet.dart';
import 'accounts_screen.dart';
import 'categories_screen.dart';
import 'family_screen.dart';
import 'notifications_screen.dart';
import 'security_screen.dart';
import 'settings_screen.dart';
import 'tariff_screen.dart';
import '../budget/month_close_screen.dart';

enum _Badge { none, soon }

/// S29 — каталог остальных разделов. Здесь только то, что уже работает;
/// будущие возможности подписаны «скоро» и ничего не обещают за Pro.
class MoreScreen extends StatelessWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final fam = context.fam;
    void open(Widget w) => Navigator.push(context, MaterialPageRoute(builder: (_) => w));

    final items = <(IconData, String, _Badge, VoidCallback)>[
      (Icons.account_balance_wallet_outlined, l.accounts, _Badge.none, () => open(const AccountsScreen())),
      (Icons.bar_chart_outlined, l.analytics, _Badge.none, () => open(const AnalyticsScreen())),
      (Icons.fact_check_outlined, l.monthCloseTitle, _Badge.none, () => open(const MonthCloseListScreen())),
      (Icons.calendar_month_outlined, l.calendar, _Badge.none, () => open(const CalendarScreen())),
      (Icons.family_restroom_outlined, l.family, _Badge.none, () => open(const FamilyScreen())),
      (Icons.label_outline, l.categories, _Badge.none, () => open(const CategoriesScreen())),
      (Icons.mic_none, l.voice, _Badge.none, () => showVoiceSheet(context)),
      (
        Icons.auto_awesome_outlined,
        l.ai,
        _Badge.soon,
        () => showDialog<void>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: Text(l.ai),
                content: Text(l.aiSoonNote),
                actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: Text(l.later))],
              ),
            ),
      ),
      (Icons.notifications_none, l.notifications, _Badge.none, () => open(const NotificationsScreen())),
      (Icons.workspace_premium_outlined, l.tariff, _Badge.none, () => open(const TariffScreen())),
      (Icons.shield_outlined, l.security, _Badge.none, () => open(const SecurityScreen())),
      (Icons.settings_outlined, l.settings, _Badge.none, () => open(const SettingsScreen())),
    ];

    return Scaffold(
      appBar: AppBar(title: Text(l.navMore)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          AppCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Column(children: [
              for (final (icon, title, badge, onTap) in items)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CategoryAvatar(icon),
                  title: Text(title, style: badge == _Badge.soon ? TextStyle(color: fam.text2) : null),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (badge == _Badge.soon)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(border: Border.all(color: fam.line), borderRadius: BorderRadius.circular(999)),
                        child: Text(l.soon, style: TextStyle(fontSize: 11, color: fam.text2)),
                      ),
                    const SizedBox(width: 8),
                    const Icon(Icons.chevron_right),
                  ]),
                  onTap: onTap,
                ),
            ]),
          ),
        ],
      ),
    );
  }
}
