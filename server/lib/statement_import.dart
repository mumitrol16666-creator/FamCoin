/// Импорт выписки Kaspi Gold через бота (D94).
///
/// Человек пересылает боту PDF-выписку из приложения банка. Бот разбирает её,
/// сверяет с итогами самой выписки и показывает, что собирается записать:
/// сколько операций новые, какие уже есть, что станет с остатком счёта. В
/// журнал всё попадает только после «Записать» — теми же командами, что из
/// приложения; записанное можно отменить целиком одной кнопкой. Сам файл
/// нигде не хранится — только разобранные строки, пока живут кнопки.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:famcoin_core/famcoin_core.dart';
import 'package:postgres/postgres.dart';

import 'auth_service.dart';
import 'chat_entry.dart';
import 'gate.dart';
import 'ledger_service.dart';
import 'notifications.dart';
import 'pdf_words.dart';
import 'statement.dart';
import 'statement_plan.dart';
import 'telegram.dart';

String _two(int n) => n.toString().padLeft(2, '0');
String _date(DateTime d) => '${_two(d.day)}.${_two(d.month)}.${d.year}';
String _period(BankStatement st) => '${_date(st.from)} – ${_date(st.to)}';
String _signed(int minor) => minor > 0 ? '+${formatMoney(minor)}' : formatMoney(minor);

/// Названия из справочников владельца могут быть любой длины, а сообщение
/// Telegram — не длиннее 4096 знаков.
String _clip(String text, int max) => text.length > max ? '${text.substring(0, max)}…' : text;

Map<String, String> _button(String text, String data) => {'text': text, 'callback_data': data};

/// Не больше стольких предложений связать строку с платежом показывается
/// кнопками и в тексте: остальные записываются обычными расходами.
const _maxSuggestions = 4;
const _maxCandidates = 2;

/// Связи «строка выписки → срок платежа», подтверждённые человеком кнопкой.
/// Живут в данных импорта, поэтому повторное построение плана (после
/// «Записать», «Список», повторного нажатия) приходит к тому же результату.
Map<int, DueMark> importLinks(Map<String, dynamic> data) => {
      for (final e in (data['links'] as Map? ?? const {}).entries)
        if (int.tryParse('${e.key}') != null && e.value is Map)
          int.parse('${e.key}'): (kind: '${(e.value as Map)['kind']}', id: '${(e.value as Map)['id']}', period: '${(e.value as Map)['period']}'),
    };

/// Счета, на которые можно записать выписку: в тенге, не архивные, не копилки.
List<ChatAccount> importAccounts(LedgerView v) => chatAccounts(v).where((a) => v.ledger.account(a.id).currency == 'KZT').toList();

/// Счёт выписки, если он очевиден: единственный «каспи» среди карт или
/// единственная карта. Иначе бот спросит.
String? guessImportAccount(List<ChatAccount> accounts) {
  final cards = accounts.where((a) => a.type != 'cash' && a.type != 'deposit').toList();
  final kaspi = cards.where((a) => RegExp('kaspi|каспи', caseSensitive: false).hasMatch(a.name)).toList();
  if (kaspi.length == 1) return kaspi.single.id;
  return kaspi.isEmpty && cards.length == 1 ? cards.single.id : null;
}

// ----------------------------------------------------------------- тексты

String _title(BankStatement st, bool kk) => kk ? '📄 <b>Kaspi үзінді көшірмесі · ${_period(st)}</b>' : '📄 <b>Выписка Kaspi · ${_period(st)}</b>';

String _accountLine(LedgerView v, String accountId) =>
    '${v.locale == 'kk' ? 'FamCoin-дегі шот' : 'Счёт в FamCoin'}: ${escapeHtml(_clip(v.of('account')[accountId]?['name'] as String? ?? accountId, 60))}';

