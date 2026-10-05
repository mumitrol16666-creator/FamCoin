import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../state/app_scope.dart';
import '../../state/app_state.dart';
import '../../state/models.dart';
import '../../theme/app_theme.dart';
import '../widgets/common.dart';
import 'ai_actions.dart';
import 'ai_context.dart';
import 'tariff_screen.dart';

/// Один и тот же чат: полный экран на телефоне, боковая панель на компьютере.
Future<void> showAiAssistant(BuildContext context) async {
  if (MediaQuery.sizeOf(context).width < 900) {
    await Navigator.push<void>(context, MaterialPageRoute(builder: (_) => const AiScreen()));
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (_) => const Dialog(
      alignment: Alignment.centerRight,
      insetPadding: EdgeInsets.zero,
      shape: RoundedRectangleBorder(),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(width: 480, height: double.infinity, child: AiScreen(panel: true)),
    ),
  );
}

/// Суммы в ответе не должны рваться на перенос строки: «15 500 ₸» — одно целое.
String _keepAmounts(String text) => text.replaceAllMapped(RegExp(r'(\d) (?=\d{3}(?!\d)|₸)'), (m) => '${m[1]}\u00A0');

class _Message {
  _Message(this.user, this.text, {this.insufficient = false, this.unverified = const [], this.actions = const [], this.requestId});
  final bool user;
  final String text;
  final bool insufficient;

  /// Кнопки-переходы под ответом (D108).
  final List<String> actions;

  /// Суммы, которые сервер не смог подтвердить данными приложения (D91, D93).
  final List<String> unverified;

  /// Вопрос ещё не получил ответа: id отправки (повтор идёт с ним же) и
  /// текст ошибки, если отправка не удалась.
  final String? requestId;
  String? failed;
}

/// S27 — ИИ-консультант (D82): вопросы по уже посчитанным показателям.
/// Консультант только объясняет; записать или изменить что-либо он не может.
class AiScreen extends StatefulWidget {
  const AiScreen({super.key, this.panel = false});
  final bool panel;

  @override
  State<AiScreen> createState() => _AiScreenState();
}

