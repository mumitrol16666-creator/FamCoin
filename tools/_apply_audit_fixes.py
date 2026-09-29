#!/usr/bin/env python3
"""One-shot source patch for FamCoin 63eb7df. Removed after application."""
from pathlib import Path
import hashlib
import json

expected = {
 'packages/famcoin_core/lib/src/ledger.dart': '1a871e378ab011bee880411d6a506da4b1b1acd3',
 'app/lib/state/app_state.dart': 'f638d88681d56bd3645a2a80fed6db51b8d99375',
 'server/lib/ledger_service.dart': '7106c717941c1b386251bea7dfd7303962372d33',
 'app/lib/ui/budget/sheets.dart': '28fa90ad0d065ea7d3fbebe741750d0357b7b6ba',
 'app/lib/ui/analytics/day_flow_chart.dart': '128ab1d7860603543c53120fab91051b1fb49141',
}
files = {}

def read(path):
    if path not in files:
        data = Path(path).read_bytes()
        if path in expected:
            actual = hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()
            if actual != expected[path]:
                raise RuntimeError(f'{path}: base changed; refusing to patch {actual}')
        files[path] = data.decode('utf-8')
    return files[path]

def replace(path, old, new):
    text = read(path)
    if text.count(old) != 1:
        raise RuntimeError(f'{path}: anchor not unique: {old[:120]!r}')
    files[path] = text.replace(old, new, 1)

def section(path, begin, end, new):
    text = read(path)
    if text.count(begin) != 1 or text.count(end) != 1:
        raise RuntimeError(f'{path}: section anchors not unique')
    a = text.index(begin)
    b = text.index(end, a)
    files[path] = text[:a] + new + text[b:]

ledger = 'packages/famcoin_core/lib/src/ledger.dart'
section(ledger, '  String purchaseRoot(String txId) {', '  /// Действующая (не отменённая)', '''  String purchaseRoot(String txId) {
    var id = txId;
    final visited = <String>{};
    while (visited.add(id)) {
      final meta = _byId[id]?.meta;
      // An edit of a restored record has both links. Both lead to the
      // same family; the immediate edit takes precedence.
      final prev = meta?['edited'] ?? meta?['restoredFrom'];
      if (prev is! String || prev.isEmpty || !_byId.containsKey(prev)) return id;
      id = prev;
    }
    throw LedgerException('Цикл в истории версий операции', code: 'invalidVersionChain');
  }

''')
replace(ledger, "  bool isRestored(String txId) =>\n      _transactions.any((t) => t.meta['restoredFrom'] == txId && !_reversed.contains(t.id));", '''  bool isRestored(String txId) {
    final root = purchaseRoot(txId);
    return _transactions.any((t) =>
        t.id != txId && t.type != EventType.reversal &&
        !_reversed.contains(t.id) && purchaseRoot(t.id) == root);
  }''')
replace(ledger, "  bool _supersededByEdit(String txId) => _transactions.any((t) => t.meta['edited'] == txId);", '''  bool _supersededByEdit(String txId) {
    // Only the most recent version may be offered in Trash. This also
    // covers restore -> delete -> restore chains, not just direct edits.
    final root = purchaseRoot(txId);
    var seen = false;
    for (final t in _transactions) {
      if (t.id == txId) {
        seen = true;
      } else if (seen && t.type != EventType.reversal && purchaseRoot(t.id) == root) {
        return true;
      }
    }
    return false;
  }''')
replace(ledger, "      case EventType.loanPayment:\n      case EventType.repaymentMade:\n        for (final p in original.postings) {", '''      case EventType.repaymentReceived:
        for (final p in original.postings) {
          if (_accounts[p.accountId]?.assetClass != AssetClass.receivable) continue;
          final principal = -p.amount;
          final owed = balance(p.accountId);
          if (principal > owed) {
            throw LedgerException('Возврат $principal больше требования $owed', code: 'repaymentExceeds');
          }
        }
      case EventType.loanPayment:
      case EventType.repaymentMade:
        for (final p in original.postings) {''')
