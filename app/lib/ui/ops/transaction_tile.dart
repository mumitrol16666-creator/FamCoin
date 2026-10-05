import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../l10n/app_localizations.dart';
import '../../state/app_scope.dart';
import '../../state/app_state.dart';
import '../../state/models.dart';
import '../../theme/app_theme.dart';
import '../budget/debt_screens.dart';
import '../widgets/common.dart';
import 'edit_transaction_sheet.dart';

/// Как операция выглядит для человека: заголовок, подпись, сумма, знак.
/// Всё выводится из проводок, а не из отдельно хранимого текста.
class TxView {
  TxView({required this.title, required this.subtitle, required this.amount, required this.icon, required this.kind, this.emoji});
  final String title;
  final List<String> subtitle;
  final int amount;
  final IconData icon;

  /// Свой смайлик категории вместо значка (D107).
  final String? emoji;

  /// `expense`, `income`, `neutral`, `debt`.
  final String kind;

  static TxView of(AppState state, AppLocalizations l, Transaction tx) {
    final ledger = state.ledger;
    String? money;
    var moneyDelta = 0;
    final cats = <String>[];
    var expense = 0;
    var income = 0;
    var liability = 0;
    String? other;
    for (final p in tx.postings) {
      final a = ledger.account(p.accountId);
      if (a.isMoney) {
        money ??= p.accountId;
        moneyDelta += p.amount;
      } else if (a.kind == LedgerKind.expense) {
        cats.add(p.accountId.substring(8));
        expense += p.amount;
      } else if (a.kind == LedgerKind.income) {
        cats.add(p.accountId.substring(7));
        income += p.amount;
      } else if (a.kind == LedgerKind.liability) {
        liability += p.amount;
        other = p.accountId.substring(10);
      } else if (a.assetClass == AssetClass.receivable) {
        other = p.accountId.substring(11);
      }
    }
    final note = tx.meta['note'] as String? ?? '';
    final who = tx.meta['who'] as String?;
    final accountName = money == null ? null : state.accountInfo(money)?.name;
    String? whoName;
    if (state.familyMode && who != null && who != 'me') {
      whoName = who == 'shared' ? l.shared : state.members.where((m) => m.id == who).firstOrNull?.name;
    }

    if (tx.type == EventType.reversal) {
      final orig = tx.reverses == null ? null : ledger.byId(tx.reverses!);
      final base = orig == null ? l.cancelled : TxView.of(state, l, orig).title;
      return TxView(title: '${l.cancelled}: $base', subtitle: [?accountName], amount: moneyDelta, icon: Icons.history, kind: 'neutral');
    }
    switch (tx.type) {
      case EventType.expense:
        return TxView(
          title: cats.map((c) => categoryName(l, c)).join(' + '),
          // Отметка первой: подпись в одну строку обрезается с конца, а отметка важнее счёта.
          subtitle: [if (tx.meta['unexpected'] == true) l.unexpectedTag else if (tx.meta['plannedPurchase'] == true) l.plannedPurchaseTag, if (note.isNotEmpty) note, ?accountName, ?whoName],
          amount: -expense,
          icon: categoryById(cats.first).icon,
          emoji: categoryById(cats.first).hasEmoji ? categoryById(cats.first).emoji : null,
          kind: 'expense',
        );
      case EventType.income:
        return TxView(
          title: categoryName(l, cats.first),
          subtitle: [if (note.isNotEmpty) note, ?accountName],
          amount: income,
          icon: categoryById(cats.first).icon,
          emoji: categoryById(cats.first).hasEmoji ? categoryById(cats.first).emoji : null,
          kind: 'income',
        );
      case EventType.transfer:
        final from = tx.postings.firstWhere((p) => p.amount < 0 && ledger.account(p.accountId).isMoney).accountId;
        final to = tx.postings.firstWhere((p) => p.amount > 0 && ledger.account(p.accountId).isMoney);
        return TxView(
          title: l.transfer,
          subtitle: ['${state.accountInfo(from)?.name} → ${state.accountInfo(to.accountId)?.name}'],
          amount: to.amount,
          icon: Icons.swap_horiz,
          kind: 'neutral',
        );
      case EventType.loanPayment:
      case EventType.repaymentMade:
        final bank = other == null ? null : state.bankDebt(other);
        return TxView(
          title: bank?.name ?? '${l.iReturned} · $other',
          subtitle: [if (liability != 0) '${l.principalShort} ${formatMoney(-liability)}', if (expense > 0) '${l.catInterest} ${formatMoney(expense)}', ?accountName],
          amount: moneyDelta,
          icon: bank != null ? Icons.account_balance_outlined : Icons.handshake_outlined,
          kind: 'expense',
        );
      case EventType.lendOut:
      case EventType.borrow:
      case EventType.repaymentReceived:
        final label = switch (tx.type) {
          EventType.lendOut => l.lendOut,
          EventType.borrow => l.borrow,
          _ => l.returnedToMe,
        };
        return TxView(title: '$label · $other', subtitle: [?accountName], amount: moneyDelta, icon: Icons.handshake_outlined, kind: 'debt');
      case EventType.refund:
        return TxView(
          title: '${l.refund} · ${cats.map((c) => categoryName(l, c)).join(' + ')}',
          subtitle: [if (note.isNotEmpty) note, ?accountName],
          amount: moneyDelta,
          icon: Icons.undo,
          kind: 'income',
        );
      case EventType.adjustment:
        return TxView(
          title: l.adjustment,
          subtitle: [if (tx.meta['reason'] is String) tx.meta['reason'] as String, ?accountName],
          amount: moneyDelta,
          icon: Icons.tune,
          kind: 'neutral',
        );
      case EventType.opening:
        return TxView(title: l.openingBalance, subtitle: [?accountName], amount: moneyDelta, icon: Icons.flag_outlined, kind: 'neutral');
      case EventType.writeOff:
        // Списание долга (Ж6): «не вернут» — расход, «простили» — доход; счёт не назван, денег не было.
        final forgiven = tx.meta['side'] == 'liability';
        final person = tx.meta['person'] as String? ?? other ?? '';
        return TxView(
          title: '${forgiven ? l.debtForgiven : l.debtWrittenOff} · $person',
          subtitle: [if (note.isNotEmpty) note],
          // Не доход и не расход (D124): сумма закрытого долга без знака.
          amount: tx.postings.where((p) => p.amount < 0 || forgiven).map((p) => p.amount.abs()).fold(0, (a, b) => a > b ? a : b),
          icon: Icons.handshake_outlined,
          kind: 'neutral',
        );
      case EventType.creditPurchase:
        return TxView(
          title: cats.map((c) => categoryName(l, c)).join(' + '),
          subtitle: [l.installment, if (note.isNotEmpty) note],
          amount: -expense,
          icon: categoryById(cats.first).icon,
          emoji: categoryById(cats.first).hasEmoji ? categoryById(cats.first).emoji : null,
          kind: 'expense',
        );
      default:
        return TxView(title: tx.type.name, subtitle: [?accountName], amount: moneyDelta, icon: Icons.receipt_long_outlined, kind: 'neutral');
    }
  }
}

