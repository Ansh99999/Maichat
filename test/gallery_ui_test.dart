import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/gallery_image.dart';
import 'package:maichat/screens/gallery/gallery_screen.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Drives the real [GalleryScreen]: searching, tag filtering, sorting, the
/// character filter, multi-select, and the pinch that walks the zoom ladder.
///
/// No [AvatarStore] is installed on purpose, so `avatarImage` resolves nothing and
/// the tiles draw their placeholder glyph. That keeps the tests off the image
/// decoder, which cannot run under the test binding's fake clock — the layout,
/// grouping and gestures are what is under test here, not the bitmaps.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  /// A gallery seeded directly, since storing real bytes needs a pictures
  /// directory this test deliberately does not have.
  Future<AppState> seeded({
    List<Character> characters = const <Character>[],
    List<GalleryImage> images = const <GalleryImage>[],
  }) async {
    final state = AppState();
    await state.init();
    for (final character in characters) {
      await state.addCharacter(character);
    }
    // Oldest first, so the newest ends up at the head of the stored list.
    for (final image in images.reversed) {
      await state.saveGalleryImage(image);
    }
    return state;
  }

  GalleryImage picture({
    required String id,
    String title = '',
    List<String> tags = const <String>[],
    String? characterId,
    DateTime? when,
    bool starred = false,
  }) =>
      GalleryImage(
        id: id,
        image: 'local:$id.png',
        title: title,
        tags: tags,
        characterId: characterId,
        createdAt: when ?? DateTime(2026, 4, 24, 12),
        starred: starred,
      );

  Widget host(AppState state, {Widget? screen}) =>
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(home: screen ?? const GalleryScreen()),
      );

  /// Pumps [screen] onto a phone-shaped surface.
  ///
  /// Not the 800x600 default on purpose: the gallery's grids are lazy, and in a
  /// landscape window one date band's tiles fill the viewport so the next band is
  /// never built — an assertion about a second heading would then fail for a
  /// reason that has nothing to do with grouping.
  Future<void> pumpGallery(
    WidgetTester tester,
    AppState state, {
    Widget? screen,
  }) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(host(state, screen: screen));
    await tester.pumpAndSettle();
  }

  /// Whether [first] is drawn before [second] in reading order — down the rows,
  /// then across. Two tiles in the same grid row share a `dy`, so comparing only
  /// the vertical would call a correct A–Z ordering a failure.
  bool precedes(WidgetTester tester, Finder first, Finder second) {
    final a = tester.getTopLeft(first);
    final b = tester.getTopLeft(second);
    return a.dy != b.dy ? a.dy < b.dy : a.dx < b.dx;
  }

  /// The grid's column count, read off the live delegate rather than inferred
  /// from tile positions.
  int columnsOf(WidgetTester tester) {
    final grid = tester.widgetList<SliverGrid>(find.byType(SliverGrid)).first;
    final delegate =
        grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    return delegate.crossAxisCount;
  }

  testWidgets('an empty gallery says so and offers to add pictures',
      (tester) async {
    final state = await seeded();
    await pumpGallery(tester, state);

    expect(find.text('No pictures yet'), findsOneWidget);
    expect(find.text('Add pictures'), findsOneWidget);
    // Selecting nothing is not an offer worth making.
    final select = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.checklist_outlined));
    expect(select.onPressed, isNull);
  });

  testWidgets('pictures are grouped under their date, newest band first',
      (tester) async {
    final state = await seeded(images: [
      picture(id: 'a', title: 'Friday', when: DateTime(2026, 4, 24)),
      picture(id: 'b', title: 'Thursday', when: DateTime(2026, 4, 23)),
    ]);
    await pumpGallery(tester, state);

    expect(find.text('April 24, 2026'), findsOneWidget);
    expect(find.text('April 23, 2026'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('April 24, 2026')).dy,
      lessThan(tester.getTopLeft(find.text('April 23, 2026')).dy),
    );
    expect(find.text('Friday'), findsOneWidget);
    expect(find.text('Thursday'), findsOneWidget);
  });

  testWidgets('a character album is titled after them and holds only theirs',
      (tester) async {
    final state = await seeded(
      characters: [Character(id: 'sumire', name: 'Sumire')],
      images: [
        picture(id: 'a', title: 'Hers', characterId: 'sumire'),
        picture(id: 'b', title: 'Someone elses', characterId: 'aoi'),
        picture(id: 'c', title: 'Nobodys'),
      ],
    );
    await pumpGallery(
      tester,
      state,
      screen: const GalleryScreen(
        mode: GalleryMode.character,
        characterId: 'sumire',
      ),
    );

    // SliverAppBar.large draws its title twice (collapsed and expanded).
    expect(find.text('Gallery of Sumire'), findsWidgets);
    expect(find.text('Hers'), findsOneWidget);
    expect(find.text('Someone elses'), findsNothing);
    expect(find.text('Nobodys'), findsNothing);
    // An album has no character filter — everything in it has one owner.
    expect(find.text('Everyone'), findsNothing);
  });

  testWidgets('search matches titles, tags and the owner\'s name',
      (tester) async {
    final state = await seeded(
      characters: [Character(id: 'sumire', name: 'Sumire')],
      images: [
        picture(id: 'a', title: 'Beach outfit', tags: ['summer']),
        picture(id: 'b', title: 'Winter coat', tags: ['snow']),
        picture(id: 'c', title: 'Portrait', characterId: 'sumire'),
      ],
    );
    await pumpGallery(tester, state);

    await tester.enterText(find.byType(SearchBar), 'beach');
    await tester.pumpAndSettle();
    expect(find.text('Beach outfit'), findsOneWidget);
    expect(find.text('Winter coat'), findsNothing);

    await tester.enterText(find.byType(SearchBar), 'snow');
    await tester.pumpAndSettle();
    expect(find.text('Winter coat'), findsOneWidget, reason: 'matched by tag');

    await tester.enterText(find.byType(SearchBar), 'sumire');
    await tester.pumpAndSettle();
    expect(find.text('Portrait'), findsOneWidget, reason: 'matched by owner');

    await tester.enterText(find.byType(SearchBar), 'nothing at all');
    await tester.pumpAndSettle();
    expect(find.text('No pictures match.'), findsOneWidget);
  });

  testWidgets('the tag sheet filters, and every chosen tag must match',
      (tester) async {
    final state = await seeded(images: [
      picture(id: 'a', title: 'Both', tags: ['beach', 'summer']),
      picture(id: 'b', title: 'One', tags: ['beach']),
      picture(id: 'c', title: 'Neither', tags: ['snow']),
    ]);
    await pumpGallery(tester, state);

    await tester.tap(find.widgetWithText(ActionChip, 'Tags'));
    await tester.pumpAndSettle();
    expect(find.text('Filter by tag'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilterChip, 'beach'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilterChip, 'summer'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(200, 40)); // Dismiss the sheet.
    await tester.pumpAndSettle();

    expect(find.widgetWithText(ActionChip, '2'), findsOneWidget);
    expect(find.text('Both'), findsOneWidget);
    expect(find.text('One'), findsNothing, reason: 'tags are ANDed');
    expect(find.text('Neither'), findsNothing);
  });

  testWidgets('sorting by name reorders and drops the date headings',
      (tester) async {
    final state = await seeded(images: [
      picture(id: 'a', title: 'Zebra', when: DateTime(2026, 4, 24)),
      picture(id: 'b', title: 'Apple', when: DateTime(2026, 4, 23)),
    ]);
    await pumpGallery(tester, state);
    expect(find.text('April 24, 2026'), findsOneWidget);

    // The chip carries the short label; the sheet spells the ordering out.
    await tester.tap(find.widgetWithText(ActionChip, 'Newest'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Name (A–Z)'));
    await tester.pumpAndSettle();

    expect(find.text('April 24, 2026'), findsNothing,
        reason: 'a date band over an A–Z list would claim an order it lacks');
    expect(precedes(tester, find.text('Apple'), find.text('Zebra')), isTrue);
  });

  testWidgets('the character filter narrows to one album, or to unassigned',
      (tester) async {
    final state = await seeded(
      characters: [
        Character(id: 'sumire', name: 'Sumire'),
        Character(id: 'aoi', name: 'Aoi'),
      ],
      images: [
        picture(id: 'a', title: 'Sumires', characterId: 'sumire'),
        picture(id: 'b', title: 'Aois', characterId: 'aoi'),
        picture(id: 'c', title: 'Loose'),
      ],
    );
    await pumpGallery(tester, state);

    await tester.tap(find.widgetWithText(ActionChip, 'Everyone'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Sumire'));
    await tester.pumpAndSettle();

    expect(find.text('Sumires'), findsOneWidget);
    expect(find.text('Aois'), findsNothing);
    expect(find.text('Loose'), findsNothing);

    // The chip, not the tile's owner caption — which also reads "Sumire" now.
    await tester.tap(find.widgetWithText(ActionChip, 'Sumire'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Unassigned'));
    await tester.pumpAndSettle();

    expect(find.text('Loose'), findsOneWidget);
    expect(find.text('Sumires'), findsNothing);
  });

  testWidgets('a long press starts multi-select and the app bar swaps',
      (tester) async {
    final state = await seeded(images: [
      picture(id: 'a', title: 'One'),
      picture(id: 'b', title: 'Two'),
    ]);
    await pumpGallery(tester, state);

    await tester.longPress(find.text('One'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    expect(find.byIcon(Icons.download_outlined), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);

    // Tapping the other tile adds it rather than opening it.
    await tester.tap(find.text('Two'));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsNothing);
    expect(find.text('Gallery'), findsWidgets);
  });

  testWidgets('deleting the selection removes those pictures', (tester) async {
    final state = await seeded(images: [
      picture(id: 'a', title: 'Doomed'),
      picture(id: 'b', title: 'Spared'),
    ]);
    await pumpGallery(tester, state);

    await tester.longPress(find.text('Doomed'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    expect(find.text('Delete 1 picture?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(state.gallery.map((i) => i.id), ['b']);
    expect(find.text('Doomed'), findsNothing);
    expect(find.text('Spared'), findsOneWidget);
  });

  group('the zoom ladder', () {
    /// Spreads or squeezes two fingers horizontally about the centre of the grid.
    /// Horizontal on purpose: a symmetric spread never moves the focal point
    /// vertically, so the list's own drag recogniser has nothing to claim and the
    /// scale gesture wins the arena the way it does on a phone.
    /// Spreads or squeezes two fingers horizontally about the centre of the list.
    ///
    /// Horizontal on purpose: a symmetric spread never moves the focal point
    /// vertically, so the scroll view's own drag recogniser has nothing to claim
    /// and the scale gesture wins the arena the way it does on a phone.
    /// [travel] is how far *each* finger moves outwards (negative squeezes),
    /// which is what decides how many rungs one gesture covers.
    Future<void> pinch(
      WidgetTester tester, {
      required double startGap,
      required double travel,
    }) async {
      // The scroll view, not the SliverGrid: a sliver has no RenderBox, so it has
      // no centre to aim at.
      final centre = tester.getCenter(find.byType(CustomScrollView));
      final left = await tester.startGesture(centre - Offset(startGap, 0));
      final right = await tester.startGesture(centre + Offset(startGap, 0));
      for (var i = 0; i < 6; i++) {
        await left.moveBy(Offset(-travel / 6, 0));
        await right.moveBy(Offset(travel / 6, 0));
        await tester.pump();
      }
      await left.up();
      await right.up();
      await tester.pumpAndSettle();
    }

    /// A squeeze just past one step of the ladder.
    ///
    /// The distances matter: each finger has to travel further than
    /// [kScaleSlop] (18) or the scale recogniser never claims the arena, the
    /// tiles' own tap wins on pointer-up, and the "pinch" opens a picture
    /// instead of resizing the grid.
    Future<void> squeezeOnce(WidgetTester tester) =>
        pinch(tester, startGap: 140, travel: -45);

    /// A spread just past one step.
    Future<void> spreadOnce(WidgetTester tester) =>
        pinch(tester, startGap: 60, travel: 26);

    testWidgets('opens two across, grouped by day', (tester) async {
      final state = await seeded(images: [picture(id: 'a', title: 'One')]);
      await pumpGallery(tester, state);
      expect(columnsOf(tester), 2);
      expect(find.text('April 24, 2026'), findsOneWidget);
    });

    testWidgets('squeezing shows more per row and widens the date bands',
        (tester) async {
      final state = await seeded(images: [
        picture(id: 'a', title: 'Friday', when: DateTime(2026, 4, 24)),
        picture(id: 'b', title: 'Monday', when: DateTime(2026, 4, 20)),
      ]);
      await pumpGallery(tester, state);
      expect(columnsOf(tester), 2);
      expect(find.text('April 24, 2026'), findsOneWidget);

      await squeezeOnce(tester);
      expect(columnsOf(tester), 4);
      // Both pictures fall in the same week now, so one band covers them.
      expect(find.text('Apr 20–26, 2026'), findsOneWidget);
      expect(find.text('April 24, 2026'), findsNothing);

      await squeezeOnce(tester);
      expect(columnsOf(tester), 6);
      expect(find.text('April 2026'), findsOneWidget);

      // The ladder ends rather than wrapping round.
      await squeezeOnce(tester);
      expect(columnsOf(tester), 6);
    });

    testWidgets('spreading goes back to one big picture per row',
        (tester) async {
      final state = await seeded(images: [picture(id: 'a', title: 'One')]);
      await pumpGallery(tester, state);

      await spreadOnce(tester);
      expect(columnsOf(tester), 1);
      await spreadOnce(tester);
      expect(columnsOf(tester), 1, reason: 'the ladder ends');
    });

    testWidgets('one finger scrolls instead of zooming', (tester) async {
      final state = await seeded(images: [
        for (var i = 0; i < 40; i++)
          picture(
            id: 'p$i',
            title: 'Picture $i',
            when: DateTime(2026, 4, 24).subtract(Duration(days: i)),
          ),
      ]);
      await pumpGallery(tester, state);
      expect(columnsOf(tester), 2);

      // Well past the collapsing large title and the search row, so the first
      // band is genuinely off screen if the drag reached the list at all.
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -900));
      await tester.pumpAndSettle();

      expect(columnsOf(tester), 2, reason: 'a scroll is not a pinch');
      expect(find.text('Picture 0'), findsNothing, reason: 'it did scroll');
    });

    testWidgets('the size menu walks the same ladder', (tester) async {
      final state = await seeded(images: [picture(id: 'a', title: 'One')]);
      await pumpGallery(tester, state);

      Future<void> choose(String label) async {
        await tester.tap(find.byIcon(Icons.grid_view_outlined));
        await tester.pumpAndSettle();
        await tester.tap(find.text(label).last);
        await tester.pumpAndSettle();
      }

      await choose('4 across, by week');
      expect(columnsOf(tester), 4);
      expect(find.text('Apr 20–26, 2026'), findsOneWidget);

      await choose('One at a time, by day');
      expect(columnsOf(tester), 1);
      expect(find.text('April 24, 2026'), findsOneWidget);
    });
  });

  group('the viewer', () {
    testWidgets('a tap opens the picture with its actions', (tester) async {
      final state = await seeded(images: [
        picture(id: 'a', title: 'Opened', tags: ['beach']),
        picture(id: 'b', title: 'Next'),
      ]);
      await pumpGallery(tester, state);

      await tester.tap(find.text('Opened'));
      await tester.pumpAndSettle();

      // The title rides the viewer's bar, and the position pill counts the run.
      expect(
        find.descendant(of: find.byType(AppBar), matching: find.text('Opened')),
        findsOneWidget,
      );
      // Two of them, because the viewer's route is deliberately see-through: the
      // gallery it was opened from is still built and still on screen behind it,
      // which is what lets a flicked-away picture reveal where it came from.
      expect(find.text('Opened'), findsNWidgets(2));
      expect(find.text('1 / 2'), findsOneWidget);
      expect(find.text('beach'), findsOneWidget, reason: 'tags are shown');
      for (final action in [
        'Export',
        'Edit',
        'Star',
        'Not avatar',
        'Delete',
      ]) {
        expect(find.text(action), findsOneWidget, reason: action);
      }
      // Only a chat's gallery offers this.
      expect(find.text('Send'), findsNothing);
      // Opening a picture is remembered, for the "Last viewed" ordering.
      expect(state.galleryImageById('a')!.lastViewed, isNotNull);
    });

    testWidgets('starring from the viewer sticks', (tester) async {
      final state = await seeded(images: [picture(id: 'a', title: 'One')]);
      await pumpGallery(tester, state);
      await tester.tap(find.text('One'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Star'));
      await tester.pumpAndSettle();
      expect(state.galleryImageById('a')!.starred, isTrue);
      expect(find.text('Starred'), findsOneWidget);

      await tester.tap(find.text('Starred'));
      await tester.pumpAndSettle();
      expect(state.galleryImageById('a')!.starred, isFalse);
    });

    testWidgets('an unowned picture cannot become an avatar, and says why',
        (tester) async {
      final state = await seeded(images: [picture(id: 'a', title: 'Loose')]);
      await pumpGallery(tester, state);
      await tester.tap(find.text('Loose'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Not avatar'));
      await tester.pumpAndSettle();
      expect(
        find.text('This picture belongs to nobody yet. Use Edit to say who, '
            'then it can be their avatar.'),
        findsOneWidget,
      );
    });

    testWidgets('an owned picture joins and leaves its owner\'s avatars',
        (tester) async {
      final state = await seeded(
        characters: [Character(id: 'sumire', name: 'Sumire')],
        images: [picture(id: 'a', title: 'Hers', characterId: 'sumire')],
      );
      await pumpGallery(tester, state);
      await tester.tap(find.text('Hers'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Not avatar'));
      await tester.pumpAndSettle();
      expect(state.characterById('sumire')!.avatar, 'local:a.png');
      // Says what happened, and that one picture is not yet something to swipe.
      expect(
        find.text('Sumire now wears this. Add another to swipe between them in '
            'a chat.'),
        findsOneWidget,
      );
      expect(find.text('Avatar'), findsOneWidget,
          reason: 'the control now reads as a state, not a command');

      await tester.tap(find.text('Avatar'));
      await tester.pumpAndSettle();
      expect(state.characterById('sumire')!.avatar, '');
      expect(find.text('Not avatar'), findsOneWidget);
    });

    testWidgets('deleting the last picture closes the viewer', (tester) async {
      final state = await seeded(images: [picture(id: 'a', title: 'Doomed')]);
      await pumpGallery(tester, state);
      await tester.tap(find.text('Doomed'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(state.gallery, isEmpty);
      // Back on the gallery, which now has nothing in it.
      expect(find.text('No pictures yet'), findsOneWidget);
    });

    testWidgets('a chat\'s gallery can send a picture to the chat',
        (tester) async {
      final character = Character(id: 'sumire', name: 'Sumire', firstMes: 'Hi.');
      final state = await seeded(
        characters: [character],
        images: [picture(id: 'a', title: 'Hers', characterId: 'sumire')],
      );
      state.startChatWithCharacter(state.characterById('sumire')!);
      final chat = state.active.id;

      await pumpGallery(
        tester,
        state,
        screen: GalleryScreen(
          mode: GalleryMode.chat,
          characterId: 'sumire',
          conversationId: chat,
        ),
      );
      await tester.tap(find.text('Hers'));
      await tester.pumpAndSettle();

      expect(find.text('Send'), findsOneWidget);
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();

      expect(state.conversationById(chat)!.floatingImages.single.imageId, 'a');
      // And it took the user back to where the picture now is.
      expect(find.text('Send'), findsNothing);
    });
  });
}
