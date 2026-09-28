// Audit-only large-text check. Run from app/ with flutter test --no-pub.
import 'package:famcoin/l10n/app_localizations.dart';
import 'package:famcoin/state/app_scope.dart';
import 'package:famcoin/state/settings.dart';
import 'package:famcoin/theme/app_theme.dart';
import 'package:famcoin/ui/shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'audit_regression_test.dart' show Fixture;

void main() {
  testWidgets('Home at 320 logical px and 200% text must not overflow', (tester) async {
    tester.view.physicalSize = const Size(320, 694);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final f = Fixture(); await f.init();
    await f.state.upsert('account', 'cash', {'name': 'Kaspi Gold', 'type': 'card'});
    final settings = await Settings.load(api: f.state.api);
    await tester.pumpWidget(AppScope(
      settings: settings, stateOrNull: f.state,
      child: MaterialApp(
        locale: const Locale('ru'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        theme: buildTheme(Brightness.light),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: const Shell(),
      ),
    ));
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