replace('packages/famcoin_core/test/restore_test.dart', '''    // Удалили восстановленную копию — исходная снова в корзине.
    applyLedgerCommand(l, {'type': 'reverse', 'txId': 'e1-back', 'id': 'e1-back-rev'});
    expect(l.isDeleted('e1'), isTrue);
    expect(l.isDeleted('e1-back'), isTrue);''', '''    // Only the latest version of this logical operation belongs in Trash.
    applyLedgerCommand(l, {'type': 'reverse', 'txId': 'e1-back', 'id': 'e1-back-rev'});
    expect(l.isDeleted('e1'), isFalse);
    expect(l.isDeleted('e1-back'), isTrue);''')
files[ledger] = files[ledger].replace('_supersededByEdit', '_hasNewerVersion')

core_export = 'packages/famcoin_core/lib/famcoin_core.dart'
files[core_export] = read(core_export).rstrip() + "\nexport 'src/planned_commands.dart';\n"

server = 'server/lib/ledger_service.dart'
replace(server, "    if (ledgerCommandTypes.contains(type)) {", '''    if (plannedCommandTypes.contains(type)) {
      final id = c['plannedId'];
      if (id is! String || id.isEmpty || id.length > maxIdLength) {
        throw ApiError(400, 'bad_request');
      }
      final rows = await ctx.s.execute(
        Sql.named("SELECT data FROM entities WHERE user_id = @u AND kind = 'planned' AND id = @id FOR UPDATE"),
        parameters: {'u': ctx.userId, 'id': id},
      );
      if (rows.isEmpty) {
        throw LedgerException('План платежа не найден', code: 'plannedNotFound');
      }
      final latest = Map<String, dynamic>.from(rows.single[0] as Map);
      for (final part in expandPlannedCommand(c, latest)) {
        await _apply(ctx, part, depth: depth + 1);
      }
      return;
    }
    if (ledgerCommandTypes.contains(type)) {''')

state = 'app/lib/state/app_state.dart'
replace(state, "      case 'upsertEntity':\n        _entities.putIfAbsent", '''      case 'payPlannedPeriod':
      case 'setPlannedPeriodPaid':
        final latest = _kind('planned')[c['plannedId']];
        if (latest == null) throw LedgerException('План платежа не найден', code: 'plannedNotFound');
        for (final part in expandPlannedCommand(c, latest)) {
          _applyLocal(part);
        }
      case 'upsertEntity':
        _entities.putIfAbsent''')
replace(state, "Future<void> payDebt({required String debtId, required String account, required int principal, int interest = 0, DateTime? date}) =>\n      send({'type': 'loanPayment', 'id': newId(), 'date': _date(date ?? today), 'account': account, 'debtId': debtId, 'principal': principal.toString(), 'interest': interest.toString()});", "Future<void> payDebt({required String debtId, required String account, required int principal, int interest = 0, DateTime? date, String? id, String? commandId}) =>\n      send({'type': 'loanPayment', 'id': id ?? newId(), 'date': _date(date ?? today), 'account': account, 'debtId': debtId, 'principal': principal.toString(), 'interest': interest.toString()}, commandId: commandId);")
section(state, '  Future<void> payDue(DueItem due,', '  /// Исправление покупки:', '''  Future<void> payDue(DueItem due, {required String account, required int amount, int interest = 0, DateTime? date, String? id, String? commandId}) =>
      send({
        'type': 'payPlannedPeriod', 'id': id ?? newId(),
        'plannedId': due.planned.id, 'period': due.period,
        'date': _date(date ?? today), 'account': account,
        'amount': amount.toString(), 'interest': interest.toString(),
        'expectedDebtId': due.planned.debtId,
      }, commandId: commandId);

  Future<void> markDuePaid(DueItem due, {String? commandId}) => send({
        'type': 'setPlannedPeriodPaid', 'plannedId': due.planned.id,
        'period': due.period, 'paid': true,
      }, commandId: commandId);

''')
replace(state, "{'type': 'upsertEntity', 'kind': 'planned', 'entityId': p.id, 'data': p.toJson(paid: {...p.paid}..remove(period))},", "{'type': 'setPlannedPeriodPaid', 'plannedId': p.id, 'period': period, 'paid': false},")
replace(state, "{'type': 'upsertEntity', 'kind': 'planned', 'entityId': p.id, 'data': p.toJson(paid: {...p.paid, period})},", "{'type': 'setPlannedPeriodPaid', 'plannedId': p.id, 'period': period, 'paid': true},")
replace(state, 'if (p != null && p.paid.contains(period)) {', 'if (p != null) {')
replace(state, 'if (p != null && !p.paid.contains(period)) {', 'if (p != null) {')
replace(state, '[for (final d in bankDebts.where(_debtStillOwed)) _debtLoadInput(d)],\n      monthlyIncome:', '[for (final d in bankDebts) _debtLoadInput(d)],\n      monthlyIncome:')
replace(state, 'monthlyPayment: plannedForDebt(d.id)?.amount ?? 0,', 'monthlyPayment: _debtStillOwed(d) ? plannedForDebt(d.id)?.amount ?? 0 : 0,')
section(state, '  DateTime? get _firstActivityMonth {', '  /// Долг, по которому сейчас', '''  DateTime? get _firstActivityDay {
    DateTime? earliest;
    for (final tx in ledger.transactions) {
      if (tx.type == EventType.reversal || ledger.isReversed(tx.id) || tx.date.isAfter(today)) continue;
      if (earliest == null || tx.date.isBefore(earliest)) earliest = tx.date;
    }
    return earliest;
  }

  DateTime? get _firstActivityMonth {
    final day = _firstActivityDay;
    return day == null ? null : DateTime(day.year, day.month, 1);
  }

''')
replace(state, '''    final requestedStart = monthOf(-(months - 1));
    final firstMonth = _firstActivityMonth;
    final start = firstMonth != null && firstMonth.isAfter(requestedStart) ? firstMonth : requestedStart;''', '''    if (months <= 0) return null;
    final requestedStart = monthOf(-(months - 1));
    final firstDay = _firstActivityDay;
    if (firstDay == null) return null;
    final start = firstDay.isAfter(requestedStart) ? firstDay : requestedStart;''')

