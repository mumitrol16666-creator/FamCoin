/// Ввод операций и запросы из чата Telegram (D79, D85, D89).
///
/// Человек пишет боту «кофе 1500», «перевёл 20000 с каспи на наличные» или
/// «дал в долг Асхату 5000» — фразу разбирает то же ядро, что и голосовой
/// ввод в приложении (`parseVoice`), бот показывает черновик с кнопками. В
/// журнал операция попадает только после «Записать» — обычной командой через
/// [LedgerService], как из приложения; отдельного пути записи у бота нет.
/// Записанное можно отменить кнопкой — это та же отмена, что удаление
/// операции в приложении (её видно в корзине).
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:famcoin_core/famcoin_core.dart';
import 'package:postgres/postgres.dart';

import 'auth_service.dart';
import 'briefs.dart';
import 'ledger_service.dart';
import 'notifications.dart';
import 'speech.dart';
import 'statement_import.dart';
import 'telegram.dart';

/// Длиннее фразы об одной трате не бывают; остальное — не ввод операции.
const maxPhraseLength = 300;
const maxNoteLength = 200;

/// Голосовое о трате — несколько секунд; длинные записи не распознаём.
const maxVoiceSeconds = 60;

/// Распознаваний на человека в сутки: расход на ИИ не должен зависеть от
/// одного увлёкшегося пользователя.
const maxVoicePerDay = 30;

// ------------------------------------------------------------ справочники

/// Встроенные категории: id → название (ru, kk) — как в приложении.
const _categoryNames = <String, (String, String)>{
  'food': ('Продукты', 'Азық-түлік'),
  'cafe': ('Кафе', 'Кафе'),
  'transport': ('Транспорт', 'Көлік'),
  'health': ('Здоровье', 'Денсаулық'),
  'kids': ('Дети', 'Балалар'),
  'home': ('Жильё', 'Тұрғын үй'),
  'utilities': ('Коммунальные', 'Коммуналдық'),
  'phone': ('Связь', 'Байланыс'),
  'household': ('Бытовые покупки', 'Тұрмыстық заттар'),
  'fun': ('Развлечения', 'Ойын-сауық'),
  'clothes': ('Одежда', 'Киім'),
  'education': ('Образование', 'Білім'),
  'subscriptions': ('Подписки', 'Жазылымдар'),
  'gifts': ('Подарки', 'Сыйлықтар'),
  'fees': ('Комиссии', 'Комиссиялар'),
  'interest': ('Проценты', 'Пайыз'),
  // Строка отчётов, не категория записи (D98).
  'debts': ('Кредиты и долги', 'Несиелер мен қарыздар'),
  'other': ('Прочее', 'Басқа'),
  'salary': ('Зарплата', 'Жалақы'),
  'side': ('Подработка', 'Қосымша табыс'),
  'cashback': ('Кешбэк', 'Кешбэк'),
  'interestIncome': ('Проценты', 'Пайыз'),
  'otherIncome': ('Прочий доход', 'Басқа кіріс'),
};

const _expenseIds = ['food', 'cafe', 'transport', 'health', 'kids', 'home', 'utilities', 'phone', 'household', 'fun', 'clothes', 'education', 'subscriptions', 'gifts'];
const _incomeIds = ['salary', 'side', 'cashback', 'interestIncome', 'otherIncome'];

/// Название категории: встроенной — на языке владельца, своей — как он её назвал.
String categoryName(String id, LedgerView v) => chatCategoryName(id, v.locale, v.of('category'));

/// То же без [LedgerView]: [custom] — свои категории владельца (id → данные).
String chatCategoryName(String id, String locale, Map<String, Map<String, dynamic>> custom) {
  final builtin = _categoryNames[id];
  if (builtin != null) return locale == 'kk' ? builtin.$2 : builtin.$1;
  return custom[id]?['name'] as String? ?? id;
}

/// Категории для выбора кнопкой — тот же набор, что в форме приложения:
/// встроенные без скрытых, свои, «Прочее» в конце.
List<String> chatCategories(LedgerView v, {required bool income}) {
  final hidden = {...((v.profile['hiddenCategories'] as List?) ?? const [])};
  return [
    ...(income ? _incomeIds : _expenseIds).where((c) => !hidden.contains(c)),
    for (final e in v.of('category').entries)
      if ((e.value['income'] == true) == income) e.key,
    if (!income) 'other',
  ];
}

class ChatAccount {
  const ChatAccount(this.id, this.name, this.type, this.liquid, this.owner);
  final String id;
  final String name;
  final String type;
  final bool liquid;
  final String? owner;
}

/// Счета для трат — без архивных и без копилок целей.
List<ChatAccount> chatAccounts(LedgerView v) {
  final meta = v.of('account');
  return [
    for (final a in v.ledger.accounts)
      if (a.isMoney && !a.archived && meta[a.id]?['type'] != 'piggy')
        ChatAccount(a.id, meta[a.id]?['name'] as String? ?? a.id, meta[a.id]?['type'] as String? ?? 'card', a.liquid, meta[a.id]?['owner'] as String?),
  ];
}

/// Люди, с которыми есть личные долги, — чтобы имя узнавалось во фразе в
/// любой форме («Асхат вернул», «вернул Асхату»). Банковские долги — не люди.
List<String> chatPeople(LedgerView v) {
  final banks = v.of('debt').keys.toSet();
  return {
    for (final a in v.ledger.accounts)
      if ((a.assetClass == AssetClass.receivable || a.kind == LedgerKind.liability) && v.ledger.balance(a.id) != 0) a.id.substring(a.id.indexOf(':') + 1),
  }.where((name) => !banks.contains(name)).toList();
}

// --------------------------------------------------------------- черновик

const _debtKinds = {'lendOut', 'borrow', 'repaymentReceived', 'repaymentMade'};

class ChatDraft {
  const ChatDraft({
    required this.kind,
    required this.amount,
    this.category = '',
    required this.account,
    this.toAccount,
    this.person,
    required this.note,
    required this.date,
    required this.time,
    required this.who,
    required this.txId,
    required this.undoId,
    this.heard = '',
  });