class TransactionTile extends StatelessWidget {
  const TransactionTile(this.tx, {super.key});
  final Transaction tx;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final fam = context.fam;
    final state = AppScope.of(context).state;
    final v = TxView.of(state, l, tx);
    final color = switch (v.kind) {
      'expense' => fam.expense,
      'income' => fam.income,
      'debt' => fam.debt,
      _ => null,
    };
    // Удалённая запись (корзина): зачёркнута, но нажатие открывает
    // восстановление. Сама отменяющая запись — только для истории.
    final deleted = state.ledger.isDeleted(tx.id);
    final cancelled = state.ledger.isReversed(tx.id) || tx.type == EventType.reversal;
    final time = timeFromField(tx.meta['time']);
    final subtitle = [if (time != null) timeToField(time), if (deleted) l.deletedMark, ...v.subtitle];
    return ListTile(
      contentPadding: EdgeInsets.zero,
      enabled: !cancelled || deleted,
      leading: CategoryAvatar(deleted ? Icons.restore_from_trash_outlined : v.icon, emoji: deleted ? null : v.emoji),
      title: Text(v.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: cancelled ? TextStyle(decoration: TextDecoration.lineThrough, color: fam.text2) : null),
      subtitle: subtitle.isEmpty ? null : Text(subtitle.join(' · '), style: TextStyle(fontSize: 12, color: fam.text2), maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: MoneyText(v.amount, sign: v.kind != 'expense' && (v.kind != 'neutral' || tx.type == EventType.adjustment), color: cancelled ? fam.text2 : color),
      onTap: deleted
          ? () => showRestoreSheet(context, tx)
          : cancelled
              ? null
              : () => showTransactionSheet(context, tx),
    );
  }
}

