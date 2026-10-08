import 'package:famcoin/state/app_scope.dart';
import 'package:famcoin/ui/analytics/month_tab.dart';
import 'package:famcoin_core/famcoin_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'layout_test.dart' show pumpApp;
void main() {
  testWidgets('UI06 residual: incomplete previous month is excluded from category comparison too', (tester) async {
    final f = await pumpApp(tester,home:Scaffold(body:Builder(builder:(c)=>ListenableBuilder(listenable:AppScope.of(c).state,builder:(c,_)=>MonthTab(offset:0,onOffset:(_){},selectedDay:null,onSelectDay:(_){})))),size:const Size(390,2600),prefs:{'season':'none'});
    await f.state.addExpense(amount:kzt(1000),category:'food',account:'cash',date:DateTime(2026,8,15));
    await f.state.addExpense(amount:kzt(2000),category:'food',account:'cash',date:DateTime(2026,9,28));
    await tester.pumpAndSettle();
    expect(f.state.hasComparablePrev(DateTime(2026,9,1)),isFalse);
    expect(find.text('За прошлый месяц пока нет данных для сравнения'),findsOneWidget);
    final category=find.byKey(const ValueKey('chart-category-food'));
    expect(find.descendant(of:category,matching:find.textContaining('прошлый месяц:')),findsNothing);
    expect(tester.takeException(),isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
