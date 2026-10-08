import 'package:flutter/material.dart';

import '../../state/app_scope.dart';
import '../../theme/app_theme.dart';
import '../auth/auth_widgets.dart';
import '../widgets/common.dart';
import 'onboarding_screen.dart';

/// Первое, что видит человек после входа: короткое приветствие и два входа в
/// настройку. «Быстрый старт» — имя, счёт и дневной лимит; «Подробная» — вся
/// анкета. Кто уже прошёл анкету, сюда не попадает.
class OnboardingGate extends StatefulWidget {
  const OnboardingGate({super.key});

  @override
  State<OnboardingGate> createState() => _OnboardingGateState();
}

class _OnboardingGateState extends State<OnboardingGate> {
  /// `null` — уровень ещё не выбран, показано приветствие.
  OnboardingLevel? _level;

  @override
  Widget build(BuildContext context) {
    final level = _level;
    if (level == null) return WelcomeScreen(onPick: (l) => setState(() => _level = l));
    return OnboardingScreen(level: level, onBack: () => setState(() => _level = null));
  }
}

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key, required this.onPick});
  final ValueChanged<OnboardingLevel> onPick;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context).state;
    // Имя может подгрузиться уже после показа экрана — следим за состоянием.
    return ListenableBuilder(listenable: state, builder: (context, _) => _content(context, state.displayName));
  }

  Widget _content(BuildContext context, String displayName) {
    final l = context.l10n;
    final fam = context.fam;
    final first = displayName.trim().split(RegExp(r'\s+')).first;
    // displayName при отсутствии имени возвращает email — его в приветствие не берём.
    final name = first.contains('@') ? '' : first;
    return AuthScaffold(children: [
      const Logo(),
      const SizedBox(height: 24),
      Text(
        name.isEmpty ? l.welcomeTitleNoName : l.welcomeTitle(name),
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.headlineSmall,
      ),
      const SizedBox(height: 8),
      Text(l.welcomeLead, textAlign: TextAlign.center, style: TextStyle(color: fam.text2)),
      const SizedBox(height: 24),
      _LevelCard(
        icon: Icons.bolt_outlined,
        title: l.welcomeQuickTitle,
        meta: l.welcomeQuickMeta,
        body: l.welcomeQuickBody,
        onTap: () => onPick(OnboardingLevel.quick),
      ),
      _LevelCard(
        icon: Icons.tune,
        title: l.welcomeFullTitle,
        meta: l.welcomeFullMeta,
        body: l.welcomeFullBody,
        onTap: () => onPick(OnboardingLevel.full),
      ),
      const SizedBox(height: 8),
      Text(l.welcomeFoot, textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: fam.text2)),
    ]);
  }
}

class _LevelCard extends StatelessWidget {
  const _LevelCard({required this.icon, required this.title, required this.meta, required this.body, required this.onTap});
  final IconData icon;
  final String title;
  final String meta;
  final String body;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fam = context.fam;
    return AppCard(
      onTap: onTap,
      child: Row(children: [
        CircleAvatar(
          backgroundColor: context.scheme.primary.withValues(alpha: 0.12),
          child: Icon(icon, color: context.scheme.primary),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            const SizedBox(height: 2),
            Text(meta, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: context.scheme.primary)),
            const SizedBox(height: 4),
            Text(body, style: TextStyle(fontSize: 13, color: fam.text2)),
          ]),
        ),
        const SizedBox(width: 8),
        Icon(Icons.chevron_right, color: fam.text2),
      ]),
    );
  }
}
