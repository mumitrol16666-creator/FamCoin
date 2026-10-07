/// Правила консультанта: список кнопок общий с приложением, подсказки по
/// приложению не устарели.
library;

import 'package:famcoin_core/famcoin_core.dart';
import 'package:famcoin_server/ai.dart';
import 'package:test/test.dart';

void main() {
  final system = chatMessages('ru', const {}, 'как перевести часть денег с копилки').first['content']!;

  test('в правилах все кнопки из ядра с их описаниями, шаблон подставлен', () {
    expect(system, isNot(contains('{{ACTIONS}}')));
    for (final e in aiActions.entries) {
      expect(system, contains('${e.key} — ${e.value}'), reason: e.key);
    }
  });

  test('перевод из копилки: «＋» → «Перевод» и карточка цели; «Счета» не называются местом перевода', () {
    expect(system, contains('«＋» → вкладка «Перевод» → в «Со счёта» выбрать копилку'));
    expect(system, contains('«Забрать из копилки»'));
    expect(system, contains('На экране «Счета» переводов нет'));
    expect(aiActions['accounts'], contains('переводов здесь нет'));
  });

  test('про долги: списание и закрытие без оплаты есть, прежнее «нельзя» убрано', () {
    expect(system, isNot(contains('списать или закрыть долг без денег нельзя')));
    expect(system, contains('«Списать долг»'));
    expect(system, contains('«Закрыть без оплаты»'));
    expect(system, contains('ни доходом, ни расходом'));
  });

  test('сценарии «а если»: итог по слагаемым прогноза, без двойного учёта дохода и займов', () {
    for (final fact in ['freeMoneyNow', 'unpaidPaymentsUntilMonthEnd', 'expectedRegularSpendUntilMonthEnd', 'не прибавляй его второй раз', 'ОДИН итог', '«и в итоге»']) {
      expect(system, contains(fact), reason: fact);
    }
  });

  test('платежи раз в неделю и год, рассрочка, возврат из архива описаны', () {
    for (final fact in ['«В рассрочку»', 'раз в год', '«Вернуть из архива»', '«Уточнить остаток»', '«Списалось»']) {
      expect(system, contains(fact), reason: fact);
    }
    expect(aiActions['add_planned'], contains('неделю или год'));
  });

  test('личные долги: путь «Внести платёж», устаревшего «Я вернул» нет, personDebts объяснены', () {
    expect(system, contains('«Внести платёж»'));
    expect(system, contains('«Вернуть всё»'));
    expect(system, isNot(contains('«Я вернул»')));
    for (final fact in ['personDebts', 'owesMe', 'iOwe', 'overdue']) {
      expect(system, contains(fact), reason: fact);
    }
  });

  test('аналитика: три вкладки, прежних названий вкладок в правилах нет (D136)', () {
    expect(system, contains('«Месяц»'));
    expect(system, contains('«Деньги»'));
    for (final old in ['«Обзор»', '«История»', '«Капитал»']) {
      expect(system, isNot(contains(old)), reason: old);
    }
  });
}
