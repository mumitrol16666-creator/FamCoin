/// Дневной ориентир трат (раздел 9.3).
library;

import 'dart:math' as math;

import '../money.dart';

class DailyGuide {
  const DailyGuide({
    required this.base,
    required this.days,
    required this.dailyBudget,
    required this.remainingToday,
  });

  /// B0 = L0 − R0 − C0 − P0.
  final int base;
  final int days;
  final int dailyBudget;
  final int remainingToday;

  /// Свободных денег не хватает на обязательства и план накоплений.
  bool get deficit => base < 0;
}

/// Простой период без поступлений до его конца.
///
/// - [liquid] L0 — ликвидные собственные деньги на начало дня;
/// - [reserves] R0 — уже защищённые резервы внутри L0;
/// - [obligations] C0 — ещё не оплаченные обязательства периода из свободных денег;
/// - [savingsPlan] P0 — ещё не выполненный план новых накоплений;
/// - [days] D — число дней периода, включая сегодня (минимум 1);
/// - [spentToday] — сегодняшние траты из дневного бюджета.
DailyGuide dailyGuide({
  required int liquid,
  required int reserves,
  required int obligations,
  required int savingsPlan,
  required int days,
  int spentToday = 0,
}) {
  final d = math.max(1, days);
  final base = liquid - reserves - obligations - savingsPlan;
  // Ориентир округляется вниз до целой единицы валюты: дробные тиыны
  // не помогают планировать день.
  final daily = base <= 0 ? 0 : (base ~/ d) ~/ minorPerUnit * minorPerUnit;
  return DailyGuide(
    base: base,
    days: d,
    dailyBudget: daily,
    remainingToday: daily - spentToday,
  );
}

/// Плановое событие внутри горизонта: день (1 = сегодня) и изменение
/// свободных денег: `+` поступление, `−` выплата или новый резерв.
class PlannedFlow {
  const PlannedFlow(this.day, this.delta);
  final int day;
  final int delta;
}

class ConstantDailyBudget {
  const ConstantDailyBudget({
    required this.dailyBudget,
    required this.bindingDay,
    this.deficitDay,
  });

  final int dailyBudget;

  /// Контрольная точка, ограничившая бюджет.
  final int bindingDay;

  /// Первый день, когда свободный остаток становится отрицательным.
  final int? deficitDay;
}

/// Обобщённый расчёт постоянного дневного бюджета для нескольких
/// поступлений и крупных платежей:
/// `Дневной бюджет = max(0, min по t [ A(t) / N(t) ])`, где A(t) — свободный
/// остаток без повседневных трат на конец дня t, N(t) — число дней трат до t.
/// В один день списание считается раньше поступления (осторожный вариант).
ConstantDailyBudget constantDailyBudget({
  required int freeLiquid,
  required int horizonDays,
  List<PlannedFlow> flows = const [],
}) {
  final d = math.max(1, horizonDays);
  final sorted = [...flows]..sort((a, b) {
      final byDay = a.day.compareTo(b.day);
      if (byDay != 0) return byDay;
      return a.delta.compareTo(b.delta); // отрицательные раньше
    });

  var budget = freeLiquid ~/ d;
  var bindingDay = d;
  int? deficitDay;
  var running = freeLiquid;
  var i = 0;
  for (var day = 1; day <= d; day++) {
    while (i < sorted.length && sorted[i].day == day) {
      running += sorted[i].delta;
      if (running < 0 && deficitDay == null) deficitDay = day;
      i++;
    }
    final perDay = running ~/ day;
    if (perDay < budget) {
      budget = perDay;
      bindingDay = day;
    }
  }
  return ConstantDailyBudget(
    dailyBudget: math.max(0, budget),
    bindingDay: bindingDay,
    deficitDay: deficitDay,
  );
}
