/// Общие элементы интерфейса: суммы, карточки, заголовки, шкалы, поля.
library;

import 'dart:async';

import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../l10n/app_localizations.dart';
import '../../state/api_client.dart';
import '../../state/app_scope.dart';
import '../../state/app_state.dart';
import '../../state/models.dart';
import '../../theme/app_theme.dart';
import '../more/tariff_screen.dart';

extension L10nX on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);
}

/// Подпись категории по её идентификатору; история хранит id, не текст.
String categoryName(AppLocalizations l, String id) => switch (id) {
      'food' => l.catFood,
      'cafe' => l.catCafe,
      'transport' => l.catTransport,
      'health' => l.catHealth,
      'kids' => l.catKids,
      'home' => l.catHome,
      'utilities' => l.catUtilities,
      'phone' => l.catPhone,
      'household' => l.catHousehold,
      'fun' => l.catFun,
      'clothes' => l.catClothes,
      'education' => l.catEducation,
      'subscriptions' => l.catSubscriptions,
      'gifts' => l.catGifts,
      'salary' => l.catSalary,
      'side' => l.catSide,
      'cashback' => l.catCashback,
      'interest' => l.catInterest,
      'interestIncome' => l.catInterest,
      'fees' => l.catFees,
      'otherIncome' => l.catOtherIncome,
      'other' => l.catOther,
      debtsCategory => l.catDebts,
      _ => customCategories[id]?.name ?? l.catOther,
    };

String accountTypeName(AppLocalizations l, String type) => switch (type) {
      'cash' => l.typeCash,
      'deposit' => l.typeDeposit,
      'piggy' => l.piggy,
      _ => l.typeCard,
    };

IconData accountTypeIcon(String type) => switch (type) {
      'cash' => Icons.payments_outlined,
      'deposit' => Icons.account_balance_outlined,
      'piggy' => Icons.savings_outlined,
      _ => Icons.credit_card_outlined,
    };

String debtKindName(AppLocalizations l, String kind) => switch (kind) {
      'installment' => l.installment,
      'creditCard' => l.creditCard,
      _ => l.kindLoan,
    };

String roleName(AppLocalizations l, String role) => switch (role) {
      'spouse' => l.roleSpouse,
      'child' => l.roleChild,
      _ => l.roleOther,
    };

/// Текст ошибки сервера на языке пользователя.
String errorText(AppLocalizations l, Object e) {
  if (e is LedgerException) return ledgerErrorText(l, e.code) ?? e.message;
  if (e is! ApiException) return l.errUnknown;
  return switch (e.code) {
    'invalid_credentials' => e.attemptsLeft != null ? l.wrongPassword(e.attemptsLeft!) : l.errInvalidCredentials,
    'locked' => l.locked,
    'email_taken' => l.errEmailTaken,
    'weak_password' => l.errWeakPassword,
    'invalid_email' => l.errInvalidEmail,
    'plan_limit' => l.errPlanLimit,
    'ledger' => ledgerErrorText(l, e.ledgerCode) ?? e.message ?? l.errUnknown,
    'network' => l.errNetwork,
    'busy' || 'timeout' => l.errBusy,
    'rate_limited' => l.errRateLimited,
    'ai_quota' => l.aiQuotaOut,
    'ai_unavailable' => l.aiUnavailable,
    _ => l.errUnknown,
  };
}

