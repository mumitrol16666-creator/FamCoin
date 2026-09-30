/// Ограничитель одновременных дорогих операций.
///
/// Хеширование пароля (bcrypt) считается внутри базы и держит соединение из
/// пула несколько сотен миллисекунд. Без ограничителя пачка входов занимает
/// весь пул, и обычные запросы (`/state`, `/command`) ждут секундами. Здесь
/// одновременно идут не более [limit] операций, остальные ждут в очереди, а
/// при переполнении очереди новые получают быстрый отказ [overflow] вместо
/// бесконечного ожидания.
library;

import 'dart:async';
import 'dart:collection';

class Gate {
  Gate(this.limit, {this.maxQueue = 60, required this.overflow});

  final int limit;
  final int maxQueue;

  /// Что бросить, когда очередь переполнена.
  final Object Function() overflow;

  int _active = 0;
  final _waiting = Queue<Completer<void>>();

  int get active => _active;
  int get waiting => _waiting.length;

  Future<T> run<T>(Future<T> Function() task) async {
    if (_active < limit) {
      _active++;
    } else {
      if (_waiting.length >= maxQueue) throw overflow();
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future; // место передано напрямую: счётчик _active не менялся
    }
    try {
      return await task();
    } finally {
      if (_waiting.isNotEmpty) {
        _waiting.removeFirst().complete();
      } else {
        _active--;
      }
    }
  }
}