/// Что бот собирается записать — показывается до подтверждения. [pro] —
/// тариф позволяет записать: разбор и сводку видят все, запись — в Pro.
String importSummaryText(BankStatement st, ImportPlan p, LedgerView v, String accountId, {bool pro = true, DateTime? today}) {
  final kk = v.locale == 'kk';
  final rows = st.rows.length;
  final expenses = [PlanGroup.purchase, PlanGroup.transferOut, PlanGroup.withdrawal, PlanGroup.otherExpense, PlanGroup.planned];
  final expenseCount = expenses.fold<int>(0, (s, g) => s + p.count(g));
  final expenseTotal = -expenses.fold<int>(0, (s, g) => s + p.total(g));
  final parts = [
    if (p.count(PlanGroup.purchase) > 0) '${kk ? 'сатып алу' : 'покупки'} ${p.count(PlanGroup.purchase)}',
    if (p.count(PlanGroup.transferOut) > 0) '${kk ? 'адамдарға аударым' : 'переводы людям'} ${p.count(PlanGroup.transferOut)}',
    if (p.count(PlanGroup.withdrawal) > 0) '${kk ? 'қолма-қол алу' : 'снятия наличных'} ${p.count(PlanGroup.withdrawal)}',
    if (p.count(PlanGroup.otherExpense) > 0) '${kk ? 'басқа' : 'прочее'} ${p.count(PlanGroup.otherExpense)}',
    if (p.count(PlanGroup.planned) > 0) '${kk ? 'жоспарлы төлем' : 'плановые платежи'} ${p.count(PlanGroup.planned)}',
  ];
  final plannedNames = escapeHtml(_clip({for (final o in p.ops.where((o) => o.mark != null)) '${(o.command['meta'] as Map)['note']}'}.join(', '), 300));
  final loanNames = escapeHtml(_clip({for (final e in p.loans) e.name}.join(', '), 300));
  final loanTotal = p.loans.fold<int>(0, (s, e) => s + st.rows[e.n].amount.abs());
  final old = p.oldOpenings.isEmpty ? null : p.oldOpenings.last;
  final gap = p.gap;
  final nothing = p.ops.isEmpty && !p.changesOpening;
  return [
    _title(st, kk),
    _accountLine(v, accountId),
    '',
    if (st.balanced)
      kk ? 'Үзінді көшірмеде $rows операция, қорытындылары банкпен сәйкес келді ✓' : 'В выписке операций: $rows, итоги сошлись с банком ✓'
    else
      kk
          ? 'Үзінді көшірмеде $rows операция. ⚠ Қорытынды бөлігін таппадым — қалдықты банкпен салыстыра алмаймын.'
          : 'В выписке операций: $rows. ⚠ Блок итогов я не нашёл — сверить остаток с банком не смогу.',
    if (p.ops.isNotEmpty) kk ? '• жаңасы — ${p.ops.length}' : '• новых — ${p.ops.length}',
    if (p.present.length + p.written.length > 0)
      kk ? '• бұрын жазылған — ${p.present.length + p.written.length}' : '• уже записаны — ${p.present.length + p.written.length}',
    if (p.removed.isNotEmpty) kk ? '• бұрын өзіңіз жойғандар — ${p.removed.length}, қайтармаймын' : '• удалены вами раньше — ${p.removed.length}, не возвращаю',
    if (p.loans.isNotEmpty) kk ? '• несие төлемдері — ${p.loans.length}, жазбаймын' : '• платежи по кредитам — ${p.loans.length}, не записываю',
    if (p.beforeStart.isNotEmpty)
      kk
          ? '• шот есебі басталғанға дейінгілер (${_date(p.startDate!)}) — ${p.beforeStart.length}, жазбаймын: олар бастапқы қалдықта ескерілген'
          : '• раньше начала учёта счёта (${_date(p.startDate!)}) — ${p.beforeStart.length}, не записываю: они уже учтены в начальном остатке',
    '',
    if (nothing)
      kk ? 'Жаңа операция жоқ — жазатын ештеңе жоқ.' : 'Новых операций нет — записывать нечего.'
    else if (p.ops.isNotEmpty) ...[
      kk ? '<b>Жазамын:</b>' : '<b>Запишу:</b>',
      if (expenseCount > 0)
        '${kk ? 'Шығыс' : 'Расходы'} — $expenseCount, ${formatMoney(expenseTotal)}${parts.length > 1 ? ' (${parts.join(', ')})' : ''}',
      if (p.count(PlanGroup.income) > 0) '${kk ? 'Кіріс' : 'Доходы'} — ${p.count(PlanGroup.income)}, ${formatMoney(p.total(PlanGroup.income))}',
      if (p.count(PlanGroup.refund) > 0) '${kk ? 'Қайтарым' : 'Возвраты'} — ${p.count(PlanGroup.refund)}, ${formatMoney(p.total(PlanGroup.refund))}',
      if (p.count(PlanGroup.move) > 0)
        '${kk ? 'Өз шоттар арасындағы аударым' : 'Переводы между своими счетами'} — ${p.count(PlanGroup.move)}, ${_signed(p.total(PlanGroup.move))}',
      if (p.count(PlanGroup.adjust) > 0)
        kk
            ? 'Қалдықты нақтылау — ${p.count(PlanGroup.adjust)}, ${_signed(p.total(PlanGroup.adjust))}: ақша FamCoin-де жоқ өз шоттарыңызға кетті немесе солардан келді. Бұл шығыс та, кіріс те емес.'
            : 'Уточнения остатка — ${p.count(PlanGroup.adjust)}, ${_signed(p.total(PlanGroup.adjust))}: деньги ушли на свои счета, которых нет в FamCoin, или пришли с них. Это не расход и не доход.',
      if (plannedNames.isNotEmpty)
        kk ? 'Жоспарлы төлемдерді төленген деп белгілеймін: $plannedNames.' : 'Плановые платежи отмечу оплаченными: $plannedNames.',
      '',
    ],
    if (p.loans.isNotEmpty) ...[
      kk
          ? 'Несие төлемдерін жазбаймын — ${p.loans.length}, ${formatMoney(loanTotal)} ($loanNames): мұндай төлем қарыз бен пайызға бөлінеді, оны банк қолданбасынан көресіз. Қолданбада белгілеңіз: «Бюджет» → төлем → «Төлеу».'
          : 'Платежи по кредитам не записываю — ${p.loans.length}, ${formatMoney(loanTotal)} ($loanNames): такой платёж делится на долг и проценты, разбивка — в приложении банка. Отметьте его в приложении: «Бюджет» → платёж → «Оплатить».',
      '',
    ],
    if (p.linked.isNotEmpty) ...[
      kk
          ? 'Өзіңіз байланыстырған төлемдер: ${p.linked.length}.'
          : 'Связано вами с платежами: ${p.linked.length}.',
      '',
    ],
    if (p.suggestions.isNotEmpty) ...[
      kk
          ? 'Мына жолдар сомасы мен күні бойынша жоспарлы төлемге ұқсайды. Қай төлем екенін, әлде төлем емес екенін тек сіз білесіз — растамайынша, әдеттегі шығыс ретінде жазамын:'
          : 'Эти строки похожи на плановый платёж по сумме и дате. Какой это платёж и платёж ли вообще, знаете только вы — пока не подтвердите, запишу как обычные расходы:',
      for (final s in p.suggestions.take(_maxSuggestions))
        '• ${escapeHtml(_clip(st.rows[s.n].details.isEmpty ? st.rows[s.n].operation : st.rows[s.n].details, 40))} ${formatMoney(st.rows[s.n].amount.abs())}, ${_date(st.rows[s.n].date)}'
            ' — ${kk ? 'бұл' : 'возможно, это'} ${s.candidates.take(_maxCandidates).map((c) => '«${escapeHtml(_clip(c.name, 40))}» (${_date(c.date)})').join(kk ? ' немесе ' : ' или ')}',
      if (p.suggestions.length > _maxSuggestions)
        kk ? '… және тағы ${p.suggestions.length - _maxSuggestions}: оларды әдеттегі шығыс ретінде жазамын.' : '… и ещё ${p.suggestions.length - _maxSuggestions}: их запишу обычными расходами.',
      kk
          ? 'Байланыстыру үшін төмендегі батырманы басыңыз. Байланысты есте сақтаймын: келесі үзінді көшірмедегі дәл осындай жол өзі байланысады.'
          : 'Чтобы связать с платежом, нажмите кнопку ниже. Связь запомню: такая же строка в следующей выписке свяжется сама.',
      '',
    ],
    if (p.changesOpening)
      old == null
          ? (kk
              ? 'Шоттың бастапқы қалдығын қоямын: ${_date(st.from)} күніне ${formatMoney(p.newOpening!)} — үзінді көшірмедегідей.'
              : 'Поставлю начальный остаток счёта: ${formatMoney(p.newOpening!)} на ${_date(st.from)} — как в выписке.')
          : (kk
              ? 'Шоттың бастапқы қалдығын ауыстырамын: ${_date(st.from)} күніне ${formatMoney(p.newOpening!)} — үзінді көшірмедегідей (қазір ${_date(old.date)} күніне ${formatMoney(old.amountOn(accountId))}). Әйтпесе ${_date(old.date)} дейінгі операциялар екі рет есептелер еді.'
              : 'Начальный остаток счёта заменю: ${formatMoney(p.newOpening!)} на ${_date(st.from)} — как в выписке (сейчас ${formatMoney(old.amountOn(accountId))} на ${_date(old.date)}). Иначе операции до ${_date(old.date)} посчитались бы дважды.'),
    if (!nothing) kk ? 'Жазғаннан кейін шот қалдығы: <b>${formatMoney(p.balanceAfter)}</b>.' : 'Остаток счёта после записи: <b>${formatMoney(p.balanceAfter)}</b>.',
    if (gap != null) _gapLine(st, p, kk, after: !nothing, today: today),
    if (gap != null && gap != 0 && p.piggyHeld == 0 && !nothing) kk ? 'Жазғаннан кейін теңестіруді ұсынамын.' : 'После записи предложу выровнять.',
    if (p.restartCarry)
      kk
          ? 'Күндік лимиттің тасымалын бүгіннен қайта бастаймын: үзінді көшірмедегі өткен шығыстар артық шығыс болып есептелмейді.'
          : 'Перенос дневного лимита начну заново с сегодняшнего дня: прошлые траты из выписки не станут перерасходом задним числом.',
    if (p.count(PlanGroup.transferOut) > 0 || p.count(PlanGroup.income) > 0) ...[
      '',
      kk
          ? 'Адамдарға аударымдарды «Басқа» шығысы, толықтыруларды кіріс етіп жазамын: санат пен жазбаны қолданбада түзетуге болады.'
          : 'Переводы людям запишу расходом «Прочее», пополнения — доходом: категорию и заметку можно поправить в приложении.',
    ],
    if (!pro && !nothing) ...[
      '',
      kk ? '🔒 Үзінді көшірмедегі операцияларды жазу — Pro мүмкіндігі. Жиынтық пен тізім — тегін.' : '🔒 Записать операции из выписки можно в Pro. Сводка и список — бесплатно.',
    ],
  ].join('\n');
}

