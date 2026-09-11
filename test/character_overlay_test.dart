import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/view_prefs.dart';
import 'package:maichat/screens/character_sheet_screen.dart';
import 'package:maichat/screens/characters_screen.dart';
import 'package:maichat/state/app_state.dart';
import 'package:maichat/widgets/adaptive_mosaic.dart';
import 'package:maichat/widgets/avatar_dots.dart';
import 'package:maichat/widgets/avatar_image.dart';
import 'package:maichat/widgets/natural_image.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _pic(String name) => 'https://example.invalid/$name.png';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    clearAvatarImageCache();
  });

  Widget host(AppState state) => ChangeNotifierProvider<AppState>.value(
    value: state,
    child: const MaterialApp(home: CharactersScreen()),
  );

  Future<AppState> open(
    WidgetTester tester, {
    bool freeSize = true,
    bool overlay = true,
    BrowseLayout layout = BrowseLayout.grid,
    List<Character>? characters,
  }) async {
    tester.view.physicalSize = const Size(424, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final state = AppState();
    addTearDown(state.dispose);
    await state.init();
    await state.addCharacters(
      characters ??
          [
            Character(
              id: 'c',
              name: 'Aria',
              avatar: _pic('one'),
              description: 'The opaque metadata panel must disappear.',
            ),
          ],
    );
    await state.setBrowseLayout(BrowseSection.characters, layout);
    await state.setFreeSizeCards(BrowseSection.characters, freeSize);
    await state.setCharacterImageOverlay(overlay);
    await tester.pumpWidget(host(state));
    await tester.pump();
    await tester.pump();
    return state;
  }

  Finder overlayCard(String id) =>
      find.byKey(ValueKey('character-overlay-card-$id'));

  group('layout matrix', () {
    for (final freeSize in [false, true]) {
      for (final overlay in [false, true]) {
        testWidgets(
          'grid freeSize=$freeSize overlay=$overlay uses overlay only together',
          (tester) async {
            noteAvatarRatio(_pic('one'), 1);
            await open(tester, freeSize: freeSize, overlay: overlay);

            expect(
              overlayCard('c'),
              freeSize && overlay ? findsOneWidget : findsNothing,
            );
            expect(
              find.byType(AdaptiveMosaicSliver<Character>),
              freeSize ? findsOneWidget : findsNothing,
            );
            expect(
              find.text('The opaque metadata panel must disappear.'),
              freeSize && overlay ? findsNothing : findsOneWidget,
            );
          },
        );
      }
    }

    for (final freeSize in [false, true]) {
      for (final overlay in [false, true]) {
        testWidgets(
          'list freeSize=$freeSize overlay=$overlay stays a list row',
          (tester) async {
            await open(
              tester,
              freeSize: freeSize,
              overlay: overlay,
              layout: BrowseLayout.list,
            );
            expect(overlayCard('c'), findsNothing);
            expect(find.byType(PageView), findsNothing);
            expect(find.byType(SliverList), findsWidgets);
            expect(
              find.text('The opaque metadata panel must disappear.'),
              findsOneWidget,
            );
          },
        );
      }
    }
  });

  testWidgets('overlay draws title, actions, star and natural artwork only', (
    tester,
  ) async {
    noteAvatarRatio(_pic('one'), 3 / 4);
    final state = await open(tester);

    expect(overlayCard('c'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('character-overlay-title-c')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('character-overlay-actions-c')),
      findsOneWidget,
    );
    expect(find.byTooltip('Star'), findsOneWidget);
    expect(tester.getSize(find.byTooltip('Star')), const Size(48, 48));
    expect(find.byTooltip('Actions'), findsOneWidget);
    expect(tester.getSize(find.byTooltip('Actions')), const Size(48, 48));
    expect(find.byKey(naturalImageFrameKey), findsOneWidget);
    expect(find.byType(PageView), findsNothing);
    expect(find.byType(AvatarDots), findsNothing);

    await tester.tap(find.byTooltip('Star'));
    await tester.pump();
    expect(state.characterById('c')!.starred, isTrue);
    expect(find.byTooltip('Unstar'), findsOneWidget);

    await tester.tap(find.byTooltip('Actions'));
    await tester.pumpAndSettle();
    expect(find.text('New chat'), findsOneWidget);
    expect(find.text('Edit'), findsOneWidget);
  });

  testWidgets('tapping overlay opens the character sheet', (tester) async {
    noteAvatarRatio(_pic('one'), 1);
    await open(tester);

    await tester.tap(overlayCard('c'));
    await tester.pumpAndSettle();

    expect(find.byType(CharacterSheetScreen), findsOneWidget);
  });

  testWidgets('long press selects the card and exposes selected semantics', (
    tester,
  ) async {
    noteAvatarRatio(_pic('one'), 1);
    await open(tester);
    await tester.longPress(overlayCard('c'));
    await tester.pump();

    expect(find.text('1 selected'), findsOneWidget);
    final semantics = tester.widgetList<Semantics>(
      find.descendant(of: overlayCard('c'), matching: find.byType(Semantics)),
    );
    expect(semantics.any((node) => node.properties.selected == true), isTrue);
    expect(
      find.byKey(const ValueKey('character-overlay-actions-c')),
      findsNothing,
    );
  });

  testWidgets(
    'multiple avatars page without resizing and commit after 420 ms',
    (tester) async {
      final one = _pic('one');
      final two = _pic('two');
      noteAvatarRatio(one, 3 / 4);
      noteAvatarRatio(two, 16 / 9);
      final state = await open(
        tester,
        characters: [
          Character(id: 'c', name: 'Aria', avatar: one, avatars: [two]),
        ],
      );
      final frame = find.descendant(
        of: overlayCard('c'),
        matching: find.byKey(naturalImageFrameKey),
      );
      final originalRect = tester.getRect(frame);
      expect(find.byType(PageView), findsOneWidget);
      expect(tester.widget<AvatarDots>(find.byType(AvatarDots)).count, 2);

      await tester.drag(find.byType(PageView), const Offset(-260, 0));
      await tester.pumpAndSettle(const Duration(milliseconds: 10));
      expect(tester.widget<AvatarDots>(find.byType(AvatarDots)).index, 1);
      expect(tester.getRect(frame), originalRect);
      expect(state.characterById('c')!.avatar, one);

      await tester.pump(const Duration(milliseconds: 420));
      await tester.pump();
      expect(state.characterById('c')!.avatar, two);
      expect(state.avatarPoolFor(state.characterById('c')!), [two, one]);
      expect(tester.widget<AvatarDots>(find.byType(AvatarDots)).index, 1);
      expect(tester.getRect(frame), originalRect);
      expect(tester.getSize(frame).aspectRatio, closeTo(3 / 4, 0.01));
    },
  );

  testWidgets('returning to the current avatar cancels a pending choice', (
    tester,
  ) async {
    final one = _pic('one');
    final two = _pic('two');
    for (final ref in [one, two]) {
      noteAvatarRatio(ref, 1);
    }
    final state = await open(
      tester,
      characters: [
        Character(id: 'c', name: 'Aria', avatar: one, avatars: [two]),
      ],
    );

    await tester.drag(find.byType(PageView), const Offset(-260, 0));
    await tester.pumpAndSettle(const Duration(milliseconds: 10));
    expect(tester.widget<AvatarDots>(find.byType(AvatarDots)).index, 1);
    await tester.drag(find.byType(PageView), const Offset(260, 0));
    await tester.pumpAndSettle(const Duration(milliseconds: 10));
    expect(tester.widget<AvatarDots>(find.byType(AvatarDots)).index, 0);

    await tester.pump(const Duration(milliseconds: 430));
    expect(state.characterById('c')!.avatar, one);
  });

  testWidgets('avatar choice keeps recent order and update timestamp', (
    tester,
  ) async {
    final one = _pic('one');
    final two = _pic('two');
    final other = _pic('other');
    for (final ref in [one, two, other]) {
      noteAvatarRatio(ref, 1);
    }
    final originalUpdated = DateTime(2026, 9, 10, 12);
    final state = await open(
      tester,
      characters: [
        Character(
          id: 'c',
          name: 'Aria',
          avatar: one,
          avatars: [two],
          updatedAt: originalUpdated,
        ),
        Character(
          id: 'other',
          name: 'Other',
          avatar: other,
          updatedAt: originalUpdated.subtract(const Duration(minutes: 1)),
        ),
      ],
    );
    final before = tester.getTopLeft(overlayCard('c'));

    await tester.drag(find.byType(PageView).first, const Offset(-260, 0));
    await tester.pumpAndSettle(const Duration(milliseconds: 10));
    await tester.pump(const Duration(milliseconds: 420));
    await tester.pump();

    expect(state.characterById('c')!.updatedAt, originalUpdated);
    expect(tester.getTopLeft(overlayCard('c')), before);
  });

  testWidgets('delayed avatar choice survives lazy card eviction', (
    tester,
  ) async {
    final one = _pic('one');
    final two = _pic('two');
    noteAvatarRatio(one, 1);
    noteAvatarRatio(two, 1);
    final now = DateTime(2026, 9, 10);
    final cards = <Character>[
      Character(
        id: 'c',
        name: 'Aria',
        avatar: one,
        avatars: [two],
        updatedAt: now,
      ),
      for (var i = 0; i < 80; i++)
        Character(
          id: 'other-$i',
          name: 'Other $i',
          avatar: _pic('other-$i'),
          updatedAt: now.subtract(Duration(seconds: i + 1)),
        ),
    ];
    for (final card in cards) {
      noteAvatarRatio(card.avatar, 1);
    }
    final state = await open(tester, characters: cards);

    await tester.drag(find.byType(PageView), const Offset(-260, 0));
    await tester.pumpAndSettle();
    await tester.fling(
      find.byType(CustomScrollView),
      const Offset(0, -6000),
      9000,
    );
    await tester.pump(const Duration(milliseconds: 430));
    await tester.pump();
    expect(state.characterById('c')!.avatar, two);
  });

  testWidgets('genuine pool membership change preserves the visible survivor', (
    tester,
  ) async {
    final one = _pic('one');
    final two = _pic('two');
    final three = _pic('three');
    for (final ref in [one, two, three]) {
      noteAvatarRatio(ref, 1);
    }
    final state = await open(
      tester,
      characters: [
        Character(id: 'c', name: 'Aria', avatar: one, avatars: [two, three]),
      ],
    );
    await tester.drag(find.byType(PageView), const Offset(-260, 0));
    await tester.pumpAndSettle(const Duration(milliseconds: 10));
    expect(tester.widget<AvatarDots>(find.byType(AvatarDots)).index, 1);

    await state.removeAvatarFromPool('c', three);
    await tester.pump();
    await tester.pump();
    expect(tester.widget<AvatarDots>(find.byType(AvatarDots)).count, 2);
    expect(tester.widget<AvatarDots>(find.byType(AvatarDots)).index, 1);
  });

  testWidgets('vertical movement scrolls the roster instead of paging', (
    tester,
  ) async {
    final one = _pic('one');
    final two = _pic('two');
    for (final ref in [one, two]) {
      noteAvatarRatio(ref, 1);
    }
    final now = DateTime(2026, 9, 10);
    final cards = [
      Character(
        id: 'c',
        name: 'Aria',
        avatar: one,
        avatars: [two],
        updatedAt: now,
      ),
      for (var i = 0; i < 30; i++)
        Character(
          id: 'other-$i',
          name: 'Other $i',
          avatar: _pic('other-$i'),
          updatedAt: now.subtract(Duration(seconds: i + 1)),
        ),
    ];
    for (final card in cards) {
      noteAvatarRatio(card.avatar, 1);
    }
    await open(tester, characters: cards);
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
    final before = scroll.position.pixels;

    await tester.drag(find.byType(PageView).first, const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(scroll.position.pixels, greaterThan(before));
    expect(tester.widget<AvatarDots>(find.byType(AvatarDots).first).index, 0);
  });
}
