import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/home_layout.dart';
import 'package:maichat/screens/chats_screen.dart';
import 'package:maichat/screens/home/home_grid.dart';
import 'package:maichat/screens/home/home_menu.dart';
import 'package:maichat/screens/home_screen.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart' hide Provider;
import 'package:shared_preferences/shared_preferences.dart';

/// A small layout the tests can reason about cell by cell: a 4×6 grid with a
/// Chats shortcut at (0,0) and a provider widget at (0,2), 2×1.
HomeLayout seedLayout() => HomeLayout(
      columns: 4,
      rows: 6,
      pages: [
        HomePage(id: 'p0', tiles: const [
          HomeTile(
            id: 'chats',
            kind: HomeWidgetKind.quickOpen,
            x: 0,
            y: 0,
            config: {'target': 'chats'},
          ),
          HomeTile(id: 'prov', kind: HomeWidgetKind.provider, x: 0, y: 2, w: 2),
        ]),
      ],
    );

Future<AppState> boot(WidgetTester tester, {HomeLayout? layout}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{
    if (layout != null) 'flutter.homeLayout': jsonEncode(layout.toJson()),
  });
  final state = AppState();
  await state.init();
  // A phone: 412 × 915 logical pixels.
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1080 / 412;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
    value: state,
    child: const MaterialApp(home: HomeScreen()),
  ));
  await tester.pumpAndSettle();
  return state;
}

Finder tileFinder(String id) => find.byKey(ValueKey('home-tile-$id'));

Future<void> enterEdit(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Home screen options'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Edit home screen'));
  await tester.pumpAndSettle();
}

/// The width and height of one cell on screen, measured off the grid.
Size cellSize(WidgetTester tester) {
  final rect = tester.getRect(tileFinder('chats'));
  return rect.size;
}

