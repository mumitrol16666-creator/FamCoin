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

  test('платежи раз в неделю и год, рассрочка, возврат из архива описаны', () {
    for (final fact in ['«В рассрочку»', 'раз в год', '«Вернуть из архива»', '«Уточнить остаток»', '«Списалось»']) {
      expect(system, contains(fact), reason: fact);
    }
    expect(aiActions['add_planned'], contains('неделю или год'));
  });
}