class _AiScreenState extends State<AiScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _messages = <_Message>[];
  bool _loaded = false;
  bool _available = true;
  bool _busy = false;
  int? _left;
  int? _limit;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded && AppScope.of(context).state.pro) _load();
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _quota(Object? q) {
    if (q is! Map) return;
    _left = (q['left'] as num?)?.toInt();
    _limit = (q['limit'] as num?)?.toInt();
  }

  Future<void> _load() async {
    _loaded = true;
    final state = AppScope.of(context).state;
    try {
      final s = await state.api.aiStatus(state.token);
      if (!mounted) return;
      setState(() {
        _available = s['available'] == true;
        _quota(s['quota']);
        _messages
          ..clear()
          ..addAll([
            for (final m in (s['messages'] as List? ?? const []).cast<Map<String, dynamic>>())
              _Message(m['role'] == 'user', m['text'] as String? ?? '', insufficient: m['insufficientData'] == true, unverified: [...?(m['unverified'] as List?)?.cast<String>()], actions: [...?(m['actions'] as List?)?.whereType<String>()]),
          ]);
      });
      _toEnd();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorText(context.l10n, e))));
    }
  }

  void _toEnd() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });

  Future<void> _ask(String text) async {
    final question = text.trim();
    if (question.isEmpty || _busy) return;
    _input.clear();
    final message = _Message(true, question, requestId: newId());
    setState(() => _messages.add(message));
    await _send(message);
  }

  /// Отправка вопроса; при повторе после ошибки — с тем же id, чтобы уже
  /// полученный сервером вопрос не списал квоту дважды.
  Future<void> _send(_Message message) async {
    final state = AppScope.of(context).state;
    final l = context.l10n;
    setState(() {
      _busy = true;
      message.failed = null;
    });
    _toEnd();
    try {
      final r = await state.api.aiChat(
        state.token,
        question: message.text,
        context: aiChatContext(state, l),
        requestId: message.requestId!,
        locale: Localizations.localeOf(context).languageCode,
      );
      if (!mounted) return;
      setState(() {
        _quota(r['quota']);
        _messages.add(_Message(false, r['answer'] as String? ?? '', insufficient: r['insufficientData'] == true, unverified: [...?(r['unverified'] as List?)?.cast<String>()], actions: [...?(r['actions'] as List?)?.whereType<String>()]));
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => message.failed = errorText(l, e));
    } finally {
      if (mounted) setState(() => _busy = false);
      _toEnd();
    }
  }

  Future<void> _newChat() async {
    final l = context.l10n;
    final state = AppScope.of(context).state;
    if (!await confirm(context, title: l.aiNewChat, message: l.aiNewChatConfirm, action: l.aiNewChat) || !mounted) return;
    final ok = await runAction(context, () => state.api.aiClear(state.token));
    if (ok && mounted) setState(_messages.clear);
  }

  void _showContext() {
    final l = context.l10n;
    final json = const JsonEncoder.withIndent('  ').convert(aiChatContext(AppScope.of(context).state, l));
    showFormSheet<void>(
      context,
      title: l.aiWhatSent,
      builder: (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(l.aiWhatSentNote, style: TextStyle(fontSize: 13, color: ctx.fam.text2)),
        const SizedBox(height: 12),
        SelectableText(json, style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
      ]),
    );
  }

  /// «Разбор: Сентябрь 2026» — всегда про прошлый, уже закончившийся месяц.
  String _reviewTitle() {
    final month = AppScope.of(context).state.monthOf(-1);
    final locale = Localizations.localeOf(context).toString();
    return context.l10n.aiReviewOf('${toBeginningOfSentenceCase(DateFormat.LLLL(locale).format(month))} ${month.year}');
  }

  void _showReview() =>
      showFormSheet<void>(context, title: _reviewTitle(), builder: (_) => _ReviewBody(month: AppScope.of(context).state.monthOf(-1)));

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final fam = context.fam;
    final state = AppScope.of(context).state;

    if (!state.pro) {
      return Scaffold(
        backgroundColor: context.scheme.surface,
        appBar: AppBar(
          backgroundColor: context.scheme.surface,
          leading: widget.panel ? CloseButton(onPressed: () => Navigator.pop(context)) : null,
          title: Text(l.ai),
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            InfoBanner(l.aiProOnly, icon: Icons.auto_awesome_outlined),
            FilledButton(
              onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const TariffScreen())),
              child: Text(l.tariff),
            ),
          ]),
        ),
      );
    }

    final out = _left == 0;
    return Scaffold(
      backgroundColor: context.scheme.surface,
      appBar: AppBar(
        backgroundColor: context.scheme.surface,
        leading: widget.panel ? CloseButton(onPressed: () => Navigator.pop(context)) : null,
        title: Text(l.ai),
        actions: [
          PopupMenuButton<VoidCallback>(
            onSelected: (f) => f(),
            itemBuilder: (_) => [
              PopupMenuItem(value: _showReview, child: Text(_reviewTitle())),
              PopupMenuItem(value: _showContext, child: Text(l.aiWhatSent)),
              if (_messages.isNotEmpty) PopupMenuItem(value: _newChat, child: Text(l.aiNewChat)),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: ListView(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              children: [
                if (!_available) InfoBanner(l.aiUnavailable, color: fam.warnBg),
                if (_messages.isEmpty) ...[
                  Text(l.aiIntro),
                  const SizedBox(height: 8),
                  Text(l.aiDisclosure, style: TextStyle(fontSize: 12, color: fam.text2)),
                  const SizedBox(height: 12),
                  for (final example in [l.aiExample1, l.aiExample2, l.aiExample3])
                    Align(
                      alignment: Alignment.centerLeft,
                      child: ActionChip(label: Text(example), onPressed: _busy || out ? null : () => _ask(example)),
                    ),
                ],
                for (final m in _messages) _bubble(context, m),
                if (_busy) Padding(padding: const EdgeInsets.only(top: 8), child: Text(l.aiThinking, style: TextStyle(color: fam.text2))),
              ],
            ),
          ),
          if (_left != null && _limit != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(out ? l.aiQuotaOut : l.aiQuotaLeft(_left!, _limit!), style: TextStyle(fontSize: 12, color: out ? fam.expense : fam.text2)),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 12),
            child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  enabled: !out && _available,
                  minLines: 1,
                  maxLines: 4,
                  maxLength: 1000,
                  textInputAction: TextInputAction.send,
                  onSubmitted: _ask,
                  decoration: InputDecoration(hintText: l.aiHint, counterText: ''),
                ),
              ),
              IconButton(
                tooltip: l.aiSend,
                onPressed: _busy || out || !_available ? null : () => _ask(_input.text),
                icon: const Icon(Icons.send),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _bubble(BuildContext context, _Message m) {
    final l = context.l10n;
    final fam = context.fam;
    return Align(
      alignment: m.user ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        // На широком экране строка во всю ширину читается плохо — держим ширину письма.
        constraints: BoxConstraints(maxWidth: (MediaQuery.of(context).size.width * 0.82).clamp(0, 560).toDouble()),
        decoration: BoxDecoration(color: m.user ? fam.incomeBg : Theme.of(context).cardColor, borderRadius: BorderRadius.circular(14)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SelectableText(m.user ? m.text : _keepAmounts(m.text)),
          if (m.insufficient) Padding(padding: const EdgeInsets.only(top: 6), child: Text(l.aiInsufficient, style: TextStyle(fontSize: 12, color: fam.warn))),
          if (m.unverified.isNotEmpty)
            Padding(padding: const EdgeInsets.only(top: 6), child: Text(l.aiUnverified(_keepAmounts(m.unverified.join(', '))), style: TextStyle(fontSize: 12, color: fam.warn))),
          if (!m.user && m.actions.isNotEmpty) AiActionChips(m.actions),
          if (m.failed != null) ...[
            Padding(padding: const EdgeInsets.only(top: 6), child: Text(m.failed!, style: TextStyle(fontSize: 12, color: fam.expense))),
            TextButton(onPressed: _busy ? null : () => _send(m), child: Text(l.aiRetry)),
          ],
        ]),
      ),
    );
  }
}