void main() {
  testWidgets('a fresh install opens on the default home screen',
      (tester) async {
    await boot(tester);
    for (final t in HomeLayout.defaults().pages.first.tiles) {
      expect(tileFinder(t.id), findsOneWidget, reason: t.id);
    }
    // The Studio is one tap away from the first screen.
    expect(find.text('Studio'), findsWidgets);
  });

  testWidgets('a tap outside edit mode does what the widget says',
      (tester) async {
    await boot(tester, layout: seedLayout());
    await tester.tap(tileFinder('chats'));
    await tester.pumpAndSettle();
    expect(find.byType(ChatsScreen), findsOneWidget);
  });

  testWidgets('edit mode: a tap opens the tile menu instead of the tile',
      (tester) async {
    await boot(tester, layout: seedLayout());
    await enterEdit(tester);
    expect(find.text('Done'), findsOneWidget);
    await tester.tap(tileFinder('chats'));
    await tester.pumpAndSettle();
    expect(find.byType(ChatsScreen), findsNothing);
    expect(find.byType(HomeTileMenu), findsOneWidget);
    // Resize is a menu action now; the handles are not up until asked for.
    expect(find.byKey(const ValueKey('home-handle-right')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('home-menu-resize')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('home-handle-right')), findsOneWidget);
  });

  testWidgets('the menu is anchored at the tile and never shrinks the page',
      (tester) async {
    await boot(tester, layout: seedLayout());
    final before = tester.getRect(tileFinder('prov'));
    await tester.longPress(tileFinder('prov'));
    await tester.pumpAndSettle();
    expect(find.text('Done'), findsOneWidget);
    final menu = tester.getRect(find.byType(HomeTileMenu));
    final tile = tester.getRect(tileFinder('prov'));
    // Pinned to the tile's left edge, just above or below it — never over it.
    expect((menu.left - tile.left).abs(), lessThan(12));
    expect(menu.overlaps(tile.deflate(8)), isFalse);
    // The tiles are drawn exactly where (and as big as) they were live.
    expect(tester.getRect(tileFinder('prov')).size, before.size);
  });

  testWidgets('holding then moving closes the menu and carries the tile',
      (tester) async {
    final state = await boot(tester, layout: seedLayout());
    final cell = cellSize(tester);
    final gesture =
        await tester.startGesture(tester.getCenter(tileFinder('chats')));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(HomeTileMenu), findsOneWidget);
    for (var i = 1; i <= 10; i++) {
      await gesture.moveBy(Offset(cell.width * 3 / 10, cell.height * 4 / 10));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(find.byType(HomeTileMenu), findsNothing);
    expect(find.byType(HomeGhost), findsOneWidget);
    await gesture.up();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    final moved = state.homeLayout.tileById('chats')!;
    expect((moved.x, moved.y), (3, 4));
  });

  testWidgets('a selected tile moves on a plain drag too', (tester) async {
    final state = await boot(tester, layout: seedLayout());
    await enterEdit(tester);
    await tester.tap(tileFinder('chats'));
    await tester.pumpAndSettle();
    final cell = cellSize(tester);
    await tester.drag(
      tileFinder('chats'),
      Offset(cell.width * 3, cell.height * 4),
      touchSlopX: 0,
      touchSlopY: 0,
    );
    await tester.pumpAndSettle();
    expect(state.homeLayout.tileById('chats')!.x, 0, reason: 'not until Done');
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    final moved = state.homeLayout.tileById('chats')!;
    expect((moved.x, moved.y), (3, 4));
    final prefs = await SharedPreferences.getInstance();
    final stored =
        HomeLayout.fromJson(jsonDecode(prefs.getString('homeLayout')!));
    expect(stored.tileById('chats')!.x, 3);
  });

  testWidgets('a move onto another widget springs back', (tester) async {
    final state = await boot(tester, layout: seedLayout());
    await enterEdit(tester);
    await tester.tap(tileFinder('chats'));
    await tester.pumpAndSettle();
    final cell = cellSize(tester);
    await tester.drag(
      tileFinder('chats'),
      Offset(cell.width * 0.4, cell.height * 2),
      touchSlopX: 0,
      touchSlopY: 0,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    final t = state.homeLayout.tileById('chats')!;
    expect((t.x, t.y), (0, 0));
  });

  testWidgets('a second finger swipes pages while the first carries a tile',
      (tester) async {
    final layout = HomeLayout(columns: 4, rows: 6, pages: [
      seedLayout().pages.single,
      const HomePage(id: 'p1'),
    ]);
    final state = await boot(tester, layout: layout);
    final hold =
        await tester.startGesture(tester.getCenter(tileFinder('chats')), pointer: 1);
    await tester.pump(const Duration(milliseconds: 600));
    final cell = cellSize(tester);
    await hold.moveBy(Offset(cell.width, cell.height));
    await tester.pump(const Duration(milliseconds: 16));
    // Another finger flicks right-to-left across the screen.
    final swipe = await tester.startGesture(const Offset(380, 600), pointer: 2);
    await swipe.moveBy(const Offset(-200, 0));
    await swipe.up();
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Page 2 of 2'), findsOneWidget);
    final dots = tester.widget<Semantics>(
      find.bySemanticsLabel('Page 2 of 2').first,
    );
    expect(dots.properties.selected, isTrue);
    await hold.up();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(state.homeLayout.pageOf('chats'), 1);
  });

  testWidgets('a shortcut dropped on a shortcut makes an app folder',
      (tester) async {
    final layout = HomeLayout(columns: 4, rows: 6, pages: [
      HomePage(id: 'p0', tiles: const [
        HomeTile(
          id: 'a',
          kind: HomeWidgetKind.quickOpen,
          x: 0,
          y: 0,
          config: {'target': 'chats'},
        ),
        HomeTile(
          id: 'b',
          kind: HomeWidgetKind.quickOpen,
          x: 2,
          y: 0,
          config: {'target': 'gallery'},
        ),
      ]),
    ]);
    final state = await boot(tester, layout: layout);
    final from = tester.getCenter(find.byKey(const ValueKey('home-tile-b')));
    final to = tester.getCenter(find.byKey(const ValueKey('home-tile-a')));
    final g = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 600));
    for (var i = 1; i <= 10; i++) {
      await g.moveTo(Offset.lerp(from, to, i / 10)!);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    final folder = state.homeLayout.tileById('a')!;
    expect(folder.kind, HomeWidgetKind.appFolder);
    expect(HomeLayout.folderTargets(folder), ['chats', 'gallery']);
    expect(state.homeLayout.tileById('b'), isNull);
  });

  testWidgets('pulling the right handle widens the tile', (tester) async {
    final state = await boot(tester, layout: seedLayout());
    await enterEdit(tester);
    await tester.tap(tileFinder('chats'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('home-menu-resize')));
    await tester.pumpAndSettle();
    final cell = cellSize(tester);
    await tester.drag(
      find.byKey(const ValueKey('home-handle-right')),
      Offset(cell.width * 2, 0),
      touchSlopX: 0,
      touchSlopY: 0,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(state.homeLayout.tileById('chats')!.w, 3);
  });

  Future<void> removeFromMenu(WidgetTester tester, String id) async {
    await tester.tap(tileFinder(id));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('home-menu-remove')));
    await tester.pumpAndSettle();
  }

  testWidgets('remove, then undo', (tester) async {
    await boot(tester, layout: seedLayout());
    await enterEdit(tester);
    await removeFromMenu(tester, 'prov');
    expect(tileFinder('prov'), findsNothing);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(tileFinder('prov'), findsOneWidget);
  });

  testWidgets('Discard throws the draft away', (tester) async {
    final state = await boot(tester, layout: seedLayout());
    await enterEdit(tester);
    await removeFromMenu(tester, 'prov');
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard changes'));
    await tester.pumpAndSettle();
    expect(find.text('Done'), findsNothing);
    expect(tileFinder('prov'), findsOneWidget);
    expect(state.homeLayout.tileById('prov'), isNotNull);
  });

  testWidgets('Back closes the menu, then leaves edit mode keeping changes',
      (tester) async {
    final state = await boot(tester, layout: seedLayout());
    await enterEdit(tester);
    await removeFromMenu(tester, 'prov');
    await tester.tap(tileFinder('chats'));
    await tester.pumpAndSettle();
    expect(find.byType(HomeTileMenu), findsOneWidget);
    final nav = tester.state<NavigatorState>(find.byType(Navigator));
    await nav.maybePop();
    await tester.pumpAndSettle();
    expect(find.byType(HomeTileMenu), findsNothing);
    expect(find.text('Done'), findsOneWidget);
    await nav.maybePop();
    await tester.pumpAndSettle();
    expect(find.text('Done'), findsNothing);
    expect(state.homeLayout.tileById('prov'), isNull);
    expect(find.byType(HomeScreen), findsOneWidget);
  });

  testWidgets('add a page, then remove it', (tester) async {
    final state = await boot(tester, layout: seedLayout());
    await enterEdit(tester);
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add a page'));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Page 2 of 2'), findsOneWidget);
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove this page'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(state.homeLayout.pages, hasLength(1));
  });

  testWidgets('reset brings the defaults back', (tester) async {
    final state = await boot(tester, layout: seedLayout());
    await enterEdit(tester);
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset to default'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Reset'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(state.homeLayout, HomeLayout.defaults());
  });

  testWidgets('every widget renders on a crowded, small home screen',
      (tester) async {
    // Each kind at its smallest and at a roomy span, on a 5×7 grid.
    var layout = HomeLayout(columns: 5, rows: 7, pages: [const HomePage(id: 'a')]);
    for (final kind in HomeWidgetKind.values) {
      layout = layout.add(kind, span: (w: 1, h: 1))?.layout ?? layout;
    }
    for (final kind in HomeWidgetKind.values) {
      layout = layout.add(kind, span: (w: 3, h: 2))?.layout ?? layout;
    }
    await boot(tester, layout: layout);
    expect(tester.takeException(), isNull);
    await enterEdit(tester);
    expect(tester.takeException(), isNull);
  });
}
