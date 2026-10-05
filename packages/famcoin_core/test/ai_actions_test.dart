import 'package:famcoin_core/famcoin_core.dart';
import 'package:test/test.dart';

void main() {
  test('кнопки консультанта: только известные id, без повторов, не больше двух (D108)', () {
    expect(knownAiActions(['calendar', 'add_goal', 'limits']), ['calendar', 'add_goal']);
    expect(knownAiActions(['calendar', 'calendar', 'secret_admin']), ['calendar']);
    expect(knownAiActions(['open:settings', 42, null]), isEmpty);
    expect(knownAiActions('calendar'), isEmpty);
    expect(knownAiActions(null), isEmpty);
    expect(aiActions.keys, isNot(contains('')), reason: 'список без пустых id');
  });
}
