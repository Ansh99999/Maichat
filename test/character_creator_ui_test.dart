import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/character_theme.dart';
import 'package:maichat/models/lorebook.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/screens/character_creator/creator_avatar_header.dart';
import 'package:maichat/screens/character_creator/creator_screen.dart';
import 'package:maichat/screens/library/lorebook_edit_screen.dart';
import 'package:maichat/services/character_writer.dart';
import 'package:maichat/services/chat_client.dart';
import 'package:maichat/state/app_state.dart';
import 'package:maichat/widgets/avatar_dots.dart';
import 'package:maichat/widgets/message_bubble.dart';
import 'package:provider/provider.dart' hide Provider;
import 'package:shared_preferences/shared_preferences.dart';

/// Answers with whatever it was told to, and keeps what it was sent — enough to
/// drive "let the AI write this" without a model behind it.
class FakeClient extends ChatClient {
  FakeClient({this.reply = '', this.error});

  String reply;
  String? error;
  List<ChatMessage>? lastHistory;

  @override
  Stream<ChatDelta> streamChat({
    required Provider provider,
    required List<ChatMessage> history,
    GenParams params = const GenParams(),
  }) async* {
    lastHistory = List<ChatMessage>.from(history);
    if (error != null) throw ChatApiException(error!);
    yield ChatDelta(text: reply);
  }

  @override
  Future<List<String>> listModels(Provider provider) async => const [];
}

