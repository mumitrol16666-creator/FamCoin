import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../state/app_scope.dart';
import '../../theme/app_theme.dart';
import '../widgets/common.dart';

const pinLength = 4;

/// Клавиатура PIN-кода с точками. Цифры вводятся кнопками или с клавиатуры.
class PinPad extends StatefulWidget {
  const PinPad({super.key, required this.title, this.subtitle, this.error, required this.onComplete, this.footer});

  final String title;
  final String? subtitle;

  /// Текст ошибки под точками; при изменении ввод очищается.
  final String? error;
  final Future<void> Function(String pin) onComplete;
  final Widget? footer;

  @override
  State<PinPad> createState() => _PinPadState();
}

class _PinPadState extends State<PinPad> {
  String _pin = '';
  bool _busy = false;
  final _focus = FocusNode();

  @override
  void didUpdateWidget(covariant PinPad old) {
    super.didUpdateWidget(old);
    if (old.error != widget.error || old.title != widget.title) _pin = '';
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  Future<void> _add(String d) async {
    if (_busy || _pin.length >= pinLength) return;
    setState(() => _pin += d);
    if (_pin.length == pinLength) {
      setState(() => _busy = true);
      await widget.onComplete(_pin);
      if (mounted) setState(() { _busy = false; _pin = ''; });
    }
  }

  void _back() {
    if (_pin.isEmpty || _busy) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  @override
  Widget build(BuildContext context) {
    final fam = context.fam;
    final scheme = context.scheme;
    Widget key(String label, {IconData? icon, VoidCallback? onTap, String? semantics}) => Semantics(
          button: true,
          label: semantics ?? label,
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: onTap,
            child: SizedBox(
              width: 72,
              height: 72,
              child: Center(
                child: icon != null ? Icon(icon, size: 26) : Text(label, style: Theme.of(context).textTheme.headlineSmall),
              ),
            ),
          ),
        );

    return KeyboardListener(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: (e) {
        if (e is! KeyDownEvent) return;
        final ch = e.character;
        if (ch != null && RegExp(r'^[0-9]$').hasMatch(ch)) _add(ch);
        if (e.logicalKey == LogicalKeyboardKey.backspace) _back();
      },
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(widget.title, style: Theme.of(context).textTheme.headlineSmall, textAlign: TextAlign.center),
        if (widget.subtitle != null) ...[
          const SizedBox(height: 6),
          Text(widget.subtitle!, textAlign: TextAlign.center, style: TextStyle(color: fam.text2, fontSize: 13)),
        ],
        const SizedBox(height: 24),
        Semantics(
          label: '${_pin.length} / $pinLength',
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            for (var i = 0; i < pinLength; i++)
              AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                margin: const EdgeInsets.symmetric(horizontal: 8),
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i < _pin.length ? scheme.primary : null,
                  border: Border.all(color: widget.error != null ? fam.expense : scheme.primary, width: 2),
                ),
              ),
          ]),
        ),
        SizedBox(
          height: 32,
          child: Center(
            child: widget.error == null ? null : Text(widget.error!, style: TextStyle(color: fam.expense, fontSize: 13), textAlign: TextAlign.center),
          ),
        ),
        for (final row in const [['1', '2', '3'], ['4', '5', '6'], ['7', '8', '9']])
          Row(mainAxisSize: MainAxisSize.min, children: [for (final d in row) key(d, onTap: () => _add(d))]),
        Row(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(width: 72, height: 72),
          key('0', onTap: () => _add('0')),
          key('⌫', icon: Icons.backspace_outlined, onTap: _back, semantics: MaterialLocalizations.of(context).deleteButtonTooltip),
        ]),
        if (widget.footer != null) ...[const SizedBox(height: 16), widget.footer!],
      ]),
    );
  }
}

/// Экран блокировки: показывается вместо приложения, пока PIN не введён.
class PinLockScreen extends StatefulWidget {
  const PinLockScreen({super.key});

  @override
  State<PinLockScreen> createState() => _PinLockScreenState();
}

class _PinLockScreenState extends State<PinLockScreen> {
  String? _error;
  int _wrong = 0;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final settings = AppScope.of(context).settings;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: PinPad(
              title: l.pinEnter,
              error: _error,
              onComplete: (pin) async {
                if (settings.unlock(pin)) return;
                _wrong++;
                // Перебор бессмыслен: после трёх ошибок — пауза.
                if (_wrong >= 3) await Future<void>.delayed(const Duration(seconds: 2));
                if (mounted) setState(() => _error = '${l.pinWrong}${_wrong > 1 ? ' ($_wrong)' : ''}');
              },
              footer: Column(children: [
                Text(l.pinForgot, textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: context.fam.text2)),
                TextButton(
                  onPressed: () async {
                    if (!await confirm(context, title: l.signOut, action: l.signOut)) return;
                    await settings.signOut();
                  },
                  child: Text(l.signOut),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Создание PIN-кода: ввести дважды. Возвращает `true`, если код сохранён.
class PinSetupScreen extends StatefulWidget {
  const PinSetupScreen({super.key});

  @override
  State<PinSetupScreen> createState() => _PinSetupScreenState();
}

class _PinSetupScreenState extends State<PinSetupScreen> {
  String? _first;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final settings = AppScope.of(context).settings;
    return Scaffold(
      appBar: AppBar(title: Text(l.pinTitle)),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: PinPad(
              title: _first == null ? l.pinCreate : l.pinRepeat,
              subtitle: l.pinNote,
              error: _error,
              onComplete: (pin) async {
                if (_first == null) {
                  setState(() {
                    _first = pin;
                    _error = null;
                  });
                  return;
                }
                if (pin != _first) {
                  setState(() {
                    _first = null;
                    _error = l.pinMismatch;
                  });
                  return;
                }
                await settings.setPin(pin);
                if (!context.mounted) return;
                Navigator.pop(context, true);
              },
            ),
          ),
        ),
      ),
    );
  }
}
