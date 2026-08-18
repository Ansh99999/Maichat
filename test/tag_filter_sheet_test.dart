import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/screens/characters_screen.dart';
import 'package:maichat/state/app_state.dart';
import 'package:maichat/widgets/tag_filter_sheet.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The tag sheet used to render every tag on the roster at once, so an imported
/// collection with a few hundred tags filled the display from the drag handle to
/// the bottom of the screen with chips. What these check is the shape of the
/// replacement: a sheet no taller than three quarters of the display, a search
/// box over the tags, a bounded number of chips per query, and a chosen tag that
/// stays reachable even when the query would hide it.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  /// One character carrying [tags], so the roster's tag list is exactly [tags].
  Future<AppState> rosterWith(List<String> tags) async {
    final state = AppState();
    await state.init();
    await state.addCharacter(
      Character(id: 'c', name: 'Aria', tags: tags),
    );
    return state;
  }

  Widget host(AppState state) => ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: CharactersScreen()),
      );

  List<String> manyTags(int n) =>
      List<String>.generate(n, (i) => 'tag${i.toString().padLeft(3, '0')}');

  /// A roomy viewport. The test font is much wider per glyph than a real one, so
  /// a true phone width overflows the roster's own controls and gets in the way
  /// of what these tests are about — the sheet's height. [height] is chosen per
  /// test: 1000 makes 400 tags overflow the three-quarter cap, 1600 leaves the
  /// same list comfortably inside it.
  void useScreen(WidgetTester tester, {double height = 1600}) {
    tester.view.physicalSize = Size(900, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  double screenHeight(WidgetTester tester) =>
      tester.view.physicalSize.height / tester.view.devicePixelRatio;

  /// The sheet's own box: the drag handle the sheet stacks on top, plus the body.
  double sheetHeight(WidgetTester tester) =>
      tester.getSize(find.byType(TagFilterSheet)).height +
      kMinInteractiveDimension;

  Future<void> openSheet(WidgetTester tester) async {
    await tester.tap(find.text('Tags'));
    await tester.pumpAndSettle();
  }

  /// The sheet's search box, not the roster's behind it.
  Finder tagSearch() => find.byType(SearchBar).last;

  testWidgets('the sheet stops at three quarters of the screen', (tester) async {
    // Short enough that the chips this many tags produce would otherwise fill
    // the display — which is the bug.
    useScreen(tester, height: 1000);

    final state = await rosterWith(manyTags(400));
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();
    await openSheet(tester);

    final screen = screenHeight(tester);
    expect(sheetHeight(tester), lessThanOrEqualTo(screen * 0.75 + 0.5));
    // And it is a real sheet, not a sliver of one.
    expect(sheetHeight(tester), greaterThan(screen * 0.5));
    // The tags did not vanish with the height — the list scrolls instead.
    expect(find.byType(FilterChip), findsWidgets);
  });

  testWidgets('a short tag list shrinks the sheet instead of padding it out',
      (tester) async {
    useScreen(tester);

    final state = await rosterWith(const ['elf', 'knight']);
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();
    await openSheet(tester);

    expect(sheetHeight(tester), lessThan(screenHeight(tester) * 0.5));
    expect(find.text('elf'), findsOneWidget);
    expect(find.text('knight'), findsOneWidget);
  });

  testWidgets(
      'only a bounded number of chips is built, and search reaches the rest',
      (tester) async {
    useScreen(tester);

    final state = await rosterWith(manyTags(400));
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();
    await openSheet(tester);

    expect(find.byType(FilterChip), findsNWidgets(kTagsShown));
    expect(find.textContaining('of 400 tags'), findsOneWidget);
    // A tag past the cut is not on screen until it is searched for.
    expect(find.text('tag399'), findsNothing);

    await tester.enterText(tagSearch(), 'tag399');
    await tester.pumpAndSettle();
    // The chip, not the query echoed in the search field.
    expect(find.widgetWithText(FilterChip, 'tag399'), findsOneWidget);
    expect(find.byType(FilterChip), findsOneWidget);
  });

  testWidgets('a chosen tag filters the roster and survives a hiding query',
      (tester) async {
    useScreen(tester);

    final state = await rosterWith(const ['elf', 'knight']);
    await state
        .addCharacter(Character(id: 'd', name: 'Borin', tags: const ['dwarf']));
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();
    await openSheet(tester);

    await tester.tap(find.widgetWithText(FilterChip, 'elf'));
    await tester.pumpAndSettle();

    // A query that matches neither the chosen tag nor anything else still keeps
    // the chosen chip listed, so the filter can be switched back off.
    await tester.enterText(tagSearch(), 'zzz');
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilterChip, 'elf'), findsOneWidget);

    // Closing the sheet leaves the roster filtered to the tagged character.
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(find.text('1 tag'), findsOneWidget);
    expect(find.text('Aria'), findsWidgets);
    expect(find.text('Borin'), findsNothing);
  });
}
