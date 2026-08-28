import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/screens/character_sheet_screen.dart';
import 'package:maichat/state/app_state.dart';
import 'package:maichat/widgets/avatar_image.dart';
import 'package:maichat/widgets/fab_menu.dart';
import 'package:maichat/widgets/message_bubble.dart';
import 'package:maichat/widgets/natural_image.dart';
import 'package:maichat/widgets/rich_notes_view.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The character sheet is layout-conditional in several independent ways — the
/// avatar's aspect ratio, whether the notes are rich or plain, how many greetings
/// the card carries, and which scenario is in force — so it is tested as a matrix
/// rather than in one configuration. Every "fixed it" on this app that shipped
/// broken was a single configuration passing.
///
/// Pictures are URLs whose ratio is pre-recorded: what is measured is the frame
/// the sheet gives a picture, which comes from the recorded ratio and not from any
/// decode, so no test here needs real image bytes.
String _pic(String tag) => 'https://example.com/$tag.png';

Character _card({
  String id = 'c',
  String name = 'Aria',
  String avatar = '',
  String notes = '',
  String scenario = '',
  String customScenario = '',
  String description = '',
  String firstMes = '',
  List<String> alternates = const <String>[],
  List<String> tags = const <String>[],
}) =>
    Character(
      id: id,
      name: name,
      avatar: avatar,
      creatorNotes: notes,
      scenario: scenario,
      customScenario: customScenario,
      description: description,
      firstMes: firstMes,
      alternateGreetings: alternates,
      tags: tags,
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    clearAvatarImageCache();
    imageCache.clear();
    imageCache.clearLiveImages();
  });

  Future<AppState> stateWith(Character character) async {
    final state = AppState();
    await state.init();
    await state.addCharacter(character);
    return state;
  }

  Widget host(AppState state, String id) =>
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(home: CharacterSheetScreen(characterId: id)),
      );

  Future<AppState> open(WidgetTester tester, Character character) async {
    final state = await stateWith(character);
    await tester.pumpWidget(host(state, character.id));
    await tester.pump();
    await tester.pump();
    return state;
  }

  Size drawnPicture(WidgetTester tester) =>
      tester.getSize(find.byKey(naturalImageFrameKey));

  /// Brings [target] into view. The header picture is deliberately large — on a
  /// phone a 1:1 avatar fills most of the screen — so anything under it is not
  /// built until it is scrolled to, and a test that forgets this reads as "the
  /// widget is missing".
  Future<void> scrollTo(WidgetTester tester, Finder target) async {
    await tester.scrollUntilVisible(
      target,
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
  }

  // --- the avatar takes its own shape ---------------------------------------

  group('avatar aspect ratio', () {
    const cases = <String, double>{
      'square': 1,
      'landscape': 16 / 9,
      'portrait': 3 / 4,
    };

    for (final entry in cases.entries) {
      testWidgets('a ${entry.key} avatar keeps its own ratio', (tester) async {
        final ref = _pic(entry.key);
        // Ratio already known (the app has drawn this picture before) — the case
        // that must not jump on open.
        noteAvatarRatio(ref, entry.value);
        await open(tester, _card(avatar: ref));

        final drawn = drawnPicture(tester);
        expect(
          drawn.width / drawn.height,
          closeTo(entry.value, 0.02),
          reason: 'the ${entry.key} picture lost its proportions',
        );
      });
    }

    testWidgets('an unmeasured avatar reserves a square rather than collapsing',
        (tester) async {
      await open(tester, _card(avatar: _pic('unmeasured')));
      final frame = tester.getSize(find.byType(NaturalImage));
      expect(frame.height, greaterThan(0));
      expect(frame.height, closeTo(frame.width, 1));
    });

    testWidgets('a very tall avatar is capped but keeps its ratio',
        (tester) async {
      final ref = _pic('tall');
      noteAvatarRatio(ref, 9 / 32);
      await open(tester, _card(avatar: ref));
      final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
      final drawn = drawnPicture(tester);
      expect(drawn.height, lessThan(screen.height));
      expect(drawn.width / drawn.height, closeTo(9 / 32, 0.02));
    });

    testWidgets('no avatar still gives a header with the name', (tester) async {
      await open(tester, _card(name: 'Nameless art'));
      expect(find.text('Nameless art'), findsOneWidget);
    });
  });

  // --- the name over the picture --------------------------------------------

  testWidgets("the name sits in the picture's lower-right", (tester) async {
    final ref = _pic('named');
    noteAvatarRatio(ref, 1);
    await open(tester, _card(name: 'Sumire', avatar: ref));
    final picture = tester.getRect(find.byType(NaturalImage));
    final name = tester.getRect(find.text('Sumire'));
    expect(name.bottom, lessThanOrEqualTo(picture.bottom + 1));
    expect(name.center.dx, greaterThan(picture.center.dx));
  });

  // --- tags ------------------------------------------------------------------

  group('tags', () {
    testWidgets('many tags stay on one horizontally scrolling line',
        (tester) async {
      await open(
        tester,
        _card(tags: List<String>.generate(24, (i) => 'tag-$i')),
      );
      await scrollTo(tester, find.text('tag-0'));
      final first = tester.getRect(find.text('tag-0'));
      final later = tester.getRect(find.text('tag-5'));
      expect(later.top, closeTo(first.top, 1),
          reason: 'the tags wrapped onto a second row instead of scrolling');
      expect(later.left, greaterThan(first.left));
    });

    testWidgets('no tags means no band at all', (tester) async {
      await open(tester, _card());
      expect(find.byType(Chip), findsNothing);
    });
  });

  // --- creator notes ---------------------------------------------------------

  group('creator notes', () {
    const styled = '<div style="background:#101018;padding:12px">'
        '<h2 style="color:#ffb86c;font-size:1.4rem">ARIA</h2>'
        '<p>A quiet librarian who <b>loves</b> books.</p>'
        '<img src="https://example.com/banner.png" width="400">'
        '</div>';

    testWidgets('a card with CSS notes renders them, images and all',
        (tester) async {
      await open(tester, _card(notes: styled));
      await scrollTo(tester, find.byType(RichNotes));
      expect(find.byType(RichNotes), findsOneWidget);
      // The engine built a real tree, not a text stand-in.
      expect(find.byType(Html), findsOneWidget);
      // The image went through the app's own capped/cached provider rather than
      // flutter_html's raw Image.network.
      expect(find.byType(Image), findsWidgets);
    });

    testWidgets('plain notes take the cheap path — no HTML engine',
        (tester) async {
      await open(
        tester,
        _card(notes: 'Just a sentence about who she is, written plainly.'),
      );
      await scrollTo(tester, find.textContaining('Just a sentence'));
      expect(find.byType(RichNotes), findsNothing);
      expect(find.byType(Html), findsNothing);
    });

    testWidgets('no notes means no notes block', (tester) async {
      await open(tester, _card());
      expect(find.byType(RichNotes), findsNothing);
      expect(find.text('CREATOR NOTES'), findsNothing);
    });
  });

  // --- the definition folds --------------------------------------------------

  group('folds', () {
    testWidgets('a fold builds its body only once opened', (tester) async {
      const body = 'She keeps the night shift at the archive.';
      await open(tester, _card(description: body));
      await scrollTo(tester, find.text('Description'));
      // skipOffstage: false on purpose — a fold that merely *hides* its body has
      // still paid for building it, which for a card with a dozen HTML greetings
      // is the whole cost this design exists to avoid.
      expect(find.text(body, skipOffstage: false), findsNothing,
          reason: 'a closed fold built its body anyway');
      await tester.tap(find.text('Description'));
      await tester.pumpAndSettle();
      expect(find.text(body), findsOneWidget);
    });

    testWidgets('an empty field has no fold at all', (tester) async {
      await open(tester, _card(description: 'Something'));
      await scrollTo(tester, find.text('Description'));
      expect(find.text('Personality'), findsNothing);
      expect(find.text('System prompt'), findsNothing);
    });
  });

  // --- greetings -------------------------------------------------------------

  group('greetings', () {
    testWidgets('a single greeting is drawn as a chat turn', (tester) async {
      await open(tester, _card(firstMes: 'Evening. Looking for something?'));
      await scrollTo(tester, find.text('Greetings'));
      await tester.tap(find.text('Greetings'));
      await tester.pumpAndSettle();
      expect(find.byType(MessageBubble), findsOneWidget);
      expect(
        find.textContaining('Looking for something?', findRichText: true),
        findsWidgets,
      );
    });

    testWidgets('several greetings each get their own nested fold',
        (tester) async {
      await open(
        tester,
        _card(
          firstMes: 'First hello.',
          alternates: ['Second hello.', 'Third hello.'],
        ),
      );
      await scrollTo(tester, find.text('Greetings'));
      expect(find.text('3 to choose from'), findsOneWidget);
      await tester.tap(find.text('Greetings'));
      await tester.pumpAndSettle();
      expect(find.text('First message'), findsOneWidget);
      expect(find.text('Alternate 1'), findsOneWidget);
      expect(find.text('Alternate 2'), findsOneWidget);
      // Nested and closed: no turn is built until one is opened.
      expect(find.byType(MessageBubble), findsNothing);
      // Scroll it clear of the action bubbles before tapping — a tap that lands
      // on the FAB layer opens the menu instead and the fold never opens.
      await scrollTo(tester, find.text('Alternate 2'));
      await tester.tap(find.text('Alternate 2'));
      await tester.pumpAndSettle();
      expect(find.byType(MessageBubble), findsOneWidget);
    });

    testWidgets("a greeting's HTML and CSS render like they will in the chat",
        (tester) async {
      await open(
        tester,
        _card(
          firstMes: '<div style="color:#ff8800">She waves.</div> '
              '<img src="https://example.com/wave.png">',
        ),
      );
      await scrollTo(tester, find.text('Greetings'));
      await tester.tap(find.text('Greetings'));
      await tester.pumpAndSettle();
      // The chat's own HTML path, not a plain-text fallback.
      expect(find.byType(Html), findsWidgets);
    });

    testWidgets('no greeting means no greetings fold', (tester) async {
      await open(tester, _card(description: 'Only a description.'));
      await scrollTo(tester, find.text('Description'));
      expect(find.text('Greetings'), findsNothing);
    });
  });

  // --- the scenario, card's and custom ---------------------------------------

  group('scenario', () {
    testWidgets("the card's scenario shows when there is no custom one",
        (tester) async {
      await open(tester, _card(scenario: 'A rainy night at the archive.'));
      await scrollTo(tester, find.text('Scenario'));
      await tester.tap(find.text('Scenario'));
      await tester.pumpAndSettle();
      expect(find.text('A rainy night at the archive.'), findsOneWidget);
      expect(find.text('Your own scenario'), findsNothing);
    });

    testWidgets('a custom scenario wins, and the card\'s is still readable',
        (tester) async {
      await open(
        tester,
        _card(
          scenario: 'A rainy night at the archive.',
          customScenario: 'A morning on the roof instead.',
        ),
      );
      await scrollTo(tester, find.text('Scenario'));
      expect(find.text('Your own scenario'), findsOneWidget);
      await tester.tap(find.text('Scenario'));
      await tester.pumpAndSettle();
      expect(find.text('A morning on the roof instead.'), findsOneWidget);
      expect(find.text('A rainy night at the archive.'), findsOneWidget);
    });

    testWidgets('writing one in the sheet saves it onto the character',
        (tester) async {
      final state = await open(tester, _card(scenario: 'Card scenario.'));
      // The row's own button opens the scenario picker now, so writing your own
      // is inside the fold, beside "Choose a scenario".
      await scrollTo(tester, find.text('Scenario'));
      await tester.tap(find.text('Scenario'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Write your own'));
      await tester.pumpAndSettle();
      expect(find.text('Custom scenario'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'Mine instead.');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(state.characterById('c')!.customScenario, 'Mine instead.');
      expect(state.characterById('c')!.activeScenario, 'Mine instead.');
      // The card's own is untouched underneath.
      expect(state.characterById('c')!.scenario, 'Card scenario.');
    });

    testWidgets("clearing it returns to the card's scenario", (tester) async {
      final state = await open(
        tester,
        _card(scenario: 'Card scenario.', customScenario: 'Mine.'),
      );
      await scrollTo(tester, find.text('Scenario'));
      await tester.tap(find.text('Scenario'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Write your own'));
      await tester.pumpAndSettle();
      await tester.tap(find.text("Use the card's"));
      await tester.pumpAndSettle();

      expect(state.characterById('c')!.customScenario, isEmpty);
      expect(state.characterById('c')!.activeScenario, 'Card scenario.');
    });

    testWidgets('a card with no scenario offers both ways to set one',
        (tester) async {
      await open(tester, _card());
      await scrollTo(tester, find.text('Scenario'));
      expect(find.text('None on this card'), findsOneWidget);
      // The picker rides on the collapsed row; writing your own is a tap deeper.
      expect(find.byTooltip('Choose a scenario'), findsOneWidget);
      await tester.tap(find.text('Scenario'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(FilledButton, 'Choose a scenario'),
          findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Write your own'), findsOneWidget);
    });
  });

  // --- the action bubbles ----------------------------------------------------

  group('the three-dot bubble', () {
    testWidgets('it offers a new chat, and a recent one only when there is one',
        (tester) async {
      final state = await open(tester, _card(firstMes: 'Hello.'));

      await tester.tap(find.byKey(fabMenuButtonKey));
      await tester.pumpAndSettle();
      expect(find.text('New chat'), findsOneWidget);
      expect(find.text('Most recent chat'), findsNothing,
          reason: 'offered a recent chat before any chat existed');

      // Close, give the character a real conversation, reopen. A card with a
      // greeting seeds the thread with it, so the thread is non-empty at once —
      // which is exactly what makes it a "recent chat" rather than a blank one.
      await tester.tap(find.byKey(fabMenuButtonKey));
      await tester.pumpAndSettle();

      final id = state.startChatWithCharacter(state.characterById('c')!);
      expect(state.mostRecentChatWith('c')?.id, id);
      await tester.pumpWidget(host(state, 'c'));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byKey(fabMenuButtonKey));
      await tester.pumpAndSettle();
      expect(find.text('Most recent chat'), findsOneWidget);
      expect(find.text('New chat'), findsOneWidget);
    });

    testWidgets('it is closed on open and costs no bubbles', (tester) async {
      await open(tester, _card());
      expect(find.text('New chat'), findsNothing);
      expect(find.byType(FloatingActionButton), findsOneWidget);
    });

    testWidgets('tapping away closes it', (tester) async {
      await open(tester, _card());
      await tester.tap(find.byKey(fabMenuButtonKey));
      await tester.pumpAndSettle();
      expect(find.text('New chat'), findsOneWidget);
      await tester.tapAt(const Offset(20, 300));
      await tester.pumpAndSettle();
      expect(find.text('New chat'), findsNothing);
    });
  });
}
