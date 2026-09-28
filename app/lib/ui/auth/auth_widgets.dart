import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../state/api_client.dart';
import '../../state/app_scope.dart';
import '../../theme/app_theme.dart';
import '../widgets/common.dart';

/// Кнопка «Войти через Telegram» (D49): одна и та же на входе и регистрации —
/// аккаунт создаётся сам, если чата ещё нет.
class TelegramButton extends StatelessWidget {
  const TelegramButton({super.key, this.enabled = true, this.primary = false});
  final bool enabled;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final onPressed = enabled ? () => telegramSignIn(context) : null;
    final icon = const Icon(Icons.send_outlined, size: 18);
    final label = Text(l.tgSignIn);
    if (primary) return FilledButton.icon(icon: icon, label: label, onPressed: onPressed);
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
      icon: icon,
      label: label,
      onPressed: onPressed,
    );
  }
}

/// Открывает бота со ссылкой-кодом и ждёт подтверждения, опрашивая сервер.
Future<void> telegramSignIn(BuildContext context) async {
  final l = context.l10n;
  final settings = AppScope.of(context).settings;
  final messenger = ScaffoldMessenger.of(context);
  final (String code, String url) = await () async {
    try {
      return await settings.api.telegramStart();
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.code == 'telegram_unavailable' ? l.tgUnavailable : errorText(l, e))));
      return ('', '');
    }
  }();
  if (code.isEmpty || !context.mounted) return;
  final uri = Uri.parse(url);
  await launchUrl(uri, mode: LaunchMode.externalApplication);
  if (!context.mounted) return;

  AuthResult? result;
  String? failure;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) {
      Timer? timer;
      var ticks = 0;
      return StatefulBuilder(builder: (ctx, set) {
        timer ??= Timer.periodic(const Duration(seconds: 2), (t) async {
          if (++ticks > 150) {
            failure = l.tgExpired;
            t.cancel();
            if (ctx.mounted) Navigator.pop(ctx);
            return;
          }
          try {
            final r = await settings.api.telegramCheck(code, settings.locale.languageCode);
            if (r != null) {
              result = r;
              t.cancel();
              if (ctx.mounted) Navigator.pop(ctx);
            }
          } on ApiException catch (e) {
            if (e.isNetwork) return;
            failure = e.code == 'code_expired' ? l.tgExpired : errorText(l, e);
            t.cancel();
            if (ctx.mounted) Navigator.pop(ctx);
          }
        });
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (_, __) => timer?.cancel(),
          child: AlertDialog(
            title: Text(l.tgSignIn),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              const SizedBox(height: 4),
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(l.tgWaiting, textAlign: TextAlign.center),
            ]),
            actions: [
              TextButton(onPressed: () => launchUrl(uri, mode: LaunchMode.externalApplication), child: Text(l.tgOpenAgain)),
              TextButton(
                onPressed: () {
                  timer?.cancel();
                  Navigator.pop(ctx);
                },
                child: Text(l.cancel),
              ),
            ],
          ),
        );
      });
    },
  );
  if (!context.mounted) return;
  if (result != null) {
    await settings.signedInWith(result!);
    if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  } else if (failure != null) {
    messenger.showSnackBar(SnackBar(content: Text(failure!)));
  }
}

class Logo extends StatelessWidget {
  const Logo({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: RichText(
        text: TextSpan(
          style: Theme.of(context).textTheme.displayMedium,
          children: [
            const TextSpan(text: 'Fam'),
            TextSpan(text: 'Coin', style: TextStyle(color: context.scheme.primary)),
          ],
        ),
      ),
    );
  }
}

class FieldLabel extends StatelessWidget {
  const FieldLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 4, top: 12),
        child: Text(text, style: TextStyle(fontSize: 12, color: context.fam.text2)),
      );
}

class AuthScaffold extends StatelessWidget {
  const AuthScaffold({super.key, required this.children, this.title});
  final List<Widget> children;
  final String? title;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: title == null ? null : AppBar(title: Text(title!)),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
            ),
          ),
        ),
      ),
    );
  }
}

/// Плашка ошибки над формой.
class AuthMessage extends StatelessWidget {
  const AuthMessage(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: context.fam.warnBg, borderRadius: BorderRadius.circular(14)),
      child: Row(children: [
        const Icon(Icons.warning_amber_outlined, size: 18),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
      ]),
    );
  }
}
