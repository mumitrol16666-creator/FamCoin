/// Настройки устройства, сессия и PIN-код.
///
/// Счётчик ошибок и блокировку ведёт сервер (F003/F004). Здесь хранится
/// только время окончания блокировки из ответа сервера — для таймера.
/// Токен сессии и PIN-код лежат в защищённом хранилище устройства
/// ([SecretStore]); остальные настройки — в обычном.
library;

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'secret_store.dart';

class Settings extends ChangeNotifier {
  Settings._(this._prefs, this.api, this._secrets, {String? token, String? pinHash, String? pinSalt})
      : _token = token,
        _pinHash = pinHash,
        _pinSalt = pinSalt,
        _locked = pinHash != null;

  final SharedPreferences _prefs;
  final ApiClient api;
  final SecretStore _secrets;

  /// Сколько приложение может быть в фоне без повторного запроса PIN-кода.
  static const lockAfter = Duration(seconds: 30);

  static Future<Settings> load({ApiClient? api, SecretStore? secrets}) async {
    final prefs = await SharedPreferences.getInstance();
    final store = secrets ?? (kIsWeb ? PrefsSecretStore(prefs) : const SecureSecretStore());
    // Перенос сессии из старых сборок, где токен лежал в обычном хранилище.
    var token = await store.read('token');
    final legacy = prefs.getString('token');
    if (token == null && legacy != null) {
      token = legacy;
      await store.write('token', token);
    }
    if (legacy != null && store is! PrefsSecretStore) await prefs.remove('token');
    return Settings._(prefs, api ?? ApiClient(), store, token: token, pinHash: await store.read('pinHash'), pinSalt: await store.read('pinSalt'));
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

  /// Сезонная тема: auto | spring | autumn | winter | none (см. `resolveSeason`).
  String get season => _prefs.getString('season') ?? 'spring';
  set season(String value) {
    _prefs.setString('season', value);
    notifyListeners();
  }

  /// Карточка «включить уведомления на телефоне» на главной (D76) показана
  /// один раз на устройство: после «Позже» или включения больше не появляется.
  bool get pushPromptDismissed => _prefs.getBool('pushPromptDismissed') ?? false;
  Future<void> dismissPushPrompt() async {
    await _prefs.setBool('pushPromptDismissed', true);
    notifyListeners();
  }

  /// Советы на главной (D96): выключатель в настройках, по умолчанию включены.
  bool get tipsEnabled => _prefs.getBool('tipsEnabled') ?? true;
  set tipsEnabled(bool value) {
    _prefs.setBool('tipsEnabled', value);
    notifyListeners();
  }

  /// Номер текущего совета. Раз в сутки сдвигается на один сам (по
  /// локальной дате [today]), «Ещё совет» сдвигает сразу — см. [nextTip].
  /// Хранится на устройстве: совет — мелочь интерфейса, синхронизировать
  /// его между телефонами незачем.
  int tipCursor(DateTime today) {
    final day = '${today.year}-${today.month}-${today.day}';
    final stored = _prefs.getString('tipDay');
    var cursor = _prefs.getInt('tipCursor') ?? 0;
    if (stored != day) {
      if (stored != null) cursor++;
      _prefs.setInt('tipCursor', cursor);
      _prefs.setString('tipDay', day);
    }
    return cursor;
  }

  Future<void> nextTip() async {
    await _prefs.setInt('tipCursor', (_prefs.getInt('tipCursor') ?? 0) + 1);
    notifyListeners();
  }

  /// Советы по данным (D97) показываются один раз за свой период: код совета
  /// («перебор в кафе в октябре») запоминается после «Ещё совет». Список
  /// ограничен сотней последних — старые периоды уже не вернутся.
  Set<String> get seenTips => {...(_prefs.getStringList('tipSeen') ?? const [])};
  Future<void> markTipSeen(String id) async {
    final list = [...(_prefs.getStringList('tipSeen') ?? const <String>[]), id];
    await _prefs.setStringList('tipSeen', list.length > 100 ? list.sublist(list.length - 100) : list);
    notifyListeners();
  }

  /// Код входа через Telegram, который ждёт подтверждения в боте (D77).
  /// Хранится на устройстве: пока человек в Telegram, Android может усыпить
  /// или выгрузить приложение, и ожидание в памяти теряется. `null` — кода
  /// нет или он уже устарел.
  ({String code, String url})? get pendingTelegramLogin {
    final code = _prefs.getString('tgLoginCode');
    final url = _prefs.getString('tgLoginUrl');
    final until = _prefs.getInt('tgLoginUntil') ?? 0;
    if (code == null || url == null || DateTime.now().millisecondsSinceEpoch > until) return null;
    return (code: code, url: url);
  }

  Future<void> setPendingTelegramLogin(String code, String url) async {
    await _prefs.setString('tgLoginCode', code);
    await _prefs.setString('tgLoginUrl', url);
    // На сервере код живёт 10 минут; с запасом на расхождение часов — 9.
    await _prefs.setInt('tgLoginUntil', DateTime.now().add(const Duration(minutes: 9)).millisecondsSinceEpoch);
  }

  Future<void> clearPendingTelegramLogin() async {
    await _prefs.remove('tgLoginCode');
    await _prefs.remove('tgLoginUrl');
    await _prefs.remove('tgLoginUntil');
  }

  // ---------------------------------------------------------------- сессия

  String? _token;
  String? get token => _token;
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
    _token = r.token;
    await _secrets.write('token', r.token);
    await _prefs.setString('email', r.email);
    await _prefs.remove('lockUntil');
    notifyListeners();
  }