/// Ошибка ядра по машинному коду — на языке пользователя; `null`, если код
/// неизвестен (тогда показывается русский текст ядра).
String? ledgerErrorText(AppLocalizations l, String? code) => switch (code) {
      'monthNotEnded' => l.monthNotEnded,
      'monthChanged' => l.monthChanged,
      'invalidId' => l.leInvalidId,
      'accountExists' => l.leAccountExists,
      'accountNotFound' => l.leAccountNotFound,
      'accountNotMoney' => l.leAccountNotMoney,
      'accountArchived' => l.leAccountArchived,
      'noPostings' => l.leNoPostings,
      'amountTooBig' => l.leAmountTooBig,
      'unbalanced' => l.leUnbalanced,
      'duplicateDifferent' => l.leDuplicateDifferent,
      'noSuchTransaction' => l.leNoSuchTransaction,
      'alreadyReversed' => l.leAlreadyReversed,
      'invalidAmount' => l.leInvalidAmount,
      'invalidGoal' => l.leInvalidGoal,
      'reserveExceedsFree' => l.leReserveExceedsFree,
      'reserveTooSmall' => l.leReserveTooSmall,
      'fieldMissing' => l.leFieldMissing,
      'noCategories' => l.leNoCategories,
      'invalidData' => l.leInvalidData,
      'adjustmentReason' => l.leAdjustmentReason,
      'unknownCommand' => l.leUnknownCommand,
      'invalidDate' => l.leInvalidDate,
      'amountNotPositive' => l.leAmountNotPositive,
      'noBonusWallet' => l.leNoBonusWallet,
      'notEnoughBonus' => l.leNotEnoughBonus,
      'sameAccounts' => l.leSameAccounts,
      'currencyMismatch' => l.leCurrencyMismatch,
      'negativeParts' => l.leNegativeParts,
      'repaymentExceeds' => l.leRepaymentExceeds,
      'principalExceeds' => l.lePrincipalExceeds,
      'downPaymentNegative' => l.leDownPaymentNegative,
      'downPaymentExceeds' => l.leDownPaymentExceeds,
      'noDownPaymentAccount' => l.leNoDownPaymentAccount,
      'refundMethod' => l.leRefundMethod,
      'purchaseCancelled' => l.lePurchaseCancelled,
      'refundExceeds' => l.leRefundExceeds,
      'zeroAdjustment' => l.leZeroAdjustment,
      'noPaymentSource' => l.leNoPaymentSource,
      'noPaymentAccount' => l.leNoPaymentAccount,
      'zeroRevaluation' => l.leZeroRevaluation,
      'restoreNotReversed' => l.leRestoreNotReversed,
      'alreadyRestored' => l.leAlreadyRestored,
      'hasRefunds' => l.leHasRefunds,
      _ => null,
    };

/// Выполняет команду и показывает ошибку, если она не прошла.
Future<bool> runAction(BuildContext context, Future<void> Function() action) async {
  final messenger = ScaffoldMessenger.of(context);
  final l = context.l10n;
  try {
    await action();
    return true;
  } on ReconciliationEditCancelled {
    return false;
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(errorText(l, e))));
    return false;
  }
}

/// Оценка (прогноз, модель графика) — до целого тенге: тиыны в прогнозе
/// создают ложное ощущение точности.
/// Сумма для вставки в предложение: пробелы неразрывные, чтобы «50 000 ₸» не
/// рвалось на две строки посреди числа.
String moneyInText(int minor) => formatMoney(minor).replaceAll(' ', '\u00A0');

String formatEstimate(int minor) => formatMoney(roundHalfUp(minor / minorPerUnit) * minorPerUnit);

/// Время операции для хранения в `meta['time']`: «09:14», всегда 24-часовое —
/// независимо от локали, как и остальные числа в приложении.
String timeToField(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

TimeOfDay? timeFromField(Object? v) {
  final m = v is String ? RegExp(r'^([0-2]?\d):([0-5]\d)$').firstMatch(v) : null;
  if (m == null) return null;
  final h = int.parse(m[1]!);
  return h > 23 ? null : TimeOfDay(hour: h, minute: int.parse(m[2]!));
}

/// Сумма из поля ввода в тиынах; `null`, если пусто или некорректно.
int? parseAmount(String text, {bool allowZero = false, bool allowNegative = false}) {
  final raw = text.replaceAll(RegExp(r'[\s ]'), '').replaceAll(',', '.');
  if (raw.isEmpty) return allowZero ? 0 : null;
  final v = double.tryParse(raw);
  if (v == null || !v.isFinite || (!allowNegative && v < 0) || (!allowZero && v == 0) || v.abs() > 1e12) return null;
  return kzt(v);
}

/// Сумма в тенге для поля ввода: `1250000` тиын → `12500`.
String amountToField(int minor) {
  final sign = minor < 0 ? '-' : '';
  final units = minor.abs() ~/ minorPerUnit;
  final frac = minor.abs() % minorPerUnit;
  return frac == 0 ? '$sign$units' : '$sign$units.${frac.toString().padLeft(2, '0')}';
}

class AmountField extends StatelessWidget {
  const AmountField({super.key, required this.controller, this.label, this.hint, this.autofocus = false, this.allowNegative = false, this.onChanged});
  final TextEditingController controller;
  final String? label;
  final String? hint;
  final bool autofocus;
  final bool allowNegative;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      autofocus: autofocus,
      keyboardType: TextInputType.numberWithOptions(decimal: true, signed: allowNegative),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(allowNegative ? r'[0-9\s.,-]' : r'[0-9\s.,]'))],
      onChanged: onChanged,
      decoration: InputDecoration(labelText: label, hintText: hint ?? '0', suffixText: '₸'),
      style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
    );
  }
}

/// Сумма с табличными цифрами: столбцы не «прыгают».
class MoneyText extends StatelessWidget {
  const MoneyText(this.minor, {super.key, this.style, this.color, this.sign = false});

