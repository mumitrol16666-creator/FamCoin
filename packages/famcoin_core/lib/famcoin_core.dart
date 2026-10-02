/// Финансовое ядро FamCoin.
///
/// Все суммы — целые числа минимальных единиц валюты (для KZT — тиын).
/// Журнал ведётся двойной записью: у каждой операции сумма дебетовых
/// изменений равна сумме кредитовых. Пользователь видит привычные
/// «расход», «перевод», «долг»; внутри это набор проводок по счетам
/// разных видов (см. `LedgerKind`).
library;

export 'src/aggregates.dart';
export 'src/commands.dart';
export 'src/events.dart';
export 'src/formulas/daily_guide.dart';
export 'src/formulas/daily_limit.dart';
export 'src/formulas/debt_load.dart';
export 'src/formulas/debt_strategy.dart';
export 'src/formulas/expense_type.dart';
export 'src/formulas/forecast.dart';
export 'src/formulas/fx.dart';
export 'src/formulas/goals.dart';
export 'src/formulas/limits.dart';
export 'src/formulas/loans.dart';
export 'src/ledger.dart';
export 'src/money.dart';
export 'src/serialization.dart';
export 'src/voice.dart';
