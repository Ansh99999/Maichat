import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/screens/profile_screen.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The main profile renders the chosen persona as "you", and invites the user to
/// pick one when none is set. A roomy viewport keeps the wide test font from
/// overflowing the layout, which is not what these check.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  Future<AppState> emptyState() async {
    final state = AppState();
    await state.init();
    return state;
  }

  Widget host(AppState state) => ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: ProfileScreen()),
      );

  void useScreen(WidgetTester tester) {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('with no persona it invites the user to choose one',
      (tester) async {
    useScreen(tester);
    final state = await emptyState();
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    expect(find.text('No persona yet'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Choose persona'), findsOneWidget);
  });

  testWidgets('with a persona it shows the editable name and picker row',
      (tester) async {
    useScreen(tester);
    final state = await emptyState();
    await state.addCharacter(Character(id: 'me', name: 'Mai'));
    await state.setDefaultPersona('me');

    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    // Name is shown in an editable field.
    expect(find.widgetWithText(TextField, 'Mai'), findsOneWidget);
    // The default-persona swap row is present.
    expect(find.text('Default persona'), findsOneWidget);

    // The corner button opens the gallery-style picture menu.
    await tester.tap(find.byTooltip('Picture options'));
    await tester.pumpAndSettle();
    expect(find.text('Import picture'), findsOneWidget);
    expect(find.text('Export picture'), findsOneWidget);
  });
}
