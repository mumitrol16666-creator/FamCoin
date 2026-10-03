import 'package:famcoin/main.dart';
import 'package:famcoin/state/app_scope.dart';
import 'package:famcoin/state/app_state.dart';
import 'package:famcoin/state/secret_store.dart';
import 'package:famcoin/state/settings.dart';
import 'package:famcoin/ui/shell.dart';
import 'package:famcoin/ui/widgets/common.dart';
import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audit_regression_test.dart' show FakeServer;

Future<({FakeServer server, AppState state, Settings settings})> openApp(
  WidgetTester tester, {
  required DateTime now,
  bool carry = false,
  int spent = 5000,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({'season': 'none', 'pushPromptDismissed': true});
  final f = FakeServer()..now = now;
  await f.init();
  await f.state.send({'type': 'updateProfile', 'profile': {'onboarded': true}});
  await f.state.setDailyLimit(kzt(5000));
  if (carry) await f.state.setDailyLimitCarryOn(true);
  await f.state.addExpense(amount: kzt(spent), category: 'cafe', account: 'cash', date: f.state.today);
  final secrets = MemorySecretStore()..values['token'] = 'test-only';
  final settings = await Settings.load(api: f.state.api, secrets: secrets);
  await tester.pumpWidget(FamCoinApp(settings: settings, clock: () => f.now));
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 500));
  final state = AppScope.of(tester.element(find.byType(Shell))).state;
  addTearDown(f.state.dispose);
  return (server: f, state: state, settings: settings);
}

int headline(WidgetTester tester) => tester.widget<BigMoney>(find.byType(BigMoney).first).minor;

void main() {
  for (final carry in [false, true]) {
    testWidgets('полночь обновляет карточку без действий и сети; перенос=$carry', (tester) async {
      final app = await openApp(tester, now: DateTime(2026, 10, 2, 23, 59, 58), carry: carry);
      expect(headline(tester), 0);
      final revision = app.state.revision;
      final profile = Map<String, dynamic>.from(app.state.profile);
      app.server.offline = true;

      app.server.now = DateTime(2026, 10, 3);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 300));
      expect(headline(tester), kzt(5000));
      expect(app.state.spentToday(), 0);

      // Следующая полночь тоже работает; с переносом копится ещё один день.
      app.server.now = DateTime(2026, 10, 4);
      await tester.pump(const Duration(days: 1));
      expect(headline(tester), kzt(carry ? 10000 : 5000));
      expect(app.state.profile, profile, reason: 'смена даты не переписывает профиль и историю лимита');
      expect(app.state.revision, revision, reason: 'обновление экрана не создаёт финансовых команд');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('возврат после сна обновляет день и месяц до срабатывания старого таймера', (tester) async {
    final app = await openApp(tester, now: DateTime(2026, 9, 30, 22));
    expect(headline(tester), 0);
    expect(app.state.monthReport.expense, kzt(5000));
    app.server.offline = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    app.server.now = DateTime(2026, 10, 2, 8);
    // Время таймеров не двигали: имитируем приостановку приложения системой.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(headline(tester), kzt(5000));
    expect(app.state.monthReport.expense, 0);

    var notifications = 0;
    app.state.addListener(() => notifications++);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(notifications, 0, reason: 'возврат в тот же день не перерисовывает данные повторно');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1)); // задержки появления новых секций месяца
  });

  testWidgets('полночь сохраняет вчерашний перерасход, а не сбрасывает перенос', (tester) async {
    final app = await openApp(tester, now: DateTime(2026, 10, 2, 23, 59, 58), carry: true, spent: 6000);
    expect(headline(tester), -kzt(1000));
    app.server.now = DateTime(2026, 10, 3);
    await tester.pump(const Duration(seconds: 2));
    expect(headline(tester), kzt(4000));
    expect(app.state.dailyLimitCarry, -kzt(1000));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('смена дня сохраняет ограничение деньгами на счетах', (tester) async {
    final app = await openApp(tester, now: DateTime(2026, 10, 2, 23, 59, 58), spent: 98000);
    app.server.now = DateTime(2026, 10, 3);
    await tester.pump(const Duration(seconds: 2));
    expect(headline(tester), kzt(2000));
    expect(app.state.dailyLimitPlanned, kzt(5000));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('выход отменяет таймер прежней сессии', (tester) async {
    final app = await openApp(tester, now: DateTime(2026, 10, 2, 23, 59, 58));
    await app.settings.dropSession();
    await tester.pump();
    app.server.now = DateTime(2026, 10, 3);
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
    expect(find.byType(Shell), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
