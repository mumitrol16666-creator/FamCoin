// Смайлик в начале названия категории (D107): распознаётся и переносится.
import 'package:famcoin/state/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('leadingEmoji: смайлик в начале названия, в том числе с модификатором', () {
    expect(leadingEmoji('☕️ Кофехуёк'), '☕️');
    expect(leadingEmoji('🚬 Сигареты'), '🚬');
    expect(leadingEmoji('👨‍👩‍👧 Семья'), '👨‍👩‍👧');
    expect(leadingEmoji('Кофе ☕️'), isNull, reason: 'только в начале');
    expect(leadingEmoji('Налоги'), isNull);
    expect(leadingEmoji(''), isNull);
  });

  test('stripLeadingEmoji: убирает смайлик и пробел после него', () {
    expect(stripLeadingEmoji('☕️ Кофехуёк'), 'Кофехуёк');
    expect(stripLeadingEmoji('🚬Сигареты'), 'Сигареты');
    expect(stripLeadingEmoji('Налоги'), 'Налоги');
  });
}
