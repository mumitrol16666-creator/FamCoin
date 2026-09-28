/// Настройки устройства и сессия.
///
/// Счётчик ошибок и блокировку ведёт сервер (F003/F004). Здесь хранится
/// только время окончания блокировки из ответа сервера — для таймера.
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';

class Settings extends ChangeNotifier {
  Settings._(this._prefs, this.api);

  final SharedPreferences _prefs;
  final ApiClient api;

  static Future<Settings> load({ApiClient? api}) async {
    final prefs = await SharedPreferences.getInstance();
    return Settings._(prefs, api ?? ApiClient());
  }

  Locale get locale => Locale(_prefs.getString('lang') ?? 'ru');
  set locale(Locale value) {
    _prefs.setString('lang', value.languageCode);
    // На сервере тот же язык — сводки в Telegram приходят на нём. Без сети
    // обновится при следующем переключении; экран не ждёт ответа.
    final t = token;
    if (t != null) api.setLocale(t, value.languageCode).catchError((_) {});
    notifyListeners();
  }

  ThemeMode get themeMode =>
      ThemeMode.values.byName(_prefs.getString('theme') ?? 'system');
  set themeMode(ThemeMode value) {
    _prefs.setString('theme', value.name);
    notifyListeners();
  }

  /// Сезонная тема: auto | autumn | winter | none (см. `resolveSeason`).
  String get season => _prefs.getString('season') ?? 'auto';
  set season(String value) {
    _prefs.setString('season', value);
    notifyListeners();
  }

  // ---------------------------------------------------------------- сессия

  String? get token => _prefs.getString('token');
  String? get email => _prefs.getString('email');
  bool get signedIn => token != null;

  DateTime? get lockUntil {
    final ms = _prefs.getInt('lockUntil');
    if (ms == null) return null;
    final until = DateTime.fromMillisecondsSinceEpoch(ms);
    return until.isAfter(DateTime.now()) ? until : null;
  }

  Future<void> rememberLock(int seconds) async {
    await _prefs.setInt('lockUntil', DateTime.now().add(Duration(seconds: seconds)).millisecondsSinceEpoch);
    notifyListeners();
  }

  Future<void> signedInWith(AuthResult r) async {
    await _prefs.setString('token', r.token);
    await _prefs.setString('email', r.email);
    await _prefs.remove('lockUntil');
    notifyListeners();
  }

  /// Сессия больше не действует (истекла или отозвана на сервере).
  Future<void> dropSession() async {
    await _prefs.remove('token');
    notifyListeners();
  }

  Future<void> signOut() async {
    final t = token;
    await dropSession();
    if (t != null) await api.logout(t);
  }
}
