import 'package:flutter/material.dart';

import 'l10n/app_localizations.dart';
import 'state/api_client.dart';
import 'state/app_scope.dart';
import 'state/app_state.dart';
import 'state/settings.dart';
import 'state/update_check.dart';
import 'theme/app_theme.dart';
import 'ui/auth/login_screen.dart';
import 'ui/auth/pin_screen.dart';
import 'ui/onboarding/onboarding_screen.dart';
import 'ui/shell.dart';
import 'ui/widgets/common.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await Settings.load();
  runApp(FamCoinApp(settings: settings));
}

class FamCoinApp extends StatefulWidget {
  const FamCoinApp({super.key, required this.settings, this.clock, this.updates});
  final Settings settings;
  final DateTime Function()? clock;

  /// Проверка обновлений (D103); `null` — создаётся своя по адресу API.
  final UpdateCheck? updates;

  @override
  State<FamCoinApp> createState() => _FamCoinAppState();
}

class _FamCoinAppState extends State<FamCoinApp> with WidgetsBindingObserver {
  AppState? _state;
  late final UpdateCheck _updates = widget.updates ?? UpdateCheck(site: apiUrl.replaceFirst(RegExp(r'/api$'), ''));

  Settings get settings => widget.settings;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    settings.addListener(_syncSession);
    _syncSession();
    _updates.start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    settings.removeListener(_syncSession);
    _state?.dispose();
    _updates.dispose();
    super.dispose();
  }

  /// PIN-код: после паузы в фоне приложение снова просит его.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        settings.noteResumed();
        _state?.checkDayChange();
        _updates.check();
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        settings.noteBackground();
    }
  }

  /// Данные владельца создаются при входе и сбрасываются при выходе.
  void _syncSession() {
    final token = settings.token;
    if (token == null) {
      if (_state != null) {
        _state!.dispose();
        setState(() => _state = null);
      }
      return;
    }
    if (_state?.token == token) return;
    _state?.dispose();
    final state = AppState(api: settings.api, token: token, clock: widget.clock);
    state.startDayUpdates();
    setState(() => _state = state);
    state.load().then((_) {
      final e = state.loadError;
      if (e is ApiException && e.code == 'unauthorized') settings.dropSession();
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final season = resolveSeason(settings.season, DateTime.now());
        return AppScope(
          settings: settings,
          stateOrNull: _state,
          child: UpdateScope(
            notifier: _updates,
            child: MaterialApp(
            title: 'FamCoin',
            debugShowCheckedModeBanner: false,
            locale: settings.locale,
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            theme: buildTheme(Brightness.light, season: season),
            darkTheme: buildTheme(Brightness.dark, season: season),
            themeMode: settings.themeMode,
            navigatorObservers: [routeObserver],
            home: _state == null
                ? const LoginScreen()
                : settings.locked
                    ? const PinLockScreen()
                    : _Home(state: _state!),
            ),
          ),
        );
      },
    );
  }
}

class _Home extends StatelessWidget {
  const _Home({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final l = context.l10n;
        if (!state.loaded) return const Scaffold(body: Center(child: CircularProgressIndicator()));
        if (state.loadError != null) {
          return Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.cloud_off_outlined, size: 40),
                    const SizedBox(height: 12),
                    Text(l.loadFailed, textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    FilledButton(onPressed: state.load, child: Text(l.retry)),
                    TextButton(
                      onPressed: () => AppScope.of(context).settings.signOut(),
                      child: Text(l.signOut),
                    ),
                  ],
                ),
              ),
            ),
          );
        }
        return state.onboarded ? const Shell() : const OnboardingScreen();
      },
    );
  }
}
