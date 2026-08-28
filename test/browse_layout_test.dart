import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/lorebook.dart';
import 'package:maichat/models/scenario.dart';
import 'package:maichat/models/view_prefs.dart';
import 'package:maichat/screens/characters_screen.dart';
import 'package:maichat/screens/library/lorebooks_screen.dart';
import 'package:maichat/screens/library/scenarios_screen.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Cards or rows is a preference, not a gesture: it says how the user likes to
/// read their own library, so it has to survive closing the app.
///
/// Every section used to reset to cards on the next launch, which meant making
/// the choice again on every single visit. The screen tests below each build the
/// screen, flip the toggle, then build a *fresh* screen from a *fresh* AppState
/// reading the same store — the closest a widget test gets to closing the app and
/// opening it again, and the only shape of test that would have caught this.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  Future<AppState> ready() async {
    final state = AppState();
    await state.init();
    return state;
  }

  Widget host(AppState state, Widget screen) =>
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(home: screen),
      );

  group('the model', () {
    test('an unset section falls back to the grid', () {
      const prefs = ViewPrefs();
      expect(prefs.layoutFor(BrowseSection.characters), BrowseLayout.grid);
      expect(
        prefs.layoutFor(BrowseSection.lorebooks, fallback: BrowseLayout.list),
        BrowseLayout.list,
      );
    });

    test('sections are remembered one at a time', () {
      final prefs = const ViewPrefs()
          .withLayout(BrowseSection.characters, BrowseLayout.list);
      expect(prefs.layoutFor(BrowseSection.characters), BrowseLayout.list);
      expect(prefs.layoutFor(BrowseSection.lorebooks), BrowseLayout.grid);
      expect(prefs.layoutFor(BrowseSection.scenarios), BrowseLayout.grid);
    });

    test('it round-trips through JSON, and junk reads as defaults', () {
      final prefs = const ViewPrefs()
          .withLayout(BrowseSection.scenarios, BrowseLayout.list);
      final back = ViewPrefs.fromJson(prefs.toJson());
      expect(back, prefs);
      expect(back.layoutFor(BrowseSection.scenarios), BrowseLayout.list);
      expect(
        ViewPrefs.fromJson(<String, dynamic>{'layouts': 'nonsense'})
            .layoutFor(BrowseSection.scenarios),
        BrowseLayout.grid,
      );
      expect(
        ViewPrefs.fromJson(<String, dynamic>{
          'layouts': {'characters': 'sideways'}
        }).layoutFor(BrowseSection.characters),
        BrowseLayout.grid,
      );
    });
  });

  group('persistence', () {
    test('a layout outlives the AppState that chose it', () async {
      final first = await ready();
      await first.setBrowseLayout(BrowseSection.characters, BrowseLayout.list);
      await first.setBrowseLayout(BrowseSection.lorebooks, BrowseLayout.list);

      final second = await ready();
      expect(second.browseLayout(BrowseSection.characters), BrowseLayout.list);
      expect(second.browseLayout(BrowseSection.lorebooks), BrowseLayout.list);
      // Untouched sections are still on the default.
      expect(second.browseLayout(BrowseSection.scenarios), BrowseLayout.grid);
    });

    test('setting the layout it already has writes nothing new', () async {
      final state = await ready();
      var notices = 0;
      state.addListener(() => notices++);
      await state.setBrowseLayout(BrowseSection.characters, BrowseLayout.grid);
      expect(notices, 0, reason: 'the grid was already the layout');
      await state.setBrowseLayout(BrowseSection.characters, BrowseLayout.list);
      expect(notices, 1);
    });

    test('going back to the grid is remembered too', () async {
      final first = await ready();
      await first.setBrowseLayout(BrowseSection.scenarios, BrowseLayout.list);
      await first.setBrowseLayout(BrowseSection.scenarios, BrowseLayout.grid);
      final second = await ready();
      expect(second.browseLayout(BrowseSection.scenarios), BrowseLayout.grid);
    });
  });
  group('the screens', () {
    /// Flips [screen]'s cards/rows toggle, then rebuilds the screen from a fresh
    /// AppState over the same store and reports what layout it came back in.
    Future<void> survivesRestart(
      WidgetTester tester, {
      required Widget Function() screen,
      required Future<void> Function(AppState) seed,
    }) async {
      final first = await ready();
      await seed(first);
      await tester.pumpWidget(host(first, screen()));
      await tester.pumpAndSettle();

      // Cards to begin with: the toggle offers the other one.
      expect(find.byTooltip('Show as list'), findsOneWidget);
      expect(find.byType(SliverGrid), findsOneWidget);

      await tester.tap(find.byTooltip('Show as list'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Show as grid'), findsOneWidget);
      expect(find.byType(SliverList), findsWidgets);

      // Close the app and open it again.
      final second = await ready();
      await tester.pumpWidget(host(second, screen()));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Show as grid'), findsOneWidget,
          reason: 'the chosen layout did not survive a restart');
      expect(find.byType(SliverGrid), findsNothing);
    }

    testWidgets('Characters keeps the layout it was left in', (tester) async {
      await survivesRestart(
        tester,
        screen: () => const CharactersScreen(),
        seed: (state) => state.addCharacter(Character(id: 'a', name: 'Aria')),
      );
    });

    testWidgets('Lorebooks keeps the layout it was left in', (tester) async {
      await survivesRestart(
        tester,
        screen: () => const LorebooksScreen(),
        seed: (state) => state.addLorebook(Lorebook(id: 'k', name: 'Kingdom')),
      );
    });

    testWidgets('Scenarios keeps the layout it was left in', (tester) async {
      await survivesRestart(
        tester,
        screen: () => const ScenariosScreen(),
        seed: (state) => state.addScenario(
          Scenario(id: 's', name: 'Snowed in', text: 'The radio is dead.'),
        ),
      );
    });

    testWidgets('each section is remembered on its own', (tester) async {
      final first = await ready();
      await first.addCharacter(Character(id: 'a', name: 'Aria'));
      await first.addLorebook(Lorebook(id: 'k', name: 'Kingdom'));

      await tester.pumpWidget(host(first, const CharactersScreen()));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Show as list'));
      await tester.pumpAndSettle();

      // Lorebooks was never touched, so it is still on cards.
      final second = await ready();
      await tester.pumpWidget(host(second, const LorebooksScreen()));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Show as list'), findsOneWidget);
      expect(find.byType(SliverGrid), findsOneWidget);
    });
  });
}
