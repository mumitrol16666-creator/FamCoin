/// Уборка данных, которые копятся сами: просроченные сессии и одноразовые
/// коды, принятые команды (нужны только для защиты от повторной отправки),
/// старые уведомления. Без неё таблицы растут бесконечно.
library;

import 'dart:async';
import 'dart:io';

import 'package:postgres/postgres.dart';

class Maintenance {
  Maintenance(this.db);

  final Pool db;
  Timer? _timer;
  bool _busy = false;

  void start() {
    Timer(const Duration(minutes: 2), run);
    _timer = Timer.periodic(const Duration(hours: 6), (_) => run());
  }

  void stop() => _timer?.cancel();

  /// Возвращает, сколько строк удалено по каждой таблице.
  Future<Map<String, int>> run() async {
    if (_busy) return const {};
    _busy = true;
    final out = <String, int>{};
    Future<void> clean(String name, String sql) async {
      try {
        out[name] = (await db.execute(sql)).affectedRows;
      } catch (e) {
        stderr.writeln('maintenance $name: ${e.runtimeType}');
      }
    }

    try {
      // Повтор команды приходит в течение секунд; 60 суток — с большим запасом.
      await clean('commands', "DELETE FROM commands WHERE created_at < now() - interval '60 days'");
      await clean('sessions', "DELETE FROM sessions WHERE expires_at < now() - interval '1 day'");
      await clean('notifications', "DELETE FROM notifications WHERE created_at < now() - interval '180 days'");
      await clean('telegram_logins', 'DELETE FROM telegram_logins WHERE expires_at < now()');
      await clean('telegram_links', 'DELETE FROM telegram_links WHERE expires_at < now()');
    } finally {
      _busy = false;
    }
    final total = out.values.fold<int>(0, (a, b) => a + b);
    if (total > 0) print('maintenance: удалено $total строк $out');
    return out;
  }
}