/// Сверка с банком: остаток на последний день выписки против журнала.
/// [after] — речь о том, что будет после записи. Деньги в копилках целей
/// ([ImportPlan.piggyHeld]) в приложении лежат на отдельных счетах, а в банке
/// могут быть на той же карте — поэтому сходиться может любой из двух итогов.
String _gapLine(BankStatement st, ImportPlan p, bool kk, {bool after = false, DateTime? today}) {
  final inLedger = p.balanceAtEnd;
  final gap = st.closing! - inLedger;
  final day = _date(st.to);
  if (gap == 0) return kk ? '$day күнгі қалдық үзінді көшірмемен сәйкес келеді ✓' : 'Остаток на $day совпадает с выпиской ✓';
  if (p.piggyHeld != 0 && gap == p.piggyHeld) {
    return kk
        ? '$day күнгі қалдық үзінді көшірмемен сәйкес келеді ✓ — жинақ қораптарындағы ${formatMoney(p.piggyHeld)} осы картада жатыр деп есептегенде.'
        : 'Остаток на $day совпадает с выпиской ✓ — если считать, что ${formatMoney(p.piggyHeld)} из копилок лежат на этой же карте.';
  }
  final diff = formatMoney(gap.abs());
  return [
    kk
        ? 'Үзінді көшірме бойынша $day күні — ${formatMoney(st.closing!)}, ал FamCoin-де бұл күні ${formatMoney(inLedger)}${after ? ' болады' : ''}: $diff ${gap > 0 ? 'аз' : 'көп'}. Бір операция қолмен басқа сомамен не басқа шотқа жазылған болуы мүмкін.'
        : 'По выписке на $day — ${formatMoney(st.closing!)}, в FamCoin на эту дату ${after ? 'выйдет' : '—'} ${formatMoney(inLedger)}: на $diff ${gap > 0 ? 'меньше' : 'больше'}. Так бывает, если что-то записано вручную с другой суммой или не на тот счёт.',
    if (p.piggyHeld != 0)
      kk
          ? 'Бұл шоттан жинақ қораптарына ${formatMoney(p.piggyHeld)} салынған: егер ол ақша осы картада жатса, айырма — ${formatMoney((gap - p.piggyHeld).abs())}. Нақты қалдықты қолданбада түзетіңіз: шот → «Қалдықты нақтылау».'
          : 'С этого счёта в копилки отложено ${formatMoney(p.piggyHeld)}: если эти деньги лежат на той же карте, расхождение — ${formatMoney((gap - p.piggyHeld).abs())}. Точный остаток поправьте в приложении: счёт → «Уточнить остаток».',
    // Выписка «по сегодня» знает остаток на минуту, когда её сформировали.
    if (today != null && !st.to.isBefore(today))
      kk
          ? 'Егер үзінді көшірме жасалғаннан кейін жаңа операциялар жазсаңыз, айырма содан болуы мүмкін — онда теңестірудің қажеті жоқ.'
          : 'Если после формирования выписки вы уже записали новые операции, разница может быть из-за них — тогда выравнивать не нужно.',
  ].join('\n');
}

/// Расхождение с банком можно выровнять одним уточнением остатка: записана вся
/// выписка, сверка возможна и её не путают копилки.
bool _canLevel(ImportPlan p) => p.ops.isEmpty && !p.changesOpening && p.gap != null && p.gap != 0 && p.piggyHeld == 0;

/// Список новых операций — отдельным сообщением по кнопке. Строк и знаков в
/// строке столько, чтобы сообщение уложилось в предел Telegram (4096 знаков).
String importListText(BankStatement st, ImportPlan p, LedgerView v, {int limit = 30}) {
  final kk = v.locale == 'kk';
  String short(String text, [int max = 40]) => text.length > max ? '${text.substring(0, max)}…' : text;
  // У перевода между счетами и уточнения остатка заметки нет — показываем детали
  // из выписки: по ним видно, что это за движение.
  String note(PlannedOp o) => short(o.group == PlanGroup.move || o.group == PlanGroup.adjust ? st.rows[o.n].details : '${(o.command['meta'] as Map?)?['note'] ?? ''}');
  String label(PlannedOp o) => short(
        switch (o.group) {
          PlanGroup.move => '↔ ${o.label}',
          PlanGroup.refund => '${kk ? 'Қайтарым' : 'Возврат'}: ${o.label}',
          _ => o.label,
        },
        30,
      );
  return [
    kk ? '<b>Үзінді көшірмедегі жаңа операциялар</b>' : '<b>Новые операции из выписки</b>',
    if (p.ops.length > limit) kk ? 'алғашқы $limit, барлығы ${p.ops.length}' : 'первые $limit из ${p.ops.length}',
    for (final o in p.ops.take(limit))
      [
        '${_two(st.rows[o.n].date.day)}.${_two(st.rows[o.n].date.month)}',
        _signed(o.amount),
        escapeHtml(label(o)),
        if (note(o).isNotEmpty) escapeHtml(note(o)),
      ].join(' · '),
  ].join('\n');
}

