import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';

import '../../state/app_scope.dart';
import '../../theme/app_theme.dart';
import '../onboarding/onboarding_screen.dart';
import '../widgets/common.dart';

/// S30 — семья: справочник людей и расходы по ним за месяц.
/// Учёт ведёт один владелец; у членов семьи нет своих аккаунтов (D08).
class FamilyScreen extends StatelessWidget {
  const FamilyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final state = AppScope.of(context).state;
    final fam = context.fam;
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        // Расходы месяца по отметке «для кого».
        final byWho = <String, int>{};
        for (final tx in state.userTransactions) {
          if (tx.type != EventType.expense || tx.date.isBefore(state.monthStart)) continue;
          final who = tx.meta['who'] as String? ?? 'me';
          final sum = tx.postings.where((p) => state.ledger.account(p.accountId).kind == LedgerKind.expense).fold(0, (s, p) => s + p.amount);
          byWho.update(who, (v) => v + sum, ifAbsent: () => sum);
        }
        return Scaffold(
          appBar: AppBar(title: Text(l.family)),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            children: [
              AppCard(
                child: SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(l.modeFamily),
                  subtitle: Text(l.familyDesc, style: TextStyle(fontSize: 12, color: fam.text2)),
                  value: state.familyMode,
                  onChanged: (v) => runAction(context, () => state.setFamilyMode(v)),
                ),
              ),
              if (state.familyMode) ...[
                InfoBanner(l.familyNote),
                AppCard(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Column(children: [
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const CircleAvatar(child: Icon(Icons.person_outline)),
                      title: Text(l.me),
                      trailing: MoneyText(byWho['me'] ?? 0),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const CircleAvatar(child: Icon(Icons.groups_outlined)),
                      title: Text(l.shared),
                      trailing: MoneyText(byWho['shared'] ?? 0),
                    ),
                    for (final m in state.members)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: CircleAvatar(child: Text(m.name.characters.first.toUpperCase())),
                        title: Text(m.name),
                        subtitle: Text(roleName(l, m.role), style: TextStyle(fontSize: 12, color: fam.text2)),
                        trailing: MoneyText(byWho[m.id] ?? 0),
                        onLongPress: () async {
                          if (await confirm(context, title: l.deleteMember, message: l.deleteMemberHint, action: l.delete) && context.mounted) {
                            await runAction(context, () => state.delete('member', m.id));
                          }
                        },
                      ),
                  ]),
                ),
                Text(l.spentThisMonthByWho, style: TextStyle(fontSize: 12, color: fam.text2)),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  icon: const Icon(Icons.person_add_alt),
                  label: Text(l.addMember),
                  onPressed: () async {
                    final m = await showMemberSheet(context);
                    if (m != null && context.mounted) await runAction(context, () => state.upsert('member', m.id, m.toJson()));
                  },
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
