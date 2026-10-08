/// Что даёт обычная версия и что Pro (D05, UI03) — одна таблица для экрана
/// «Тариф», проверок приложения и сервера.
///
/// Раньше таблица на экране жила отдельно от проверок и разошлась с ними:
/// сравнение с прошлым месяцем значилось только в Pro, хотя доступно всем,
/// работающий консультант — «скоро», импорта выписки в таблице не было.
library;

/// Сколько в обычной версии: сервер отклоняет сверх этого (`plan_limit`),
/// приложение заранее показывает предложение Pro.
const freeMoneyAccounts = 1;
const freeLimits = 2;
const freeGoals = 1;

/// Вопросов консультанту в месяц в Pro (D82); сервер может переопределить
/// переменной `AI_CHAT_QUOTA`.
const proAiQuestionsPerMonth = 100;

/// Возможности, которые различаются или могли бы различаться по тарифу.
enum PlanFeature { manual, accounts, limits, goals, debts, reports, compare, early, voice, statementImport, ai, family, history }

/// Как возможность доступна в тарифе.
class PlanAccess {
  const PlanAccess.yes() : allowed = true, limit = null, perMonth = null, unlimited = false, previewOnly = false;
  const PlanAccess.no() : allowed = false, limit = null, perMonth = null, unlimited = false, previewOnly = false;

  /// Не больше [limit] штук (счета, лимиты, цели).
  const PlanAccess.upTo(int this.limit) : allowed = true, perMonth = null, unlimited = false, previewOnly = false;

  /// Сколько угодно штук — то, что в обычной версии ограничено.
  const PlanAccess.unlimited() : allowed = true, limit = null, perMonth = null, unlimited = true, previewOnly = false;

  /// До [perMonth] раз в месяц.
  const PlanAccess.monthly(int this.perMonth) : allowed = true, limit = null, unlimited = false, previewOnly = false;

  /// Только посмотреть (сводка импорта без записи в журнал).
  const PlanAccess.preview() : allowed = false, limit = null, perMonth = null, unlimited = false, previewOnly = true;

  final bool allowed;
  final int? limit;
  final int? perMonth;
  final bool unlimited;
  final bool previewOnly;
}

/// Матрица: возможность → (обычная версия, Pro), в порядке строк на экране «Тариф».
const planMatrix = <PlanFeature, (PlanAccess, PlanAccess)>{
  PlanFeature.manual: (PlanAccess.yes(), PlanAccess.yes()),
  PlanFeature.accounts: (PlanAccess.upTo(freeMoneyAccounts), PlanAccess.unlimited()),
  PlanFeature.limits: (PlanAccess.upTo(freeLimits), PlanAccess.unlimited()),
  PlanFeature.goals: (PlanAccess.upTo(freeGoals), PlanAccess.unlimited()),
  PlanFeature.debts: (PlanAccess.yes(), PlanAccess.yes()),
  PlanFeature.reports: (PlanAccess.yes(), PlanAccess.yes()),
  PlanFeature.compare: (PlanAccess.yes(), PlanAccess.yes()),
  PlanFeature.early: (PlanAccess.no(), PlanAccess.yes()),
  PlanFeature.voice: (PlanAccess.yes(), PlanAccess.yes()),
  PlanFeature.statementImport: (PlanAccess.preview(), PlanAccess.yes()),
  PlanFeature.ai: (PlanAccess.no(), PlanAccess.monthly(proAiQuestionsPerMonth)),
  PlanFeature.family: (PlanAccess.yes(), PlanAccess.yes()),
  PlanFeature.history: (PlanAccess.yes(), PlanAccess.yes()),
};

PlanAccess planAccess(PlanFeature f, {required bool pro}) => pro ? planMatrix[f]!.$2 : planMatrix[f]!.$1;

/// Возможность доступна в тарифе (для счётных — хотя бы одна штука).
bool planAllows(PlanFeature f, {required bool pro}) => planAccess(f, pro: pro).allowed;

/// Можно ли добавить ещё одну штуку, когда их уже [count].
bool planAllowsMore(PlanFeature f, {required bool pro, required int count}) {
  final a = planAccess(f, pro: pro);
  return a.allowed && (a.limit == null || count < a.limit!);
}