// ----------------------------------------------------------------- сервис

/// Очередь чтения файлов переполнена.
class _Busy implements Exception {
  const _Busy();
}

class StatementImport {
  StatementImport(this.db, this.ledger, this.telegram, this.reader, {this.proLink});

  final Pool db;
  final LedgerService ledger;
  final Telegram telegram;
  final PdfReader reader;

  /// Ссылка на счёт Pro в Telegram — кнопкой под отказом записать на обычном
  /// тарифе; без неё бот отправляет в приложение.
  final Future<String?> Function(String userId)? proLink;

  /// Разбор и сводка доступны всем, запись в журнал — возможность Pro.
  Future<bool> _isPro(String userId) async {
    final r = await db.execute(Sql.named('SELECT plan FROM users WHERE id = @u'), parameters: {'u': userId});
    return r.isNotEmpty && r.first[0] == 'pro';
  }

  Future<String> _offerPro(int chatId, String userId, bool kk) async {
    final link = await proLink?.call(userId);
    await telegram.send(
      chatId,
      [
        kk
            ? '🔒 Үзінді көшірмедегі операцияларды жазу <b>Pro</b> тарифіне кіреді. Бұл жиынтық 30 күн сақталады: Pro рәсімдеп, «Жазу» батырмасын қайта басыңыз.'
            : '🔒 Запись операций из выписки входит в <b>Pro</b>. Эта сводка сохранится на 30 дней: оформите Pro и нажмите «Записать» ещё раз.',
        if (link == null) kk ? 'Рәсімдеу: қолданбада «Қосымша → Тариф».' : 'Оформить: в приложении «Ещё → Тариф».',
      ].join('\n'),
      buttons: link == null
          ? null
          : [
              [
                {'text': kk ? 'Pro рәсімдеу' : 'Оформить Pro', 'url': link},
              ],
            ],
    );
    return kk ? 'Pro қажет' : 'Нужен Pro';
  }

  /// Выписка за полгода — сотни килобайт; больше — не выписка.
  static const maxFileBytes = 5 * 1024 * 1024;

  /// Разбор файла занимает секунды процессора — не больше стольких файлов
  /// в сутки от одного человека, считая и неразобранные.
  static const maxPerDay = 20;

  /// Одновременно читаются не больше двух файлов, остальные ждут в очереди:
  /// пачка выписок не должна занять весь сервер.
  final _reading = Gate(2, maxQueue: 20, overflow: () => const _Busy());

  /// Когда человек присылал файлы за последние сутки.
  final _attempts = <String, List<DateTime>>{};

  bool _tooMany(String userId) {
    final now = DateTime.now();
    final recent = (_attempts[userId] ?? const <DateTime>[]).where((t) => now.difference(t) < const Duration(days: 1)).toList();
    if (recent.length >= maxPerDay) {
      _attempts[userId] = recent;
      return true;
    }
    _attempts[userId] = recent..add(now);
    if (_attempts.length > 5000) _attempts.remove(_attempts.keys.first);
    return false;
  }

  /// Операций в одной команде журнала (предел пачки — [maxBatch]).
  static const chunk = 150;

  DateTime _today() {
    final now = DateTime.now().toUtc().add(kzOffset);
    return DateTime(now.year, now.month, now.day);
  }

