/// Справочники владельца: описания счетов, члены семьи, лимиты, цели,
/// плановые платежи и условия кредитов. Хранятся на сервере как `entities`.
library;

import 'dart:math';

import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';

/// Случайный идентификатор для новых объектов и команд.
String newId() {
  final r = Random.secure();
  return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

int _minor(Object? v) => v == null ? 0 : parseMinor(v);

class CategoryDef {
  const CategoryDef(this.id, this.icon, {this.isIncome = false, this.name, this.iconIndex, this.expenseType});
  final String id;
  final IconData icon;
  final bool isIncome;

  /// Название своей категории; у встроенных подпись берётся из локализации.
  final String? name;
  final int? iconIndex;

  /// Тип расхода, выбранный владельцем для своей категории (F12); `null` —
  /// не выбирался, тогда действует запасной вариант из ядра (свободные).
  final ExpenseType? expenseType;

  bool get isCustom => name != null;
  Map<String, Object?> toJson() => {'name': name, 'icon': iconIndex ?? 0, 'income': isIncome, if (expenseType != null) 'expenseType': expenseType!.name};
}

/// Значки для своих категорий — фиксированный набор, чтобы сборка
/// не тянула весь шрифт иконок.
const customIcons = <IconData>[
  Icons.star_outline, Icons.pets_outlined, Icons.sports_soccer_outlined, Icons.fitness_center_outlined, Icons.spa_outlined,
  Icons.brush_outlined, Icons.local_florist_outlined, Icons.directions_car_outlined, Icons.flight_outlined, Icons.hotel_outlined,
  Icons.smoking_rooms_outlined, Icons.local_bar_outlined, Icons.cake_outlined, Icons.volunteer_activism_outlined, Icons.church_outlined,
  Icons.build_outlined, Icons.computer_outlined, Icons.music_note_outlined, Icons.camera_alt_outlined, Icons.savings_outlined,
  Icons.attach_money, Icons.work_history_outlined, Icons.storefront_outlined, Icons.more_horiz,
];

/// Свои категории пользователя (id → описание); заполняется из данных сервера.
final Map<String, CategoryDef> customCategories = {};

CategoryDef customCategoryFromJson(String id, Map<String, dynamic> d) {
  final idx = ((d['icon'] as num?)?.toInt() ?? 0).clamp(0, customIcons.length - 1);
  final typeName = d['expenseType'] as String?;
  final type = typeName == null ? null : ExpenseType.values.where((t) => t.name == typeName).firstOrNull;
  return CategoryDef(id, customIcons[idx], isIncome: d['income'] == true, name: d['name'] as String? ?? '?', iconIndex: idx, expenseType: type);
}

const categories = <CategoryDef>[
  CategoryDef('food', Icons.shopping_basket_outlined),
  CategoryDef('cafe', Icons.local_cafe_outlined),
  CategoryDef('transport', Icons.local_taxi_outlined),
  CategoryDef('health', Icons.medical_services_outlined),
  CategoryDef('kids', Icons.child_care_outlined),
  CategoryDef('home', Icons.home_outlined),
  CategoryDef('utilities', Icons.bolt_outlined),
  CategoryDef('phone', Icons.phone_iphone_outlined),
  CategoryDef('household', Icons.cleaning_services_outlined),
  CategoryDef('fun', Icons.movie_outlined),
  CategoryDef('clothes', Icons.checkroom_outlined),
  CategoryDef('education', Icons.school_outlined),
  CategoryDef('subscriptions', Icons.subscriptions_outlined),
  CategoryDef('gifts', Icons.redeem_outlined),
  CategoryDef('fees', Icons.receipt_outlined),
  CategoryDef('interest', Icons.percent),
  CategoryDef('other', Icons.category_outlined),
  CategoryDef('salary', Icons.work_outline, isIncome: true),
  CategoryDef('side', Icons.handyman_outlined, isIncome: true),
  CategoryDef('cashback', Icons.card_giftcard_outlined, isIncome: true),
  CategoryDef('interestIncome', Icons.account_balance_outlined, isIncome: true),
  CategoryDef('otherIncome', Icons.add_card_outlined, isIncome: true),
];

/// Категории для выбора: встроенные (без технических) плюс свои.
List<CategoryDef> get expenseCategories => [
      ...categories.where((c) => !c.isIncome && c.id != 'interest' && c.id != 'fees' && c.id != 'other'),
      ...customCategories.values.where((c) => !c.isIncome),
      categories.firstWhere((c) => c.id == 'other'),
    ];
List<CategoryDef> get incomeCategories => [...categories.where((c) => c.isIncome), ...customCategories.values.where((c) => c.isIncome)];

CategoryDef categoryById(String id) =>
    categories.where((c) => c.id == id).firstOrNull ?? customCategories[id] ?? categories.firstWhere((c) => c.id == 'other');

const accountTypes = ['card', 'cash', 'deposit'];

/// Тип счёта-копилки: создаётся вместе с целью, в выбор счетов для трат не попадает.
const piggyType = 'piggy';
const accountPalette = [0xFFD62F2F, 0xFF1F8A4C, 0xFF2C6FB2, 0xFF8A7A55, 0xFF6B4FBB, 0xFFE0A43A];

class AccountInfo {
  const AccountInfo({required this.id, required this.name, required this.type, required this.color, required this.liquid, required this.archived, this.owner});
  final String id;
  final String name;
  final String type;
  final Color color;
  final bool liquid;
  final bool archived;

  /// Чей это счёт для семейного режима: `me`, `shared`, id члена семьи —
  /// или `null`, если не привязан (при выборе счёта «для кого» не меняется
  /// сама). Не путать со `shared`, которое привязывает явно.
  final String? owner;
}

class Member {
  const Member(this.id, this.name, this.role);
  factory Member.fromJson(String id, Map<String, dynamic> d) => Member(id, d['name'] as String? ?? '', d['role'] as String? ?? 'other');
  final String id;
  final String name;

  /// `spouse`, `child`, `other`.
  final String role;
  Map<String, Object?> toJson() => {'name': name, 'role': role};
}

class LimitInfo {
  const LimitInfo(this.id, this.category, this.amount);
  factory LimitInfo.fromJson(String id, Map<String, dynamic> d) => LimitInfo(id, d['category'] as String? ?? 'other', _minor(d['amount']));
  final String id;
  final String category;
  final int amount;
  Map<String, Object?> toJson() => {'category': category, 'amount': amount.toString()};
}

/// Цель с копилкой: отдельный счёт, куда деньги переводятся со своих счетов.
class GoalInfo {
  const GoalInfo(this.id, this.name, this.target, this.deadline, {this.account});
  factory GoalInfo.fromJson(String id, Map<String, dynamic> d) =>
      GoalInfo(id, d['name'] as String? ?? '', _minor(d['target']), d['deadline'] == null ? null : dateFromJson(d['deadline']), account: d['account'] as String?);
  final String id;
  final String name;
  final int target;
  final DateTime? deadline;

  /// Id счёта-копилки; у старых целей может отсутствовать.
  final String? account;
  Map<String, Object?> toJson() => {'name': name, 'target': target.toString(), if (deadline != null) 'deadline': dateToJson(deadline!), if (account != null) 'account': account};
}

/// Плановый платёж: план не меняет баланс, факт оплаты проводится отдельно (D14).
class PlannedInfo {
  const PlannedInfo(this.id, this.name, this.amount, this.day, this.category, this.debtId, this.paid, {this.start, this.once, this.goalId});
  factory PlannedInfo.fromJson(String id, Map<String, dynamic> d) => PlannedInfo(
        id,
        d['name'] as String? ?? '',
        _minor(d['amount']),
        (d['day'] as num?)?.toInt() ?? 1,
        d['category'] as String? ?? 'other',
        d['debtId'] as String?,
        {...((d['paid'] as List?) ?? const []).cast<String>()},
        start: d['start'] == null ? null : dateFromJson(d['start']),
        once: d['once'] as String?,
        goalId: d['goal'] as String?,
      );
  final String id;
  final String name;
  final int amount;

  /// Число месяца, 1–31; в коротком месяце — последний день.
  final int day;
  final String category;

  /// Если задан — оплата проводится как платёж по долгу.
  final String? debtId;

  /// Оплаченные периоды `YYYY-MM`.
  final Set<String> paid;

  /// Дата добавления: более ранние сроки не считаются просроченными.
  final DateTime? start;

  /// Разовая покупка (D88): единственный месяц `YYYY-MM`, в котором она
  /// запланирована. `null` — обычный ежемесячный платёж.
  final String? once;

  /// Цель-копилка, в которую откладывают на разовую покупку (D90).
  final String? goalId;

  /// Вид справочника на сервере: разовые покупки хранятся отдельно.
  String get entityKind => once == null ? 'planned' : 'purchase';

  /// Первое число месяца разовой покупки.
  DateTime? get onceMonth => once == null ? null : DateTime(int.parse(once!.substring(0, 4)), int.parse(once!.substring(5, 7)), 1);

  /// [goal] привязывает копилку; `keepGoal: false` снимает привязку (покупка
  /// совершена, копилка закрыта).
  Map<String, Object?> toJson({Set<String>? paid, String? goal, bool keepGoal = true}) => {
        'name': name,
        'amount': amount.toString(),
        'day': day,
        'category': category,
        if (debtId != null) 'debtId': debtId,
        'paid': [...(paid ?? this.paid)]..sort(),
        if (start != null) 'start': dateToJson(start!),
        if (once != null) 'once': once,
        if ((goal ?? (keepGoal ? goalId : null)) != null) 'goal': goal ?? goalId,
      };
}

class DebtInfo {
  const DebtInfo(this.id, this.name, this.kind, this.rate);
  factory DebtInfo.fromJson(String id, Map<String, dynamic> d) =>
      DebtInfo(id, d['name'] as String? ?? '', d['kind'] as String? ?? 'loan', (d['rate'] as num?)?.toDouble() ?? 0);
  final String id;
  final String name;

  /// `loan`, `installment`, `creditCard`.
  final String kind;

  /// Номинальная годовая ставка, %.
  final double rate;
  Map<String, Object?> toJson() => {'name': name, 'kind': kind, 'rate': rate};
}

/// Быстрая операция (D46): плитка на главной — категория, сумма, подпись.
/// Один тап записывает расход на основной счёт сегодняшним числом.
class QuickAction {
  const QuickAction(this.id, this.name, this.category, this.amount);
  factory QuickAction.fromJson(String id, Map<String, dynamic> d) =>
      QuickAction(id, d['name'] as String? ?? '', d['category'] as String? ?? 'other', _minor(d['amount']));
  final String id;
  final String name;
  final String category;
  final int amount;
  Map<String, Object?> toJson() => {'name': name, 'category': category, 'amount': amount.toString()};
}

class PersonDebt {
  const PersonDebt(this.person, this.oweMe, this.amount);
  final String person;
  final bool oweMe;
  final int amount;
}

/// Один срок планового платежа.
class DueItem {
  const DueItem(this.planned, this.date, this.period);
  final PlannedInfo planned;
  final DateTime date;
  final String period;
}

/// Как получено «доступно сегодня» (D73): деньги на счетах → свободные деньги
/// → расчётный ориентир → лимит владельца с переносом → доступно.
class LimitExplain {
  const LimitExplain({
    required this.liquid,
    required this.reserves,
    required this.obligations,
    required this.overdue,
    required this.days,
    required this.until,
    required this.byMonthEnd,
    required this.guideDaily,
    required this.spent,
    required this.outside,
    required this.today,
    this.limit,
    this.carry = 0,
    this.planned,
    this.available,
  });

  /// Ликвидные деньги сейчас.
  final int liquid;

  /// Отложено на цели.
  final int reserves;

  /// Неоплаченные платежи до следующего дохода (в том числе просроченные).
  final int obligations;

  /// Из них просрочено.
  final int overdue;

  /// Дней до следующего дохода (не меньше одного, считая сегодня).
  final int days;
  final DateTime until;

  /// Дата дохода не задана: считаем до конца месяца.
  final bool byMonthEnd;

  /// Расчётный ориентир (формула 9.3): свободно на начало дня ÷ дни.
  final int guideDaily;
  final int spent;

  /// Запланированные траты сегодня — не вошли в лимит (D74).
  final int outside;
  final DateTime today;
  final int? limit;
  final int carry;

  /// Доступно по лимиту и переносу без оглядки на деньги.
  final int? planned;

  /// Доступно с ограничением деньгами на счетах (без отложенного на цели).
  final int? available;

  /// Свободные деньги сейчас; отрицательные — платежи нечем покрыть.
  int get free => liquid - reserves - obligations;

  /// Свободно на начало дня: сегодняшние траты возвращаются в базу, иначе
  /// «хватит на N дней» уменьшалось бы после каждой покупки.
  int get freeAtDayStart => free + spent;

  /// Сколько не хватает на платежи до дохода. Только предупреждение: доступное
  /// сегодня от этого не уменьшается (D81).
  int get shortfall => free < 0 ? -free : 0;

  /// Доступное срезано деньгами на счетах.
  bool get capped => planned != null && available != null && planned! > available!;

  /// На сколько дней при этом лимите хватит свободных денег.
  int? get coverDays {
    final l = limit;
    if (l == null || l <= 0) return null;
    return freeAtDayStart <= 0 ? 0 : freeAtDayStart ~/ l;
  }

  /// Лимит выше того, что позволяют свободные деньги до дохода.
  bool get limitTooHigh => coverDays != null && coverDays! < days;

  /// Когда закончатся свободные деньги при таком лимите.
  DateTime? get runOutDate => coverDays == null ? null : today.add(Duration(days: coverDays!));
}

/// Итоги месяца для сверки (D75).
class MonthSummary {
  const MonthSummary({
    required this.month,
    required this.current,
    required this.income,
    required this.expense,
    required this.prevIncome,
    required this.prevExpense,
    required this.top,
    required this.adjustments,
    required this.paymentsPaid,
    required this.paymentsTotal,
    required this.days,
    required this.avgDaily,
  });

  final DateTime month;

  /// Месяц ещё идёт — итоги промежуточные.
  final bool current;
  final int income;
  final int expense;
  final int prevIncome;
  final int prevExpense;

  /// Три категории, на которые ушло больше всего: id категории → сумма.
  final List<MapEntry<String, int>> top;

  /// Корректировки остатков за месяц (сверка): не доход и не расход.
  final int adjustments;
  final int paymentsPaid;
  final int paymentsTotal;

  /// За сколько дней считан средний расход.
  final int days;

  /// Средний расход в день из дневного лимита (без запланированных покупок).
  final int avgDaily;

  int get result => income - expense;
  bool get hasPrev => prevExpense != 0;

  /// На сколько процентов расходы отличаются от прошлого месяца (минус — меньше).
  /// Для идущего месяца `null`: неполный месяц с целым сравнивать нечестно.
  int? get expenseChangePercent => hasPrev && !current ? ((expense - prevExpense) * 100 / prevExpense).round() : null;
}