  final int minor;
  final TextStyle? style;
  final Color? color;

  /// Показывать знак «+» для положительных сумм.
  final bool sign;

  @override
  Widget build(BuildContext context) {
    final base = style ?? DefaultTextStyle.of(context).style;
    final prefix = sign && minor > 0 ? '+' : '';
    return Text(
      '$prefix${formatMoney(minor)}',
      style: base.copyWith(
        color: color ?? base.color,
        fontWeight: FontWeight.w600,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// Крупная сумма главного показателя. Число «перетекает» к новому значению,
/// а не прыгает (250 мс, табличные цифры — ширина не дёргается).
class BigMoney extends StatelessWidget {
  const BigMoney(this.minor, {super.key, this.color});
  final int minor;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.displayMedium!;
    final c = color ?? style.color!;
    return TweenAnimationBuilder<double>(
      tween: Tween(end: minor.toDouble()),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      builder: (context, v, _) {
        // Промежуточные кадры — целые тенге, чтобы не мелькали случайные тиыны;
        // конечное значение показывается точно.
        final shown = (v - minor).abs() < 1 ? minor : (v / minorPerUnit).round() * minorPerUnit;
        return RichText(
        text: TextSpan(
          style: style.copyWith(color: c, fontFeatures: const [FontFeature.tabularFigures()]),
          children: [
            TextSpan(text: formatMoney(shown, symbol: '').trim()),
            TextSpan(text: ' ₸', style: style.copyWith(fontSize: 18, color: c.withValues(alpha: .7))),
          ],
        ),
      );
      },
    );
  }
}

/// Мягкое появление содержимого при первом показе; [index] — задержка
/// каскадом, чтобы карточки не вспыхивали разом.
class FadeIn extends StatefulWidget {
  const FadeIn({super.key, required this.child, this.index = 0});
  final Widget child;
  final int index;

  @override
  State<FadeIn> createState() => _FadeInState();
}

class _FadeInState extends State<FadeIn> with SingleTickerProviderStateMixin {
  Timer? _delay;
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 260));

  @override
  void initState() {
    super.initState();
    _delay = Timer(Duration(milliseconds: 40 * widget.index.clamp(0, 8)), () {
      if (mounted) _c.forward();
    });
  }

  @override
  void dispose() {
    _delay?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return widget.child;
    return FadeTransition(
      opacity: CurvedAnimation(parent: _c, curve: Curves.easeOut),
      child: SlideTransition(
        position: Tween(begin: const Offset(0, .04), end: Offset.zero).animate(CurvedAnimation(parent: _c, curve: Curves.easeOutCubic)),
        child: widget.child,
      ),
    );
  }
}

class AppCard extends StatelessWidget {
  const AppCard({super.key, required this.child, this.onTap, this.color, this.background, this.padding = const EdgeInsets.fromLTRB(16, 14, 16, 14)});
  final Widget child;
  final VoidCallback? onTap;
  final Color? color;
  final Widget? background;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final content = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Padding(padding: padding, child: child),
    );
    return Card(
      color: color,
      clipBehavior: Clip.antiAlias,
      child: background == null ? content : Stack(children: [
        Positioned.fill(child: IgnorePointer(child: ExcludeSemantics(child: background!))),
        content,
      ]),
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.action, this.onAction});
  final String title;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: Row(
        children: [
          Expanded(child: Text(title, style: Theme.of(context).textTheme.titleLarge)),
          if (action != null) TextButton(onPressed: onAction, child: Text(action!)),
        ],
      ),
    );
  }
}

/// Пустое состояние раздела: что здесь будет и как начать.
class EmptyHint extends StatelessWidget {
  const EmptyHint(this.text, {super.key, this.icon = Icons.inbox_outlined});
  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Row(children: [
        Icon(icon, color: context.fam.text2),
        const SizedBox(width: 12),
        Expanded(child: Text(text, style: TextStyle(color: context.fam.text2, fontSize: 13))),
      ]),
    );
  }
}

/// Горизонтальная шкала «потрачено / лимит»: сравнимая между категориями.
class UsageBar extends StatelessWidget {
  const UsageBar({super.key, required this.value, required this.max, this.color});
  final int value;
  final int max;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final fam = context.fam;
    final pct = max <= 0 ? (value > 0 ? 1.0 : 0.0) : (value / max).clamp(0.0, 1.0);
    final c = color ?? (pct >= 1 ? fam.expense : pct >= .8 ? fam.warn : context.scheme.primary);
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: LinearProgressIndicator(
        value: pct,
        minHeight: 8,
        backgroundColor: context.scheme.surfaceContainerHighest,
        color: c,
      ),
    );
  }
}

