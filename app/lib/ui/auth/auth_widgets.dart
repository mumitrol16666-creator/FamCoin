import 'dart:async';

import 'package:flutter/foundation.dart';
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
///
/// Ожидание не должно зависеть от того, выжило ли приложение в фоне (D77):
/// на Android оно усыпляется или выгружается, пока человек в Telegram. Поэтому
/// код запоминается на устройстве, окно ожидания рисуется до перехода в
/// Telegram, а проверка идёт сразу при возврате в приложение. [resume] —
/// продолжить вход, начатый до перезапуска приложения (без нового кода).
Future<void> telegramSignIn(BuildContext context, {bool resume = false}) async {
  final l = context.l10n;
  final settings = AppScope.of(context).settings;
  final messenger = ScaffoldMessenger.of(context);
  var pending = resume ? settings.pendingTelegramLogin : null;
  if (resume && pending == null) return;
  if (pending == null) {
    try {
      final (code, url) = await settings.api.telegramStart();
      await settings.setPendingTelegramLogin(code, url);
      pending = (code: code, url: url);
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.code == 'telegram_unavailable' ? l.tgUnavailable : errorText(l, e))));
      return;
    }
  }
  if (!context.mounted) return;
  final login = pending;
  // В браузере Telegram открывается сразу, как и раньше: новую вкладку
  // браузеры разрешают только вплотную к нажатию, а вкладка сайта в фоне не
  // засыпает. В приложении — после того, как окно ожидания нарисовано.
  if (!resume && kIsWeb) {
    try {
      await launchUrl(Uri.parse(login.url), mode: LaunchMode.externalApplication);
    } catch (_) {}
    if (!context.mounted) return;
  }
  final outcome = await showDialog<_TgOutcome>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _TelegramWaitDialog(code: login.code, url: Uri.parse(login.url), openTelegram: !resume && !kIsWeb),
  );
  // Окно закрылось — вход состоялся, отменён или код устарел: хранить его незачем.
  await settings.clearPendingTelegramLogin();
  if (!context.mounted) return;
  final result = outcome?.result;
  final failure = outcome?.failure;
  if (result != null) {
    await settings.signedInWith(result);
    if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  } else if (failure != null) {
    messenger.showSnackBar(SnackBar(content: Text(failure)));
  }
}

/// Чем закончилось ожидание: вход, отказ с текстом или отмена.
class _TgOutcome {
  const _TgOutcome.ok(AuthResult this.result) : failure = null;
  const _TgOutcome.failed(String this.failure) : result = null;
  const _TgOutcome.cancelled()
      : result = null,
        failure = null;
  final AuthResult? result;
  final String? failure;
}

/// Окно «ждём подтверждения в Telegram»: опрос раз в 2 секунды и сразу при
/// возврате в приложение.
class _TelegramWaitDialog extends StatefulWidget {
  const _TelegramWaitDialog({required this.code, required this.url, required this.openTelegram});
  final String code;
  final Uri url;

  /// Открыть Telegram, как только окно нарисовано (при продолжении — не нужно).
  final bool openTelegram;

  @override
  State<_TelegramWaitDialog> createState() => _TelegramWaitDialogState();
}

class _TelegramWaitDialogState extends State<_TelegramWaitDialog> with WidgetsBindingObserver {
  Timer? _timer;
  bool _checking = false;
  bool _done = false;
  final _deadline = DateTime.now().add(const Duration(minutes: 10));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _check());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.openTelegram) {
        _open(); // окно уже на экране — к возврату из Telegram оно будет ждать
      } else {
        _check(); // продолжение после перезапуска: код мог быть уже подтверждён
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  /// Вернулись из Telegram — проверяем сразу: в фоне таймер мог стоять, а
  /// запросы — не доходить до сервера.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _open() async {
    try {
      await launchUrl(widget.url, mode: LaunchMode.externalApplication);
    } catch (_) {
      // Telegram не открылся — в окне есть кнопка «Открыть Telegram».
    }
  }

  Future<void> _check() async {
    if (_checking || _done || !mounted) return;
    final l = context.l10n;
    final settings = AppScope.of(context).settings;
    if (DateTime.now().isAfter(_deadline)) {
      _finish(_TgOutcome.failed(l.tgExpired));
      return;
    }
    _checking = true;
    try {
      final r = await settings.api.telegramCheck(widget.code, settings.locale.languageCode);
      if (r != null) _finish(_TgOutcome.ok(r));
    } on ApiException catch (e) {
      // Нет связи — не повод сдаваться: следующая проверка через 2 секунды.
      if (!e.isNetwork) _finish(_TgOutcome.failed(e.code == 'code_expired' ? l.tgExpired : errorText(l, e)));
    } finally {
      _checking = false;
    }
  }

  void _finish(_TgOutcome outcome) {
    if (_done) return;
    _done = true;
    _timer?.cancel();
    if (mounted) Navigator.pop(context, outcome);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(l.tgSignIn),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 4),
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(l.tgWaiting, textAlign: TextAlign.center),
        ]),
        actions: [
          TextButton(onPressed: _open, child: Text(l.tgOpenAgain)),
          TextButton(onPressed: () => _finish(const _TgOutcome.cancelled()), child: Text(l.cancel)),
        ],
      ),
    );
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
