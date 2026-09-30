import 'dart:async';

import 'package:famcoin_server/gate.dart';
import 'package:test/test.dart';

void main() {
  test('одновременно идёт не больше limit задач, остальные ждут своей очереди', () async {
    final gate = Gate(3, maxQueue: 100, overflow: () => StateError('full'));
    var running = 0, peak = 0;
    final order = <int>[];
    await Future.wait([
      for (var i = 0; i < 20; i++)
        gate.run(() async {
          running++;
          if (running > peak) peak = running;
          order.add(i);
          await Future<void>.delayed(const Duration(milliseconds: 5));
          running--;
        }),
    ]);
    expect(peak, 3);
    expect(order, List.generate(20, (i) => i), reason: 'очередь FIFO');
    expect(gate.active, 0);
    expect(gate.waiting, 0);
  });

  test('переполненная очередь отказывает сразу, а не ждёт', () async {
    final gate = Gate(1, maxQueue: 2, overflow: () => StateError('full'));
    final hold = Completer<void>();
    final first = gate.run(() => hold.future); // занимает единственное место
    final queued = [gate.run(() async => 1), gate.run(() async => 2)];
    await expectLater(gate.run(() async => 3), throwsA(isA<StateError>()));
    hold.complete();
    await first;
    expect(await Future.wait(queued), [1, 2]);
    expect(gate.active, 0);
  });

  test('место освобождается и после ошибки в задаче', () async {
    final gate = Gate(1, overflow: () => StateError('full'));
    await expectLater(gate.run<void>(() async => throw FormatException('x')), throwsFormatException);
    expect(await gate.run(() async => 'ok'), 'ok');
    expect(gate.active, 0);
  });
}