  /// Документ из чата. Разбор не ждут в общем опросе бота — как и голосовое.
  Future<void> onDocument(int chatId, String userId, Map<String, dynamic> doc) async {
    final v = await ledger.view(userId);
    if (v == null) return;
    final kk = v.locale == 'kk';
    Future<void> say(String ru, String kz) => telegram.send(chatId, kk ? kz : ru);

    final name = '${doc['file_name'] ?? ''}'.toLowerCase();
    if (doc['mime_type'] != 'application/pdf' && !name.endsWith('.pdf')) {
      return say(
        'Из файлов я понимаю только PDF-выписку Kaspi Gold. В приложении Kaspi.kz: «Мой Банк» → Kaspi Gold → вкладка «Выписка», выберите период и отправьте PDF-файл сюда.',
        'Файлдардан тек Kaspi Gold PDF үзінді көшірмесін түсінемін. Kaspi.kz қосымшасында: «Жеке Банк» → Kaspi Gold → «Көшірме» қойындысы, кезеңді таңдап, PDF-файлды осында жіберіңіз.',
      );
    }
    if (!reader.enabled) {
      return say('Импорт выписок сейчас недоступен. Попробуйте позже.', 'Үзінді көшірмелерді импорттау қазір қолжетімсіз. Кейінірек көріңіз.');
    }
    if (((doc['file_size'] as num?) ?? 0) > maxFileBytes) {
      return say('Файл больше 5 МБ. Сформируйте выписку за более короткий период.', 'Файл 5 МБ-тан үлкен. Үзінді көшірмені қысқарақ кезеңге жасаңыз.');
    }
    final accounts = importAccounts(v);
    if (accounts.isEmpty) {
      return say('Сначала завершите анкету в приложении и добавьте счёт — записывать пока некуда.', 'Алдымен қолданбада сауалнаманы аяқтап, шот қосыңыз.');
    }
    final recent = await db.execute(
      Sql.named("SELECT count(*) FROM telegram_imports WHERE user_id = @u AND created_at > now() - interval '1 day'"),
      parameters: {'u': userId},
    );
    if ((recent.first[0] as int) >= maxPerDay || _tooMany(userId)) {
      return say('На сегодня выписок достаточно — попробуйте завтра.', 'Бүгінге үзінді көшірмелер жеткілікті — ертең көріңіз.');
    }

    unawaited(telegram.call('sendChatAction', {'chat_id': chatId, 'action': 'typing'}));
    final List<PdfWord>? words;
    try {
      words = await _reading.run(() async {
        final bytes = await telegram.download(doc['file_id'] as String, maxBytes: maxFileBytes);
        return bytes == null ? null : reader.words(bytes);
      });
    } on _Busy {
      return say('Сейчас читаю слишком много файлов. Пришлите выписку ещё раз через пару минут.', 'Қазір тым көп файл оқып жатырмын. Үзінді көшірмені бірнеше минуттан кейін қайта жіберіңіз.');
    }
    if (words == null) {
      return say(
        'Не смог прочитать файл. Нужна выписка в PDF, сформированная в приложении Kaspi.kz, — не фото и не скан.',
        'Файлды оқи алмадым. Kaspi.kz қосымшасында жасалған PDF үзінді көшірме керек — фото да, скан да емес.',
      );
    }
    final BankStatement st;
    try {
      st = parseStatement(words);
    } on StatementError catch (e) {
      // Содержание файла в журнал не попадает — только его строение.
      stderr.writeln('import: выписка не разобрана — ${e.code} ${e.detail}\n${maskedLayout(words)}');
      return switch (e.code) {
        'tooMany' => say(
            'В выписке больше 3 000 операций. Сформируйте её за более короткий период — например, по месяцам.',
            'Үзінді көшірмеде 3 000-нан астам операция бар. Оны қысқарақ кезеңге, мысалы ай сайын жасаңыз.',
          ),
        'currency' => say(
            'Похоже, это выписка по счёту не в тенге. Пока я записываю только тенговые счета.',
            'Бұл теңгедегі шоттың үзінді көшірмесі емес сияқты. Әзірге тек теңгедегі шоттарды жазамын.',
          ),
        'badRows' || 'mismatch' => say(
            'Я прочитал выписку, но операции не сошлись с её итогами — значит, часть строк я понял неверно. Ничего не записываю, чтобы не испортить учёт. Попробуйте выписку за другой период.',
            'Үзінді көшірмені оқыдым, бірақ операциялар оның қорытындысымен сәйкес келмеді — демек, кейбір жолдарды дұрыс түсінбедім. Есепті бүлдірмеу үшін ештеңе жазбаймын. Басқа кезеңнің үзінді көшірмесін жіберіп көріңіз.',
          ),
        _ => say(
            'Это не похоже на выписку Kaspi Gold: я не нашёл в файле таблицу операций. Нужна выписка по Kaspi Gold из приложения Kaspi.kz. Другие банки пока не поддерживаются.',
            'Бұл Kaspi Gold үзінді көшірмесіне ұқсамайды: файлдан операциялар кестесін таппадым. Kaspi.kz қосымшасынан Kaspi Gold үзінді көшірмесі керек. Басқа банктерге әзірге қолдау жоқ.',
          ),
      };
    }

    // Что разобралось — в журнал без содержания: по счётчикам видно, узнаны
    // ли названия операций и сошлись ли итоги.
    final kinds = <String, int>{};
    for (final r in st.rows) {
      kinds.update(r.kind.name, (n) => n + 1, ifAbsent: () => 1);
    }
    print('import: выписка разобрана — строк ${st.rows.length}, язык ${st.language}, ${st.balanced ? 'итоги сошлись' : 'без итогов'}, виды $kinds');

    final id = newChatId(6);
    final account = guessImportAccount(accounts);
    await db.execute(
      Sql.named('INSERT INTO telegram_imports (id, user_id, chat_id, data) VALUES (@id, @u, @c, @d:jsonb)'),
      parameters: {'id': id, 'u': userId, 'c': chatId, 'd': {'statement': st.toJson(), 'account': account}},
    );
    if (account == null) {
      await telegram.send(chatId, _chooseText(st, kk), buttons: _accountButtons(id, accounts, kk, back: false));
    } else {
      final plan = planImport(st, v, account, id, _today());
      await telegram.send(chatId, importSummaryText(st, plan, v, account, pro: await _isPro(userId), today: _today()), buttons: _summaryButtons(id, st, plan, accounts.length, kk));
    }
  }

  String _chooseText(BankStatement st, bool kk) =>
      '${_title(st, kk)}\n\n${kk ? 'Бұл үзінді көшірме қай шотқа қатысты?' : 'К какому счёту относится эта выписка?'}';

  Buttons _accountButtons(String id, List<ChatAccount> accounts, bool kk, {required bool back}) => [
        for (var i = 0; i < accounts.length; i += 2) [for (var k = i; k < min(i + 2, accounts.length); k++) _button(accounts[k].name, 'i:$id:a:$k')],
        [back ? _button(kk ? '← Артқа' : '← Назад', 'i:$id:back') : _button(kk ? '✖ Болдырмау' : '✖ Отмена', 'i:$id:no')],
      ];

  Buttons _summaryButtons(String id, BankStatement st, ImportPlan p, int accounts, bool kk) {
    final nothing = p.ops.isEmpty && !p.changesOpening;
    final account = _button(kk ? 'Шот' : 'Счёт', 'i:$id:acc');
    if (nothing) {
      return [
        if (_canLevel(p)) [_button(kk ? 'Қалдықты банкпен теңестіру' : 'Выровнять остаток по выписке', 'i:$id:lvl')],
        [if (accounts > 1) account, _button(kk ? 'Жабу' : 'Закрыть', 'i:$id:no')],
      ];
    }
    return [
      [_button(kk ? '✅ Жазу (${p.ops.length})' : '✅ Записать (${p.ops.length})', 'i:$id:ok'), _button(kk ? '✖ Болдырмау' : '✖ Отмена', 'i:$id:no')],
      [if (p.ops.isNotEmpty) _button(kk ? '📋 Тізім' : '📋 Список', 'i:$id:list'), if (accounts > 1) account],
      // Предложения связать строку с платежом: связь — только по кнопке.
      for (final s in p.suggestions.take(_maxSuggestions))
        for (var k = 0; k < min(s.candidates.length, _maxCandidates); k++)
          [_button('🔗 ${_clip(st.rows[s.n].details.isEmpty ? st.rows[s.n].operation : st.rows[s.n].details, 18)} → ${_clip(s.candidates[k].name, 22)}', 'i:$id:lk:${s.n}.$k')],
      for (final n in p.linked)
        [_button('↩ ${kk ? 'Байланыс жоқ' : 'Не связывать'}: ${_clip(st.rows[n].details.isEmpty ? st.rows[n].operation : st.rows[n].details, 28)}', 'i:$id:ul:$n')],
    ];
  }

