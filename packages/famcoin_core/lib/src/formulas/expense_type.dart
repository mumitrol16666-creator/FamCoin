/// Три типа повседневных трат (раздел 9.8): обязательные, обычные,
/// свободные. Деление — по категории, без отдельного поля у операции:
/// категория и так выбирается на каждой записи, а свои категории редки.
library;

enum ExpenseType {
  /// Аренда, коммуналка, связь, подписки, платежи по кредитам.
  mandatory,

  /// Еда, транспорт, здоровье, дети, бытовые покупки — необходимо, но сумма
  /// каждый месяц разная.
  regular,

  /// Кафе, развлечения, одежда, подарки, прочее — по желанию.
  discretionary,
}

/// Встроенные категории с их типом. Свои категории — [ExpenseType.discretionary]
/// по умолчанию: определить их смысл по названию нельзя, а свободные траты —
/// самый безопасный ярлык по умолчанию (не создаёт ложного чувства обязательства).
const Map<String, ExpenseType> _builtin = {
  'home': ExpenseType.mandatory,
  'utilities': ExpenseType.mandatory,
  'phone': ExpenseType.mandatory,
  'subscriptions': ExpenseType.mandatory,
  'interest': ExpenseType.mandatory,
  'fees': ExpenseType.mandatory,
  'food': ExpenseType.regular,
  'transport': ExpenseType.regular,
  'health': ExpenseType.regular,
  'kids': ExpenseType.regular,
  'household': ExpenseType.regular,
  'education': ExpenseType.regular,
  'other': ExpenseType.regular,
  'cafe': ExpenseType.discretionary,
  'fun': ExpenseType.discretionary,
  'clothes': ExpenseType.discretionary,
  'gifts': ExpenseType.discretionary,
};

ExpenseType expenseTypeOf(String categoryId) => _builtin[categoryId] ?? ExpenseType.discretionary;

/// Сумма расходов по трём типам вместо десятков категорий.
class ExpenseTypeSplit {
  const ExpenseTypeSplit({required this.mandatory, required this.regular, required this.discretionary});
  final int mandatory;
  final int regular;
  final int discretionary;
  int get total => mandatory + regular + discretionary;
}

/// [byCategory] — сумма расхода по id категории за период (без знака, ≥ 0).
/// [classify] переопределяет тип по умолчанию — например, чтобы учесть
/// выбор владельца для своей категории (см. `AppState.expenseTypeFor`).
ExpenseTypeSplit splitExpenseTypes(Map<String, int> byCategory, {ExpenseType Function(String)? classify}) {
  final resolve = classify ?? expenseTypeOf;
  var mandatory = 0, regular = 0, discretionary = 0;
  for (final e in byCategory.entries) {
    switch (resolve(e.key)) {
      case ExpenseType.mandatory:
        mandatory += e.value;
      case ExpenseType.regular:
        regular += e.value;
      case ExpenseType.discretionary:
        discretionary += e.value;
    }
  }
  return ExpenseTypeSplit(mandatory: mandatory, regular: regular, discretionary: discretionary);
}
