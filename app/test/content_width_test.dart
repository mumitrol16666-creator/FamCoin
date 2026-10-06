/// Ограничение ширины содержимого на экранах «планшетной» ширины.
library;

import 'package:famcoin/ui/widgets/content_width.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<(double, double)> measure(WidgetTester tester, double width) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  late double mqWidth;
  await tester.pumpWidget(MaterialApp(
    builder: (context, child) => ContentWidthCap(child: child!),
    home: Builder(builder: (context) {
      mqWidth = MediaQuery.sizeOf(context).width;
      return const SizedBox.expand(key: ValueKey('page'));
    }),
  ));
  return (tester.getSize(find.byKey(const ValueKey('page'))).width, mqWidth);
}

void main() {
  testWidgets('обычный телефон (390) и узкий (320) — без изменений', (tester) async {
    expect(await measure(tester, 390), (390.0, 390.0));
    expect(await measure(tester, 320), (320.0, 320.0));
  });

  testWidgets('ширина 600–900 (мелкий масштаб, планшет) — колонка 600 по центру, экран знает свою ширину', (tester) async {
    expect(await measure(tester, 880), (600.0, 600.0));
    expect(await measure(tester, 700), (600.0, 600.0));
    final left = tester.getTopLeft(find.byKey(const ValueKey('page'))).dx;
    expect(left, closeTo((700 - 600) / 2, 0.5));
  });

  testWidgets('широкий экран (900 и больше) — настольная вёрстка не сужается', (tester) async {
    expect(await measure(tester, 900), (900.0, 900.0));
    expect(await measure(tester, 1280), (1280.0, 1280.0));
  });
}