  /// Что записано — после «Записать». Сверка с банком считается заново по
  /// журналу: её могли поменять и операции, записанные позже.
  String _savedText(BankStatement st, Map<String, dynamic> data, LedgerView v, String accountId, ImportPlan now, DateTime today) {
    final kk = v.locale == 'kk';
    final done = Map<String, dynamic>.from(data['done'] as Map? ?? const {});
    final count = done['count'] as int? ?? 0;
    final expense = parseMinor(done['expense'] ?? '0');
    final income = parseMinor(done['income'] ?? '0');
    final opening = data['opening'] as Map?;
    final level = data['level'] as String?;
    final loans = escapeHtml(_clip(
      [
        for (final e in (data['loans'] as List? ?? const []).cast<Map>()) '${e['name']} ${formatMoney(parseMinor(e['amount']))} (${_date(dateFromJson(e['date']))})',
      ].join(', '),
      500,
    ));
    return [
      kk ? '✅ <b>Жазылған операция: $count</b> — Kaspi үзінді көшірмесі, ${_period(st)}' : '✅ <b>Записано операций: $count</b> — выписка Kaspi за ${_period(st)}',
      '${_accountLine(v, accountId)} · ${kk ? 'қалдық' : 'остаток'} <b>${formatMoney(v.ledger.balance(accountId))}</b>',
      if (expense > 0 || income > 0)
        [
          if (expense > 0) '${kk ? 'Шығыс' : 'Расходы'} ${formatMoney(expense)}',
          if (income > 0) '${kk ? 'Кіріс' : 'Доходы'} ${formatMoney(income)}',
        ].join(' · '),
      if (opening != null)
        kk
            ? 'Бастапқы қалдық енді ${_date(st.from)} күніне ${formatMoney(parseMinor(opening['new']))}.'
            : 'Начальный остаток теперь ${formatMoney(parseMinor(opening['new']))} на ${_date(st.from)}.',
      if (level != null)
        kk
            ? 'Қалдық үзінді көшірмемен теңестірілді: ${_date(st.to)} күніне ${_signed(parseMinor(level))} нақтылау.'
            : 'Остаток выровнен по выписке: уточнение остатка ${_signed(parseMinor(level))} на ${_date(st.to)}.'
      else if (now.gap != null && now.ops.isEmpty && !now.changesOpening) ...[
        _gapLine(st, now, kk, today: today),
        if (_canLevel(now))
          kk
              ? '«Теңестіру» батырмасын бассаңыз, айырма қалдықты нақтылау болып жазылады — шығыс та, кіріс те емес.'
              : 'Нажмите «Выровнять» — разница запишется уточнением остатка: это не расход и не доход.',
      ],
      if ((done['planned'] as int? ?? 0) > 0)
        kk ? 'Төленген деп белгіленген жоспарлы төлемдер: ${done['planned']}.' : 'Плановые платежи отмечены оплаченными: ${done['planned']}.',
      if (loans.isNotEmpty)
        kk
            ? 'Несие төлемдері жазылмады: $loans. Қолданбада белгілеңіз: «Бюджет» → төлем → «Төлеу» — сонда қарыз да азаяды.'
            : 'Платежи по кредитам не записаны: $loans. Отметьте их в приложении: «Бюджет» → платёж → «Оплатить» — тогда уменьшится и долг.',
      if (data['carry'] != null) kk ? 'Күндік лимиттің тасымалы бүгіннен қайта басталды.' : 'Перенос дневного лимита начат заново с сегодняшнего дня.',
      if (done['failure'] != null) '⚠ ${kk ? 'Бәрі жазылған жоқ' : 'Записано не всё'}: ${escapeHtml('${done['failure']}')}',
      if (count > 0) kk ? 'Санаттар мен жазбаларды қолданбада түзетуге болады.' : 'Категории и заметки можно поправить в приложении.',
    ].join('\n');
  }

  Buttons _savedButtons(String id, Map<String, dynamic> data, bool kk, ImportPlan now) {
    return [
      if (data['level'] == null && _canLevel(now)) [_button(kk ? 'Қалдықты банкпен теңестіру' : 'Выровнять остаток по выписке', 'i:$id:lvl')],
      [_button(kk ? '↩ Импортты болдырмау' : '↩ Отменить импорт', 'i:$id:undo')],
    ];
  }