/// S28 — разбор месяца (F084): готовый текст с сервера или кнопка «Составить».
class _ReviewBody extends StatefulWidget {
  const _ReviewBody({required this.month});
  final DateTime month;

  @override
  State<_ReviewBody> createState() => _ReviewBodyState();
}

class _ReviewBodyState extends State<_ReviewBody> {
  String? _text;
  List<String> _unverified = const [];
  String? _error;
  bool _busy = true;
  bool _started = false;

  String get _period => '${widget.month.year}-${widget.month.month.toString().padLeft(2, '0')}';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final state = AppScope.of(context).state;
    _run((_) => state.api.aiReview(state.token, _period));
  }

  Future<void> _run(Future<Map<String, dynamic>?> Function(AppState) call) async {
    final l = context.l10n;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final review = await call(AppScope.of(context).state);
      if (mounted) {
        setState(() {
          _text = review?['text'] as String?;
          _unverified = [...?(review?['unverified'] as List?)?.cast<String>()];
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = errorText(l, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final fam = context.fam;
    final locale = Localizations.localeOf(context).languageCode;
    if (_text != null) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SelectableText(_keepAmounts(_text!)),
        if (_unverified.isNotEmpty)
          Padding(padding: const EdgeInsets.only(top: 8), child: Text(l.aiUnverified(_keepAmounts(_unverified.join(', '))), style: TextStyle(fontSize: 12, color: fam.warn))),
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(l.aiReviewIntro, style: TextStyle(fontSize: 13, color: fam.text2)),
      const SizedBox(height: 4),
      Text(l.aiDisclosure, style: TextStyle(fontSize: 12, color: fam.text2)),
      if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: TextStyle(color: fam.expense))),
      const SizedBox(height: 12),
      FilledButton(
        onPressed: _busy
            ? null
            : () => _run((state) => state.api.aiMakeReview(state.token, period: _period, context: aiReviewContext(state, l, widget.month), locale: locale)),
        child: Text(_busy ? l.aiThinking : l.aiReviewMake),
      ),
    ]);
  }
}
