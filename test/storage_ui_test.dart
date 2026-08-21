import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/screens/settings/storage_category_screen.dart';
import 'package:maichat/screens/settings/storage_settings_page.dart';
import 'package:maichat/services/storage_report.dart';
import 'package:maichat/state/app_state.dart';
import 'package:maichat/widgets/storage_bar.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  Widget host(AppState state, Widget page) =>
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(home: page),
      );

  Character character(String id, String name, {int pad = 0}) =>
      Character(id: id, name: name, description: 'x' * pad);

  testWidgets('overview shows the used total, the bar, and category rows',
      (tester) async {
    final state = AppState();
    await state.addCharacter(character('a', 'Aria', pad: 4000));

    await tester.pumpWidget(host(state, const StorageSettingsPage()));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, 'Storage'), findsOneWidget);
    expect(find.text('Used'), findsOneWidget);
    expect(find.byType(StorageBar), findsOneWidget);
    expect(find.byType(StorageLegend), findsOneWidget);
    expect(find.text('Characters'), findsWidgets);
    // Every category has a row, including the empty placeholders further down.
    final scrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(find.text('Embeddings'), 200,
        scrollable: scrollable);
    expect(find.text('Embeddings'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Cache'), 200,
        scrollable: scrollable);
    expect(find.text('Cache'), findsOneWidget);
  });

  testWidgets('select-all then delete removes the items via app state',
      (tester) async {
    final state = AppState();
    await state.addCharacter(character('a', 'Aria'));
    await state.addCharacter(character('b', 'Bram'));

    await tester.pumpWidget(host(
      state,
      const StorageCategoryScreen(category: StorageCategory.characters),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Aria'), findsOneWidget);
    expect(find.text('Bram'), findsOneWidget);

    await tester.tap(find.text('Select all'));
    await tester.pumpAndSettle();
    expect(find.text('Delete (2)'), findsOneWidget);

    await tester.tap(find.text('Delete (2)'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(state.characters, isEmpty);
    expect(find.text('Aria'), findsNothing);
  });

  testWidgets('search filters the list by title', (tester) async {
    final state = AppState();
    await state.addCharacter(character('a', 'Alpha'));
    await state.addCharacter(character('b', 'Beta'));

    await tester.pumpWidget(host(
      state,
      const StorageCategoryScreen(category: StorageCategory.characters),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(SearchBar), 'Alph');
    await tester.pumpAndSettle();

    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsNothing);
  });

  testWidgets('sort reorders: largest-first vs A–Z put a different row on top',
      (tester) async {
    final state = AppState();
    // "Zed" is the biggest, "Ann" the smallest — so the two sorts disagree.
    await state.addCharacter(character('z', 'Zed', pad: 5000));
    await state.addCharacter(character('n', 'Ann', pad: 10));

    await tester.pumpWidget(host(
      state,
      const StorageCategoryScreen(category: StorageCategory.characters),
    ));
    await tester.pumpAndSettle();

    // Default is largest-first: Zed sits above Ann.
    expect(tester.getTopLeft(find.text('Zed')).dy,
        lessThan(tester.getTopLeft(find.text('Ann')).dy));

    // Switch to Name A–Z: Ann now sits above Zed.
    await tester.tap(find.byIcon(Icons.sort));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Name A–Z').last);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('Ann')).dy,
        lessThan(tester.getTopLeft(find.text('Zed')).dy));
  });

  testWidgets('clearing the cache empties the cache keys', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.modelCache': '{"p":["gpt"]}',
      'flutter.discover': '{"catalogue":"chub"}',
    });
    final state = AppState();

    await tester.pumpWidget(host(state, const StorageCacheScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Clear cache'));
    await tester.pumpAndSettle();

    final report = await state.storageReport();
    expect(report[StorageCategory.cache].bytes, 0);
    expect(find.text('Cache cleared'), findsOneWidget);
  });
}