fake = 'app/test/audit_regression_test.dart'
replace(fake, "      case 'upsertEntity':\n        entities.putIfAbsent", '''      case 'payPlannedPeriod':
      case 'setPlannedPeriodPaid':
        final latest = entities['planned']?[c['plannedId']];
        if (latest == null) throw LedgerException('План платежа не найден', code: 'plannedNotFound');
        for (final part in expandPlannedCommand(c, latest)) {
          _apply(part);
        }
      case 'upsertEntity':
        entities.putIfAbsent''')

sheets = 'app/lib/ui/budget/sheets.dart'
replace(sheets, "import '../widgets/common.dart';", "import '../widgets/common.dart';\nimport 'payment_sheet.dart';")
section(sheets, '/// Оплата срока планового платежа', '/// Новая цель:', '''/// Payment forms keep one immutable attempt until its outcome is known.
Future<void> showPayDueSheet(BuildContext context, DueItem due) => showPaymentSheet(context, due: due);

Future<void> showBankPaySheet(BuildContext context, DebtInfo debt, {int? principal}) =>
    showPaymentSheet(context, bankDebt: debt, principal: principal);

Future<void> showPersonRepaySheet(BuildContext context, PersonDebt debt) =>
    showPaymentSheet(context, personDebt: debt);

''')
for language, hint, label in [
 ('ru', 'Ответ сервера не получен. Повторите проверку той же оплаты: сумма и счёт зафиксированы, новая операция не создаётся.', 'Повторить проверку оплаты'),
 ('kk', 'Сервердің жауабы алынбады. Сол төлемді қайта тексеріңіз: сома мен шот бекітілген, жаңа операция жасалмайды.', 'Төлемді қайта тексеру'),
]:
    path = f'app/lib/l10n/app_{language}.arb'
    text = read(path)
    at = text.rfind('}')
    files[path] = text[:at].rstrip() + f',\n  "paymentRetryHint": "{hint}",\n  "paymentRetryAction": "{label}"\n' + text[at:]