  /// Нажатие кнопки под сообщением импорта: `i:<импорт>:<действие>[:<значение>]`.
  Future<String?> press(int chatId, int messageId, List<String> parts) async {
    if (parts.length < 3) return null;
    final id = parts[1];
    final arg = parts.length > 3 ? parts[3] : '';
    // Импорт принадлежит тому, к кому чат привязан сейчас, — как и черновик.
    final row = await db.execute(
      Sql.named('''
        SELECT i.user_id, i.data, i.status FROM telegram_imports i
        JOIN users u ON u.id = i.user_id AND u.telegram_chat_id = i.chat_id
        WHERE i.id = @id AND i.chat_id = @c'''),
      parameters: {'id': id, 'c': chatId},
    );
    const stale = 'Выписка устарела — пришлите файл ещё раз.';
    if (row.isEmpty) return stale;
    final userId = row.first[0].toString();
    final data = Map<String, dynamic>.from(row.first[1] as Map);
    final status = row.first[2] as String;
    final v = await ledger.view(userId);
    if (v == null) return stale;
    final kk = v.locale == 'kk';
    final st = BankStatement.fromJson(Map<String, dynamic>.from(data['statement'] as Map));
    final accounts = importAccounts(v);
    var account = data['account'] as String?;
    if (status == 'pending' && account != null && !accounts.any((a) => a.id == account)) account = null;
    final today = _today();

    Future<void> save({String? to}) => db.execute(
          Sql.named('UPDATE telegram_imports SET data = @d:jsonb, status = coalesce(@s, status) WHERE id = @id'),
          parameters: {'id': id, 'd': data, 's': to},
        );
    Future<void> showSummary(String accountId) async {
      final plan = planImport(st, v, accountId, id, today, links: importLinks(data));
      await telegram.edit(chatId, messageId, importSummaryText(st, plan, v, accountId, pro: await _isPro(userId), today: today), buttons: _summaryButtons(id, st, plan, accounts.length, kk));
    }

    Future<void> showSaved(String accountId) async {
      final fresh = await ledger.view(userId) ?? v;
      final now = planImport(st, fresh, accountId, id, today, links: importLinks(data));
      await telegram.edit(chatId, messageId, _savedText(st, data, fresh, accountId, now, today), buttons: _savedButtons(id, data, kk, now));
    }

    final gone = kk ? 'Бұл батырма енді жұмыс істемейді.' : 'Эта кнопка уже не действует.';
    switch (parts[2]) {
      case 'acc' when status == 'pending':
        await telegram.edit(chatId, messageId, _chooseText(st, kk), buttons: _accountButtons(id, accounts, kk, back: account != null));
        return null;
      case 'a' when status == 'pending':
        final i = int.tryParse(arg);
        if (i == null || i < 0 || i >= accounts.length) return stale;
        data['account'] = accounts[i].id;
        await save();
        await showSummary(accounts[i].id);
        return null;
      case 'back' when status == 'pending' && account != null:
        await showSummary(account);
        return null;
      case 'lk' when status == 'pending' && account != null:
        // `<строка>.<номер предложенного платежа>`: связь появляется только
        // здесь, по нажатию человека, и только на то, что предлагал план.
        final at = arg.split('.');
        final n = at.length == 2 ? int.tryParse(at[0]) : null;
        final k = at.length == 2 ? int.tryParse(at[1]) : null;
        final suggestion = n == null ? null : planImport(st, v, account, id, today, links: importLinks(data)).suggestions.where((s) => s.n == n).firstOrNull;
        if (n == null || k == null || suggestion == null || k < 0 || k >= suggestion.candidates.length) return gone;
        final mark = suggestion.candidates[k].mark;
        data['links'] = {
          ...(data['links'] as Map? ?? const {}),
          '$n': {'kind': mark.kind, 'id': mark.id, 'period': mark.period},
        };
        await save();
        await showSummary(account);
        return kk ? 'Байланыстырылды' : 'Связано';
      case 'ul' when status == 'pending' && account != null:
        final links = Map<String, dynamic>.from(data['links'] as Map? ?? const {})..remove(arg);
        data['links'] = links;
        await save();
        await showSummary(account);
        return kk ? 'Байланыс алынды' : 'Связь снята';
      case 'list' when status == 'pending' && account != null:
        await telegram.send(chatId, importListText(st, planImport(st, v, account, id, today, links: importLinks(data)), v));
        return null;
      case 'no' when status == 'pending':
        await save(to: 'cancelled');
        await telegram.edit(chatId, messageId, '✖ ${kk ? 'Үзінді көшірме жазылмады' : 'Выписка не записана'}\n<s>Kaspi · ${_period(st)}</s>');
        return null;
      case 'ok' when status == 'pending' && account != null:
        if (!await _isPro(userId)) return _offerPro(chatId, userId, kk);
        final error = await _apply(id, userId, st, account, data, v, today, save);
        if (error != null) return error;
        await save(to: 'saved');
        await showSaved(account);
        return kk ? 'Жазылды' : 'Записано';
      case 'ok' when status == 'saved' && account != null:
        await showSaved(account);
        return kk ? 'Жазылды' : 'Записано';
      case 'lvl' when (status == 'saved' || status == 'pending') && account != null:
        if (!await _isPro(userId)) return _offerPro(chatId, userId, kk);
        final error = await _level(id, userId, st, account, data, v, pending: status == 'pending', today: today);
        if (error != null) return error;
        await save(to: 'saved');
        await showSaved(account);
        return kk ? 'Теңестірілді' : 'Выровнено';
      case 'undo' when status == 'saved' && account != null:
        final error = await _undo(id, userId, account, data, v);
        if (error != null) return error;
        await save(to: 'undone');
        await telegram.edit(
          chatId,
          messageId,
          '↩ <b>${kk ? 'Импорт болдырылмады' : 'Импорт отменён'}</b>\n'
          '${kk ? 'Kaspi үзінді көшірмесі' : 'Выписка Kaspi'} · ${_period(st)}: '
          '${kk ? 'операциялар журналдан алынды' : 'операции убраны из журнала'}'
          '${data['opening'] != null ? (kk ? ', бастапқы қалдық қайтарылды' : ', начальный остаток возвращён') : ''}.',
        );
        return kk ? 'Болдырылмады' : 'Отменено';
      default:
        return gone;
    }
  }

  /// Команды уходят пачками. [units] — неделимые группы команд (операция и
  /// отметка её срока оплаченным пишутся только вместе). Id пачки зависит от
  /// её первой операции: повтор той же пачки журнал примет один раз, а пачка
  /// с другим содержимым после сбоя — это уже другая команда. Возвращает,
  /// сколько групп записано.
  Future<({int applied, String? failure})> _send(String userId, String prefix, List<List<Map<String, dynamic>>> units) async {
    var applied = 0;
    while (applied < units.length) {
      final part = <Map<String, dynamic>>[];
      var taken = 0;
      while (applied + taken < units.length && (taken == 0 || part.length + units[applied + taken].length <= chunk)) {
        part.addAll(units[applied + taken++]);
      }
      final key = part.map((c) => c['id']).whereType<String>().firstOrNull ?? 'profile';
      try {
        await ledger.command(userId, {'type': 'batch', 'commands': part, 'commandId': '$prefix-$key-${part.length}'});
        applied += taken;
      } on ApiError catch (e) {
        stderr.writeln('import: команда не принята — ${e.code} ${e.ledgerCode ?? ''}');
        return (applied: applied, failure: e.message ?? e.code);
      }
    }
    return (applied: applied, failure: null);
  }

  /// Записывает план. Возвращает текст ошибки, если не записано ничего.
  Future<String?> _apply(String id, String userId, BankStatement st, String account, Map<String, dynamic> data, LedgerView v, DateTime today, Future<void> Function() persist) async {
    final kk = v.locale == 'kk';
    final plan = planImport(st, v, account, id, today, links: importLinks(data));
    final opening = openingCommands(plan, st, account, id);
    final units = <List<Map<String, dynamic>>>[
      if (opening.isNotEmpty) opening,
      for (final o in plan.ops) [o.command, if (o.mark != null) markCommand(o.mark!)],
      if (plan.restartCarry)
        [
          {
            'type': 'updateProfile',
            'profile': {
              'dailyLimitSince': dateToJson(today),
              'dailyLimitHistory': [
                {'from': dateToJson(today), 'amount': parseMinor(v.profile['dailyLimit']).toString()},
              ],
            },
          },
        ],
    ];
    if (units.isEmpty) return kk ? 'Жазатын ештеңе жоқ.' : 'Записывать нечего.';

    // Что было до импорта, сохраняется раньше самой записи: если сервер
    // остановится посреди неё, «Отменить импорт» всё равно вернёт прежний
    // начальный остаток и перенос лимита.
    if (plan.changesOpening) {
      data['opening'] = {
        'old': [
          for (final t in plan.oldOpenings) {'id': t.id, 'date': dateToJson(t.date), 'amount': t.amountOn(account).toString()},
        ],
        'new': plan.newOpening.toString(),
      };
    }
    if (plan.restartCarry) {
      data['carry'] = {'since': v.profile['dailyLimitSince'], 'history': v.profile['dailyLimitHistory'], 'set': dateToJson(today)};
    }
    await persist();

    final sent = await _send(userId, 'imp-$id', units);
    if (plan.restartCarry && sent.applied < units.length) data.remove('carry');
    if (sent.applied == 0) {
      if (plan.changesOpening) data.remove('opening');
      await persist();
      return sent.failure ?? (kk ? 'Жазу мүмкін болмады.' : 'Не удалось записать.');
    }

    final written = plan.ops.take(max(0, sent.applied - (opening.isEmpty ? 0 : 1))).toList();
    data['applied'] = [...plan.written, for (final o in written) o.n];
    data['marks'] = [
      ...(data['marks'] as List? ?? const []),
      for (final o in written)
        if (o.mark != null) {'n': o.n, 'kind': o.mark!.kind, 'id': o.mark!.id, 'period': o.mark!.period},
    ];
    if (plan.loans.isNotEmpty) {
      data['loans'] = [
        for (final e in plan.loans) {'name': e.name, 'amount': st.rows[e.n].amount.abs().toString(), 'date': dateToJson(st.rows[e.n].date)},
      ];
    }
    data['done'] = {
      'count': written.length + plan.written.length,
      'expense': (-written.where((o) => o.command['type'] == 'expense').fold<int>(0, (s, o) => s + o.amount)).toString(),
      'income': written.where((o) => o.command['type'] == 'income').fold<int>(0, (s, o) => s + o.amount).toString(),
      'planned': written.where((o) => o.mark != null).length,
      if (sent.failure != null) 'failure': sent.failure,
    };
    return null;
  }