  factory ChatDraft.fromJson(Map<String, dynamic> j) => ChatDraft(
        // Черновики до D89 знали только расход и доход (поле `income`).
        kind: j['kind'] as String? ?? (j['income'] == true ? 'income' : 'expense'),
        amount: parseMinor(j['amount']),
        category: j['category'] as String? ?? '',
        account: j['account'] as String,
        toAccount: j['toAccount'] as String?,
        person: j['person'] as String?,
        note: j['note'] as String? ?? '',
        date: j['date'] as String,
        time: j['time'] as String,
        who: j['who'] as String? ?? 'me',
        txId: j['txId'] as String,
        undoId: j['undoId'] as String,
        heard: j['heard'] as String? ?? '',
      );

  /// Вид операции — то же слово, что тип команды журнала: `expense`, `income`,
  /// `transfer`, `lendOut`, `borrow`, `repaymentReceived`, `repaymentMade`.
  final String kind;

  /// В тиынах.
  final int amount;

  /// Категория расхода или источник дохода; у переводов и долгов — пусто.
  final String category;

  /// Счёт операции; у перевода — откуда.
  final String account;

  /// У перевода — куда.
  final String? toAccount;

  /// У долга — с кем.
  final String? person;
  final String note;

  /// День операции `ГГГГ-ММ-ДД` и время `ЧЧ:ММ` по времени Казахстана.
  final String date;
  final String time;
  final String who;

  /// Выданы заранее: повтор нажатия отправляет ту же операцию, а не новую.
  final String txId;
  final String undoId;

  /// Что распознано из голосового сообщения — человек видит, что услышал бот.
  final String heard;

  bool get income => kind == 'income';
  bool get transfer => kind == 'transfer';
  bool get debt => _debtKinds.contains(kind);

  /// Деньги уходят со счёта [account] — после записи он может уйти в минус.
  bool get outflow => kind == 'expense' || kind == 'transfer' || kind == 'lendOut' || kind == 'repaymentMade';

  ChatDraft copyWith({String? kind, String? category, String? account, String? toAccount, String? who, String? heard}) => ChatDraft(
        kind: kind ?? this.kind,
        amount: amount,
        category: category ?? this.category,
        account: account ?? this.account,
        toAccount: toAccount ?? this.toAccount,
        person: person,
        note: note,
        date: date,
        time: time,
        who: who ?? this.who,
        txId: txId,
        undoId: undoId,
        heard: heard ?? this.heard,
      );

  Map<String, Object?> toJson() => {
        'kind': kind,
        'amount': amount.toString(),
        'category': category,
        'account': account,
        if (toAccount != null) 'toAccount': toAccount,
        if (person != null) 'person': person,
        'note': note,
        'date': date,
        'time': time,
        'who': who,
        'txId': txId,
        'undoId': undoId,
        if (heard.isNotEmpty) 'heard': heard,
      };

  /// Команда журнала — в том же виде, в каком её отправляет форма приложения.
  Map<String, dynamic> command() => switch (kind) {
        'income' => {
            'type': 'income',
            'id': txId,
            'date': date,
            'account': account,
            'source': category,
            'amount': amount.toString(),
            'meta': {if (note.isNotEmpty) 'note': note, 'time': time},
          },
        'transfer' => {
            'type': 'transfer',
            'id': txId,
            'date': date,
            'from': account,
            'to': toAccount,
            'amount': amount.toString(),
            'meta': {'time': time},
          },
        'lendOut' || 'borrow' || 'repaymentReceived' || 'repaymentMade' => {
            'type': kind,
            'id': txId,
            'date': date,
            'account': account,
            'person': person,
            // У возврата долга сумма — это тело долга; проценты из чата не пишутся.
            (kind.startsWith('repayment') ? 'principal' : 'amount'): amount.toString(),
            'meta': {'time': time},
          },
        _ => {
            'type': 'expense',
            'id': txId,
            'date': date,
            'account': account,
            'splits': {category: amount.toString()},
            'meta': {'who': who, if (note.isNotEmpty) 'note': note, 'time': time},
          },
      };
}

/// Почему из сообщения не получился черновик.
enum DraftProblem { noAccount, noAmount, noPerson, needSecondAccount }