chart = 'app/lib/ui/analytics/day_flow_chart.dart'
section(chart, '                      Expanded(\n                        child: Align(\n                          alignment: Alignment.bottomCenter,', '                      Expanded(\n                        child: Align(\n                          alignment: Alignment.topCenter,', '''                      Expanded(
                        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                          Expanded(child: Align(
                            alignment: Alignment.bottomCenter,
                            child: Container(
                              key: ValueKey('day-$i-income'),
                              margin: const EdgeInsets.symmetric(horizontal: 1),
                              height: income[i] <= 0 ? 0 : (4 + (height / 2 - 6) * income[i] / scale).clamp(0, height / 2 - 2).toDouble(),
                              decoration: BoxDecoration(color: fam.income.withValues(alpha: selectedDay == i || todayIndex == i ? 1 : .55),
                                  borderRadius: const BorderRadius.vertical(top: Radius.circular(2))),
                            ),
                          )),
                          if (expense[i] < 0)
                            Expanded(child: Align(
                              alignment: Alignment.bottomCenter,
                              child: Container(
                                key: ValueKey('day-$i-refund'),
                                margin: const EdgeInsets.symmetric(horizontal: 1),
                                height: (4 + (height / 2 - 6) * -expense[i] / scale).clamp(0, height / 2 - 2).toDouble(),
                                decoration: BoxDecoration(color: fam.accent,
                                    borderRadius: const BorderRadius.vertical(top: Radius.circular(2))),
                              ),
                            )),
                        ]),
                      ),
''')
replace(chart, "height: expense[i] == 0 ? 0 : (4 + (height / 2 - 6) * expense[i].abs() / scale).clamp(0, height / 2 - 2).toDouble(),", "key: ValueKey('day-$i-expense'),\n                            height: expense[i] <= 0 ? 0 : (4 + (height / 2 - 6) * expense[i] / scale).clamp(0, height / 2 - 2).toDouble(),")
replace(chart, '''                            // Возврат может сделать расход дня отрицательным
                            // (в пределах месяца это редкость, межмесячный —
                            // обычное дело); столбик по модулю, а не 0 —
                            // иначе день с одним возвратом выглядит пустым,
                            // будто в нём вообще ничего не было (F05).''', '''                            // Only positive net expense points down. Net refunds
                            // have their own upward series in the top half.''')
replace('app/lib/ui/analytics/overview_tab.dart', '              _legendDot(fam.expense, l.reportExpense),', '              _legendDot(fam.expense, l.reportExpense),\n              _legendDot(fam.accent, l.refund),')
replace('app/test/analytics_state_test.dart', '''    // Знаменатель — все наблюдаемые дни месяца с начала учёта ДО СЕГОДНЯ
    // включительно (сегодня 20 сентября, F13 и повторный аудит F04 — дни
    // после сегодня ещё не наступили и не могут быть «обычными днями без
    // трат»), а не только дни, когда что-то потрачено: 1 день дохода
    // (40000 ₸), 19 обычных (20000 ₸ на двоих, остальные 17 — без трат, но
    // считаются).
    expect(s.paydaySpendRatio(), closeTo(40000 / (20000 / 19), 0.001));''', '''    // First observed day is September 10, today is September 20:
    // one income day and ten other observed days. September 1-9 is unknown.
    expect(s.paydaySpendRatio(), closeTo(40000 / (20000 / 10), 0.001));''')

messages = {
 'lePeriodAlreadyPaid': ('Этот период уже оплачен. Обновите данные.', 'Бұл кезең төленген. Деректерді жаңартыңыз.'),
 'lePlannedChanged': ('План платежа изменён. Обновите данные.', 'Төлем жоспары өзгерді. Деректерді жаңартыңыз.'),
 'lePlannedNotFound': ('План платежа не найден.', 'Төлем жоспары табылмады.'),
 'leInvalidVersionChain': ('Ошибка истории операции. Обратитесь в поддержку.', 'Операция тарихында қате бар. Қолдау қызметіне хабарласыңыз.'),
}
for index, language in enumerate(['ru', 'kk']):
    path = f'app/lib/l10n/app_{language}.arb'
    text = read(path)
    at = text.rfind('}')
    extra = ',\n'.join('  ' + json.dumps(k) + ': ' + json.dumps(v[index], ensure_ascii=False) for k, v in messages.items())
    files[path] = text[:at].rstrip() + ',\n' + extra + '\n' + text[at:]
    json.loads(files[path])
replace('app/lib/ui/widgets/common.dart', "      'hasRefunds' => l.leHasRefunds,", "      'hasRefunds' => l.leHasRefunds,\n      'periodAlreadyPaid' => l.lePeriodAlreadyPaid,\n      'plannedChanged' => l.lePlannedChanged,\n      'plannedNotFound' => l.lePlannedNotFound,\n      'invalidVersionChain' => l.leInvalidVersionChain,")

# Do not write anything until every base check and every anchor succeeded.
for path, text in files.items():
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text, encoding='utf-8')
    print(f'updated {path}')