/// Корзина: карточка удалённой операции с восстановлением.
Future<void> showRestoreSheet(BuildContext context, Transaction tx) {
  final l = context.l10n;
  final state = AppScope.of(context).state;
  final locale = Localizations.localeOf(context).toString();
  final v = TxView.of(state, l, tx);
  return showFormSheet<void>(
    context,
    title: '${l.deletedMark}: ${v.title}',
    builder: (ctx) {
      final fam = ctx.fam;
      final time = timeFromField(tx.meta['time']);
      Widget row(String a, String b) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(children: [Expanded(child: Text(a, style: TextStyle(color: fam.text2))), Text(b)]),
          );
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Center(child: BigMoney(v.amount)),
        const SizedBox(height: 12),
        row(l.date, '${DateFormat.yMMMMd(locale).format(tx.date)}${time == null ? '' : ' · ${timeToField(time)}'}'),
        for (final s in v.subtitle) row('', s),
        const SizedBox(height: 8),
        InfoBanner(l.restoreNote, icon: Icons.restore_from_trash_outlined),
        const SizedBox(height: 12),
        FilledButton.icon(
          icon: const Icon(Icons.restore),
          label: Text(l.restore),
          onPressed: () async {
            final nav = Navigator.of(ctx);
            if (await runAction(ctx, () => state.restoreTransaction(tx.id))) nav.pop();
          },
        ),
      ]);
    },
  );
}

/// S11 — карточка операции: детали, проводки, удаление с сохранением истории.
Future<void> showTransactionSheet(BuildContext context, Transaction tx) {
  final l = context.l10n;
  final state = AppScope.of(context).state;
  final locale = Localizations.localeOf(context).toString();
  final v = TxView.of(state, l, tx);
  return showFormSheet<void>(
    context,
    title: v.title,
    builder: (ctx) {
      final fam = ctx.fam;
      final time = timeFromField(tx.meta['time']);
      Widget row(String a, String b) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(children: [Expanded(child: Text(a, style: TextStyle(color: fam.text2))), Text(b)]),
          );
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Center(child: BigMoney(v.amount)),
        const SizedBox(height: 12),
        row(l.date, '${DateFormat.yMMMMd(locale).format(tx.date)}${time == null ? '' : ' · ${timeToField(time)}'}'),
        if (tx.type == EventType.transfer) ...[
          // Откуда и куда — отдельными строками: это главное, что нужно знать о переводе.
          for (final (label, positive) in [(l.fromAccount, false), (l.toAccount, true)])
            row(
              label,
              state.accountInfo(tx.postings.firstWhere((p) => (p.amount > 0) == positive && state.ledger.account(p.accountId).isMoney).accountId)?.name ?? '',
            ),
        ] else
          for (final s in v.subtitle) row('', s),
        if (tx.type == EventType.lendOut) InfoBanner(l.debtNote),
        if (tx.type == EventType.opening) InfoBanner(l.openingNote),
        if (tx.type == EventType.adjustment) InfoBanner(l.adjustmentNote),
        if (tx.meta['edited'] != null) Text(l.editedMark, style: TextStyle(fontSize: 12, color: fam.text2)),
        const SizedBox(height: 12),
        if (tx.type == EventType.expense || tx.type == EventType.income)
          FilledButton.tonalIcon(
            icon: const Icon(Icons.edit_outlined),
            label: Text(tx.type == EventType.expense ? l.editOrSplit : l.edit),
            onPressed: () {
              Navigator.pop(ctx);
              showEditTransactionSheet(context, tx);
            },
          ),
        if (tx.type == EventType.expense) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.undo),
            label: Text(l.refund),
            onPressed: () {
              Navigator.pop(ctx);
              showRefundSheet(context, tx);
            },
          ),
        ],
        if (_debtLink(state, tx) case final link?) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.handshake_outlined),
            label: Text(l.openDebt),
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.push(context, MaterialPageRoute(builder: (_) => link));
            },
          ),
        ],
        const SizedBox(height: 8),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(foregroundColor: fam.expense),
          icon: const Icon(Icons.delete_outline),
          label: Text(l.delete),
          onPressed: () async {
            final nav = Navigator.of(ctx);
            if (!await confirm(ctx, title: l.confirmDelete, message: l.deleteHint, action: l.delete)) return;
            if (!ctx.mounted) return;
            if (await runAction(ctx, () => state.deleteTransaction(tx.id))) nav.pop();
          },
        ),
      ]);
    },
  );
}

/// Экран долга, к которому относится операция.
Widget? _debtLink(AppState state, Transaction tx) {
  for (final p in tx.postings) {
    final a = state.ledger.account(p.accountId);
    if (a.kind == LedgerKind.liability) {
      final id = p.accountId.substring(10);
      return state.bankDebt(id) != null ? BankDebtScreen(debtId: id) : PersonDebtScreen(person: id);
    }
    if (a.assetClass == AssetClass.receivable) return PersonDebtScreen(person: p.accountId.substring(11));
  }
  return null;
}
