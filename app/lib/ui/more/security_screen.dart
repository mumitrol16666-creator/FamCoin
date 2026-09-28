import 'package:flutter/material.dart';

import '../../state/app_scope.dart';
import '../../theme/app_theme.dart';
import '../budget/sheets.dart';
import '../widgets/common.dart';

/// S32 — безопасность: смена пароля, сессии на других устройствах.
class SecurityScreen extends StatefulWidget {
  const SecurityScreen({super.key});

  @override
  State<SecurityScreen> createState() => _SecurityScreenState();
}

class _SecurityScreenState extends State<SecurityScreen> {
  int? _sessions;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loadSessions();
  }

  Future<void> _loadSessions() async {
    final state = AppScope.of(context).state;
    try {
      final n = await state.api.sessionCount(state.token);
      if (mounted) setState(() => _sessions = n);
    } catch (_) {
      // Число сессий — справочное; без сети экран остаётся рабочим.
    }
  }

  Future<void> _changePassword() {
    final l = context.l10n;
    final state = AppScope.of(context).state;
    final current = TextEditingController();
    final next = TextEditingController();
    final repeat = TextEditingController();
    return showFormSheet<void>(
      context,
      title: l.changePassword,
      builder: (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(controller: current, obscureText: true, decoration: InputDecoration(labelText: l.currentPassword, helperText: l.currentPasswordHint, helperMaxLines: 2)),
        const SizedBox(height: 12),
        TextField(controller: next, obscureText: true, decoration: InputDecoration(labelText: l.newPassword, hintText: l.passwordHint)),
        const SizedBox(height: 12),
        TextField(controller: repeat, obscureText: true, decoration: InputDecoration(labelText: l.passwordRepeat)),
        const SizedBox(height: 8),
        Text(l.changePasswordNote, style: TextStyle(fontSize: 12, color: ctx.fam.text2)),
        const SizedBox(height: 20),
        SubmitButton(
          label: l.save,
          onSubmit: () async {
            final messenger = ScaffoldMessenger.of(ctx);
            if (next.text.length < 8) {
              messenger.showSnackBar(SnackBar(content: Text(l.errWeakPassword)));
              return false;
            }
            if (next.text != repeat.text) {
              messenger.showSnackBar(SnackBar(content: Text(l.passwordsDiffer)));
              return false;
            }
            final ok = await runAction(ctx, () => state.changePassword(current.text, next.text));
            if (ok) {
              messenger.showSnackBar(SnackBar(content: Text(l.passwordChanged)));
              _loadSessions();
            }
            return ok;
          },
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final state = AppScope.of(context).state;
    final fam = context.fam;
    return Scaffold(
      appBar: AppBar(title: Text(l.security)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          AppCard(
            onTap: _changePassword,
            child: Row(children: [
              const Icon(Icons.password_outlined),
              const SizedBox(width: 12),
              Expanded(child: Text(l.changePassword)),
              const Icon(Icons.chevron_right),
            ]),
          ),
          AppCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.devices_outlined),
                const SizedBox(width: 12),
                Expanded(child: Text(l.activeSessions)),
                Text(_sessions == null ? '—' : '$_sessions', style: const TextStyle(fontWeight: FontWeight.w700)),
              ]),
              const SizedBox(height: 8),
              Text(l.sessionsNote, style: TextStyle(fontSize: 12, color: fam.text2)),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: (_sessions ?? 0) <= 1
                    ? null
                    : () async {
                        if (!await confirm(context, title: l.logoutOthers, action: l.logoutOthersAction) || !context.mounted) return;
                        await runAction(context, () async {
                          await state.api.logoutOthers(state.token);
                          await _loadSessions();
                        });
                      },
                child: Text(l.logoutOthers),
              ),
            ]),
          ),
          InfoBanner(l.lockPolicy, icon: Icons.lock_clock_outlined),
          InfoBanner(l.pinSoon, icon: Icons.fingerprint, color: fam.warnBg),
        ],
      ),
    );
  }
}