class CategoryAvatar extends StatelessWidget {
  const CategoryAvatar(this.icon, {super.key, this.color, this.size = 40});
  final IconData icon;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color ?? context.scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(size * .3),
      ),
      child: Icon(icon, size: size * .5, color: color == null ? context.scheme.onSurface : Colors.white),
    );
  }
}

class ProBadge extends StatelessWidget {
  const ProBadge({super.key});
  @override
  Widget build(BuildContext context) {
    final fam = context.fam;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: fam.accent, borderRadius: BorderRadius.circular(999)),
      child: Text('Pro', style: TextStyle(color: fam.onAccent, fontSize: 11, fontWeight: FontWeight.w700)),
    );
  }
}

/// Текущий тариф — всегда на виду; нажатие открывает экран тарифа.
class PlanChip extends StatelessWidget {
  const PlanChip({super.key, required this.pro, this.onTap});
  final bool pro;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final fam = context.fam;
    final l = context.l10n;
    return Semantics(
      button: true,
      label: '${l.tariff}: ${pro ? l.proPlan : l.freePlan}',
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: pro ? fam.accent : null,
            border: pro ? null : Border.all(color: fam.line),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(pro ? Icons.workspace_premium : Icons.workspace_premium_outlined, size: 14, color: pro ? fam.onAccent : fam.text2),
            const SizedBox(width: 4),
            Flexible(child: Text(pro ? l.proPlan : l.freeShort, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: pro ? fam.onAccent : fam.text2, fontSize: 12, fontWeight: FontWeight.w700))),
          ]),
        ),
      ),
    );
  }
}

/// Значок «ⓘ» рядом с непонятным пунктом: по нажатию — короткое
/// человеческое объяснение внизу экрана (D50).
class InfoTip extends StatelessWidget {
  const InfoTip(this.text, {super.key, this.title, this.color});
  final String text;
  final String? title;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return IconButton(
      tooltip: l.whatIsThis,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      icon: Icon(Icons.info_outline, size: 18, color: color ?? context.fam.text2),
      onPressed: () => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (ctx) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (title != null) ...[Text(title!, style: Theme.of(ctx).textTheme.headlineSmall), const SizedBox(height: 8)],
              Text(text, style: const TextStyle(fontSize: 15, height: 1.45)),
              const SizedBox(height: 16),
              FilledButton(onPressed: () => Navigator.pop(ctx), child: Text(l.gotIt)),
            ]),
          ),
        ),
      ),
    );
  }
}

/// «После этой операции счёт уйдёт в минус» (D87) — для любой формы, где
/// деньги уходят со счёта. Записать не мешает: человек знает о своих деньгах
/// больше приложения. [returned] — сколько вернётся на счёт той же командой
/// (правка уже записанной траты).
class MinusWarning extends StatelessWidget {
  const MinusWarning({super.key, required this.accountId, required this.amount, this.returned = 0});
  final String? accountId;
  final int? amount;
  final int returned;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context).state;
    final id = accountId;
    final sum = amount;
    if (id == null || sum == null || !state.ledger.hasAccount(id)) return const SizedBox.shrink();
    final after = state.ledger.balance(id) + returned - sum;
    if (after >= 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: InfoBanner(context.l10n.minusWarn(state.accountInfo(id)?.name ?? '', moneyInText(-after)), color: context.fam.warnBg, icon: Icons.warning_amber_outlined),
    );
  }
}

class InfoBanner extends StatelessWidget {
  const InfoBanner(this.text, {super.key, this.icon = Icons.info_outline, this.color});
  final String text;
  final IconData icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: color ?? context.fam.incomeBg, borderRadius: BorderRadius.circular(14)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }
}

/// Нижняя панель с формой: заголовок, прокрутка, отступ под клавиатуру.
Future<T?> showFormSheet<T>(BuildContext context, {required String title, required Widget Function(BuildContext) builder}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          Text(title, style: Theme.of(ctx).textTheme.headlineSmall),
          const SizedBox(height: 16),
          builder(ctx),
        ]),
      ),
    ),
  );
}

Future<bool> confirm(BuildContext context, {required String title, String? message, required String action}) async {
  final l = context.l10n;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: message == null ? null : Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.cancel)),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(action)),
      ],
    ),
  );
  return ok == true;
}

