/// Советы на главной (D96): какой совет показывается, как листается и когда
/// исчезает.
library;

import 'package:famcoin/l10n/app_localizations.dart';
import 'package:famcoin/l10n/app_localizations_ru.dart';
import 'package:famcoin/state/app_scope.dart';
import 'package:famcoin/state/models.dart';
import 'package:famcoin/ui/home/tips.dart';
import 'package:famcoin/ui/shell.dart';
import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'audit_regression_test.dart' show FakeServer;
import 'layout_test.dart' show pumpApp;

final AppLocalizations ru = AppLocalizationsRu();

Future<FakeServer> pumpHome(WidgetTester tester, {Map<String, Object> prefs = const {}}) =>
    pumpApp(tester, home: const Shell(), size: const Size(390, 844), prefs: {'pushPromptDismissed': true, ...prefs});

/// Смена совета: кадр на перестроение, затухание, кадр на уход старого текста.
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();
}

String shownTip(WidgetTester tester) {
  final card = find.ancestor(of: find.text(ru.adviceTitle), matching: find.byType(Card)).first;
  final texts = tester.widgetList<Text>(find.descendant(of: card, matching: find.byType(Text))).map((t) => t.data).whereType<String>().toList();
  return texts[1];
}

void main() {
  group('пул советов', () {
    testWidgets('у новичка: по очереди про приложение и про деньги; подсказки исчезают, когда сделано', (tester) async {
      final f = FakeServer();
      await f.init();
      final s = f.state;

      final fresh = tipsFor(s, ru);
      expect(fresh.map((t) => t.id).take(4), ['appLimit', 'moneyPayFirst', 'appGoal', 'moneyTenPercent']);
      expect(fresh.map((t) => t.id).toSet().length, fresh.length, reason: 'без повторов');
      expect(fresh.where((t) => t.id.startsWith('money')).length, 24);

      await s.setDailyLimit(kzt(5000));
      await s.upsert('quick', 'q1', const QuickAction('', 'Кофе', 'cafe', 150000).toJson());
      final later = tipsFor(s, ru);
      expect(later.map((t) => t.id), isNot(contains('appLimit')));
      expect(later.map((t) => t.id), isNot(contains('appQuick')));
      expect(later.map((t) => t.id), contains('appGoal'));
      // Общие советы остаются всегда: пул не бывает пустым.
      expect(later.where((t) => t.id.startsWith('money')).length, 24);

      // Ротация зациклена.
      expect(tipAt(later, later.length)!.id, later.first.id);
      expect(tipAt(later, 1)!.id, later[1].id);
    });
  });

  group('карточка на главной', () {
    testWidgets('первый день: лампочка и первый совет; «Ещё совет» листает дальше', (tester) async {
      final f = await pumpHome(tester);
      final pool = tipsFor(f.state, ru);
      expect(find.byIcon(Icons.lightbulb_outline), findsOneWidget);
      expect(shownTip(tester), pool[0].text);
      expect(find.text('${ru.adviceActLimit} ›'), findsOneWidget);

      // Список ленивый: карточка может быть построена, но ниже экрана.
      await tester.ensureVisible(find.text(ru.adviceNext));
      await tester.pump(); // прокрутка применяется следующим кадром
      await tester.tap(find.text(ru.adviceNext));
      await settle(tester);
      expect(shownTip(tester), pool[1].text);
      // У общего совета кнопки-перехода нет.
      expect(find.text('${ru.adviceActLimit} ›'), findsNothing);

      // Карточка стала короче (кнопки-перехода нет) и сдвинулась — снова в кадр.
      await tester.ensureVisible(find.text(ru.adviceNext));
      await tester.pump(); // прокрутка применяется следующим кадром
      await tester.tap(find.text(ru.adviceNext));
      await settle(tester);
      expect(shownTip(tester), pool[2].text);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('новый день сдвигает совет на один; тот же день — нет', (tester) async {
      // Вчера показывали совет № 3; сегодня (28.09 у FakeServer) — № 4.
      final f = await pumpHome(tester, prefs: {'tipDay': '2026-9-27', 'tipCursor': 3});
      final pool = tipsFor(f.state, ru);
      expect(shownTip(tester), pool[4].text);
      // Повторный вход в тот же день — совет тот же.
      final settings = AppScope.of(tester.element(find.byType(Shell))).settings;
      expect(settings.tipCursor(f.state.today), 4);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('кнопка-переход открывает форму лимита; после лимита подсказка про него уходит', (tester) async {
      final f = await pumpHome(tester);
      await tester.ensureVisible(find.text('${ru.adviceActLimit} ›'));
      await tester.pump();
      await tester.tap(find.text('${ru.adviceActLimit} ›'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text(ru.limitAmountDay), findsOneWidget);
      await f.state.setDailyLimit(kzt(5000));
      Navigator.of(tester.element(find.text(ru.limitAmountDay))).pop();
      await settle(tester);
      // Форма закрывается с анимацией и таймером поля ввода — даём им дойти.
      await tester.pump(const Duration(seconds: 1));
      // Пул сдвинулся: на месте № 0 теперь первый общий совет.
      expect(shownTip(tester), tipsFor(f.state, ru)[0].text);
      expect(find.text('${ru.adviceActLimit} ›'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('выключено в настройках — карточки нет', (tester) async {
      await pumpHome(tester, prefs: {'tipsEnabled': false});
      expect(find.byIcon(Icons.lightbulb_outline), findsNothing);
      expect(find.text(ru.adviceTitle), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('на 320 px и тексте 200 % — без переполнений', (tester) async {
      await pumpApp(tester, home: const Shell(), size: const Size(320, 694), textScale: 2, prefs: const {'pushPromptDismissed': true});
      // Секции появляются с затуханием: пока они прозрачны, переполнение не
      // рисуется и не ловится — поэтому прокручиваем и даём кадрам пройти.
      await tester.dragUntilVisible(find.byIcon(Icons.lightbulb_outline), find.byType(ListView).first, const Offset(0, -200));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byIcon(Icons.lightbulb_outline), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.dragUntilVisible(find.text(ru.recent), find.byType(ListView).first, const Offset(0, -300));
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
