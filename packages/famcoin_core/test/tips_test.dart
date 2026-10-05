import 'package:famcoin_core/famcoin_core.dart';
import 'package:test/test.dart';

void main() {
  test('советы: 72 штуки, коды и тексты уникальны, оба языка заполнены и различаются', () {
    expect(moneyTips.length, 72);
    expect(moneyTips.map((t) => t.id).toSet().length, moneyTips.length);
    expect(moneyTips.map((t) => t.ru.trim()).toSet().length, moneyTips.length);
    expect(moneyTips.map((t) => t.kk.trim()).toSet().length, moneyTips.length);
    for (final t in moneyTips) {
      expect(t.ru.trim(), isNotEmpty, reason: t.id);
      expect(t.kk.trim(), isNotEmpty, reason: t.id);
      expect(t.ru, isNot(equals(t.kk)), reason: t.id);
      expect(t.text('kk'), t.kk);
      expect(t.text('ru'), t.ru);
      expect(t.text('en'), t.ru, reason: 'неизвестный язык — русский');
    }
  });

  test('совет дня: один на все сутки, назавтра следующий, по кругу, и до 2026 года тоже работает', () {
    final a = moneyTipOfDay(DateTime(2026, 10, 3, 0, 1));
    expect(moneyTipOfDay(DateTime(2026, 10, 3, 23, 59)).id, a.id);
    expect(moneyTipOfDay(DateTime(2026, 10, 4)).id, isNot(a.id));
    expect(moneyTipOfDay(DateTime(2026, 10, 3 + moneyTips.length)).id, a.id);
    expect(moneyTipOfDay(DateTime(2025, 12, 31)).id, moneyTips.last.id);
    expect(moneyTipOfDay(DateTime(2026, 1, 1)).id, moneyTips.first.id);
    expect({for (var i = 0; i < moneyTips.length; i++) moneyTipOfDay(DateTime(2026, 10, 3 + i)).id},
        moneyTips.map((t) => t.id).toSet(), reason: 'за полный цикл каждый совет появляется один раз');
  });
}
