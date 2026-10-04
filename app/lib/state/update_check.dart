/// Проверка обновлений (D103): приложение само замечает новую версию.
///
/// Сайт: при сборке в код зашивается метка сборки `BUILD_ID`, а рядом с
/// сайтом лежит `build.json` с меткой выложенной сборки. Разошлись — вышло
/// обновление, достаточно перезагрузить страницу. Android: версия приложения
/// (`APP_VERSION` из pubspec) сверяется с `download/android.json`, который
/// пишет сборка APK; новее — предлагается скачать.
///
/// Проверка идёт через несколько секунд после запуска, затем раз в
/// [interval] и при каждом возврате в приложение. Закрытая плашка не
/// возвращается до следующей версии (метка запоминается на устройстве).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Метка сборки сайта (`--dart-define=BUILD_ID`); пустая в отладке и в APK.
const buildId = String.fromEnvironment('BUILD_ID');

/// Версия приложения в APK (`--dart-define=APP_VERSION`, как в pubspec).
const appVersion = String.fromEnvironment('APP_VERSION');

class UpdateInfo {
  const UpdateInfo({required this.id, required this.version, this.url});

  /// Что именно вышло: метка сборки сайта или версия APK. По ней помнится «Позже».
  final String id;

  /// Версия для подписи плашки; может быть пустой.
  final String version;

  /// Ссылка на APK; `null` — сайт, достаточно перезагрузки.
  final String? url;

  bool get isDownload => url != null;
}

/// `0.1.3+4` новее `0.1.2+3`: сначала по номеру сборки после «+», если он
/// есть у обеих, иначе по частям версии слева направо.
bool isNewerVersion(String candidate, String current) {
  if (candidate.isEmpty || current.isEmpty) return false;
  (List<int>, int?) parse(String v) {
    final plus = v.indexOf('+');
    final build = plus < 0 ? null : int.tryParse(v.substring(plus + 1));
    final parts = (plus < 0 ? v : v.substring(0, plus)).split('.').map((p) => int.tryParse(p) ?? 0).toList();
    return (parts, build);
  }

  final (a, ab) = parse(candidate);
  final (b, bb) = parse(current);
  if (ab != null && bb != null && ab != bb) return ab > bb;
  for (var i = 0; i < a.length || i < b.length; i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    if (x != y) return x > y;
  }
  return false;
}

class UpdateCheck extends ChangeNotifier {
  UpdateCheck({
    required this.site,
    http.Client? client,
    bool? web,
    String? currentBuild,
    String? currentVersion,
    this.interval = const Duration(minutes: 10),
    this.firstDelay = const Duration(seconds: 5),
  })  : _http = client ?? http.Client(),
        _web = web ?? kIsWeb,
        _build = currentBuild ?? buildId,
        _version = currentVersion ?? appVersion;

  /// Адрес сайта без `/api`, например `https://coin.edudev.kz`.
  final String site;
  final Duration interval;
  final Duration firstDelay;
  final http.Client _http;
  final bool _web;
  final String _build;
  final String _version;

  static const _dismissedKey = 'updateDismissed';

  UpdateInfo? _available;
  String? _dismissed;
  Timer? _timer;
  bool _checking = false;

  /// Что вышло; `null` — обновлений нет или проверка ещё не прошла.
  UpdateInfo? get available => _available;

  /// Показывать ли плашку: обновление есть и человек его не откладывал.
  bool get show => _available != null && _available!.id != _dismissed;

  /// Без зашитой метки (отладка, тесты) сравнивать не с чем: ни таймеров, ни
  /// запросов — виджет-тесты проверяют, что после них не осталось таймеров.
  bool get _enabled => _web ? _build.isNotEmpty : _version.isNotEmpty;

  /// Первая проверка через [firstDelay], дальше раз в [interval].
  void start() {
    if (!_enabled) return;
    _timer?.cancel();
    Timer(firstDelay, check);
    _timer = Timer.periodic(interval, (_) => check());
  }

  /// Одна проверка; ошибки сети молча пропускаются — это не повод беспокоить.
  Future<void> check() async {
    if (_checking || !_enabled) return;
    _checking = true;
    try {
      _dismissed ??= (await SharedPreferences.getInstance()).getString(_dismissedKey) ?? '';
      final path = _web ? '/build.json' : '/download/android.json';
      final r = await _http.get(Uri.parse('$site$path?t=${DateTime.now().millisecondsSinceEpoch}')).timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) return;
      final j = jsonDecode(r.body);
      if (j is! Map) return;
      UpdateInfo? found;
      if (_web) {
        final id = '${j['buildId'] ?? ''}';
        if (id.isNotEmpty && id != _build) found = UpdateInfo(id: id, version: '${j['version'] ?? ''}');
      } else {
        final v = '${j['version'] ?? ''}';
        final url = '${j['url'] ?? ''}';
        if (url.isNotEmpty && isNewerVersion(v, _version)) found = UpdateInfo(id: v, version: v, url: url);
      }
      if (found?.id != _available?.id) {
        _available = found;
        notifyListeners();
      }
    } catch (_) {
      // сеть, не JSON, таймаут — проверим в следующий раз
    } finally {
      _checking = false;
    }
  }

  /// «Позже»: плашка уходит до следующей версии.
  Future<void> dismiss() async {
    final id = _available?.id;
    if (id == null) return;
    _dismissed = id;
    notifyListeners();
    try {
      await (await SharedPreferences.getInstance()).setString(_dismissedKey, id);
    } catch (_) {}
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// Доступ к проверке обновлений из дерева виджетов; `null` — проверки нет
/// (например, в тестах).
class UpdateScope extends InheritedNotifier<UpdateCheck> {
  const UpdateScope({super.key, required UpdateCheck super.notifier, required super.child});

  static UpdateCheck? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<UpdateScope>()?.notifier;
}
