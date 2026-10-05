import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../../state/app_scope.dart';
import '../../theme/app_theme.dart';
import '../budget/sheets.dart';
import '../widgets/common.dart';
import 'add_transaction_sheet.dart';

/// S38 — голосовой ввод. Речь распознаёт устройство (бесплатно, без ИИ),
/// фразу разбирает ядро в черновик. Черновик — те же поля, что и в ручной
/// форме, сразу редактируемые; ничего не записывается до «Сохранить».
Future<void> showVoiceSheet(BuildContext context) {
  final state = AppScope.of(context).state;
  if (state.activeAccounts.isEmpty) return addAccountFlow(context);
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => const _VoiceSheet(),
  );
}

class _VoiceSheet extends StatefulWidget {
  const _VoiceSheet();

  @override
  State<_VoiceSheet> createState() => _VoiceSheetState();
}

class _VoiceSheetState extends State<_VoiceSheet> {
  final _stt = stt.SpeechToText();
  bool _ready = false;
  bool _listening = false;
  String? _localeId;

  /// Нужен казахский, но устройство умеет только русский.
  bool _kkFallback = false;
  String _text = '';
  String? _error;
  VoiceDraft? _draft;

  /// Растёт с каждым новым черновиком — новый `key` пересоздаёт
  /// [TransactionFields], чтобы поля заполнились заново, а не остались
  /// от предыдущей попытки.
  int _draftVersion = 0;
  final _manual = TextEditingController();

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final ok = await _stt.initialize(
        onStatus: (s) {
          if (!mounted) return;
          if (s == 'done' || s == 'notListening') setState(() => _listening = false);
        },
        onError: (e) {
          if (!mounted) return;
          setState(() {
            _listening = false;
            if (_unsupported(e.errorMsg)) {
              _ready = false;
            } else {
              _error = e.errorMsg;
            }
          });
        },
      );
      if (!mounted) return;
      if (ok) {
        // Казахский распознаёт не каждое устройство: тогда слушаем по-русски.
        final want = Localizations.localeOf(context).languageCode == 'kk' ? 'kk' : 'ru';
        final locales = await _stt.locales();
        final match = locales.where((l) => l.localeId.toLowerCase().startsWith(want)).firstOrNull ??
            locales.where((l) => l.localeId.toLowerCase().startsWith('ru')).firstOrNull;
        // Браузер список не отдаёт — иначе он слушал бы на языке системы.
        _localeId = match?.localeId ?? (locales.isEmpty ? (want == 'kk' ? 'kk-KZ' : 'ru-RU') : null);
        // Честно сказать, что казахского распознавания здесь нет.
        _kkFallback = want == 'kk' && locales.isNotEmpty && !(match?.localeId.toLowerCase().startsWith('kk') ?? false);
      }
      setState(() => _ready = ok);
    } catch (_) {
      if (mounted) setState(() => _ready = false);
    }
  }

  /// Коды ошибок плагина: браузер/устройство без распознавания.
  static bool _unsupported(String code) =>
      code.contains('not supported') || code.contains('not_supported') || code.contains('recognizerNotAvailable');

  /// Причина — пользователю словами, а не кодом плагина.
  String _errorText(String code) {
    final l = context.l10n;
    final c = code.toLowerCase();
    if (c.contains('not-allowed') || c.contains('permission') || c.contains('audio')) return l.voiceDenied;
    if (c.contains('network')) return l.voiceNetwork;
    return l.voiceError;
  }

  @override
  void dispose() {
    _stt.stop();
    _manual.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_listening) {
      await _stt.stop();
      setState(() => _listening = false);
      return;
    }
    setState(() {
      _error = null;
      _draft = null;
      _text = '';
      _listening = true;
    });
    await _stt.listen(
      listenOptions: stt.SpeechListenOptions(
        localeId: _localeId,
        partialResults: true,
        cancelOnError: true,
        listenMode: stt.ListenMode.dictation,
        pauseFor: const Duration(seconds: 3),
        listenFor: const Duration(seconds: 30),
      ),
      onResult: (r) {
        if (!mounted) return;
        setState(() {
          _text = r.recognizedWords;
          if (r.finalResult) {
            _listening = false;
            _parse(_text);
          }
        });
      },
    );
  }

  void _parse(String phrase) {
    final state = AppScope.of(context).state;
    final l = context.l10n;
    final accounts = [
      for (final a in state.activeAccounts)
        VoiceAccount(a.id, [a.name, ...a.name.split(RegExp(r'\s+')), if (a.type == 'cash') l.typeCash, if (a.type == 'deposit') l.typeDeposit], isCash: a.type == 'cash'),
    ];
    setState(() {
      _draft = parseVoice(phrase, accounts: accounts, people: state.knownPeople);
      _draftVersion++;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final fam = context.fam;
    final d = _draft;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(l.voiceTitle, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text(l.voiceSubtitle, style: TextStyle(color: fam.text2, fontSize: 13)),
          const SizedBox(height: 16),

          // Микрофон
          Center(
            child: Semantics(
              button: true,
              enabled: _ready,
              label: _listening ? l.tipMicStop : l.tipMic,
              child: GestureDetector(
              onTap: _ready ? _toggle : null,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: !_ready ? context.scheme.surfaceContainerHighest : _listening ? fam.expense : context.scheme.primary,
                  boxShadow: _listening ? [BoxShadow(color: fam.expense.withValues(alpha: .35), blurRadius: 24, spreadRadius: 6)] : null,
                ),
                child: Icon(_listening ? Icons.stop : Icons.mic, size: 40, color: _ready ? context.scheme.onPrimary : fam.text2),
              ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Center(child: Text(!_ready ? l.voiceUnavailable : _listening ? l.voiceListening : l.voiceTapToSpeak, style: TextStyle(color: fam.text2, fontSize: 13))),
          if (_ready && _kkFallback) Padding(padding: const EdgeInsets.only(top: 8), child: InfoBanner(l.voiceKkFallback, icon: Icons.translate)),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: InfoBanner(_errorText(_error!), color: fam.warnBg, icon: Icons.mic_off)),

          // Распознанный текст
          if (_text.isNotEmpty) ...[
            const SizedBox(height: 14),
            Row(children: [
              Expanded(child: AppCard(child: Text('«$_text»', style: const TextStyle(fontSize: 17)))),
              if (d != null && _ready) ...[
                const SizedBox(width: 8),
                IconButton.filledTonal(tooltip: l.voiceAgain, onPressed: _toggle, icon: const Icon(Icons.replay)),
              ],
            ]),
          ],

          // Черновик — сразу редактируемые поля обычной формы; ничего не
          // сохраняется, пока не нажата «Сохранить» внизу.
          if (d != null) TransactionFields(key: ValueKey(_draftVersion), draft: d, showVoiceChip: false),

          // Подсказки
          if (d == null) ...[
            const SizedBox(height: 16),
            Text(l.voiceHintsTitle, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            for (final h in [l.voiceHint1, l.voiceHint2, l.voiceHint3, l.voiceHint4, l.voiceHint5, l.voiceHint6])
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(Icons.format_quote, size: 16, color: fam.text2),
                  const SizedBox(width: 8),
                  Expanded(child: Text(h, style: const TextStyle(fontSize: 13))),
                ]),
              ),
            const SizedBox(height: 6),
            Text(l.voiceHintNote, style: TextStyle(fontSize: 12, color: fam.text2)),
            const SizedBox(height: 16),
            // Без микрофона фразу можно набрать — разбор тот же.
            TextField(
              controller: _manual,
              decoration: InputDecoration(labelText: l.voiceTypeInstead, suffixIcon: IconButton(tooltip: l.tipParse, icon: const Icon(Icons.arrow_forward), onPressed: () {
                if (_manual.text.trim().isEmpty) return;
                setState(() => _text = _manual.text.trim());
                _parse(_text);
              })),
              onSubmitted: (v) {
                if (v.trim().isEmpty) return;
                setState(() => _text = v.trim());
                _parse(_text);
              },
            ),
          ],
        ]),
      ),
    );
  }
}
