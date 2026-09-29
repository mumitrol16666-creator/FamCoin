import 'ledger.dart';
import 'serialization.dart';

const plannedCommandTypes = {'payPlannedPeriod', 'setPlannedPeriodPaid'};

/// The server calls this under the owner's PostgreSQL lock. The client
/// calls it only when its revision is exactly the command's predecessor.
/// Generated commands preserve all other periods and plan attributes.
List<Map<String, dynamic>> expandPlannedCommand(
    Map<String, dynamic> command, Map<String, dynamic> latest) {
  String id(String key) {
    final v = command[key];
    if (v is! String || v.isEmpty || v.length > maxIdLength) {
      throw LedgerException('Некорректное поле $key', code: 'fieldMissing');
    }
    return v;
  }

  final plannedId = id('plannedId');
  final period = id('period');
  if (!RegExp(r'^\d{4}-(0[1-9]|1[0-2])$').hasMatch(period)) {
    throw LedgerException('Некорректный период платежа', code: 'invalidData');
  }
  dateFromJson('$period-01');
  final paidRaw = latest['paid'];
  if (paidRaw != null && (paidRaw is! List || paidRaw.any((v) => v is! String))) {
    throw LedgerException('Некорректная история оплат', code: 'invalidData');
  }
  final paid = <String>{...((paidRaw as List?) ?? const []).cast<String>()};
  final result = <Map<String, dynamic>>[];
  switch (command['type']) {
    case 'setPlannedPeriodPaid':
      if (command['paid'] is! bool) {
        throw LedgerException('Не указан статус оплаты', code: 'invalidData');
      }
      command['paid'] == true ? paid.add(period) : paid.remove(period);
    case 'payPlannedPeriod':
      if (paid.contains(period)) {
        throw LedgerException('Этот период уже оплачен. Обновите данные.', code: 'periodAlreadyPaid');
      }
      final amount = parseMinor(command['amount']);
      final interest = command['interest'] == null ? 0 : parseMinor(command['interest']);
      if (amount <= 0 || amount > maxAmount || interest < 0 || interest > amount) {
        throw LedgerException('Некорректная сумма платежа', code: 'invalidAmount');
      }
      final debtId = latest['debtId'];
      // Do not silently redirect a payment after the plan was repurposed.
      if (command['expectedDebtId'] != debtId) {
        throw LedgerException('План платежа изменён. Обновите данные.', code: 'plannedChanged');
      }
      if (debtId != null && (debtId is! String || debtId.isEmpty)) {
        throw LedgerException('Некорректный долг плана', code: 'invalidData');
      }
      if (debtId == null && interest != 0) {
        throw LedgerException('Проценты допустимы только для долга', code: 'invalidAmount');
      }
      final date = dateToJson(dateFromJson(command['date']));
      final account = id('account');
      final transactionId = id('id');
      final link = <String, Object?>{'planned': plannedId, 'period': period};
      if (debtId != null) {
        result.add({
          'type': 'loanPayment', 'id': transactionId, 'date': date,
          'account': account, 'debtId': debtId,
          'principal': (amount - interest).toString(),
          'interest': interest.toString(), 'meta': link,
        });
      } else {
        final category = latest['category'] as String? ?? 'other';
        result.add({
          'type': 'expense', 'id': transactionId, 'date': date,
          'account': account, 'splits': {category: amount.toString()},
          'meta': {'who': 'shared', 'note': latest['name'] ?? '', ...link},
        });
      }
      paid.add(period);
    default:
      throw LedgerException('Неизвестная команда плана', code: 'invalidData');
  }
  result.add({
    'type': 'upsertEntity', 'kind': 'planned', 'entityId': plannedId,
    'data': {...latest, 'paid': paid.toList()..sort()},
  });
  return result;
}
