import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../state/app_scope.dart';
import '../../state/app_state.dart';
import '../../theme/app_theme.dart';
import '../budget/sheets.dart';
import '../widgets/common.dart';
import 'export.dart';
import 'notifications_screen.dart';
import 'security_screen.dart';
import 'tariff_screen.dart';

/// S31 — язык, тема, режим учёта, день зарплаты, тариф, выход.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final scope = AppScope.of(context);
    final settings = scope.settings;
    final state = scope.state;
    final fam = context.fam;

    Widget section(String title, Widget child, {String? tip}) => AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: fam.text2))),
              if (tip != null) InfoTip(tip, title: title),
            ]),
            const SizedBox(height: 8),
            SizedBox(width: double.infinity, child: child),
          ]),
        );

    return ListenableBuilder(
      listenable: Listenable.merge([settings, state]),
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(title: Text(l.settings)),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            children: [
              AppCard(
                onTap: () => _editAbout(context, state),
                child: Row(children: [
                  const Icon(Icons.person_outline),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Builder(builder: (context) {
                      final subtitle = [
                        if (state.birthDate != null) DateFormat.yMMMMd(Localizations.localeOf(context).toString()).format(state.birthDate!),
                        if (!state.email.endsWith('@telegram.local')) state.email,
                      ].join(' · ');
                      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(state.displayName),
                        // Пустая строка тоже занимает высоту и сдвигает иконку
                        // выше центра — показываем подпись, только если есть что.
                        if (subtitle.isNotEmpty) Text(subtitle, style: TextStyle(fontSize: 12, color: fam.text2)),
                      ]);
                    }),
                  ),
                  const Icon(Icons.chevron_right),
                ]),
              ),
              section(
                l.language,
                SegmentedButton<String>(
                  showSelectedIcon: false,
                  segments: const [ButtonSegment(value: 'ru', label: Text('Русский')), ButtonSegment(value: 'kk', label: Text('Қазақша'))],
                  selected: {settings.locale.languageCode},
                  onSelectionChanged: (s) => settings.locale = Locale(s.first),
                ),
              ),
              section(
                l.theme,
                SegmentedButton<ThemeMode>(
                  showSelectedIcon: false,
                  segments: [
                    ButtonSegment(value: ThemeMode.light, label: Text(l.themeLight)),
                    ButtonSegment(value: ThemeMode.dark, label: Text(l.themeDark)),
                    ButtonSegment(value: ThemeMode.system, label: Text(l.themeSystem)),
                  ],
                  selected: {settings.themeMode},
                  onSelectionChanged: (s) => settings.themeMode = s.first,
                ),
              ),
              section(
                l.seasonTheme,
                tip: l.tipSeason,
                Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: [
                      ButtonSegment(value: 'auto', label: Text(l.seasonAuto)),
                      ButtonSegment(value: 'autumn', label: Text(l.seasonAutumn)),
                      ButtonSegment(value: 'winter', label: Text(l.seasonWinter)),
                      ButtonSegment(value: 'none', label: Text(l.seasonNone)),
                    ],
                    selected: {settings.season},
                    onSelectionChanged: (s) => settings.season = s.first,
                  ),
                  const SizedBox(height: 6),
                  Text(l.seasonNote, style: TextStyle(fontSize: 12, color: fam.text2)),
                ]),
              ),
              section(
                l.mode,
                tip: l.tipMode,
                SegmentedButton<bool>(
                  showSelectedIcon: false,
                  segments: [ButtonSegment(value: false, label: Text(l.modePersonal)), ButtonSegment(value: true, label: Text(l.modeFamily))],
                  selected: {state.familyMode},
                  onSelectionChanged: (s) => runAction(context, () => state.setFamilyMode(s.first)),
                ),
              ),
              AppCard(
                child: SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(l.carryToggle),
                  subtitle: Text(l.carryToggleDesc, style: TextStyle(fontSize: 12, color: fam.text2)),
                  value: state.dailyLimitCarryOn,
                  onChanged: (v) => runAction(context, () => state.setDailyLimitCarryOn(v)),
                ),
              ),
              if (state.goals.isNotEmpty || !state.offerGoalsOnIncome)
                AppCard(
                  child: SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(l.incomeGoalsToggle),
                    subtitle: Text(l.incomeGoalsToggleDesc(moneyInText(AppState.incomeOfferMin)), style: TextStyle(fontSize: 12, color: fam.text2)),
                    value: state.offerGoalsOnIncome,
                    onChanged: (v) => runAction(context, () => state.setOfferGoalsOnIncome(v)),
                  ),
                ),
              AppCard(
                child: SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(l.adviceToggle),
                  subtitle: Text(l.adviceToggleDesc, style: TextStyle(fontSize: 12, color: fam.text2)),
                  value: settings.tipsEnabled,
                  onChanged: (v) => settings.tipsEnabled = v,
                ),
              ),
              AppCard(
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const TariffScreen())),
                child: Row(children: [
                  Expanded(child: Text('${l.tariff}: ${state.pro ? 'Pro' : l.freePlan}')),
                  const Icon(Icons.chevron_right),
                ]),
              ),
              AppCard(
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const NotificationsScreen())),
                child: Row(children: [
                  Expanded(child: Text(l.notifications)),
                  const Icon(Icons.chevron_right),
                ]),
              ),
              AppCard(
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SecurityScreen())),
                child: Row(children: [
                  Expanded(child: Text(l.security)),
                  const Icon(Icons.chevron_right),
                ]),
              ),
              section(
                l.dataSection,
                Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(foregroundColor: fam.expense),
                    icon: const Icon(Icons.restart_alt),
                    label: Text(l.resetAll),
                    onPressed: () => _resetAll(context),
                  ),
                  const SizedBox(height: 4),
                  Text(l.resetAllNote, style: TextStyle(fontSize: 12, color: fam.text2)),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.table_chart_outlined),
                    label: Text(l.exportCsv),
                    onPressed: () => exportData(context, format: 'csv'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.save_alt),
                    label: Text(l.exportJson),
                    onPressed: () => exportData(context, format: 'json'),
                  ),
                  const SizedBox(height: 6),
                  Text(l.exportNote, style: TextStyle(fontSize: 12, color: fam.text2)),
                ]),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () async {
                  Navigator.of(context).popUntil((r) => r.isFirst);
                  await settings.signOut();
                },
                child: Text(l.signOut),
              ),
            ],
          ),
        );
      },
    );
  }

  /// «Начать всё заново»: подтверждение словом, сервер стирает журнал,
  /// счета, планы и анкету; аккаунт и вход остаются, открывается анкета.
  Future<void> _resetAll(BuildContext context) async {
    final l = context.l10n;
    final state = AppScope.of(context).state;
    final nav = Navigator.of(context);
    final word = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text(l.resetAll),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(l.resetAllConfirm),
            const SizedBox(height: 12),
            TextField(controller: word, autofocus: true, onChanged: (_) => set(() {}), decoration: InputDecoration(hintText: l.deleteAccountWord)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.cancel)),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: ctx.fam.expense),
              onPressed: word.text.trim().toUpperCase() == l.deleteAccountWord ? () => Navigator.pop(ctx, true) : null,
              child: Text(l.resetAllAction),
            ),
          ],
        ),
      ),
    );
    word.dispose();
    if (ok != true || !context.mounted) return;
    if (await runAction(context, () async {
      await state.api.resetData(state.token);
      await state.refresh();
    })) {
      nav.popUntil((r) => r.isFirst);
    }
  }

  /// Имя, фамилия, дата рождения (D50).
  void _editAbout(BuildContext context, AppState state) {
    final l = context.l10n;
    final first = TextEditingController(text: state.firstName);
    final last = TextEditingController(text: state.lastName);
    var birth = state.birthDate;
    final locale = Localizations.localeOf(context).toString();
    showFormSheet<void>(
      context,
      title: l.aboutYou,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(controller: first, textCapitalization: TextCapitalization.words, decoration: InputDecoration(labelText: l.firstName)),
          const SizedBox(height: 12),
          TextField(controller: last, textCapitalization: TextCapitalization.words, decoration: InputDecoration(labelText: l.lastName)),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            icon: const Icon(Icons.cake_outlined),
            label: Text(birth == null ? l.birthDatePick : DateFormat.yMMMMd(locale).format(birth!)),
            onPressed: () async {
              final now = DateTime.now();
              final picked = await showDatePicker(context: ctx, initialDate: birth ?? DateTime(now.year - 30, now.month, now.day), firstDate: DateTime(1920), lastDate: now);
              if (picked != null) set(() => birth = DateTime(picked.year, picked.month, picked.day));
            },
          ),
          const SizedBox(height: 20),
          SubmitButton(
            label: l.save,
            onSubmit: () {
              if (first.text.trim().isEmpty) return Future.value(false);
              return runAction(ctx, () => state.setAbout(firstName: first.text.trim(), lastName: last.text.trim(), birthDate: birth));
            },
          ),
        ]),
      ),
    );
  }
}