  /// Сессия больше не действует (истекла, отозвана или закрыта). PIN-код
  /// защищал именно эту сессию на этом устройстве — сбрасывается вместе с ней.
  Future<void> dropSession() async {
    _token = null;
    await _secrets.write('token', null);
    await clearPin();
    notifyListeners();
  }

  Future<void> signOut() async {
    final t = token;
    await dropSession();
    if (t != null) await api.logout(t);
  }

  // --------------------------------------------------------------- PIN-код

  String? _pinHash;
  String? _pinSalt;
  bool _locked;
  DateTime? _backgroundSince;

  bool get pinEnabled => _pinHash != null;

  /// Экран заблокирован: нужен PIN-код.
  bool get locked => pinEnabled && _locked;

  static String _hash(String pin, String salt) => sha256.convert(utf8.encode('$salt:$pin')).toString();

  bool verifyPin(String pin) => _pinHash != null && _pinSalt != null && _hash(pin, _pinSalt!) == _pinHash;

  Future<void> setPin(String pin) async {
    final rnd = Random.secure();
    final salt = base64Url.encode(List<int>.generate(16, (_) => rnd.nextInt(256)));
    _pinSalt = salt;
    _pinHash = _hash(pin, salt);
    await _secrets.write('pinSalt', salt);
    await _secrets.write('pinHash', _pinHash);
    _locked = false;
    notifyListeners();
  }

  Future<void> clearPin() async {
    if (_pinHash == null && _pinSalt == null) return;
    _pinHash = null;
    _pinSalt = null;
    _locked = false;
    await _secrets.write('pinHash', null);
    await _secrets.write('pinSalt', null);
    notifyListeners();
  }

  void lock() {
    if (!pinEnabled || _locked) return;
    _locked = true;
    notifyListeners();
  }

  bool unlock(String pin) {
    if (!verifyPin(pin)) return false;
    _locked = false;
    notifyListeners();
    return true;
  }

  /// Приложение ушло в фон / вернулось: после [lockAfter] снова просим PIN.
  void noteBackground() => _backgroundSince ??= DateTime.now();

  void noteResumed() {
    final since = _backgroundSince;
    _backgroundSince = null;
    if (since != null && DateTime.now().difference(since) >= lockAfter) lock();
  }
}