/// Один вопрос до записи. «Отмена» ничего не меняет, подтверждение сохраняет
/// операцию и пересчитывает зависимые остатки обычными формулами журнала.
Future<bool> confirmReconciliationRecalculation(BuildContext context, DateTime month) => confirm(
  context,
  title: context.l10n.monthRecalculateTitle,
  message: context.l10n.monthRecalculateBody(DateFormat('LLLL y', Localizations.localeOf(context).toString()).format(month)),
  action: context.l10n.monthRecalculateAction,
);

/// Выбор денежного счёта.
class AccountPicker extends StatelessWidget {
  const AccountPicker({super.key, required this.accounts, required this.value, required this.onChanged, this.label});
  final List<AccountInfo> accounts;
  final String? value;
  final ValueChanged<String> onChanged;
  final String? label;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      initialValue: accounts.any((a) => a.id == value) ? value : null,
      decoration: InputDecoration(labelText: label ?? context.l10n.account),
      items: [for (final a in accounts) DropdownMenuItem(value: a.id, child: Text(a.name))],
      onChanged: (v) => v == null ? null : onChanged(v),
    );
  }
}

/// Имя владельца счёта для показа: «Я», «Общее» или имя члена семьи.
String? ownerName(AppLocalizations l, AppState state, String? owner) => switch (owner) {
      null => null,
      'me' => l.me,
      'shared' => l.shared,
      _ => state.members.where((m) => m.id == owner).firstOrNull?.name,
    };

/// Чей счёт (семейный режим): «Я», «Общее», член семьи — или без привязки.
/// Форма операции подставляет это значение в «для кого», не заставляя
/// выбирать его на каждой записи заново.
class AccountOwnerPicker extends StatelessWidget {
  const AccountOwnerPicker({super.key, required this.value, required this.onChanged});
  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final state = AppScope.of(context).state;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text(l.accountOwner, style: TextStyle(fontSize: 12, color: context.fam.text2))),
        InfoTip(l.accountOwnerNote, title: l.accountOwner),
      ]),
      const SizedBox(height: 6),
      Wrap(spacing: 8, runSpacing: 4, children: [
        ChoiceChip(label: Text(l.unassigned), selected: value == null, onSelected: (_) => onChanged(null)),
        ChoiceChip(label: Text(l.me), selected: value == 'me', onSelected: (_) => onChanged('me')),
        ChoiceChip(label: Text(l.shared), selected: value == 'shared', onSelected: (_) => onChanged('shared')),
        for (final m in state.members) ChoiceChip(label: Text(m.name), selected: value == m.id, onSelected: (_) => onChanged(m.id)),
      ]),
    ]);
  }
}

class CategoryPicker extends StatelessWidget {
  const CategoryPicker({super.key, required this.options, required this.value, required this.onChanged, this.onAdd});
  final List<CategoryDef> options;
  final String value;
  final ValueChanged<String> onChanged;

  /// «＋ Своя»: создать категорию, не выходя из формы.
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Wrap(spacing: 8, runSpacing: 4, children: [
      for (final c in options)
        ChoiceChip(
          avatar: Icon(c.icon, size: 16, color: value == c.id ? context.scheme.onPrimary : null),
          label: Text(categoryName(l, c.id)),
          selected: value == c.id,
          onSelected: (_) => onChanged(c.id),
        ),
      if (onAdd != null) ActionChip(avatar: const Icon(Icons.add, size: 16), label: Text(l.ownCategory), onPressed: onAdd),
    ]);
  }
}

/// Список категорий для пикера с гарантией, что текущее значение в нём есть —
/// даже если категорию потом скрыли (иначе выбор в форме сломается).
List<CategoryDef> ensureIncluded(List<CategoryDef> options, String value) =>
    options.any((c) => c.id == value) ? options : [...options, categoryById(value)];

/// Диалог закрытой возможности.
Future<void> showProGate(BuildContext context, String message) {
  final l = context.l10n;
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (ctx) => SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const ProBadge(),
          const SizedBox(height: 8),
          Text(l.proTitle, style: Theme.of(ctx).textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(message, style: TextStyle(color: ctx.fam.text2)),
          const SizedBox(height: 16),
          AppCard(
            color: ctx.scheme.surfaceContainerHighest,
            child: Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('FamCoin Pro', style: TextStyle(fontWeight: FontWeight.w700)),
                Text(l.proSub, style: TextStyle(fontSize: 12, color: ctx.fam.text2)),
              ])),
              Text(l.proPrice, style: const TextStyle(fontWeight: FontWeight.w700)),
            ]),
          ),
          Text(l.proHow, style: TextStyle(fontSize: 12, color: ctx.fam.text2)),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: FilledButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const TariffScreen()));
                },
                child: Text(l.proBuy),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l.later)),
          ]),
        ],
      ),
    ),
  );
}
