/// Советы на главной (D96): один короткий ориентир в день — про деньги или
/// про приложение.
///
/// Подсказки про приложение показываются, пока их условие верно (нет
/// дневного лимита, нет копилки, нет платежей…), и ведут в нужное место.
/// Общие советы — ориентиры финансовой грамотности: как откладывать, зачем
/// подушка, как не терять мелочи. Без инвестиций, кредитов и банков — те же
/// границы, что у консультанта (D84).
///
/// Порядок постоянный: по очереди совет про приложение и про деньги, чтобы
/// новичка не заваливало подсказками «настройте то, настройте это». Ротация —
/// по номеру ([tipAt]), номер ведёт [Settings.tipCursor].
library;

import '../../l10n/app_localizations.dart';
import '../../state/app_state.dart';

/// Куда ведёт совет; обработчики — в карточке на главной.
enum TipAction { setLimit, addGoal, openCalendar, openLimits, addQuick, voice, telegram }

class Tip {
  const Tip(this.id, this.text, {this.actionLabel, this.action});

  /// Устойчивый код — для тестов и журнала, не для показа.
  final String id;
  final String text;
  final String? actionLabel;
  final TipAction? action;
}

/// Советы, подходящие сейчас. Никогда не пуст: общие есть всегда.
List<Tip> tipsFor(AppState s, AppLocalizations l) {
  final app = <Tip>[
    if (s.dailyLimit == null) Tip('appLimit', l.adviceAppLimit, actionLabel: l.adviceActLimit, action: TipAction.setLimit),
    if (s.goals.isEmpty) Tip('appGoal', l.adviceAppGoal, actionLabel: l.adviceActGoal, action: TipAction.addGoal),
    if (s.planned.isEmpty) Tip('appPlanned', l.adviceAppPlanned, actionLabel: l.adviceActCalendar, action: TipAction.openCalendar),
    if (s.limits.isEmpty) Tip('appCatLimit', l.adviceAppCatLimit, actionLabel: l.adviceActCatLimit, action: TipAction.openLimits),
    if (s.quickActions.isEmpty) Tip('appQuick', l.adviceAppQuick, actionLabel: l.adviceActQuick, action: TipAction.addQuick),
    Tip('appVoice', l.adviceAppVoice, actionLabel: l.adviceActVoice, action: TipAction.voice),
    Tip('appTelegram', l.adviceAppTelegram, actionLabel: l.adviceActTelegram, action: TipAction.telegram),
    Tip('appNote', l.adviceAppNote),
    Tip('appMonthClose', l.adviceAppMonthClose),
  ];
  final money = <Tip>[
    Tip('moneyPayFirst', l.adviceMoneyPayFirst),
    Tip('moneyTenPercent', l.adviceMoneyTenPercent),
    Tip('moneyCushion', l.adviceMoneyCushion),
    Tip('moneyRecordNow', l.adviceMoneyRecordNow),
    Tip('moneyMinutes', l.adviceMoneyMinutes),
    Tip('moneyIrregular', l.adviceMoneyIrregular),
    Tip('moneyWait', l.adviceMoneyWait),
    Tip('moneyList', l.adviceMoneyList),
    Tip('moneySubscriptions', l.adviceMoneySubscriptions),
    Tip('moneyCompare', l.adviceMoneyCompare),
    Tip('moneyBigCategory', l.adviceMoneyBigCategory),
    Tip('moneySmall', l.adviceMoneySmall),
    Tip('moneyNotPerfect', l.adviceMoneyNotPerfect),
    Tip('moneySeparate', l.adviceMoneySeparate),
    Tip('moneyRoundUp', l.adviceMoneyRoundUp),
    Tip('moneyFamily', l.adviceMoneyFamily),
    Tip('moneyKids', l.adviceMoneyKids),
    Tip('moneyGoalDate', l.adviceMoneyGoalDate),
    Tip('moneyWindfall', l.adviceMoneyWindfall),
    Tip('moneyDiscount', l.adviceMoneyDiscount),
    Tip('moneyLeaks', l.adviceMoneyLeaks),
    Tip('moneyHoliday', l.adviceMoneyHoliday),
    Tip('moneyUnexpected', l.adviceMoneyUnexpected),
    Tip('moneyWants', l.adviceMoneyWants),
  ];
  return [
    for (var i = 0; i < app.length || i < money.length; i++) ...[
      if (i < app.length) app[i],
      if (i < money.length) money[i],
    ],
  ];
}

/// Совет под номером [cursor]: список зациклен, номер растёт без ограничений.
Tip? tipAt(List<Tip> pool, int cursor) => pool.isEmpty ? null : pool[cursor % pool.length];
