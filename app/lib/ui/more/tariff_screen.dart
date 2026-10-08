import 'dart:async';

import 'package:famcoin_core/famcoin_core.dart' show PlanAccess, PlanFeature, formatMoney, planMatrix;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../state/api_client.dart';
import '../../state/app_scope.dart';
import '../../theme/app_theme.dart';
import '../widgets/common.dart';
import 'pro_celebration.dart';

/// Сборка для App Store: покупка внутри приложения скрыта, Pro оформляется
/// на сайте (правила магазина о цифровых покупках). `--dart-define=STORE_BUILD=true`.
const storeBuild = bool.fromEnvironment('STORE_BUILD');

/// S37 — тариф: сравнение, покупка Pro звёздами Telegram (D52), срок, платежи.
class TariffScreen extends StatefulWidget {
  const TariffScreen({super.key});

  @override
  State<TariffScreen> createState() => _TariffScreenState();
}

class _TariffScreenState extends State<TariffScreen> {
  Map<String, dynamic>? _billing;
  bool _busy = false;

  bool _requested = false;

  // Не в initState: AppScope — унаследованный виджет, обращаться к нему до
  // конца initState нельзя (в отладочной сборке это падение).
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_requested) return;
    _requested = true;
    _loadBilling();
  }

  Future<void> _loadBilling() async {
    final scope = AppScope.of(context);
    try {
      final b = await scope.settings.api.billing(scope.state.token);
      if (mounted) setState(() => _billing = b);
    } on ApiException {
      // Без данных о цене экран всё равно показывает сравнение тарифов.
    }
  }

  /// Открывает счёт в Telegram и ждёт, пока сервер отметит оплату.
  Future<void> _buy() async {
    if (_busy) return;
    final l = context.l10n;
    final scope = AppScope.of(context);
    final state = scope.state;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    String url;
    try {
      url = await scope.settings.api.billingInvoice(state.token);
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.code == 'telegram_unavailable' ? l.proUnavailable : errorText(l, e))));
      if (mounted) setState(() => _busy = false);
      return;
    }
    final uri = Uri.parse(url);
    final wasPro = state.pro;
    final wasUntil = state.proUntil;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!mounted) return;

    var paid = false;
    var cancelled = false;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        Timer? timer;
        var ticks = 0;
        return StatefulBuilder(builder: (ctx, set) {
          timer ??= Timer.periodic(const Duration(seconds: 3), (t) async {
            if (++ticks > 200) {
              t.cancel();
              if (ctx.mounted) Navigator.pop(ctx);
              return;
            }
            try {
              await state.refresh();
            } on ApiException {
              return;
            }
            if (state.pro && (!wasPro || state.proUntil != wasUntil)) {
              paid = true;
              t.cancel();
              if (ctx.mounted) Navigator.pop(ctx);
            }
          });
          return PopScope(
            canPop: false,
            onPopInvokedWithResult: (_, __) => timer?.cancel(),
            child: AlertDialog(
              title: Text(l.proWaitingTitle),
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                const SizedBox(height: 4),
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(l.proWaiting, textAlign: TextAlign.center),
              ]),
              actions: [
                TextButton(onPressed: () => launchUrl(uri, mode: LaunchMode.externalApplication), child: Text(l.tgOpenAgain)),
                TextButton(
                  onPressed: () {
                    cancelled = true;
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
    if (!mounted) return;
    setState(() => _busy = false);
    if (paid) {
      _loadBilling();
      await showProCelebration(context, until: state.proUntil); // сцена «Pro включён» (D110)
    } else {
      // Могли закрыть окно раньше, чем пришло подтверждение — проверим ещё раз.
      try {
        await state.refresh();
      } on ApiException {
        // сеть; экран покажет прежние данные
      }
      if (mounted && !(state.pro && (!wasPro || state.proUntil != wasUntil))) {
        // «Отмена» — молча; истёкшее ожидание — подсказка, что делать.
        if (!cancelled) messenger.showSnackBar(SnackBar(content: Text(l.proTimeout)));
      } else if (mounted) {
        _loadBilling();
        await showProCelebration(context, until: state.proUntil);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final state = AppScope.of(context).state;
    final fam = context.fam;
    final locale = Localizations.localeOf(context).toString();
    String date(DateTime d) => DateFormat.yMMMMd(locale).format(d);

    // Строки — из общей матрицы тарифа (UI03): те же правила проверяют
    // приложение и сервер, поэтому таблица не обещает лишнего и не прячет
    // доступное.
    String name(PlanFeature f) => switch (f) {
          PlanFeature.manual => l.tManual,
          PlanFeature.accounts => l.accounts,
          PlanFeature.limits => l.limits,
          PlanFeature.goals => l.tGoals,
          PlanFeature.debts => l.tDebts,
          PlanFeature.reports => l.tReports,
          PlanFeature.compare => l.tCompare,
          PlanFeature.early => l.tEarly,
          PlanFeature.voice => l.tVoice,
          PlanFeature.statementImport => l.tImport,
          PlanFeature.ai => l.ai,
          PlanFeature.family => l.tFamily,
          PlanFeature.history => l.tHistory,
        };
    String cell(PlanAccess a) => a.previewOnly
        ? l.tPreview
        : !a.allowed
            ? '—'
            : a.limit != null
                ? '${a.limit}'
                : a.perMonth != null
                    ? l.tPerMonth(a.perMonth!)
                    : a.unlimited
                        ? '∞'
                        : '✓';
    final rows = <(String, String, String)>[
      for (final e in planMatrix.entries) (name(e.key), cell(e.value.$1), e.key == PlanFeature.ai ? (_billing?['aiChatQuota'] is int ? l.tPerMonth(_billing!['aiChatQuota'] as int) : '✓') : cell(e.value.$2)),
    ];

    final stars = _billing?['stars'] as int?;
    // Ориентир в тенге приходит с сервера вместе с ценой в звёздах.
    final priceTenge = _billing?['priceTenge'] as int?;
    final available = _billing == null ? true : _billing!['available'] == true;
    final payments = (_billing?['payments'] as List?)?.cast<Map<String, dynamic>>() ?? const [];

    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final pro = state.pro;
        final until = state.proUntil;
        // Бессрочный Pro (выдан вручную) продлевать нечем.
        final canBuy = !storeBuild && !(pro && until == null);
        return Scaffold(
          appBar: AppBar(title: Text(l.tariff)),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            children: [
              AppCard(
                color: context.scheme.primary,
                child: DefaultTextStyle(
                  style: TextStyle(color: context.scheme.onPrimary),
                  child: Row(children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('FamCoin Pro', style: Theme.of(context).textTheme.headlineSmall!.copyWith(color: context.scheme.onPrimary)),
                        Text(priceTenge == null ? l.proSub : l.proSubMonthly(formatMoney((priceTenge / 12).round() * 100)), style: const TextStyle(fontSize: 13)),
                      ]),
                    ),
                    Text(priceTenge == null ? l.proPrice : l.proPriceYear(formatMoney(priceTenge * 100)), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                  ]),
                ),
              ),

              // Текущий тариф и покупка
              AppCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${l.currentPlan}: ${pro ? l.proPlan : l.freePlan}', style: const TextStyle(fontWeight: FontWeight.w700)),
                        if (pro)
                          Text(until == null ? l.proForever : l.proUntilLabel(date(until)), style: TextStyle(fontSize: 13, color: fam.text2)),
                      ]),
                    ),
                    if (pro) const ProBadge(),
                  ]),
                  if (canBuy) ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: available && !_busy ? _buy : null,
                        icon: _busy
                            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.send_rounded),
                        label: Text(pro ? l.proRenew : l.proBuy),
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (!available)
                      Text(l.proUnavailable, style: TextStyle(fontSize: 12, color: fam.text2))
                    else ...[
                      if (stars != null)
                        Text(l.proStarsPrice(stars, formatMoney((priceTenge ?? 10000) * 100)), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: context.scheme.primary)),
                      const SizedBox(height: 4),
                      Text(l.proHow, style: TextStyle(fontSize: 12, color: fam.text2)),
                    ],
                  ],
                  if (storeBuild) ...[
                    const SizedBox(height: 8),
                    Text(l.proSiteNote, style: TextStyle(fontSize: 12, color: fam.text2)),
                  ],
                ]),
              ),

              // Сравнение
              AppCard(
                child: Column(children: [
                  Row(children: [
                    const Expanded(child: SizedBox()),
                    SizedBox(width: 72, child: Text(l.freePlan, textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: fam.text2))),
                    const SizedBox(width: 72, child: Center(child: ProBadge())),
                  ]),
                  const SizedBox(height: 6),
                  for (final (name, free, proMark) in rows)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(children: [
                        Expanded(child: Text(name, style: const TextStyle(fontSize: 13))),
                        SizedBox(
                          width: 72,
                          // Галочка — значком: в веб-шрифте символа «✓» нет.
                          child: free == '✓'
                              ? Icon(Icons.check, size: 18, color: context.scheme.onSurface)
                              : Text(free, textAlign: TextAlign.center, style: TextStyle(color: free == '—' ? fam.text2 : null)),
                        ),
                        SizedBox(
                          width: 72,
                          child: proMark == '✓'
                              ? Icon(Icons.check, size: 18, color: context.scheme.primary)
                              : Text(proMark,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(fontWeight: FontWeight.w700, color: context.scheme.primary, fontSize: proMark.length > 2 ? 11 : 14)),
                        ),
                      ]),
                    ),
                ]),
              ),

              // Платежи
              if (payments.isNotEmpty)
                AppCard(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(l.payments, style: const TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    for (final p in payments)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(children: [
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text('${date(DateTime.parse(p['createdAt'] as String).toLocal())} · ${p['stars']} ⭐', style: const TextStyle(fontSize: 13)),
                              Text(l.proUntilLabel(date(DateTime.parse(p['proUntil'] as String).toLocal())), style: TextStyle(fontSize: 12, color: fam.text2)),
                            ]),
                          ),
                          Text(
                            p['status'] == 'refunded' ? l.paymentRefunded : l.paymentPaid,
                            style: TextStyle(fontSize: 12, color: p['status'] == 'refunded' ? fam.expense : context.scheme.primary),
                          ),
                        ]),
                      ),
                  ]),
                ),

              Text(l.dataKept, style: TextStyle(fontSize: 12, color: fam.text2)),
            ],
          ),
        );
      },
    );
  }
}
