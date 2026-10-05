// Сцена «Pro включён» (D110): появляется, анимация доходит до конца без
// ошибок, список открытого на месте, «Поехали» закрывает.
import 'package:famcoin/l10n/app_localizations.dart';
import 'package:famcoin/theme/app_theme.dart';
import 'package:famcoin/ui/more/pro_celebration.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('сцена Pro: вырастает, показывает открытое, закрывается кнопкой', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 732));
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('ru'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      theme: buildTheme(Brightness.dark),
      home: Builder(builder: (context) => Scaffold(body: Center(child: TextButton(onPressed: () => showProCelebration(context, until: DateTime(2027, 10, 5)), child: const Text('open'))))),
    ));
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Pro'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3)); // анимация 2,6 с + переход
    expect(find.text('Pro включён'), findsOneWidget);
    expect(find.textContaining('5 октября 2027'), findsOneWidget);
    expect(find.text('ИИ-консультант по вашим цифрам'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Поехали'));
    await tester.pump();
    await tester.tap(find.byType(FilledButton));
    await tester.pump(); // кадр на обработку нажатия
    await tester.pump(const Duration(milliseconds: 400)); // уход сцены (200 мс)
    expect(find.text('Pro включён'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