/// Creator v2's screens: the six tabs, what Save actually writes, and the
/// assistant that writes a field for you.
///
/// What the new *data* does is covered by `character_creator_test.dart`. This file
/// is about the wiring: that a tab shows what the card says, that nothing reaches
/// the roster except what Save built, and that backing out of unsaved work asks
/// first.
void main() {
  Future<AppState> boot({ChatClient? client}) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final state = client == null ? AppState() : AppState(client: client);
    await state.init();
    await state.addProvider(Provider(
      id: 'p',
      name: 'Test',
      kind: ProviderKind.openai,
      baseUrl: 'https://host.tld/v1',
      apiKey: 'k',
      model: 'gpt-test',
    ));
    return state;
  }

  /// A phone-shaped window, tall enough that the tab under the portrait is really
  /// built: the header takes 30% of the height, and a `ListView` only builds what
  /// is near its viewport.
  void tall(WidgetTester tester, {double height = 1500}) {
    tester.view.physicalSize = Size(440, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  /// Opens the creator on a pushed route, so backing out is a real pop and the
  /// card Save hands back can be caught in [popped].
  Future<void> open(
    WidgetTester tester,
    AppState state, {
    Character? character,
    bool persist = true,
    List<Character?>? popped,
  }) async {
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  final card = await Navigator.of(context).push<Character>(
                    MaterialPageRoute<Character>(
                      builder: (_) => CharacterCreatorScreen(
                        character: character,
                        persist: persist,
                      ),
                    ),
                  );
                  popped?.add(card);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  /// Moves to a tab by name. Six tabs do not fit a 440-wide bar, so the bar is
  /// scrolled until the one wanted is on screen before it is tapped.
  Future<void> goTo(WidgetTester tester, String tab) async {
    final target = find.widgetWithText(Tab, tab);
    await tester.dragUntilVisible(
      target,
      find.byType(TabBar),
      const Offset(-90, 0),
    );
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  /// The box inside one of the creator's keyed fields — or the box itself, for
  /// the few that carry the key on the `TextField`.
  Finder boxOf(String key) => find.descendant(
        of: find.byKey(Key(key)),
        matching: find.byType(TextField),
        matchRoot: true,
      );

  /// A button inside one of those fields, by its tooltip.
  Finder inField(String key, String tooltip) => find.descendant(
        of: find.byKey(Key(key)),
        matching: find.byTooltip(tooltip),
      );

  String textOf(WidgetTester tester, String key) =>
      tester.widget<TextField>(boxOf(key)).controller!.text;

  /// Advances the clock in small steps. A reply in flight draws a spinner in the
  /// pending bubble, so `pumpAndSettle` would never return while it is working.
  Future<void> work(WidgetTester tester, [int steps = 14]) async {
    for (var i = 0; i < steps; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  /// Closes a modal sheet by tapping its barrier.
  Future<void> dismissSheet(WidgetTester tester) async {
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
  }

  group('the screen', () {
    testWidgets('opens on Identity, six tabs under the portrait',
        (tester) async {
      tall(tester);
      final state = await boot();
      await open(tester, state);

      expect(find.text('New character'), findsOneWidget);
      for (final name in const [
        'Identity',
        'Persona',
        'Greetings',
        'Scenarios',
        'Lorebooks',
        'Advanced',
      ]) {
        expect(find.widgetWithText(Tab, name), findsOneWidget, reason: name);
      }
      // The picture belongs to the screen, not to one of the tabs.
      expect(find.text('No picture yet'), findsOneWidget);
      expect(find.byTooltip('Add a picture'), findsOneWidget);
      // Identity is what is on show, and the title is folded away behind its
      // switch.
      expect(find.byKey(const Key('creator-name')), findsOneWidget);
      expect(find.text('No tags yet.'), findsOneWidget);
      expect(find.byKey(const Key('creator-title')), findsNothing);
    });

    testWidgets('a sideways drag moves to the next tab', (tester) async {
      tall(tester);
      final state = await boot();
      await open(tester, state);

      // From empty space below the fields: a vertical list does not claim a
      // horizontal drag, so the tab view's own page gesture wins the arena.
      await tester.dragFrom(const Offset(220, 1300), const Offset(-400, 0));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('creator-description')), findsOneWidget);
      expect(find.text('No tags yet.'), findsNothing);
    });

    testWidgets('the keyboard puts the portrait away, tabs and all',
        (tester) async {
      tall(tester);
      final state = await boot();
      await open(tester, state);
      expect(find.text('No picture yet'), findsOneWidget);

      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();

      expect(find.text('No picture yet'), findsNothing);
      // The tabs are still there — that is the point of collapsing the picture
      // rather than the whole header.
      expect(find.widgetWithText(Tab, 'Identity'), findsOneWidget);
      expect(find.byKey(const Key('creator-name')), findsOneWidget);
    });
  });

  group('the portrait', () {
    testWidgets('scrolls away and leaves the tabs pinned at the top',
        (tester) async {
      tall(tester);
      final state = await boot();
      await open(tester, state);

      // It starts under the picture…
      final before = tester.getTopLeft(find.byType(TabBar)).dy;
      expect(before, greaterThan(200));

      await tester.drag(find.byType(CustomScrollView).first, const Offset(0, -600));
      await tester.pumpAndSettle();

      // …and ends up directly under the app bar, with the picture lifted clean
      // off the top — which is the whole point: the tab gets the display.
      final after = tester.getTopLeft(find.byType(TabBar)).dy;
      expect(after, lessThan(before));
      expect(after, lessThanOrEqualTo(kToolbarHeight));
      expect(find.byType(CreatorAvatarHeader), findsNothing);
      // And the tab starts *below* the bar rather than under it: the overlap the
      // pinned bar takes is injected back into the tab's own scroll view, so the
      // first thing on it is still readable and still tappable.
      final barBottom = tester.getBottomLeft(find.byType(TabBar)).dy;
      expect(tester.getTopLeft(find.byKey(const Key('creator-name'))).dy,
          greaterThanOrEqualTo(barBottom),
          reason: 'the top of the tab is hiding under the tab bar');

      // Switching tabs from there is still one tap, and the bar has not moved.
      await goTo(tester, 'Persona');
      expect(find.byKey(const Key('creator-description')), findsOneWidget);
      expect(tester.getTopLeft(find.byType(TabBar)).dy, after);
    });

    testWidgets('a run of pictures is swiped, and where you stop is what the '
        'card wears', (tester) async {
      tall(tester);
      final state = await boot();
      await open(
        tester,
        state,
        character: Character(
          id: 'c',
          name: 'Aria',
          avatar: 'https://example.com/one.png',
          avatars: const [
            'https://example.com/two.png',
            'https://example.com/three.png',
          ],
        ),
      );

      final pager = find.descendant(
        of: find.byType(CreatorAvatarHeader),
        matching: find.byType(PageView),
      );
      expect(pager, findsOneWidget);
      expect(tester.widget<AvatarDots>(find.byType(AvatarDots)).count, 3);
      expect(tester.widget<AvatarDots>(find.byType(AvatarDots)).index, 0);

      await tester.drag(pager, const Offset(-400, 0));
      await tester.pumpAndSettle();
      expect(tester.widget<AvatarDots>(find.byType(AvatarDots)).index, 1);

      await tester.tap(find.byKey(const Key('creator-save')));
      await tester.pumpAndSettle();
      final saved = state.characterById('c')!;
      expect(saved.avatar, 'https://example.com/two.png');
      // Nothing is lost by looking: the rest of the run stays, in its own order.
      expect(saved.avatars, [
        'https://example.com/one.png',
        'https://example.com/three.png',
      ]);
    });

    testWidgets('one picture draws no dots at all', (tester) async {
      tall(tester);
      final state = await boot();
      await open(
        tester,
        state,
        character: Character(
          id: 'c',
          name: 'Aria',
          avatar: 'https://example.com/one.png',
        ),
      );
      expect(find.byType(AvatarDots), findsNothing);
    });

    testWidgets('a quiet pencil is the whole control, and it opens the sources',
        (tester) async {
      tall(tester);
      final state = await boot();
      await open(tester, state);

      // No button with a label on the picture — one pencil, and that is all.
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byIcon(Icons.edit_outlined), findsOneWidget);

      await tester.tap(find.byKey(const Key('creator-avatar-button')));
      await tester.pumpAndSettle();
      for (final source in const [
        'Image URL',
        'App gallery',
        'This device',
        'Generate one',
      ]) {
        expect(find.text(source), findsOneWidget, reason: source);
      }
      // Nothing to remove while there is no picture.
      expect(find.text('Remove this picture'), findsNothing);
    });

    testWidgets('removing the picture on show asks first', (tester) async {
      tall(tester);
      final state = await boot();
      await open(
        tester,
        state,
        character: Character(
          id: 'c',
          name: 'Aria',
          avatar: 'https://example.com/one.png',
        ),
      );
      // A picture on the card, so the pencil offers to change it rather than to
      // add one. (What is *drawn* proves nothing here: a URL never loads in a
      // test, so the empty state is on screen either way.)
      expect(find.byTooltip('Change the picture'), findsOneWidget);

      await tester.tap(find.byKey(const Key('creator-avatar-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('creator-avatar-remove')));
      await tester.pumpAndSettle();
      expect(find.text('Remove this picture?'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('creator-avatar-remove')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await tester.pumpAndSettle();

      expect(find.byTooltip('Add a picture'), findsOneWidget);
      await tester.tap(find.byKey(const Key('creator-save')));
      await tester.pumpAndSettle();
      expect(state.characterById('c')!.avatar, isEmpty);
      expect(state.characterById('c')!.avatars, isEmpty);
    });
  });

  group('Identity', () {
    testWidgets('the switch is what decides a title is used', (tester) async {
      tall(tester);
      final state = await boot();
      await open(tester, state);

      await tester.enterText(boxOf('creator-name'), 'Serina');
      expect(find.byKey(const Key('creator-title')), findsNothing);

      await tester.tap(find.byKey(const Key('creator-title-toggle')));
      await tester.pumpAndSettle();
      await tester.enterText(
        boxOf('creator-title'),
        'she was your sister, back then',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('creator-save')));
      await tester.pumpAndSettle();

      final card = state.characters.single;
      expect(card.name, 'Serina');
      expect(card.title, 'she was your sister, back then');
      expect(card.titleShown, isTrue);
      expect(card.hasTitle, isTrue);
    });

    testWidgets('switching the title off keeps the words', (tester) async {
      tall(tester);
      final state = await boot();
      final card = Character(
        id: 'c',
        name: 'Serina',
        title: 'she was your sister',
        titleShown: true,
      );
      await state.addCharacter(card);
      await open(tester, state, character: card);

      expect(textOf(tester, 'creator-title'), 'she was your sister');
      await tester.tap(find.byKey(const Key('creator-title-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('creator-save')));
      await tester.pumpAndSettle();

      final saved = state.characterById('c')!;
      expect(saved.titleShown, isFalse);
      expect(saved.title, 'she was your sister');
      expect(saved.hasTitle, isFalse);
    });

    testWidgets('a tag written in the tag engine lands on the card',
        (tester) async {
      tall(tester);
      final state = await boot();
      await open(tester, state);

      await tester.enterText(boxOf('creator-name'), 'Serina');
      await tester.tap(find.byKey(const Key('creator-tags-add')));
      await tester.pumpAndSettle();

      expect(find.text('Tags for this character'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('tag-editor-search')),
        'harbour',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('tag-editor-add')));
      await tester.pumpAndSettle();
      await dismissSheet(tester);

      // On the tab as a chip, and on the card once it is saved.
      expect(find.widgetWithText(InputChip, 'harbour'), findsOneWidget);
      expect(find.text('No tags yet.'), findsNothing);
      await tester.tap(find.byKey(const Key('creator-save')));
      await tester.pumpAndSettle();
      expect(state.characters.single.tags, ['harbour']);
    });

    testWidgets('Save with no name writes nothing and says why',
        (tester) async {
      tall(tester);
      final state = await boot();
      await open(tester, state);

      await goTo(tester, 'Persona');
      await tester.enterText(boxOf('creator-description'), 'A dockworker.');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('creator-save')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Give them a name first.'), findsOneWidget);
      expect(state.characters, isEmpty);
      // Let the snackbar go before the test ends, so no timer outlives it.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      // It jumped back to the tab holding the field it is complaining about…
      expect(find.byKey(const Key('creator-name')), findsOneWidget);
      // …and the writing that was done is still there, on a tab that was
      // rebuilt in the meantime. That is what the draft is for.
      await goTo(tester, 'Persona');
      expect(textOf(tester, 'creator-description'), 'A dockworker.');
    });
  });

  group('backing out', () {
    testWidgets('an untouched card just closes', (tester) async {
      tall(tester);
      final state = await boot();
      await open(tester, state);

      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      expect(find.text('Discard this character?'), findsNothing);
      expect(find.widgetWithText(Tab, 'Identity'), findsNothing);
      expect(find.text('open'), findsOneWidget);
    });

    testWidgets('work in progress asks first, and Keep editing keeps it',
        (tester) async {
      tall(tester);
      final state = await boot();
      await open(tester, state);
      await tester.enterText(boxOf('creator-name'), 'Serina');
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();
      expect(find.text('Discard this character?'), findsOneWidget);
      expect(find.text('Nothing has been saved yet.'), findsOneWidget);

      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(textOf(tester, 'creator-name'), 'Serina');

      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();

      expect(find.text('open'), findsOneWidget);
      expect(state.characters, isEmpty);
    });

    testWidgets('an edit is told what it stands to lose', (tester) async {
      tall(tester);
      final state = await boot();
      final card = Character(id: 'c', name: 'Serina', description: 'calm');
      await state.addCharacter(card);
      await open(tester, state, character: card);

      await goTo(tester, 'Persona');
      await tester.enterText(boxOf('creator-description'), 'furious');
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      expect(find.text('The changes you made will be lost.'), findsOneWidget);
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      expect(state.characterById('c')!.description, 'calm');
    });

    testWidgets('with persist off Save hands the card back instead',
        (tester) async {
      tall(tester);
      final state = await boot();
      final popped = <Character?>[];
      await open(tester, state, persist: false, popped: popped);

      await tester.enterText(boxOf('creator-name'), 'Serina');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('creator-save')));
      await tester.pumpAndSettle();

      expect(popped.single?.name, 'Serina');
      expect(state.characters, isEmpty);
    });
  });

  group('greetings', () {
    testWidgets('the first is the opening line, the rest are alternates',
        (tester) async {
      tall(tester, height: 2000);
      final state = await boot();
      await open(tester, state);
      await tester.enterText(boxOf('creator-name'), 'Serina');
      await goTo(tester, 'Greetings');

      // One fold, open, and one box inside it — the greeting is named by the fold
      // and nowhere else.
      expect(find.text('First message'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Evening.');
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('creator-add-greeting')));
      await tester.pumpAndSettle();
      expect(find.text('Greeting 2'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, 'Or this way.');
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('creator-save')));
      await tester.pumpAndSettle();

      final card = state.characters.single;
      expect(card.firstMes, 'Evening.');
      expect(card.alternateGreetings, ['Or this way.']);
      expect(card.greetings, ['Evening.', 'Or this way.']);
    });

    testWidgets('the only greeting cannot be removed, an extra one can',
        (tester) async {
      tall(tester, height: 2000);
      final state = await boot();
      await open(tester, state);
      await goTo(tester, 'Greetings');

      expect(find.byKey(const Key('creator-remove-greeting-0')), findsNothing);
      await tester.tap(find.byKey(const Key('creator-add-greeting')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('creator-remove-greeting-1')),
        findsOneWidget,
      );

      // Nothing is taken away on one tap: the fold's Remove asks first, and
      // Cancel means the greeting is still there.
      await tester.tap(find.byKey(const Key('creator-remove-greeting-1')));
      await tester.pumpAndSettle();
      expect(find.text('Remove this greeting?'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      // Still there — the fold that names it is the only place it is named.
      expect(find.text('Greeting 2'), findsOneWidget);

      await tester.tap(find.byKey(const Key('creator-remove-greeting-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await tester.pumpAndSettle();
      expect(find.text('Greeting 2'), findsNothing);
      expect(find.byKey(const Key('creator-remove-greeting-0')), findsNothing);
    });

    testWidgets('the drop-down arrow never moves, and the tools pop out',
        (tester) async {
      tall(tester, height: 2000);
      final state = await boot();
      await open(tester, state);
      await goTo(tester, 'Greetings');

      final arrow = find.byIcon(Icons.expand_more);
      final openArrow = tester.getCenter(arrow.first);
      // Right of everything else on the row — including the tools, which arrive
      // to its left.
      expect(openArrow.dx,
          greaterThan(tester.getCenter(find.byTooltip('Write full screen')).dx));

      await tester.tap(find.text('First message'));
      await tester.pumpAndSettle();
      // Closed: same place, to the pixel. It is the one thing on the row whose
      // position must not move.
      expect(tester.getCenter(arrow.first), openArrow);

      // Opening it again fades and scales the tools in rather than blinking them
      // into place.
      await tester.tap(find.text('First message'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 70));
      final midway = tester
          .widgetList<Opacity>(find.byType(Opacity))
          .map((o) => o.opacity)
          .where((o) => o > 0 && o < 1);
      expect(midway, isNotEmpty, reason: 'the tools appeared with no animation');
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<Opacity>(find.byType(Opacity))
            .every((o) => o.opacity == 1 || o.opacity == 0),
        isTrue,
        reason: 'the animation never finished',
      );
      expect(tester.getCenter(arrow.first), openArrow);
    });

    testWidgets('the fold itself slides open rather than snapping',
        (tester) async {
      tall(tester, height: 2000);
      final state = await boot();
      await open(tester, state);
      await goTo(tester, 'Greetings');

      // Everything under the fold is what shows the box arriving: the button at
      // the foot of the tab is pushed down as it opens.
      final foot = find.byKey(const Key('creator-add-greeting'));
      final whenOpen = tester.getTopLeft(foot).dy;
      await tester.tap(find.text('First message'));
      await tester.pumpAndSettle();
      final whenShut = tester.getTopLeft(foot).dy;
      expect(whenShut, lessThan(whenOpen));

      await tester.tap(find.text('First message'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final midway = tester.getTopLeft(foot).dy;
      expect(midway, greaterThan(whenShut),
          reason: 'the box appeared in one frame');
      expect(midway, lessThan(whenOpen),
          reason: 'the box appeared in one frame');

      await tester.pumpAndSettle();
      expect(tester.getTopLeft(foot).dy, moreOrLessEquals(whenOpen, epsilon: 1));
    });

    testWidgets('a closed fold previews what is in it; an open one does not',
        (tester) async {
      tall(tester, height: 2000);
      final state = await boot();
      await open(tester, state);
      await goTo(tester, 'Greetings');

      // The open fold names the greeting once and shows the words themselves —
      // no second copy of the name, and no one-line summary of a box that is
      // right there. Its three tools are on the header beside the name.
      expect(find.text('First message'), findsOneWidget);
      expect(find.text('Empty'), findsNothing);
      expect(find.byTooltip('Let the AI write this'), findsOneWidget);
      expect(find.byTooltip('Preview it as a message'), findsOneWidget);
      expect(find.byTooltip('Write full screen'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'Evening. Looking for me?');
      await tester.pumpAndSettle();
      // Closing it hands the space back and leaves the first line behind, which
      // is what tells eight greetings apart.
      await tester.tap(find.text('First message'));
      await tester.pumpAndSettle();
      expect(find.text('Evening. Looking for me?'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.byTooltip('Write full screen'), findsNothing);

      await tester.tap(find.byKey(const Key('creator-add-greeting')));
      await tester.pumpAndSettle();
      // The new one is empty and says so, in its own fold.
      expect(find.text('Greeting 2'), findsOneWidget);
      await tester.tap(find.text('Greeting 2'));
      await tester.pumpAndSettle();
      expect(find.text('Empty'), findsOneWidget);
    });

    testWidgets('Preview draws the greeting as the chat will', (tester) async {
      tall(tester, height: 2000);
      final state = await boot();
      await open(tester, state);
      await tester.enterText(boxOf('creator-name'), 'Serina');
      await goTo(tester, 'Greetings');
      await tester.enterText(
        find.byType(TextField),
        'Evening, {{user}}. Looking for something?',
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('creator-preview-greeting-0')));
      await tester.pumpAndSettle();

      // A blank screen with a real turn on it, and nothing of the creator left.
      expect(find.byKey(const Key('greeting-preview-body')), findsOneWidget);
      expect(find.byType(MessageBubble), findsOneWidget);
      expect(find.widgetWithText(Tab, 'Greetings'), findsNothing);
      expect(
        find.textContaining('Looking for something?', findRichText: true),
        findsWidgets,
      );

      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(Tab, 'Greetings'), findsOneWidget);
    });
  });

  group('scenarios', () {
    /// The scenario body of the open fold: a fold holds its name box and then
    /// the scenario itself.
    Finder scenarioBox() => find.byType(TextField).last;

    testWidgets("an old card's one scenario is here, and stays the card's own",
        (tester) async {
      tall(tester, height: 2200);
      final state = await boot();
      final card = Character(
        id: 'c',
        name: 'Serina',
        scenario: 'A library after hours.',
        firstMes: 'Evening.',
      );
      await state.addCharacter(card);
      await open(tester, state, character: card);
      await goTo(tester, 'Scenarios');

      expect(find.text('No scenarios yet.'), findsNothing);
      expect(
        tester.widget<TextField>(scenarioBox()).controller!.text,
        'A library after hours.',
      );

      await tester.enterText(scenarioBox(), 'A library after hours, raining.');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('creator-save')));
      await tester.pumpAndSettle();

      final saved = state.characterById('c')!;
      // Written back to the slot it came from, not to the user's own override.
      expect(saved.scenario, 'A library after hours, raining.');
      expect(saved.customScenario, '');
      expect(saved.scenarios.single.appliesToAll, isTrue);
      expect(saved.activeScenario, 'A library after hours, raining.');
    });

    testWidgets('a scenario can belong to one greeting only', (tester) async {
      tall(tester, height: 2200);
      final state = await boot();
      final card = Character(
        id: 'c',
        name: 'Serina',
        scenario: 'A library after hours.',
        firstMes: 'Evening.',
        alternateGreetings: const ['Or this way.'],
      );
      await state.addCharacter(card);
      await open(tester, state, character: card);
      await goTo(tester, 'Scenarios');

      expect(find.text('Every greeting'), findsWidgets);
      await tester.tap(find.byKey(const Key('scenario-scope-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('creator-save')));
      await tester.pumpAndSettle();

      expect(state.characterById('c')!.scenarios.single.greetings, [1]);
    });

    testWidgets('deleting the greeting it was pinned to unpins it',
        (tester) async {
      tall(tester, height: 2200);
      final state = await boot();
      final card = Character(
        id: 'c',
        name: 'Serina',
        scenario: 'A library after hours.',
        firstMes: 'Evening.',
        alternateGreetings: const ['Or this way.'],
      );
      await state.addCharacter(card);
      await open(tester, state, character: card);

      await goTo(tester, 'Scenarios');
      await tester.tap(find.byKey(const Key('scenario-scope-1')));
      await tester.pumpAndSettle();

      await goTo(tester, 'Greetings');
      // Its fold is closed, and a closed fold's Remove is not in the tree.
      await tester.tap(find.text('Greeting 2'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('creator-remove-greeting-1')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('creator-save')));
      await tester.pumpAndSettle();

      final saved = state.characterById('c')!;
      expect(saved.alternateGreetings, isEmpty);
      // Left pinned it would never fire and never be visible again.
      expect(saved.scenarios.single.greetings, isEmpty);
      expect(saved.scenarios.single.appliesToAll, isTrue);
    });

    testWidgets('a second scenario is written beside the first',
        (tester) async {
      tall(tester, height: 2200);
      final state = await boot();
      await open(tester, state);
      await tester.enterText(boxOf('creator-name'), 'Serina');
      await goTo(tester, 'Scenarios');
      expect(find.text('No scenarios yet.'), findsOneWidget);

      await tester.tap(find.byKey(const Key('creator-add-scenario')));
      await tester.pumpAndSettle();
      expect(find.text('Scenario 1'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'Name (optional)').last,
        'The library',
      );
      await tester.pumpAndSettle();
      // Naming it renames the fold: twice on screen now — the heading, and the
      // box it was typed into.
      expect(find.text('The library'), findsNWidgets(2));
      await tester.enterText(scenarioBox(), 'A library after hours.');
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('creator-add-scenario')));
      await tester.pumpAndSettle();
      await tester.enterText(scenarioBox(), 'The harbour at dawn.');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('creator-save')));
      await tester.pumpAndSettle();

      final saved = state.characters.single;
      expect(saved.scenarios.map((s) => s.text),
          ['A library after hours.', 'The harbour at dawn.']);
      expect(saved.scenarios.first.name, 'The library');
      // The one every other app reads is the first that covers everything.
      expect(saved.scenario, 'A library after hours.');
    });

    testWidgets('a scenario is not taken off the card without asking',
        (tester) async {
      tall(tester, height: 2200);
      final state = await boot();
      await open(
        tester,
        state,
        character: Character(
          id: 'c',
          name: 'Aria',
          scenario: 'A library after hours.',
        ),
      );
      await goTo(tester, 'Scenarios');

      await tester.tap(find.widgetWithText(TextButton, 'Remove'));
      await tester.pumpAndSettle();
      expect(find.text('Remove this scenario?'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('No scenarios yet.'), findsNothing);

      await tester.tap(find.widgetWithText(TextButton, 'Remove'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await tester.pumpAndSettle();
      expect(find.text('No scenarios yet.'), findsOneWidget);

      await tester.tap(find.byKey(const Key('creator-save')));
      await tester.pumpAndSettle();
      expect(state.characterById('c')!.scenario, isEmpty);
      expect(state.characterById('c')!.scenarios, isEmpty);
    });

    testWidgets('the library picker is the same sheet as everywhere else',
        (tester) async {
      tall(tester, height: 2200);
      final state = await boot();
      await open(tester, state);
      await goTo(tester, 'Scenarios');

      await tester.tap(find.byKey(const Key('creator-scenario-library')));
      await tester.pumpAndSettle();
      expect(find.text('Write a new one'), findsOneWidget);

      await dismissSheet(tester);
      expect(find.text('No scenarios yet.'), findsOneWidget);
    });
  });

  group('lorebooks', () {
    Lorebook book({String id = 'b', String name = 'Port'}) => Lorebook(
          id: id,
          name: name,
          entries: [
            LorebookEntry(
              uid: 0,
              name: 'Harbour',
              keys: const ['harbour'],
              content: 'It never stops raining.',
            ),
          ],
        );

    testWidgets('a book attached here rides along on Save', (tester) async {
      tall(tester);
      final state = await boot();
      await state.addLorebook(book());
      await open(tester, state);
      await tester.enterText(boxOf('creator-name'), 'Serina');
      await goTo(tester, 'Lorebooks');
      expect(find.text('No lorebook attached.'), findsOneWidget);

      await tester.tap(find.byKey(const Key('creator-attach-lorebook')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('attach-b')));
      await tester.pumpAndSettle();
      await dismissSheet(tester);

      // The row is the library's, entry count and all.
      expect(find.text('Port'), findsOneWidget);
      expect(find.text('1 entry'), findsOneWidget);
      expect(find.text('No lorebook attached.'), findsNothing);

      await tester.tap(find.byKey(const Key('creator-save')));
      await tester.pumpAndSettle();
      expect(state.characters.single.lorebookIds, ['b']);
    });

    testWidgets('detaching takes it off the card, not out of the library',
        (tester) async {
      tall(tester);
      final state = await boot();
      await state.addLorebook(book());
      await open(
        tester,
        state,
        character: Character(id: 'c', name: 'Aria', lorebookIds: const ['b']),
      );
      await goTo(tester, 'Lorebooks');
      expect(find.text('Port'), findsOneWidget);

      await tester.tap(find.byTooltip('Detach'));
      await tester.pumpAndSettle();
      // Unlinking a book is a confirmation too, and it says the book stays.
      expect(find.text('Detach this lorebook?'), findsOneWidget);
      expect(find.textContaining('stays in your library'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Detach'));
      await tester.pumpAndSettle();
      expect(find.text('No lorebook attached.'), findsOneWidget);

      await tester.tap(find.byKey(const Key('creator-save')));
      await tester.pumpAndSettle();
      expect(state.characterById('c')!.lorebookIds, isEmpty);
      // Still in the library for every other character.
      expect(state.lorebookById('b'), isNotNull);
    });

    testWidgets('with an empty library, Attach says so instead of opening '
        'nothing', (tester) async {
      tall(tester);
      final state = await boot();
      await open(tester, state);
      await goTo(tester, 'Lorebooks');

      await tester.tap(find.byKey(const Key('creator-attach-lorebook')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.text('No lorebooks in your library yet — create one.'),
        findsOneWidget,
      );
      expect(find.text('Attach a lorebook'), findsOneWidget); // the button only
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('Create a new one opens the library\'s own editor',
        (tester) async {
      tall(tester);
      final state = await boot();
      await open(tester, state);
      await goTo(tester, 'Lorebooks');

      await tester.tap(find.byKey(const Key('creator-new-lorebook')));
      await tester.pumpAndSettle();

      // The real lorebook editor, on top of the creator — not a parallel one.
      expect(find.byType(LorebookEditScreen), findsOneWidget);
      expect(find.text('New lorebook'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();
      // Backing out of it attaches nothing.
      expect(find.text('No lorebook attached.'), findsOneWidget);
    });
  });

  group('a field', () {
    testWidgets('the box never changes size as it is typed into',
        (tester) async {
      tall(tester);
      final state = await boot();
      await open(tester, state);
      await goTo(tester, 'Persona');

      final box = boxOf('creator-description');
      final below = find.byKey(const Key('creator-personality'));
      final height = tester.getSize(box).height;
      final belowTop = tester.getTopLeft(below).dy;

      // Enough words to wrap many times over. A box grown between minLines and
      // maxLines pushed everything under it down a line at a time as this was
      // typed, and the caret then had to be scrolled back into view — which is
      // what made the page bob up and down under the cursor.
      await tester.enterText(
        box,
        List<String>.filled(60, 'a rain-soaked port city').join(' '),
      );
      // Past the token count's debounce, so its row has settled too.
      await tester.pump(const Duration(milliseconds: 400));

      expect(tester.getSize(box).height, height,
          reason: 'the box grew with the words in it');
      expect(tester.getTopLeft(below).dy, belowTop,
          reason: 'the field below was pushed down');
      // The words are all there — the box scrolls, it does not truncate.
      expect(textOf(tester, 'creator-description'), contains('port city'));
    });

    testWidgets('counts its tokens and opens full screen onto the same text',
        (tester) async {
      tall(tester);
      final state = await boot();
      await open(tester, state);
      await goTo(tester, 'Persona');

      await tester.enterText(
        boxOf('creator-description'),
        'A retired duellist running a tea house in a rain-soaked port city.',
      );
      // The count is debounced by a quarter of a second.
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.descendant(
          of: find.byKey(const Key('creator-description')),
          matching: find.textContaining('tokens'),
        ),
        findsOneWidget,
      );

      await tester.tap(inField('creator-description', 'Write full screen'));
      await tester.pumpAndSettle();
      final full = find.byKey(const Key('creator-fullscreen-field'));
      expect(tester.widget<TextField>(full).controller!.text,
          contains('tea house'));

      // A bar with nothing on it but a way back and the assistant: no Done (the
      // controller is the tab's own, so there is nothing to apply) and no token
      // count competing with the words — that has moved to the foot of the page.
      expect(find.byTooltip('Done'), findsNothing);
      expect(find.byTooltip('Let the AI write this'), findsOneWidget);
      expect(find.textContaining('tokens'), findsOneWidget);

      await tester.enterText(full, 'Rewritten full screen.');
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();
      expect(textOf(tester, 'creator-description'), 'Rewritten full screen.');

      await tester.tap(find.byKey(const Key('creator-save')));
      await tester.pumpAndSettle();
      // No name was given, so Save refused — the point is only that the text is
      // the field's, and it survived the round trip.
      expect(find.text('Give them a name first.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('the creator notes preview draws them as the sheet will',
        (tester) async {
      tall(tester, height: 2000);
      final state = await boot();
      await open(tester, state);
      await goTo(tester, 'Advanced');

      await tester.enterText(
        boxOf('creator-notes'),
        '<b>Slow burn.</b> Needs a long context.',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('creator-notes-preview')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('notes-preview-body')), findsOneWidget);
      expect(find.text('Creator notes'), findsOneWidget);
      // Rendered, not shown as markup.
      expect(find.textContaining('Slow burn.', findRichText: true),
          findsWidgets);
      expect(find.textContaining('<b>', findRichText: true), findsNothing);

      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('creator-notes')), findsOneWidget);
    });

    testWidgets('the Advanced tab writes the instruction fields', (tester) async {
      tall(tester, height: 2400);
      final state = await boot();
      await open(tester, state);
      await tester.enterText(boxOf('creator-name'), 'Serina');
      await goTo(tester, 'Advanced');

      await tester.enterText(boxOf('creator-system'), 'Two paragraphs, no more.');
      await tester.enterText(boxOf('creator-post-history'), 'Stay in the past.');
      await tester.enterText(boxOf('creator-example'), '<START>\n{{char}}: Hm.');
      await tester.enterText(boxOf('creator-notes'), 'Slow burn.');
      await tester.enterText(boxOf('creator-author'), 'Ansh');
      await tester.enterText(boxOf('creator-version'), '1.2');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('creator-save')));
      await tester.pumpAndSettle();

      final saved = state.characters.single;
      expect(saved.systemPrompt, 'Two paragraphs, no more.');
      expect(saved.postHistoryInstructions, 'Stay in the past.');
      expect(saved.mesExample, '<START>\n{{char}}: Hm.');
      expect(saved.creatorNotes, 'Slow burn.');
      expect(saved.creator, 'Ansh');
      expect(saved.characterVersion, '1.2');
    });
  });

  group('a theme of their own', () {
    testWidgets('a strength is enough to give them one, and Save keeps it',
        (tester) async {
      tall(tester);
      final state = await boot();
      await open(tester, state);
      await tester.enterText(boxOf('creator-name'), 'Serina');
      await tester.pumpAndSettle();

      // Hollow palette while the card wears the app's colours.
      expect(find.byIcon(Icons.palette_outlined), findsOneWidget);
      await tester.tap(find.byKey(const Key('creator-theme-button')));
      await tester.pumpAndSettle();
      expect(find.text("This character's theme"), findsOneWidget);
      // Nothing to clear yet.
      expect(find.byKey(const Key('character-theme-clear')), findsNothing);

      // Picking a strength turns the theme on with the app's own colour as the
      // seed — otherwise the choice would change nothing visible.
      await tester.tap(find.text('Expressive'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('character-theme-clear')), findsOneWidget);

      await dismissSheet(tester);
      expect(find.byIcon(Icons.palette), findsOneWidget);

      await tester.tap(find.byKey(const Key('creator-save')));
      await tester.pumpAndSettle();
      final saved = state.characters.single;
      expect(saved.theme.isSet, isTrue);
      expect(saved.theme.strength, CharacterThemeStrength.expressive);
    });

    testWidgets("Use the app's takes it back off", (tester) async {
      tall(tester);
      final state = await boot();
      await open(
        tester,
        state,
        character: Character(
          id: 'c',
          name: 'Aria',
          theme: const CharacterTheme(
            seedColor: 0xFF7E57C2,
            strength: CharacterThemeStrength.faithful,
          ),
        ),
      );
      expect(find.byIcon(Icons.palette), findsOneWidget);

      await tester.tap(find.byKey(const Key('creator-theme-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('character-theme-clear')));
      await tester.pumpAndSettle();
      await dismissSheet(tester);
      expect(find.byIcon(Icons.palette_outlined), findsOneWidget);

      await tester.tap(find.byKey(const Key('creator-save')));
      await tester.pumpAndSettle();
      expect(state.characterById('c')!.theme.isSet, isFalse);
    });
  });

  group('letting the AI write a field', () {
    /// A reply in the shape the writer asks for: the field between the markers,
    /// the remark to the author outside them.
    String reply(String field, [String note = 'Colder, and I kept the sister.']) =>
        '${CharacterWriter.openTag}\n$field\n${CharacterWriter.closeTag}\n$note';

    Future<void> ask(WidgetTester tester, String what) async {
      await tester.enterText(find.byKey(const Key('writer-ask')), what);
      await tester.tap(find.byKey(const Key('writer-send')));
      await work(tester);
    }

    testWidgets('the answer lands in the field, and the remark in the sheet',
        (tester) async {
      tall(tester);
      final client = FakeClient(reply: reply('A retired duellist.'));
      final state = await boot(client: client);
      await open(tester, state);
      await tester.enterText(boxOf('creator-name'), 'Serina');
      await goTo(tester, 'Persona');

      await tester.tap(inField('creator-description', 'Let the AI write this'));
      await tester.pumpAndSettle();
      expect(find.text('Write description'), findsOneWidget);
      // The model behind it is named, so it is never a mystery which one wrote.
      expect(find.text('gpt-test'), findsOneWidget);

      await ask(tester, 'a duellist running a tea house');

      // The field, not the note.
      expect(textOf(tester, 'creator-description'), 'A retired duellist.');
      expect(find.text('Colder, and I kept the sister.'), findsOneWidget);
      expect(find.text('a duellist running a tea house'), findsOneWidget);
      // Nothing of the marker survives anywhere on screen.
      expect(find.textContaining(CharacterWriter.openTag), findsNothing);

      // What went out: the standing instruction first, the ask last.
      final sent = client.lastHistory!;
      expect(sent.first.role, 'system');
      expect(sent.first.content, contains('Description'));
      // The card so far rides in the system turn, so a long conversation does
      // not re-send it.
      expect(sent.first.content, contains('Serina'));
      expect(sent.last.role, 'user');
      expect(sent.last.content, 'a duellist running a tea house');
      expect(sent.length, 2);

      // Asking again sends what has happened so far, once each.
      client.reply = reply('A duellist who lost.', 'Shorter.');
      await ask(tester, 'shorter');
      final second = client.lastHistory!;
      expect(second.map((m) => m.role),
          ['system', 'user', 'assistant', 'user']);
      expect(second[1].content, 'a duellist running a tea house');
      expect(second[2].content, 'Colder, and I kept the sister.');
      expect(second.last.content, 'shorter');
      // The field it is rewriting is the one it wrote.
      expect(second.first.content, contains('A retired duellist.'));
      expect(textOf(tester, 'creator-description'), 'A duellist who lost.');
    });

    testWidgets('Undo puts back what the field said before', (tester) async {
      tall(tester);
      final client = FakeClient(reply: reply('Something else entirely.'));
      final state = await boot(client: client);
      await open(tester, state);
      await goTo(tester, 'Persona');
      await tester.enterText(boxOf('creator-description'), 'What I wrote.');
      await tester.pumpAndSettle();

      await tester.tap(inField('creator-description', 'Let the AI write this'));
      await tester.pumpAndSettle();
      // Nothing to undo before it has written anything.
      expect(find.byKey(const Key('writer-undo')), findsNothing);
      await ask(tester, 'rewrite it');
      expect(find.byKey(const Key('writer-undo')), findsOneWidget);

      await tester.tap(find.byKey(const Key('writer-undo')));
      await tester.pumpAndSettle();
      expect(textOf(tester, 'creator-description'), 'What I wrote.');
      expect(find.byKey(const Key('writer-undo')), findsNothing);
    });

    testWidgets('the conversation is still there when the sheet is reopened',
        (tester) async {
      tall(tester);
      final client = FakeClient(reply: reply('A duellist.'));
      final state = await boot(client: client);
      await open(tester, state);
      await goTo(tester, 'Persona');

      await tester.tap(inField('creator-description', 'Let the AI write this'));
      await tester.pumpAndSettle();
      await ask(tester, 'a duellist');
      await dismissSheet(tester);

      await tester.tap(inField('creator-description', 'Let the AI write this'));
      await tester.pumpAndSettle();
      expect(find.text('a duellist'), findsOneWidget);
      expect(find.text('Colder, and I kept the sister.'), findsOneWidget);

      // Start over empties it, and the sheet says what it is for again.
      await tester.tap(find.byKey(const Key('writer-clear')));
      await tester.pumpAndSettle();
      expect(find.text('a duellist'), findsNothing);
      expect(find.textContaining('Say what you want in Description'),
          findsOneWidget);
    });

    testWidgets('each greeting keeps its own conversation', (tester) async {
      tall(tester, height: 2000);
      final client = FakeClient(reply: reply('Evening.', 'Warmer.'));
      final state = await boot(client: client);
      await open(tester, state);
      await goTo(tester, 'Greetings');

      await tester.tap(find.byTooltip('Let the AI write this'));
      await tester.pumpAndSettle();
      // The opening line is named as it is named everywhere else on a card.
      expect(find.text('Write first message'), findsOneWidget);
      await ask(tester, 'warmer than that');
      await dismissSheet(tester);

      await tester.tap(find.byKey(const Key('creator-add-greeting')));
      await tester.pumpAndSettle();
      // The new fold's own assistant, with nothing said in it yet.
      await tester.tap(find.byTooltip('Let the AI write this').last);
      await tester.pumpAndSettle();
      expect(find.text('Write greeting 2'), findsOneWidget);
      expect(find.text('warmer than that'), findsNothing);
    });

    testWidgets('tags come back as chips on the card', (tester) async {
      tall(tester);
      final client = FakeClient(
        reply: reply('noir, slow burn, #rain', 'Four would be too many.'),
      );
      final state = await boot(client: client);
      await open(tester, state);
      await tester.enterText(boxOf('creator-name'), 'Serina');
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('creator-tags-ai')));
      await tester.pumpAndSettle();
      expect(find.text('Write tags'), findsOneWidget);
      await ask(tester, 'tags for a noir romance');
      await dismissSheet(tester);

      expect(find.widgetWithText(InputChip, 'noir'), findsOneWidget);
      expect(find.widgetWithText(InputChip, 'slow burn'), findsOneWidget);
      // The hash a model adds when it forgets it was asked for plain words.
      expect(find.widgetWithText(InputChip, 'rain'), findsOneWidget);

      await tester.tap(find.byKey(const Key('creator-save')));
      await tester.pumpAndSettle();
      expect(state.characters.single.tags, ['noir', 'slow burn', 'rain']);
    });

    testWidgets('a refusal from the provider is shown, not thrown',
        (tester) async {
      tall(tester);
      final client = FakeClient(error: 'That key is not valid.');
      final state = await boot(client: client);
      await open(tester, state);
      await goTo(tester, 'Persona');
      await tester.enterText(boxOf('creator-description'), 'Mine.');
      await tester.pumpAndSettle();

      await tester.tap(inField('creator-description', 'Let the AI write this'));
      await tester.pumpAndSettle();
      await ask(tester, 'rewrite it');

      expect(find.text('That key is not valid.'), findsOneWidget);
      // The field is untouched, and the sheet is still usable.
      expect(textOf(tester, 'creator-description'), 'Mine.');
      expect(find.byKey(const Key('writer-undo')), findsNothing);
      expect(find.byKey(const Key('writer-ask')), findsOneWidget);
    });

    testWidgets('a reply that only talks leaves the field alone',
        (tester) async {
      tall(tester);
      final client = FakeClient(
        reply: 'What tone are you after — warm or cold?',
      );
      final state = await boot(client: client);
      await open(tester, state);
      await goTo(tester, 'Persona');
      await tester.enterText(boxOf('creator-description'), 'Mine.');
      await tester.pumpAndSettle();

      await tester.tap(inField('creator-description', 'Let the AI write this'));
      await tester.pumpAndSettle();
      await ask(tester, 'write me a description');

      expect(find.text('What tone are you after — warm or cold?'),
          findsOneWidget);
      expect(textOf(tester, 'creator-description'), 'Mine.');
      expect(find.byKey(const Key('writer-undo')), findsNothing);
    });
  });
}