  /// Выравнивает остаток счёта на последний день выписки по банку — одной
  /// уточнением с причиной, как «Уточнить остаток» в приложении (O21).
  Future<String?> _level(String id, String userId, BankStatement st, String account, Map<String, dynamic> data, LedgerView v, {required bool pending, required DateTime today}) async {
    final kk = v.locale == 'kk';
    final gone = kk ? 'Бұл батырма енді жұмыс істемейді.' : 'Эта кнопка уже не действует.';
    if (data['level'] != null) return gone;
    // Выравнивать можно, когда записывать больше нечего: и сразу после
    // записи, и когда вся выписка уже была в журнале.
    final plan = planImport(st, v, account, id, today, links: importLinks(data));
    if (!_canLevel(plan)) return gone;
    if (pending) {
      data['done'] = {'count': 0, 'expense': '0', 'income': '0'};
      data['applied'] = plan.written;
    }
    final gap = plan.gap!;
    try {
      await ledger.command(userId, {
        'type': 'adjustment',
        'id': importLevelId(id),
        'date': dateToJson(st.to),
        'account': account,
        'delta': gap.toString(),
        'reason': kk ? 'Kaspi үзінді көшірмесімен салыстыру, ${_period(st)}' : 'Сверка с выпиской Kaspi за ${_period(st)}',
        'commandId': 'imp-$id-level',
      });
    } on ApiError catch (e) {
      return e.message ?? (kk ? 'Теңестіру мүмкін болмады.' : 'Не удалось выровнять.');
    }
    data['level'] = gap.toString();
    return null;
  }

  /// Отменяет импорт целиком: операции, отметки плановых платежей,
  /// выравнивание, начальный остаток и начало переноса лимита возвращаются
  /// к состоянию до записи.
  Future<String?> _undo(String id, String userId, String account, Map<String, dynamic> data, LedgerView v) async {
    final kk = v.locale == 'kk';
    final l = v.ledger;
    final marks = {for (final m in (data['marks'] as List? ?? const []).cast<Map>()) m['n'] as int: m};
    final units = <List<Map<String, dynamic>>>[];
    for (final n in (data['applied'] as List? ?? const []).cast<int>()) {
      final tx = l.byId(importRowId(id, n));
      if (tx == null) continue;
      // Операцию могли поправить в приложении — отменяется её действующая
      // версия; удалённую вручную не трогаем.
      final current = tx.type == EventType.refund ? (l.isReversed(tx.id) ? null : tx) : l.currentVersion(tx.id);
      if (current == null) continue;
      final unit = <Map<String, dynamic>>[
        {'type': 'reverse', 'txId': current.id, 'id': importUndoId(id, n)},
      ];
      // Срок планового платежа снова становится неоплаченным — если сам
      // платёж ещё есть в справочнике.
      final mark = marks[n];
      final entity = mark == null ? null : v.of(mark['kind'] as String)[mark['id']];
      if (mark != null && entity != null) {
        unit.add(markCommand((kind: mark['kind'] as String, id: mark['id'] as String, period: mark['period'] as String), paid: false));
      }
      units.add(unit);
    }
    final level = l.byId(importLevelId(id));
    if (level != null && !l.isReversed(level.id)) {
      units.add([
        {'type': 'reverse', 'txId': level.id, 'id': importUndoId(id, 'level')},
      ]);
    }

    final opening = data['opening'] as Map?;
    if (opening != null) {
      if (l.account(account).archived) {
        return kk ? 'Шот мұрағатта — импортты болдырмау үшін оны мұрағаттан шығарыңыз.' : 'Счёт в архиве — верните его из архива, чтобы отменить импорт.';
      }
      final newId = importOpeningId(id);
      final posted = l.byId(newId);
      // Действующая запись начального остатка — сама наша или её копия,
      // которую вернула отмена более позднего импорта. Если остаток с тех пор
      // стал другим, его заменил импорт, который ещё не отменён.
      final current = posted == null ? null : l.currentVersion(newId);
      if (posted != null && (current == null || current.date != posted.date || current.amountOn(account) != posted.amountOn(account))) {
        return kk
            ? 'Бұл импорттан кейін бастапқы қалдық тағы өзгерген. Алдымен кейінгі импортты болдырмаңыз.'
            : 'После этого импорта начальный остаток менялся ещё раз. Сначала отмените более поздний импорт.';
      }
      var k = 0;
      units.add([
        if (current != null) {'type': 'reverse', 'txId': current.id, 'id': importUndoId(id, 'open')},
        for (final o in (opening['old'] as List).cast<Map>())
          {
            'type': 'opening',
            'id': importUndoId(id, 'old${k++}'),
            'date': o['date'],
            'account': account,
            'amount': o['amount'],
            'meta': {'edited': current?.id ?? o['id']},
          },
      ]);
    }
    final carry = data['carry'] as Map?;
    if (carry != null && v.profile['dailyLimitSince'] == carry['set']) {
      units.add([
        {
          'type': 'updateProfile',
          'profile': {'dailyLimitSince': carry['since'], 'dailyLimitHistory': carry['history']},
        },
      ]);
    }
    units.removeWhere((u) => u.isEmpty);
    if (units.isEmpty) return null;
    final sent = await _send(userId, 'imp-$id-undo', units);
    return sent.failure;
  }
}
