import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/regex_rule.dart';
import 'package:maichat/screens/library/regex_screen.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<AppState> boot() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final state = AppState();
    await state.init();
    return state;
  }

  Widget host(AppState state) => ChangeNotifierProvider.value(
        value: state,
        child: const MaterialApp(home: RegexScreen()),
      );

  testWidgets('has a hamburger that opens the Library drawer', (tester) async {
    final state = await boot();
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    // The menu (hamburger) button, not a back arrow.
    expect(find.byTooltip('Open navigation menu'), findsOneWidget);
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    expect(find.text('Library'), findsOneWidget);
    // The drawer lists Regex among the Library destinations.
    expect(find.text('Regex'), findsWidgets);
  });

  testWidgets('search filters the rules by name', (tester) async {
    final state = await boot();
    await state.saveRegexRule(
        RegexRule(id: 'a', name: 'Trim OOC', find: 'x', replace: 'y'));
    await state.saveRegexRule(
        RegexRule(id: 'b', name: 'Italicise', find: 'x', replace: 'y'));

    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    expect(find.text('Trim OOC'), findsOneWidget);
    expect(find.text('Italicise'), findsOneWidget);

    await tester.enterText(find.byType(SearchBar), 'italic');
    await tester.pumpAndSettle();

    expect(find.text('Italicise'), findsOneWidget);
    expect(find.text('Trim OOC'), findsNothing);
  });

  testWidgets('search that matches nothing says so', (tester) async {
    final state = await boot();
    await state.saveRegexRule(
        RegexRule(id: 'a', name: 'Trim OOC', find: 'x', replace: 'y'));

    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(SearchBar), 'zzz');
    await tester.pumpAndSettle();

    expect(find.textContaining('No rules match'), findsOneWidget);
  });
}
