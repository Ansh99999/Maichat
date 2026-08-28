import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/scenario.dart';
import 'package:maichat/screens/character_sheet_screen.dart';
import 'package:maichat/screens/chat_settings_screen.dart';
import 'package:maichat/screens/library/library_screen.dart';
import 'package:maichat/screens/library/scenario_edit_screen.dart';
import 'package:maichat/screens/library/scenario_info.dart';
import 'package:maichat/screens/library/scenarios_screen.dart';
import 'package:maichat/state/app_state.dart';
import 'package:maichat/widgets/scenario_picker_sheet.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Drives the real scenario screens. The model, the codec and the wire have their
/// own tests; what these check is the seam a unit test cannot see — that the
/// screens are wired to the state, and that the picker's browse → preview → edit
/// → save → proceed path ends with the scenario the user chose actually applied.
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

  Scenario winter() => Scenario(
        id: 'w',
        name: 'Snowed in',
        text: 'The radio has been dead since Tuesday.',
        tags: const ['winter'],
      );

  Scenario heat() => Scenario(
        id: 'h',
        name: 'Heatwave',
        text: 'The tarmac is soft underfoot.',
        tags: const ['summer'],
      );

  group('the shelf', () {
    testWidgets('an empty shelf explains itself and offers the maker',
        (tester) async {
      final state = await ready();
      await tester.pumpWidget(host(state, const ScenariosScreen()));
      await tester.pumpAndSettle();

      expect(find.text('Scenarios'), findsWidgets);
      expect(find.text('No scenarios yet'), findsOneWidget);
      // Import, multi-select and the explainer are the app bar's three actions;
      // making one is the button under the thumb.
      expect(find.byTooltip('Import'), findsOneWidget);
      expect(find.byTooltip('Select multiple'), findsOneWidget);
      expect(find.byTooltip('About scenarios'), findsOneWidget);
      expect(find.widgetWithText(FloatingActionButton, 'New scenario'),
          findsOneWidget);
    });

    testWidgets('the i explains how to use them', (tester) async {
      final state = await ready();
      await tester.pumpWidget(host(state, const ScenariosScreen()));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('About scenarios'));
      await tester.pumpAndSettle();

      expect(find.byType(ScenarioInfoScreen), findsOneWidget);
      expect(find.text('What is a scenario?'), findsOneWidget);
      expect(find.text('Three places a scenario comes from'), findsOneWidget);
    });

    testWidgets('it lists what it holds, and search narrows it', (tester) async {
      final state = await ready();
      await state.addScenario(winter());
      await state.addScenario(heat());
      await tester.pumpWidget(host(state, const ScenariosScreen()));
      await tester.pumpAndSettle();

      expect(find.text('Snowed in'), findsOneWidget);
      expect(find.text('Heatwave'), findsOneWidget);

      await tester.enterText(find.byType(SearchBar), 'tarmac');
      await tester.pumpAndSettle();
      expect(find.text('Heatwave'), findsOneWidget);
      expect(find.text('Snowed in'), findsNothing);
    });

    testWidgets('multi-select deletes what was picked', (tester) async {
      final state = await ready();
      await state.addScenario(winter());
      await state.addScenario(heat());
      await tester.pumpWidget(host(state, const ScenariosScreen()));
      await tester.pumpAndSettle();

      await tester.longPress(find.text('Snowed in'));
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);

      await tester.tap(find.byTooltip('Delete selected'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(state.scenarios.map((s) => s.name), ['Heatwave']);
    });

    testWidgets('the Library card counts them and opens the shelf',
        (tester) async {
      final state = await ready();
      await state.addScenario(winter());
      await tester.pumpWidget(host(state, const LibraryScreen()));
      await tester.pumpAndSettle();

      expect(find.textContaining('1 scenario to plug into a chat'),
          findsOneWidget);
      await tester.tap(find.text('Scenarios'));
      await tester.pumpAndSettle();
      expect(find.byType(ScenariosScreen), findsOneWidget);
    });
  });
  group('the maker', () {
    testWidgets('title, tags, the prompt and what it costs', (tester) async {
      final state = await ready();
      await tester.pumpWidget(host(state, const ScenarioEditScreen()));
      await tester.pumpAndSettle();

      expect(find.text('New scenario'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Title'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Tags'), findsOneWidget);
      expect(find.text('The scenario'), findsOneWidget);
      expect(find.text('No tokens yet'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextField, 'Title'),
        'Snowed in',
      );
      // The prompt field is the only one with no label of its own.
      await tester.enterText(
        find.byType(TextField).last,
        'The radio has been dead since Tuesday.',
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('on every turn'), findsOneWidget);
      expect(find.text('No tokens yet'), findsNothing);

      await tester.tap(find.widgetWithText(TextButton, 'Save'));
      await tester.pumpAndSettle();

      expect(state.scenarios.length, 1);
      expect(state.scenarios.single.name, 'Snowed in');
      expect(state.scenarios.single.text,
          'The radio has been dead since Tuesday.');
      expect(state.scenarios.single.overwriteCharacterScenario, isTrue);
    });

    testWidgets('an empty scenario is refused rather than saved',
        (tester) async {
      final state = await ready();
      await tester.pumpWidget(host(state, const ScenarioEditScreen()));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'Title'),
        'Nothing',
      );
      await tester.tap(find.widgetWithText(TextButton, 'Save'));
      await tester.pumpAndSettle();

      expect(state.scenarios, isEmpty);
      expect(find.textContaining('write the opening first'), findsOneWidget);
    });

    testWidgets('"adds to" is a choice the maker offers', (tester) async {
      final state = await ready();
      await state.addScenario(winter());
      await tester.pumpWidget(
        host(state, ScenarioEditScreen(scenario: state.scenarios.single)),
      );
      await tester.pumpAndSettle();

      // The switch sits under the prompt field, past the foot of the viewport.
      await tester.scrollUntilVisible(
        find.text("Replace the character's scenario"),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.text("Replace the character's scenario"), findsOneWidget);
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Save'));
      await tester.pumpAndSettle();

      expect(state.scenarioById('w')!.overwriteCharacterScenario, isFalse);
    });

    testWidgets('backing out of unsaved work asks first', (tester) async {
      final state = await ready();
      // Pushed onto a route, so there is something to go back to.
      await tester.pumpWidget(host(
        state,
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<Scenario>(
                      builder: (_) => const ScenarioEditScreen()),
                ),
                child: const Text('make one'),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('make one'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).last, 'Half a thought');
      await tester.pumpAndSettle();

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Discard this scenario?'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Keep editing'));
      await tester.pumpAndSettle();
      expect(find.text('New scenario'), findsOneWidget);
      expect(state.scenarios, isEmpty);
    });
  });
  group('the picker', () {
    ScenarioPick? picked;

    /// A page whose only job is to open the picker and keep what it returns.
    Widget opener(AppState state,
            {String? currentScenarioId,
            String currentText = '',
            String cardScenario = ''}) =>
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () async {
                      picked = await showScenarioPickerSheet(
                        context,
                        localLabel: 'this chat',
                        currentScenarioId: currentScenarioId,
                        currentText: currentText,
                        cardScenario: cardScenario,
                      );
                    },
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        );

    Future<void> open(WidgetTester tester, Widget page) async {
      picked = null;
      await tester.pumpWidget(page);
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('it browses, then previews the one that was tapped',
        (tester) async {
      final state = await ready();
      await state.addScenario(winter());
      await state.addScenario(heat());
      await open(tester, opener(state));

      expect(find.text('Choose a scenario'), findsOneWidget);
      expect(find.text('Write a new one'), findsOneWidget);
      expect(find.text('Snowed in'), findsOneWidget);

      // The tag strip narrows the list without leaving the sheet.
      await tester.tap(find.widgetWithText(FilterChip, 'summer'));
      await tester.pumpAndSettle();
      expect(find.text('Heatwave'), findsOneWidget);
      expect(find.text('Snowed in'), findsNothing);
      await tester.tap(find.widgetWithText(FilterChip, 'summer'));
      await tester.pumpAndSettle();

      // The search bar does the same job for a phrase from the opening.
      await tester.enterText(find.byType(SearchBar), 'Tuesday');
      await tester.pumpAndSettle();
      expect(find.text('Snowed in'), findsOneWidget);
      expect(find.text('Heatwave'), findsNothing);

      await tester.tap(find.text('Snowed in'));
      await tester.pumpAndSettle();

      // The preview, in the same window: the prompt, what it costs, and Proceed.
      expect(find.textContaining('dead since Tuesday'), findsOneWidget);
      expect(find.textContaining("Replaces the character's"), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Proceed'), findsOneWidget);
    });

    testWidgets('Proceed hands back the scenario that was previewed',
        (tester) async {
      final state = await ready();
      await state.addScenario(winter());
      await open(tester, opener(state));
      await tester.tap(find.text('Snowed in'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Proceed'));
      await tester.pumpAndSettle();

      expect(picked, isNotNull);
      expect(picked!.scenarioId, 'w');
      expect(picked!.text, isEmpty, reason: 'unedited, so it stays a live link');
      expect(picked!.preview, 'The radio has been dead since Tuesday.');
      expect(picked!.isClear, isFalse);
    });

    testWidgets('an "adds to" scenario previews as it will be sent',
        (tester) async {
      final state = await ready();
      await state
          .addScenario(winter().copyWith(overwriteCharacterScenario: false));
      await open(tester, opener(state, cardScenario: 'A market at dawn.'));
      await tester.tap(find.text('Snowed in'));
      await tester.pumpAndSettle();

      expect(find.textContaining("Adds to the character's"), findsOneWidget);
      expect(find.textContaining('A market at dawn.'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Proceed'));
      await tester.pumpAndSettle();
      expect(picked!.preview,
          'A market at dawn.\n\nThe radio has been dead since Tuesday.');
    });

    testWidgets('editing happens in the same place, and asks where it goes',
        (tester) async {
      final state = await ready();
      await state.addScenario(winter());
      await open(tester, opener(state));
      await tester.tap(find.text('Snowed in'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Edit'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'The scenario'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextField, 'The scenario'),
        'The radio came back on.',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      // The question the flow turns on.
      expect(find.text('Save this scenario where?'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Just this chat'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'The library'), findsOneWidget);
    });

    testWidgets('saved to the library, the library says the new thing',
        (tester) async {
      final state = await ready();
      await state.addScenario(winter());
      await open(tester, opener(state));
      await tester.tap(find.text('Snowed in'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Edit'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'The scenario'),
        'The radio came back on.',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'The library'));
      await tester.pumpAndSettle();

      // Back on the preview, showing what was just saved.
      expect(find.widgetWithText(FilledButton, 'Proceed'), findsOneWidget);
      expect(find.textContaining('The radio came back on.'), findsOneWidget);
      expect(state.scenarioById('w')!.text, 'The radio came back on.');

      await tester.tap(find.widgetWithText(FilledButton, 'Proceed'));
      await tester.pumpAndSettle();
      expect(picked!.scenarioId, 'w');
      expect(picked!.text, isEmpty,
          reason: 'the library is authoritative again, so no local copy');
    });

    testWidgets('kept for here only, the library is left alone', (tester) async {
      final state = await ready();
      await state.addScenario(winter());
      await open(tester, opener(state));
      await tester.tap(find.text('Snowed in'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Edit'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'The scenario'),
        'Only here: the radio came back on.',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Just this chat'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Edited for this chat'), findsOneWidget);
      expect(state.scenarioById('w')!.text,
          'The radio has been dead since Tuesday.');

      await tester.tap(find.widgetWithText(FilledButton, 'Proceed'));
      await tester.pumpAndSettle();
      expect(picked!.scenarioId, 'w');
      expect(picked!.text, 'Only here: the radio came back on.');
    });

    testWidgets('one written on the spot can skip the library', (tester) async {
      final state = await ready();
      await open(tester, opener(state));

      await tester.tap(find.text('Write a new one'));
      await tester.pumpAndSettle();
      expect(find.text('Write a scenario'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextField, 'The scenario'),
        'A bright roof at noon.',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Just this chat'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Proceed'));
      await tester.pumpAndSettle();

      expect(state.scenarios, isEmpty, reason: 'it was never filed');
      expect(picked!.scenarioId, isNull);
      expect(picked!.text, 'A bright roof at noon.');
    });

    testWidgets('one written on the spot can be filed as it is used',
        (tester) async {
      final state = await ready();
      await open(tester, opener(state));
      await tester.tap(find.text('Write a new one'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Title'),
        'Rooftop',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'The scenario'),
        'A bright roof at noon.',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'The library'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Proceed'));
      await tester.pumpAndSettle();

      expect(state.scenarios.single.name, 'Rooftop');
      expect(picked!.scenarioId, state.scenarios.single.id);
      expect(picked!.text, isEmpty);
    });

    testWidgets('the way back to the character\'s own is offered when one is set',
        (tester) async {
      final state = await ready();
      await state.addScenario(winter());
      // Nothing set: no reason to offer clearing it.
      await open(tester, opener(state));
      expect(find.text("Use the character's own"), findsNothing);
      await tester.tapAt(const Offset(400, 30));
      await tester.pumpAndSettle();

      await open(tester, opener(state, currentScenarioId: 'w'));
      expect(find.text("Use the character's own"), findsOneWidget);
      await tester.tap(find.text("Use the character's own"));
      await tester.pumpAndSettle();
      expect(picked, isNotNull);
      expect(picked!.isClear, isTrue);
    });
  });
  group('where a scenario is chosen', () {
    testWidgets('the character sheet plugs one in for every new chat',
        (tester) async {
      final state = await ready();
      await state.addScenario(winter());
      await state.addCharacter(Character(
        id: 'a',
        name: 'Aria',
        scenario: 'A rainy night at the archive.',
      ));
      await tester.pumpWidget(
        host(state, const CharacterSheetScreen(characterId: 'a')),
      );
      await tester.pumpAndSettle();

      // The scenario fold is where the choice lives, below the portrait.
      await tester.scrollUntilVisible(
        find.text('Scenario'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Scenario'));
      await tester.pumpAndSettle();
      expect(find.text('Choose a scenario'), findsOneWidget);

      await tester.tap(find.text('Choose a scenario'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Snowed in'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Proceed'));
      await tester.pumpAndSettle();

      final aria = state.characterById('a')!;
      expect(aria.activeScenario, 'The radio has been dead since Tuesday.');
      expect(aria.scenario, 'A rainy night at the archive.',
          reason: "the card's own scenario is kept underneath");
    });

    testWidgets('chat settings sets one for that chat alone', (tester) async {
      final state = await ready();
      await state.addScenario(winter());
      final aria = Character(
        id: 'a',
        name: 'Aria',
        scenario: 'A rainy night at the archive.',
      );
      await state.addCharacter(aria);
      final chatId = state.startChatWithCharacter(aria);

      await tester.pumpWidget(
        host(state, ChatSettingsScreen(conversationId: chatId)),
      );
      await tester.pumpAndSettle();

      // The row says where the opening comes from before anything is chosen.
      expect(find.text('Scenario'), findsOneWidget);
      expect(find.textContaining("The character's own"), findsOneWidget);

      await tester.tap(find.text('Scenario'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Snowed in'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Proceed'));
      await tester.pumpAndSettle();

      final chat = state.conversationById(chatId)!;
      expect(chat.scenarioId, 'w');
      expect(state.scenarioFor(chat, aria),
          'The radio has been dead since Tuesday.');
      // The roster card is untouched — this was for one chat.
      expect(state.characterById('a')!.hasCustomScenario, isFalse);

      // And Reset puts the chat back on the card's own. The row now names the
      // scenario it is running, so the title reads inside a longer line.
      expect(find.textContaining('Snowed in'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Reset'));
      await tester.pumpAndSettle();
      expect(state.conversationById(chatId)!.hasScenarioOfItsOwn, isFalse);
    });
  });
}
