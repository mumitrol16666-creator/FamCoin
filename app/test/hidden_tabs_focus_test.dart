/// Клавиатурный фокус не уходит в скрытые вкладки (аудит 08.10, UI02).
library;

import 'package:famcoin/ui/shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'layout_test.dart' show pumpApp;

/// Поле поиска Журнала (вкладка живёт в дереве и тогда, когда скрыта).
EditableText journalSearch(WidgetTester tester) => tester.widget<EditableText>(
      find.descendant(of: find.widgetWithText(TextField, 'Поиск по заметкам и категориям'), matching: find.byType(EditableText), skipOffstage: false),
    );

void main() {
  testWidgets('Tab на Главной обходит только видимое: поиск Журнала фокус не получает', (tester) async {
    await pumpApp(tester, home: const Shell(), size: const Size(390, 844), prefs: {'season': 'none'});
    await tester.pump(const Duration(seconds: 1));
    final search = journalSearch(tester).focusNode;
    for (var i = 0; i < 40; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(search.hasFocus, isFalse, reason: 'шаг $i: фокус в невидимом поле');
    }
  });

  testWidgets('на вкладке Журнала поиск доступен с клавиатуры; при уходе с вкладки фокус и ввод не остаются в скрытом поле', (tester) async {
    await pumpApp(tester, home: const Shell(), size: const Size(390, 844), prefs: {'season': 'none'});
    await tester.pump(const Duration(seconds: 1));
    final nav = find.byWidgetPredicate((w) => w is Material && w.child is SafeArea);
    await tester.tap(find.descendant(of: nav, matching: find.text('Операции')));
    await tester.pump(const Duration(milliseconds: 600));
    final search = journalSearch(tester).focusNode;
    var reached = false;
    for (var i = 0; i < 40 && !reached; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      reached = search.hasFocus;
    }
    expect(reached, isTrue, reason: 'видимое поле достижимо клавиатурой');

    await tester.tap(find.descendant(of: nav, matching: find.text('Главная')));
    await tester.pump(const Duration(milliseconds: 600));
    expect(search.hasFocus, isFalse, reason: 'скрытая вкладка отдала фокус');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pump();
    expect(journalSearch(tester).controller.text, isEmpty, reason: 'нажатия не попадают в невидимый поиск');
  });
}
