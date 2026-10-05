import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../state/app_scope.dart';
import '../widgets/common.dart';

/// Экспорт данных владельца: журнал в CSV или полная копия в JSON.
///
/// Сервер отдаёт файл по одноразовой ссылке, которую открывает браузер —
/// так файл сохраняется на любом устройстве без передачи токена в адресе.
/// Названия столбцов, категорий, счетов и типов приложение подставляет само:
/// файл получается на языке интерфейса.
Future<void> exportData(BuildContext context, {required String format}) async {
  final l = context.l10n;
  final state = AppScope.of(context).state;
  final messenger = ScaffoldMessenger.of(context);

  final names = <String, String>{};
  for (final a in state.ledger.accounts) {
    final id = a.id;
    if (a.isMoney) {
      names[id] = state.accountInfo(id)?.name ?? id;
    } else if (a.kind == LedgerKind.expense) {
      names[id] = categoryName(l, id.substring(8));
    } else if (a.kind == LedgerKind.income) {
      names[id] = categoryName(l, id.substring(7));
    } else if (a.kind == LedgerKind.liability) {
      final key = id.substring(10);
      names[id] = state.bankDebt(key)?.name ?? key;
    } else if (a.assetClass == AssetClass.receivable) {
      names[id] = id.substring(11);
    }
  }
  names.addAll({
    'type:opening': l.openingBalance,
    'type:expense': l.expense,
    'type:income': l.income,
    'type:transfer': l.transfer,
    'type:lendOut': l.lendOut,
    'type:borrow': l.borrow,
    'type:repaymentReceived': l.returnedToMe,
    'type:repaymentMade': l.iReturned,
    'type:creditReceived': l.typeCreditReceived,
    'type:loanPayment': l.typeLoanPayment,
    'type:creditPurchase': l.typeCreditPurchase,
    'type:refund': l.refund,
    'type:adjustment': l.adjustment,
    'type:writeOff': l.typeWriteOff,
    'type:reversal': l.cancelled,
    'who:me': l.me,
    'who:shared': l.shared,
    for (final m in state.members) 'who:${m.id}': m.name,
    'status:active': l.statusActive,
    'status:cancelled': l.cancelled,
    'status:reversal': l.statusReversal,
  });
  final headers = [l.date, l.csvTime, l.csvType, l.category, l.account, l.amount, l.note, l.forWhom, l.csvStatus, 'ID'];

  messenger.showSnackBar(SnackBar(content: Text(l.exportOpening), duration: const Duration(seconds: 2)));
  final ok = await runAction(context, () async {
    final path = await state.api.exportLink(state.token, format: format, headers: headers, names: names);
    await launchUrl(Uri.parse('${state.api.baseUrl}$path'), mode: LaunchMode.externalApplication);
  });
  if (!ok) messenger.clearSnackBars();
}
