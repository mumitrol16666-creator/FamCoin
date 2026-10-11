/// D166: отклик на быструю операцию — индикатор на плитке до ответа сервера,
/// «монетка» с вибрацией после записи, два касания — две траты, выключатель
/// в настройках.
library;

import 'dart:async';

import 'package:famcoin/l10n/app_localizations.dart';
import 'package:famcoin/state/app_scope.dart';
import 'package:famcoin/state/models.dart';
import 'package:famcoin/state/secret_store.dart';
import 'package:famcoin/state/settings.dart';
import 'package:famcoin/theme/app_theme.dart';
import 'package:famcoin/ui/home/quick_actions.dart';
import 'package:famcoin/ui/more/settings_screen.dart';
import 'package:famcoin/ui/widgets/record_feedback.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audit_regression_test.dart' show FakeServer;

Future<(FakeServer, Settings)> pumpRow(WidgetTester tester, {Widget? home, Map<String, Object> prefs = const {}}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues(prefs);
  recordFeedbackLog.clear();
  final f = FakeServer();
  await f.init();
  await f.state.upsert('account', 'cash', {'name': 'Kaspi Gold', 'type': 'card'});
  await f.state.send({'type': 'updateProfile', 'profile': {'onboarded': true}});
  await f.state.upsert('quick', 'bus', const QuickAction('bus', 'Автобус', 'transport', 8000).toJson());
  final settings = await Settings.load(api: f.state.api, secrets: MemorySecretStore());
  await tester.pumpWidget(AppScope(
    settings: settings,
    stateOrNull: f.state,
    child: MaterialApp(
      locale: const Locale('ru'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      theme: buildTheme(Brightness.light),
      home: home ?? const Scaffold(body: QuickActionsRow()),
    ),
  ));
  await tester.pump(const Duration(seconds: 1));
  return (f, settings);
}

int rides(FakeServer f) => f.state.userTransactions.where((t) => t.meta['note'] == 'Автобус').length;

void main() {
  testWidgets('индикатор до ответа сервера, монетка после; два касания — две поездки', (tester) async {
    final (f, _) = await pumpRow(tester);
    final gate = Completer<void>();
    f.commandGate = gate.future;

    await tester.tap(find.text('Автобус'));
    await tester.pump();
    expect(find.byKey(const ValueKey('quick-busy-bus')), findsOneWidget, reason: 'нажатие видно сразу');
    expect(recordFeedbackLog, isEmpty, reason: 'звук только после подтверждения');
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('Автобус'));
    await tester.pump();

    gate.complete();
    f.commandGate = null;
    await tester.pumpAndSettle();
    expect(rides(f), 2, reason: 'владелец: «оплатил 2 проезда» — второе касание не глотается');
    expect(recordFeedbackLog, ['coin', 'coin']);
    expect(find.byKey(const ValueKey('quick-busy-bus')), findsNothing);
    expect(find.text('Автобус · 80 ₸'), findsWidgets);
  });

  testWidgets('ошибка сети: индикатор уходит, звука нет', (tester) async {
    final (f, _) = await pumpRow(tester);
    f.offline = true;
    await tester.tap(find.text('Автобус'));
    await tester.pumpAndSettle();
    expect(rides(f), 0);
    expect(recordFeedbackLog, isEmpty);
    expect(find.byKey(const ValueKey('quick-busy-bus')), findsNothing);
  });

  testWidgets('звук выключен в настройках — записывается тихо', (tester) async {
    final (f, _) = await pumpRow(tester, prefs: {'recordSound': false});
    await tester.tap(find.text('Автобус'));
    await tester.pumpAndSettle();
    expect(rides(f), 1);
    expect(recordFeedbackLog, isEmpty);
  });

  testWidgets('переключатель «Звук при записи» в настройках, по умолчанию включён', (tester) async {
    final (_, settings) = await pumpRow(tester, home: const SettingsScreen());
    expect(settings.recordSound, isTrue);
    await tester.dragUntilVisible(find.text('Звук при записи'), find.byType(ListView), const Offset(0, -200));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Звук при записи'));
    await tester.pumpAndSettle();
    expect(settings.recordSound, isFalse);
  });
}