String newChatId([int bytes = 16]) {
  final r = Random.secure();
  return List.generate(bytes, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

String _two(int n) => n.toString().padLeft(2, '0');

/// «Для кого» по счёту — как в форме приложения; вне семейного режима всегда «я».
String _whoFor(LedgerView v, ChatAccount a) => v.profile['mode'] == 'family' ? a.owner ?? 'me' : 'me';

/// Счёт последней записанной траты или дохода — чаще всего он же и нужен.
ChatAccount? _lastUsed(LedgerView v, List<ChatAccount> accounts) {
  final byId = {for (final a in accounts) a.id: a};
  for (final tx in v.ledger.transactions.reversed) {
    if ((tx.type != EventType.expense && tx.type != EventType.income) || v.ledger.isReversed(tx.id)) continue;
    for (final p in tx.postings) {
      final a = byId[p.accountId];
      if (a != null) return a;
    }
  }
  return null;
}

/// Название своей категории как слово для словаря: без окончания, чтобы
/// «Собака» узнавалась и в «корм собаке».
String _stem(String name) {
  final w = name.trim().toLowerCase().replaceAll('ё', 'е');
  return w.length >= 4 && RegExp(r'[аеиоуыэюяйь]$').hasMatch(w) ? w.substring(0, w.length - 1) : w;
}

/// Разбирает сообщение в черновик операции. [now] — время Казахстана.
(ChatDraft?, DraftProblem?) buildDraft(String phrase, LedgerView v, DateTime now) {
  final accounts = chatAccounts(v);
  if (accounts.isEmpty) return (null, DraftProblem.noAccount);
  final d = parseVoice(
    phrase,
    // Названия счетов — как их передаёт приложение: целиком и по словам.
    accounts: [
      for (final a in accounts)
        VoiceAccount(a.id, [
          a.name,
          ...a.name.split(RegExp(r'\s+')),
          if (a.type == 'cash') ...['наличные', 'қолма-қол'],
          if (a.type == 'deposit') 'депозит',
        ], isCash: a.type == 'cash'),
    ],
    people: chatPeople(v),
    // Свои категории узнаются по названию: «собака 3000» → «Собака».
    userWords: {
      for (final e in v.of('category').entries)
        if (e.value['income'] != true && '${e.value['name'] ?? ''}'.trim().length >= 3) _stem('${e.value['name']}'): e.key,
    },
  );
  if (!d.complete) return (null, DraftProblem.noAmount);
  final named = accounts.where((a) => a.id == d.accountId).firstOrNull;
  final usual = _lastUsed(v, accounts) ?? accounts.where((a) => a.liquid).firstOrNull ?? accounts.first;
  final date = dateToJson(DateTime(now.year, now.month, now.day + (d.date ?? 0)));
  final time = '${_two(now.hour)}:${_two(now.minute)}';

  if (d.kind == VoiceKind.transfer) {
    if (accounts.length < 2) return (null, DraftProblem.needSecondAccount);
    final target = accounts.where((a) => a.id == d.toAccountId).firstOrNull;
    // Откуда: названный счёт, иначе привычный — но не тот, куда переводим.
    final from = named ?? (usual.id != target?.id ? usual : accounts.firstWhere((a) => a.id != target?.id));
    final to = target != null && target.id != from.id ? target : accounts.firstWhere((a) => a.id != from.id);
    return (ChatDraft(kind: 'transfer', amount: d.amount!, account: from.id, toAccount: to.id, note: '', date: date, time: time, who: 'me', txId: newChatId(), undoId: newChatId()), null);
  }
  final account = named ?? usual;
  if (d.kind != VoiceKind.expense && d.kind != VoiceKind.income) {
    final person = d.person?.trim() ?? '';
    if (person.isEmpty) return (null, DraftProblem.noPerson);
    return (
      ChatDraft(
        kind: d.kind.name,
        amount: d.amount!,
        account: account.id,
        person: person.length > 60 ? person.substring(0, 60) : person,
        note: '',
        date: date,
        time: time,
        who: 'me',
        txId: newChatId(),
        undoId: newChatId(),
      ),
      null,
    );
  }
  final income = d.kind == VoiceKind.income;
  return (
    ChatDraft(
      kind: income ? 'income' : 'expense',
      amount: d.amount!,
      category: d.category ?? (income ? 'otherIncome' : 'other'),
      account: account.id,
      note: d.note.length > maxNoteLength ? d.note.substring(0, maxNoteLength) : d.note,
      date: date,
      time: time,
      who: _whoFor(v, account),
      txId: newChatId(),
      undoId: newChatId(),
    ),
    null,
  );
}

/// На сколько счёт уйдёт в минус после этой операции (D87); 0 — не уйдёт.
int minusAfter(ChatDraft d, LedgerView v) {
  if (!d.outflow || !v.ledger.hasAccount(d.account)) return 0;
  final after = v.ledger.balance(d.account) - d.amount;
  return after < 0 ? -after : 0;
}

// ----------------------------------------------------------------- тексты

/// Названия и заметки приходят от человека, а сообщения уходят как HTML.
String escapeHtml(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

String _dayLabel(String date, DateTime now, bool kk) {
  final d = dateFromJson(date);
  final short = '${_two(d.day)}.${_two(d.month)}';
  final diff = DateTime.utc(now.year, now.month, now.day).difference(DateTime.utc(d.year, d.month, d.day)).inDays;
  return switch (diff) {
    0 => kk ? 'бүгін' : 'сегодня',
    1 => kk ? 'кеше, $short' : 'вчера, $short',
    2 => kk ? 'алдыңғы күні, $short' : 'позавчера, $short',
    _ => short,
  };
}

String _accountName(String? id, LedgerView v) => escapeHtml(v.of('account')[id]?['name'] as String? ?? id ?? '');

String _kindTitle(String kind, bool kk) => switch (kind) {
      'income' => kk ? 'Кіріс' : 'Доход',
      'transfer' => kk ? 'Аударым' : 'Перевод',
      'lendOut' => kk ? 'Қарызға бердім' : 'Дал в долг',
      'borrow' => kk ? 'Қарызға алдым' : 'Взял в долг',
      'repaymentReceived' => kk ? 'Маған қарыз қайтарылды' : 'Мне вернули долг',
      'repaymentMade' => kk ? 'Қарызды қайтардым' : 'Вернул долг',
      _ => kk ? 'Шығыс' : 'Расход',
    };

String _personLabel(String kind, bool kk) => switch (kind) {
      'borrow' => kk ? 'Кімнен' : 'У кого',
      'repaymentReceived' => kk ? 'Кім қайтарды' : 'Кто вернул',
      _ => kk ? 'Кімге' : 'Кому',
    };

String draftText(ChatDraft d, LedgerView v, DateTime now) {
  final kk = v.locale == 'kk';
  final today = dateToJson(DateTime(now.year, now.month, now.day));
  final minus = minusAfter(d, v);
  return [
    if (d.heard.isNotEmpty) '🎤 <i>«${escapeHtml(d.heard)}»</i>',
    '<b>${_kindTitle(d.kind, kk)} · ${formatMoney(d.amount)}</b>',
    if (d.transfer) ...[
      '${kk ? 'Қай шоттан' : 'Со счёта'}: ${_accountName(d.account, v)}',
      '${kk ? 'Қай шотқа' : 'На счёт'}: ${_accountName(d.toAccount, v)}',
    ] else ...[
      d.debt ? '${_personLabel(d.kind, kk)}: ${escapeHtml(d.person ?? '')}' : '${kk ? 'Санат' : 'Категория'}: ${escapeHtml(categoryName(d.category, v))}',
      '${kk ? 'Шот' : 'Счёт'}: ${_accountName(d.account, v)}',
    ],
    if (d.note.isNotEmpty) '${kk ? 'Жазба' : 'Заметка'}: ${escapeHtml(d.note)}',
    if (d.date != today) '${kk ? 'Күні' : 'Дата'}: ${_dayLabel(d.date, now, kk)}',
    // В минус уйти можно — но человек должен увидеть это до записи (D87).
    if (minus > 0)
      kk
          ? '⚠ Жазылғаннан кейін «${_accountName(d.account, v)}» шоты ${formatMoney(minus)} минусқа кетеді.'
          : '⚠ После записи счёт «${_accountName(d.account, v)}» уйдёт в минус на ${formatMoney(minus)}.',
  ].join('\n');
}

/// Одна строка об операции: «Расход 1 500 ₸ · Кафе · Kaspi Gold · Кофе».
String _oneLine(ChatDraft d, LedgerView v, DateTime now) {
  final kk = v.locale == 'kk';
  final today = dateToJson(DateTime(now.year, now.month, now.day));
  return [
    '${_kindTitle(d.kind, kk)} ${formatMoney(d.amount)}',
    if (d.transfer)
      '${_accountName(d.account, v)} → ${_accountName(d.toAccount, v)}'
    else ...[
      d.debt ? escapeHtml(d.person ?? '') : escapeHtml(categoryName(d.category, v)),
      _accountName(d.account, v),
    ],
    if (d.note.isNotEmpty) escapeHtml(d.note),
    if (d.date != today) _dayLabel(d.date, now, kk),
  ].join(' · ');
}

/// «Доступно сегодня: 1 527 ₸» или «Перерасход по лимиту: 2 000 ₸» — то же
/// число, что на главном экране приложения: расчёт общий, из ядра.
String _availableLine(DailyLimitState s, bool kk) {
  final a = s.available!;
  return a >= 0
      ? '${kk ? 'Бүгін қолжетімді' : 'Доступно сегодня'}: <b>${formatMoney(a)}</b>'
      : '${kk ? 'Лимиттен асып кетті' : 'Перерасход по лимиту'}: <b>${formatMoney(-a)}</b>';
}

/// Строка после записи расхода: сколько потрачено сегодня и сколько доступно.
String _spentLine(LedgerView v, DateTime now) {
  final kk = v.locale == 'kk';
  final s = dailyLimitState(v.ledger, v.profile, DateTime(now.year, now.month, now.day));
  final spent = kk ? 'Бүгін жұмсалды: ${formatMoney(s.spentToday)}.' : 'Сегодня потрачено: ${formatMoney(s.spentToday)}.';
  return s.available == null ? spent : '$spent ${_availableLine(s, kk)}.';
}

/// [v] — данные уже после записи: в строке о тратах учтена и эта операция.
String savedText(ChatDraft d, LedgerView v, DateTime now) {
  final kk = v.locale == 'kk';
  return [
    '✅ <b>${kk ? 'Жазылды' : 'Записано'}</b>',
    _oneLine(d, v, now),
    '',
    d.kind == 'expense' ? _spentLine(v, now) : (kk ? 'Шоттарда: ${formatMoney(v.ledger.liquid())}.' : 'На счетах: ${formatMoney(v.ledger.liquid())}.'),
  ].join('\n');
}

String cancelledText(ChatDraft d, LedgerView v, DateTime now) =>
    '✖ ${v.locale == 'kk' ? 'Жазылмады' : 'Не записано'}\n<s>${_oneLine(d, v, now)}</s>';

String undoneText(ChatDraft d, LedgerView v, DateTime now) =>
    '↩ ${v.locale == 'kk' ? 'Жазба жойылды' : 'Запись отменена'}\n<s>${_oneLine(d, v, now)}</s>';

String todayText(LedgerView v, DateTime now) {
  final kk = v.locale == 'kk';
  final today = DateTime(now.year, now.month, now.day);
  final s = spendBetween(v.ledger, today, today);
  final limit = dailyLimitState(v.ledger, v.profile, today);
  final top = s.byCategory.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  return [
    '<b>${kk ? 'Бүгін' : 'Сегодня'}, ${_two(now.day)}.${_two(now.month)}</b>',
    s.everyday == 0 && s.outside == 0
        ? (kk ? 'Шығыс жазылмады.' : 'Расходов не записано.')
        : (kk ? 'Жұмсалды: <b>${formatMoney(s.everyday)}</b>' : 'Потрачено: <b>${formatMoney(s.everyday)}</b>'),
    for (final e in top.take(5)) '• ${escapeHtml(categoryName(e.key, v))} — ${formatMoney(e.value)}',
    if (s.planned > 0) kk ? 'Лимиттен тыс (жоспарланған): ${formatMoney(s.planned)}' : 'Вне лимита (запланированное): ${formatMoney(s.planned)}',
    if (s.unexpected > 0) kk ? 'Лимиттен тыс (күтпеген): ${formatMoney(s.unexpected)}' : 'Вне лимита (непредвиденное): ${formatMoney(s.unexpected)}',
    if (limit.limit != null) ...[
      kk ? 'Күндік лимит: ${formatMoney(limit.limit!)}' : 'Лимит на день: ${formatMoney(limit.limit!)}',
      [
        _availableLine(limit, kk),
        if (limit.carry > 0) kk ? 'алдыңғы күндерден +${formatMoney(limit.carry)}' : 'с прошлых дней +${formatMoney(limit.carry)}',
        if (limit.carry < 0) kk ? 'алдыңғы күндердің артық шығысы ${formatMoney(-limit.carry)}' : 'перерасход прошлых дней ${formatMoney(-limit.carry)}',
        if (limit.capped) kk ? 'шоттардағы ақшамен шектелген' : 'ограничено деньгами на счетах',
      ].join(' · '),
    ],
    kk ? 'Шоттарда: ${formatMoney(v.ledger.liquid())}' : 'На счетах: ${formatMoney(v.ledger.liquid())}',
  ].join('\n');
}

String monthText(LedgerView v, DateTime now) {
  final kk = v.locale == 'kk';
  final from = DateTime(now.year, now.month, 1);
  final to = DateTime(now.year, now.month + 1, 1);
  final r = v.ledger.report(from, to);
  // Платежи по кредитам и долгам — строкой среди категорий (D98).
  final top = ([
    for (final e in v.ledger.expenseByCategory(from, to).entries)
      if (e.value > 0) (e.key.substring(8), e.value),
    if (r.debtPayments > 0) ('debts', r.debtPayments),
  ]..sort((a, b) => b.$2.compareTo(a.$2)))
      .take(5)
      .toList();
  final name = monthName(now.month, v.locale);
  return [
    '<b>${name[0].toUpperCase()}${name.substring(1)} ${now.year}</b>',
    '${kk ? 'Кіріс' : 'Доходы'}: ${formatMoney(r.income)}',
    '${kk ? 'Шығыс' : 'Расходы'}: ${formatMoney(r.total)}',
    '${kk ? 'Ай қорытындысы' : 'Итог месяца'}: <b>${r.result > 0 ? '+' : ''}${formatMoney(r.result)}</b>',
    if (top.isNotEmpty) kk ? 'Ең көп шығыс:' : 'Больше всего ушло:',
    for (final e in top) '• ${escapeHtml(categoryName(e.$1, v))} — ${formatMoney(e.$2)}',
  ].join('\n');
}

String helpText(bool kk, {String? origin, bool voice = false, bool statements = false}) => [
      kk
          ? 'Шығысты, кірісті, аударымды немесе қарызды жай хабарламамен жазыңыз — мен жобасын көрсетемін, растағаннан кейін жазамын.'
          : 'Напишите трату, доход, перевод или долг обычным сообщением — я покажу черновик и запишу после подтверждения.',
      '',
      kk ? 'Мысалы:' : 'Например:',
      '• кофе 1500',
      kk ? '• такси 2 мың кеше' : '• такси 2 тысячи вчера',
      kk ? '• азық-түлік 12400' : '• продукты 12400 с каспи',
      kk ? '• жалақы 350000' : '• зарплата 350000',
      kk ? '• Асхатқа 5000 қарыз бердім' : '• перевёл 20000 с каспи на наличные',
      if (!kk) '• дал в долг Асхату 5000',
      if (voice) ...['', kk ? 'Дауыстық хабарламамен де болады — қысқаша айтыңыз.' : 'Можно и голосовым сообщением — скажите то же самое вслух.'],
      if (statements) ...[
        '',
        kk
            ? '📄 Kaspi Gold үзінді көшірмесін PDF-файлмен жіберіңіз — әлі жазылмаған операцияларды қосамын.'
            : '📄 Пришлите PDF-выписку Kaspi Gold — добавлю операции, которых ещё нет в учёте.',
      ],
      '',
      kk ? '/today — бүгінгі шығыс' : '/today — траты за сегодня',
      kk ? '/month — ай қорытындысы' : '/month — итоги месяца',
      kk ? '/quick — жылдам операциялар' : '/quick — быстрые операции из приложения',
      if (origin != null && origin.startsWith('https://')) ...['', kk ? 'Қалғаны — қолданбада: $origin' : 'Всё остальное — в приложении: $origin'],
    ].join('\n');

// ----------------------------------------------------------------- кнопки

Map<String, String> _button(String text, String data) => {'text': text, 'callback_data': data};

/// Кнопки под черновиком. У расхода и дохода — категория, счёт и смена типа
/// (на случай если бот понял фразу не так: «премия 5000» — это доход); у
/// перевода — откуда и куда; у долга — счёт.
Buttons draftButtons(String id, LedgerView v, ChatDraft d) {
  final kk = v.locale == 'kk';
  final account = _button(kk ? 'Шот' : 'Счёт', 'd:$id:acc');
  final many = chatAccounts(v).length > 1;
  return [
    [_button(kk ? '✅ Жазу' : '✅ Записать', 'd:$id:ok'), _button(kk ? '✖ Болдырмау' : '✖ Отмена', 'd:$id:no')],
    if (d.transfer)
      [_button(kk ? 'Қай шоттан' : 'Со счёта', 'd:$id:acc'), _button(kk ? 'Қай шотқа' : 'На счёт', 'd:$id:to')]
    else if (d.debt) ...[
      if (many) [account],
    ] else
      [
        _button(kk ? 'Санат' : 'Категория', 'd:$id:cat'),
        if (many) account,
        _button(d.income ? (kk ? 'Бұл шығыс' : 'Это расход') : (kk ? 'Бұл кіріс' : 'Это доход'), 'd:$id:type'),
      ],
  ];
}

// ------------------------------------------------------- быстрые операции

/// Постоянные кнопки внизу чата (D85).
const quickLabelRu = '⚡ Быстрые';
const quickLabelKk = '⚡ Жылдам';
const todayLabelRu = '📅 Сегодня';
const todayLabelKk = '📅 Бүгін';

List<List<String>> chatKeyboard(bool kk) => [
      [kk ? quickLabelKk : quickLabelRu, kk ? todayLabelKk : todayLabelRu],
    ];

class ChatQuick {
  const ChatQuick(this.id, this.name, this.category, this.amount, {this.account});
  final String id;
  final String name;
  final String category;
  final int amount;

  /// Счёт плитки (Ж9); `null` — как у обычной записи из чата.
  final String? account;
}

/// «Быстрые операции» владельца из приложения — те, у которых задана сумма
/// (без суммы одним нажатием записывать нечего). Расходы: доходных быстрых
/// операций в приложении нет.
List<ChatQuick> chatQuicks(LedgerView v) => [
      for (final e in v.of('quick').entries)
        if (e.value['amount'] != null && parseMinor(e.value['amount']) > 0 && e.key.length <= 60)
          ChatQuick(e.key, '${e.value['name'] ?? ''}'.trim(), e.value['category'] as String? ?? 'other', parseMinor(e.value['amount']), account: e.value['account'] as String?),
    ];

Buttons quickButtons(LedgerView v) => [
      for (final q in chatQuicks(v)) [_button('${q.name.isEmpty ? categoryName(q.category, v) : q.name} · ${formatMoney(q.amount)}', 'q:${q.id}')],
    ];

/// Черновик из быстрой операции: сумма и категория готовы, счёт — как обычно.
ChatDraft? quickDraft(ChatQuick q, LedgerView v, DateTime now) {
  final accounts = chatAccounts(v);
  if (accounts.isEmpty) return null;
  final account = accounts.where((a) => a.id == q.account).firstOrNull ?? _lastUsed(v, accounts) ?? accounts.where((a) => a.liquid).firstOrNull ?? accounts.first;
  return ChatDraft(
    kind: 'expense',
    amount: q.amount,
    category: q.category,
    account: account.id,
    note: q.name,
    date: dateToJson(DateTime(now.year, now.month, now.day)),
    time: '${_two(now.hour)}:${_two(now.minute)}',
    who: _whoFor(v, account),
    txId: newChatId(),
    undoId: newChatId(),
  );
}

Buttons _grid(List<Map<String, String>> items, int perRow, Map<String, String> back) => [
      for (var i = 0; i < items.length; i += perRow) items.sublist(i, min(i + perRow, items.length)),
      [back],
    ];

Buttons categoryButtons(String id, ChatDraft d, LedgerView v) => _grid(
      [for (final c in chatCategories(v, income: d.income)) _button(categoryName(c, v), 'd:$id:c:$c')],
      3,
      _button(v.locale == 'kk' ? '← Артқа' : '← Назад', 'd:$id:back'),
    );

/// Счёт в кнопке — номером в списке: id счёта может не уместиться в 64 байта.
/// [target] — выбирается счёт, на который идёт перевод.
Buttons accountButtons(String id, LedgerView v, {bool target = false}) {
  final accounts = chatAccounts(v);
  return _grid(
    [for (var i = 0; i < accounts.length; i++) _button(accounts[i].name, 'd:$id:${target ? 't' : 'a'}:$i')],
    2,
    _button(v.locale == 'kk' ? '← Артқа' : '← Назад', 'd:$id:back'),
  );
}

Buttons undoButtons(String id, bool kk) => [
      [_button(kk ? '↩ Жазбаны жою' : '↩ Отменить запись', 'd:$id:undo')],
    ];

// ----------------------------------------------------------------- сервис

class ChatEntry {
  ChatEntry(this.db, this.ledger, this.telegram, {this.origin, this.speech, this.imports});

  final Pool db;
  final LedgerService ledger;
  final Telegram telegram;

  /// Адрес приложения (https://…) для подсказки; без него ссылки нет.
  final String? origin;

  /// Распознавание голосовых; без него бот просит написать текстом.
  final Speech? speech;

  /// Импорт выписки банка из присланного PDF (D94).
  final StatementImport? imports;

  String _help(bool kk) => helpText(kk, origin: origin, voice: speech?.enabled == true, statements: imports?.reader.enabled == true);

  /// Подключает бота: сообщения, кнопки и меню команд.
  void attach() {
    telegram.onMessage = onMessage;
    telegram.onCallback = onCallback;
    telegram.setCommands(const {'today': 'Траты за сегодня', 'month': 'Итоги месяца', 'quick': 'Быстрые операции', 'help': 'Как записать трату'});
    telegram.setCommands(const {'today': 'Бүгінгі шығыс', 'month': 'Ай қорытындысы', 'quick': 'Жылдам операциялар', 'help': 'Шығысты қалай жазу керек'}, language: 'kk');
  }

  DateTime _now() => DateTime.now().toUtc().add(kzOffset);

  Future<String?> _userOf(int chatId) async {
    final r = await db.execute(Sql.named('SELECT id FROM users WHERE telegram_chat_id = @c'), parameters: {'c': chatId});
    return r.isEmpty ? null : r.first[0].toString();
  }

  /// Сообщение из личного чата. `false` — чат не привязан к аккаунту, бот
  /// ответит обычной подсказкой о привязке.
  Future<bool> onMessage(int chatId, Map<String, dynamic> msg) async {
    final userId = await _userOf(chatId);
    final v = userId == null ? null : await ledger.view(userId);
    if (userId == null || v == null) return false;
    final kk = v.locale == 'kk';
    final now = _now();

    final voice = msg['voice'] as Map<String, dynamic>?;
    if (voice != null && speech?.enabled == true) {
      // Распознавание занимает секунды, а опрос бота один на всех: не ждём
      // его здесь, чтобы не задержать чужие сообщения и подтверждение оплаты.
      unawaited(_voice(chatId, userId, voice).catchError((Object e, StackTrace st) => stderr.writeln('telegram voice: ${e.runtimeType}\n$st')));
      return true;
    }
    if (voice != null || msg['audio'] != null || msg['video_note'] != null) {
      await telegram.send(
        chatId,
        kk
            ? 'Дауыстық хабарламаларды әзірге түсінбеймін. Мәтінмен жазыңыз немесе пернетақтадағы микрофонмен айтыңыз: «кофе 1500».'
            : 'Голосовые сообщения я пока не разбираю. Напишите текстом или надиктуйте через микрофон на клавиатуре: «кофе 1500».',
      );
      return true;
    }
    final document = msg['document'] as Map<String, dynamic>?;
    if (document != null && imports != null) {
      // Разбор файла занимает секунды — не ждём его в общем опросе бота.
      unawaited(imports!.onDocument(chatId, userId, document).catchError((Object e, StackTrace st) => stderr.writeln('telegram import: ${e.runtimeType}\n$st')));
      return true;
    }
    final text = (msg['text'] as String? ?? '').trim();
    final command = text.startsWith('/') ? text.split(RegExp(r'[\s@]')).first.toLowerCase() : null;
    if (command == '/quick' || text == quickLabelRu || text == quickLabelKk) {
      final buttons = quickButtons(v);
      if (buttons.isEmpty) {
        await telegram.send(
          chatId,
          kk
              ? 'Жылдам операциялар әзірге жоқ. Оларды қолданбаның басты бетінде, «Жылдам операциялар» бөлімінде сомасымен қосыңыз — осында батырма болып шығады.'
              : 'Быстрых операций пока нет. Добавьте их с суммой в приложении на главной, в блоке «Быстрые операции» — здесь они появятся кнопками.',
          keyboard: chatKeyboard(kk),
        );
      } else {
        await telegram.send(chatId, kk ? 'Жылдам операциялар — басыңыз, жобасын көрсетемін:' : 'Быстрые операции — нажмите, покажу черновик:', buttons: buttons);
      }
      return true;
    }
    if (command != null || text == todayLabelRu || text == todayLabelKk) {
      final reply = switch (command) {
        '/month' => monthText(v, now),
        '/today' || null => todayText(v, now),
        _ => _help(kk),
      };
      await telegram.send(chatId, reply, keyboard: chatKeyboard(kk));
      return true;
    }
    if (text.isEmpty || text.length > maxPhraseLength) {
      await telegram.send(chatId, _help(kk), keyboard: chatKeyboard(kk));
      return true;
    }

    await _offer(chatId, userId, v, text, now);
    return true;
  }

  /// Разбирает фразу и отправляет черновик с кнопками — или объясняет, чего
  /// не хватило. [heard] — фраза распознана из голосового: её показываем.
  Future<void> _offer(int chatId, String userId, LedgerView v, String text, DateTime now, {bool heard = false}) async {
    final kk = v.locale == 'kk';
    final quote = heard ? '🎤 <i>«${escapeHtml(text)}»</i>\n' : '';
    final (parsed, problem) = buildDraft(text, v, now);
    if (parsed == null) {
      await telegram.send(
        chatId,
        quote +
            switch (problem!) {
              DraftProblem.noAccount => kk ? 'Алдымен қолданбада сауалнаманы аяқтап, шот қосыңыз.' : 'Сначала завершите анкету в приложении и добавьте счёт — записывать пока некуда.',
              DraftProblem.needSecondAccount => kk ? 'Аударым үшін екінші шот керек — оны қолданбаның «Шоттар» бөлімінде қосыңыз.' : 'Для перевода нужен второй счёт — добавьте его в приложении в разделе «Счета».',
              DraftProblem.noPerson => kk
                  ? 'Қарыз кіммен екенін түсінбедім. Атымен жазыңыз: «Асхатқа 5000 қарыз бердім».'
                  : 'Не понял, с кем долг. Напишите с именем: «дал в долг Асхату 5000» или «Асхат вернул мне 5000».',
              DraftProblem.noAmount => '${kk ? 'Соманы таппадым.' : 'Не нашёл сумму.'}\n\n${_help(kk)}',
            },
      );
      return;
    }
    await _sendDraft(chatId, userId, v, heard ? parsed.copyWith(heard: text) : parsed, now);
  }

  /// Сохраняет черновик и показывает его с кнопками.
  Future<void> _sendDraft(int chatId, String userId, LedgerView v, ChatDraft draft, DateTime now) async {
    final id = newChatId(6);
    await db.execute(
      Sql.named('INSERT INTO telegram_drafts (id, user_id, chat_id, data) VALUES (@id, @u, @c, @d:jsonb)'),
      parameters: {'id': id, 'u': userId, 'c': chatId, 'd': draft.toJson()},
    );
    await telegram.send(chatId, draftText(draft, v, now), buttons: draftButtons(id, v, draft));
  }

  /// Нажатие быстрой операции: черновик с её суммой и категорией. Запись —
  /// всё равно только после «Записать», как и у набранной фразы.
  Future<String?> _quick(int chatId, String quickId) async {
    final userId = await _userOf(chatId);
    final v = userId == null ? null : await ledger.view(userId);
    if (userId == null || v == null) return 'Чат не привязан к аккаунту.';
    final kk = v.locale == 'kk';
    final quick = chatQuicks(v).where((q) => q.id == quickId).firstOrNull;
    final now = _now();
    final draft = quick == null ? null : quickDraft(quick, v, now);
    if (draft == null) return kk ? 'Бұл жылдам операция енді жоқ.' : 'Этой быстрой операции уже нет.';
    await _sendDraft(chatId, userId, v, draft, now);
    return null;
  }

  /// Голосовое сообщение: скачать, распознать, дальше — как набранный текст.
  Future<void> _voice(int chatId, String userId, Map<String, dynamic> voice) async {
    final v = await ledger.view(userId);
    if (v == null) return;
    final kk = v.locale == 'kk';
    if (((voice['duration'] as num?) ?? 0) > maxVoiceSeconds) {
      await telegram.send(chatId, kk ? 'Тым ұзақ хабарлама. Қысқаша айтыңыз: «кофе 1500».' : 'Слишком длинное сообщение. Скажите коротко: «кофе 1500».');
      return;
    }
    final used = await db.execute(
      Sql.named("SELECT count(*) FROM ai_usage WHERE user_id = @u AND feature = 'voice' AND created_at > now() - interval '1 day'"),
      parameters: {'u': userId},
    );
    if ((used.first[0] as int) >= maxVoicePerDay) {
      await telegram.send(chatId, kk ? 'Бүгінге дауыстық хабарламалар шегі бітті. Мәтінмен жазыңыз: «кофе 1500».' : 'На сегодня лимит голосовых исчерпан. Напишите текстом: «кофе 1500».');
      return;
    }
    final audio = await telegram.download(voice['file_id'] as String);
    final heard = audio == null ? null : await speech!.transcribe(audio);
    if (heard == null || heard.text.isEmpty) {
      await telegram.send(chatId, kk ? 'Хабарламаны түсіне алмадым. Қайталап көріңіз немесе мәтінмен жазыңыз.' : 'Не смог разобрать сообщение. Попробуйте ещё раз или напишите текстом.');
      return;
    }
    await db.execute(
      Sql.named('INSERT INTO ai_usage (user_id, feature, model, request_id, tokens_in, tokens_out) '
          "VALUES (@u, 'voice', @m, @r, @i, @o) ON CONFLICT (user_id, request_id) DO NOTHING"),
      parameters: {'u': userId, 'm': speech!.model, 'r': 'tg-voice-${voice['file_unique_id'] ?? voice['file_id']}', 'i': heard.tokensIn, 'o': heard.tokensOut},
    );
    final text = heard.text.length > maxPhraseLength ? heard.text.substring(0, maxPhraseLength) : heard.text;
    await _offer(chatId, userId, v, text, _now(), heard: true);
  }

  /// Нажатие кнопки под черновиком: `d:<черновик>:<действие>[:<значение>]`.
  Future<void> onCallback(Map<String, dynamic> q) async {
    final queryId = q['id'] as String;
    try {
      await telegram.answerCallback(queryId, text: await _press(q));
    } catch (_) {
      await telegram.answerCallback(queryId, text: 'Не получилось. Попробуйте ещё раз.');
      rethrow;
    }
  }

  /// Выполняет нажатие; возвращает короткую подпись-всплывашку или `null`.
  Future<String?> _press(Map<String, dynamic> q) async {
    final message = q['message'] as Map<String, dynamic>?;
    final chatId = (message?['chat'] as Map?)?['id'] as int?;
    final messageId = message?['message_id'] as int?;
    final data = q['data'] as String? ?? '';
    if (data.startsWith('q:') && chatId != null) return _quick(chatId, data.substring(2));
    if (data.startsWith('i:') && chatId != null && messageId != null && imports != null) return imports!.press(chatId, messageId, data.split(':'));
    final parts = data.split(':');
    if (parts.length < 3 || parts[0] != 'd' || chatId == null || messageId == null) return null;
    final id = parts[1];
    final arg = parts.length > 3 ? parts[3] : '';

    // Черновик принадлежит тому, к кому этот чат привязан сейчас: после
    // отвязки или перепривязки чата старые кнопки не действуют.
    final row = await db.execute(
      Sql.named('''
        SELECT d.user_id, d.data, d.status FROM telegram_drafts d
        JOIN users u ON u.id = d.user_id AND u.telegram_chat_id = d.chat_id
        WHERE d.id = @id AND d.chat_id = @c'''),
      parameters: {'id': id, 'c': chatId},
    );
    const stale = 'Черновик устарел — отправьте сообщение ещё раз.';
    if (row.isEmpty) return stale;
    final userId = row.first[0].toString();
    final draft = ChatDraft.fromJson(Map<String, dynamic>.from(row.first[1] as Map));
    final status = row.first[2] as String;
    final v = await ledger.view(userId);
    if (v == null) return stale;
    final kk = v.locale == 'kk';
    final now = _now();

    Future<bool> move(String from, String to) async =>
        (await db.execute(Sql.named('UPDATE telegram_drafts SET status = @to WHERE id = @id AND status = @from'), parameters: {'id': id, 'from': from, 'to': to})).affectedRows > 0;
    Future<void> show(ChatDraft d) async {
      await db.execute(Sql.named("UPDATE telegram_drafts SET data = @d:jsonb WHERE id = @id AND status = 'pending'"), parameters: {'id': id, 'd': d.toJson()});
      await telegram.edit(chatId, messageId, draftText(d, v, now), buttons: draftButtons(id, v, d));
    }

    switch (parts[2]) {
      case 'ok' when status == 'pending' || status == 'saved':
        // Повторное нажатие повторяет ту же команду — журнал примет её один раз.
        try {
          await ledger.command(userId, {...draft.command(), 'commandId': 'tg-$id'});
        } on ApiError catch (e) {
          return e.message ?? (kk ? 'Жазу мүмкін болмады.' : 'Не удалось записать.');
        }
        await move('pending', 'saved');
        await telegram.edit(chatId, messageId, savedText(draft, await ledger.view(userId) ?? v, now), buttons: undoButtons(id, kk));
        return kk ? 'Жазылды' : 'Записано';
      case 'undo' when status == 'saved':
        try {
          await ledger.command(userId, {'type': 'reverse', 'txId': draft.txId, 'id': draft.undoId, 'commandId': 'tg-$id-undo'});
        } on ApiError catch (e) {
          return e.message ?? (kk ? 'Жою мүмкін болмады.' : 'Не удалось отменить.');
        }
        await move('saved', 'undone');
        await telegram.edit(chatId, messageId, undoneText(draft, v, now));
        return kk ? 'Жойылды' : 'Отменено';
      case 'no' when status == 'pending':
        await move('pending', 'cancelled');
        await telegram.edit(chatId, messageId, cancelledText(draft, v, now));
        return null;
      case 'cat' when status == 'pending' && !draft.transfer && !draft.debt:
        await telegram.edit(chatId, messageId, draftText(draft, v, now), buttons: categoryButtons(id, draft, v));
        return null;
      case 'acc' when status == 'pending':
        await telegram.edit(chatId, messageId, draftText(draft, v, now), buttons: accountButtons(id, v));
        return null;
      case 'to' when status == 'pending' && draft.transfer:
        await telegram.edit(chatId, messageId, draftText(draft, v, now), buttons: accountButtons(id, v, target: true));
        return null;
      case 'c' when status == 'pending' && !draft.transfer && !draft.debt && chatCategories(v, income: draft.income).contains(arg):
        await show(draft.copyWith(category: arg));
        return null;
      case 'a' || 't' when status == 'pending':
        final accounts = chatAccounts(v);
        final i = int.tryParse(arg);
        if (i == null || i < 0 || i >= accounts.length || (parts[2] == 't' && !draft.transfer)) return stale;
        final chosen = accounts[i];
        if (parts[2] == 't') {
          // Выбрали «куда» тот же счёт, что «откуда» — меняем их местами.
          await show(draft.copyWith(toAccount: chosen.id, account: chosen.id == draft.account ? draft.toAccount : null));
        } else if (draft.transfer) {
          await show(draft.copyWith(account: chosen.id, toAccount: chosen.id == draft.toAccount ? draft.account : null));
        } else {
          await show(draft.copyWith(account: chosen.id, who: draft.kind == 'expense' ? _whoFor(v, chosen) : 'me'));
        }
        return null;
      case 'type' when status == 'pending' && !draft.transfer && !draft.debt:
        // Расход ↔ доход: категория другого типа не подходит — ставим общую,
        // её можно сменить кнопкой «Категория».
        final income = !draft.income;
        final account = chatAccounts(v).where((a) => a.id == draft.account).firstOrNull;
        await show(draft.copyWith(kind: income ? 'income' : 'expense', category: income ? 'otherIncome' : 'other', who: income || account == null ? 'me' : _whoFor(v, account)));
        return null;
      case 'back' when status == 'pending':
        await show(draft);
        return null;
      default:
        return kk ? 'Бұл батырма енді жұмыс істемейді.' : 'Эта кнопка уже не действует.';
    }
  }
}
