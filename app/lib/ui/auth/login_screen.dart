import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../state/api_client.dart' show ApiException, apiUrl;
import '../../state/app_scope.dart';
import '../../theme/app_theme.dart';
import '../widgets/common.dart';
import 'auth_widgets.dart';

/// S03 — вход. Основной путь — Telegram (D49): аккаунт создаётся сам при
/// первом входе. Email и пароль — только для аккаунтов, созданных раньше,
/// форма спрятана за ссылкой. Счётчик ошибок и блокировку ведёт сервер.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  late final _email = TextEditingController(text: AppScope.of(context).settings.email ?? '');
  final _password = TextEditingController();
  Timer? _timer;
  bool _busy = false;
  bool _showEmail = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && AppScope.of(context).settings.lockUntil != null) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    final l = context.l10n;
    final settings = AppScope.of(context).settings;
    final email = _email.text.trim();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await settings.api.login(email, _password.text);
      await settings.signedInWith(r);
    } on ApiException catch (e) {
      if (e.code == 'locked' && e.retryAfterSeconds != null) {
        await settings.rememberLock(e.retryAfterSeconds!);
      } else {
        _error = errorText(l, e);
      }
    } finally {
      _password.clear();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final settings = AppScope.of(context).settings;
    final lockUntil = settings.lockUntil;
    final locked = lockUntil != null;
    final fam = context.fam;

    return AuthScaffold(children: [
      const Logo(),
      const SizedBox(height: 8),
      Center(child: Text(l.tagline, textAlign: TextAlign.center, style: TextStyle(color: fam.text2))),
      const SizedBox(height: 28),
      const TelegramButton(primary: true),
      const SizedBox(height: 8),
      Center(child: Text(l.tgPrimaryHint, textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: fam.text2))),
      const SizedBox(height: 20),
      TextButton(
        onPressed: () => setState(() => _showEmail = !_showEmail),
        child: Text(l.emailLoginToggle, style: TextStyle(color: fam.text2)),
      ),
      if (_showEmail) ...[
        if (locked) _LockBanner(until: lockUntil),
        if (!locked && _error != null) AuthMessage(_error!),
        FieldLabel(l.email),
        TextField(
          controller: _email,
          enabled: !locked && !_busy,
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
          autofillHints: const [AutofillHints.email],
          textInputAction: TextInputAction.next,
        ),
        FieldLabel(l.password),
        TextField(
          controller: _password,
          enabled: !locked && !_busy,
          obscureText: true,
          autofillHints: const [AutofillHints.password],
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: 16),
        OutlinedButton(
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
          onPressed: locked || _busy ? null : _submit,
          child: _busy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : Text(l.signIn),
        ),
        const SizedBox(height: 4),
        Center(child: Text(l.forgotViaTelegram, textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: fam.text2))),
      ],
      // Установщик для Android лежит рядом с API: <origin>/download/famcoin.apk.
      if (kIsWeb && apiUrl.startsWith('https://')) ...[
        const SizedBox(height: 16),
        TextButton.icon(
          icon: const Icon(Icons.android, size: 18),
          label: Text(l.downloadAndroid),
          onPressed: () => launchUrl(Uri.parse('${apiUrl.replaceFirst(RegExp(r'/api$'), '')}/download/famcoin.apk'), mode: LaunchMode.externalApplication),
        ),
      ],
    ]);
  }
}

class _LockBanner extends StatelessWidget {
  const _LockBanner({required this.until});
  final DateTime until;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final left = until.difference(DateTime.now());
    final mm = left.inMinutes.toString().padLeft(2, '0');
    final ss = (left.inSeconds % 60).toString().padLeft(2, '0');
    return Container(
      padding: const EdgeInsets.all(14),
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(color: context.fam.expenseBg, borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.lock_outline, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(l.locked, style: const TextStyle(fontWeight: FontWeight.w700))),
        ]),
        const SizedBox(height: 4),
        Text(l.lockedHint, style: const TextStyle(fontSize: 12)),
        const SizedBox(height: 8),
        Text('$mm:$ss', style: Theme.of(context).textTheme.headlineSmall),
      ]),
    );
  }
}
