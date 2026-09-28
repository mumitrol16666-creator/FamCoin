import 'package:flutter/material.dart';

import '../../state/app_scope.dart';
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

/// S29 — каталог остальных разделов. Здесь только то, что уже работает;
/// закрытые возможности подписаны меткой Pro.
class MoreScreen extends StatelessWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final state = AppScope.of(context).state;
    void open(Widget w) => Navigator.push(context, MaterialPageRoute(builder: (_) => w));

    final items = <(IconData, String, bool, VoidCallback)>[
      (Icons.account_balance_wallet_outlined, l.accounts, false, () => open(const AccountsScreen())),
      (Icons.bar_chart_outlined, l.analytics, false, () => open(const AnalyticsScreen())),
      (Icons.calendar_month_outlined, l.calendar, false, () => open(const CalendarScreen())),
      (Icons.family_restroom_outlined, l.family, false, () => open(const FamilyScreen())),
      (Icons.label_outline, l.categories, false, () => open(const CategoriesScreen())),
      (Icons.auto_awesome_outlined, l.ai, true, () => showProGate(context, l.proGateAi)),
      (Icons.mic_none, l.voice, false, () => showVoiceSheet(context)),
      (Icons.qr_code_scanner, l.receipt, true, () => showProGate(context, l.proGateFast)),
      (Icons.notifications_none, l.notifications, false, () => open(const NotificationsScreen())),
      (Icons.workspace_premium_outlined, l.tariff, false, () => open(const TariffScreen())),
      (Icons.shield_outlined, l.security, false, () => open(const SecurityScreen())),
      (Icons.settings_outlined, l.settings, false, () => open(const SettingsScreen())),
    ];

    return Scaffold(
      appBar: AppBar(title: Text(l.navMore)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          AppCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Column(children: [
              for (final (icon, title, pro, onTap) in items)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CategoryAvatar(icon),
                  title: Text(title),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (pro && !state.pro) const ProBadge(),
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
