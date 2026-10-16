import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/home_layout.dart';
import 'package:maichat/screens/home/home_grid.dart';
import 'package:maichat/screens/home/home_menu.dart';
import 'package:maichat/screens/home/home_spec.dart';

import 'home_screen_test.dart' show boot, enterEdit, seedLayout, tileFinder;

Finder _frameFinder(String id) =>
    find.descendant(of: tileFinder(id), matching: find.byType(HomeTileFrame));

HomeTileFrame _frame(WidgetTester tester, String id) =>
    tester.widget<HomeTileFrame>(_frameFinder(id));

Finder _statusFinder(String id) =>
    find.descendant(of: tileFinder(id), matching: find.byType(HomeTileStatus));

HomeTileStatus _status(WidgetTester tester, String id) =>
    tester.widget<HomeTileStatus>(_statusFinder(id));

Finder get _liftedStatus => find.byWidgetPredicate(
  (widget) => widget is HomeTileStatus && widget.lifted,
);

HomeGridMetrics _metrics(WidgetTester tester) =>
    tester.widget<HomeGridPage>(find.byType(HomeGridPage).first).metrics;

BorderSide _outline(WidgetTester tester, String id) {
  final statusElement = tester.element(_statusFinder(id));
  late Element content;
  statusElement.visitChildren((element) => content = element);
  return homeOutlineSide(content);
}

void _expectHandles({required bool visible}) {
  for (final edge in HomeEdge.values) {
    expect(
      find.byKey(ValueKey('home-handle-${edge.name}')),
      visible ? findsOneWidget : findsNothing,
    );
  }
}

void _expectClean(WidgetTester tester) {
  expect(find.byType(HomeGhost), findsNothing);
  expect(find.byType(HomeTileMenu), findsNothing);
  _expectHandles(visible: false);
  for (final status in tester.widgetList<HomeTileStatus>(
    find.byType(HomeTileStatus, skipOffstage: false),
  )) {
    expect(status.selected, isFalse);
    expect(status.lifted, isFalse);
  }
  for (final frame in tester.widgetList<HomeTileFrame>(
    find.byType(HomeTileFrame, skipOffstage: false),
  )) {
    expect(frame.hidden, isFalse, reason: frame.tile.id);
    expect(frame.selected, isFalse, reason: frame.tile.id);
  }
}

/// Deliver real pointer events on separate frames, including moves too small
/// to clear the carry threshold individually.
Future<void> _moveByInFrames(
  WidgetTester tester,
  TestGesture gesture,
  Offset offset,
) async {
  final steps = (offset.distance / 6).ceil().clamp(1, 1000);
  final delta = offset / steps.toDouble();
  for (var i = 0; i < steps; i++) {
    await gesture.moveBy(delta);
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  testWidgets('only the selected tile has a border and empty tap clears it', (
    tester,
  ) async {
    await boot(tester, layout: seedLayout());
    await enterEdit(tester);
    for (final id in ['chats', 'prov']) {
      expect(_status(tester, id).editing, isTrue);
      expect(_status(tester, id).selected, isFalse);
      expect(_outline(tester, id), BorderSide.none);
    }

    await tester.tap(tileFinder('chats'));
    await tester.pump();
    expect(_status(tester, 'chats').selected, isTrue);
    expect(_outline(tester, 'chats').width, greaterThan(0));
    expect(_outline(tester, 'prov'), BorderSide.none);
    _expectHandles(visible: true);
    expect(find.byType(HomeTileMenu), findsNothing);

    await tester.tap(tileFinder('prov'));
    await tester.pump();
    expect(_status(tester, 'chats').selected, isFalse);
    expect(_outline(tester, 'chats'), BorderSide.none);
    expect(_status(tester, 'prov').selected, isTrue);
    expect(_outline(tester, 'prov').width, greaterThan(0));
    _expectHandles(visible: true);

    final page = tester.getRect(find.byType(HomeGridPage).first);
    final metrics = _metrics(tester);
    await tester.tapAt(
      page.topLeft + Offset(metrics.cellW * 3.5, metrics.cellH * 4.5),
    );
    await tester.pumpAndSettle();
    _expectClean(tester);
    expect(_outline(tester, 'prov'), BorderSide.none);
    expect(_status(tester, 'prov').editing, isTrue);
  });

  for (final edge in [HomeEdge.right, HomeEdge.bottom]) {
    testWidgets('${edge.name} resize survives live previews across pumps', (
      tester,
    ) async {
      final state = await boot(tester, layout: seedLayout().remove('prov'));
      await enterEdit(tester);
      await tester.tap(tileFinder('chats'));
      await tester.pump();
      final metrics = _metrics(tester);
      final horizontal = edge == HomeEdge.right;
      final cell = horizontal ? metrics.cellW : metrics.cellH;
      final handle = find.byKey(ValueKey('home-handle-${edge.name}'));
      final handleElement = tester.element(handle);
      final gesture = await tester.startGesture(tester.getCenter(handle));
      var previous = 0.0;
      // Grow twice, shrink, then grow again without lifting the pointer. Each
      // preview changes the tile's layout while the recognizer is active.
      for (final (cells, span) in [(0.75, 2), (1.75, 3), (0.75, 2), (2.0, 3)]) {
        final distance = (cells - previous) * cell;
        await _moveByInFrames(
          tester,
          gesture,
          horizontal ? Offset(distance, 0) : Offset(0, distance),
        );
        previous = cells;
        final tile = _frame(tester, 'chats').tile;
        expect(
          horizontal ? tile.w : tile.h,
          span,
          reason: 'live preview at $cells cells must still follow the pointer',
        );
        final size = tester.getSize(tileFinder('chats'));
        expect(
          horizontal ? size.width : size.height,
          closeTo(span * cell, 0.01),
        );
        expect(tester.element(handle), same(handleElement));
        _expectHandles(visible: true);
        expect(find.byType(HomeTileMenu), findsNothing);
      }
      await gesture.up();
      await tester.pumpAndSettle();
      final preview = _frame(tester, 'chats').tile;
      expect(horizontal ? preview.w : preview.h, 3);
      expect(state.homeLayout.tileById('chats')!.w, 1);
      expect(state.homeLayout.tileById('chats')!.h, 1);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      final saved = state.homeLayout.tileById('chats')!;
      expect(horizontal ? saved.w : saved.h, 3);
      expect(horizontal ? saved.h : saved.w, 1);
      _expectClean(tester);
    });
  }

  testWidgets(
    'slow long press drag accumulates moves smaller than eight pixels',
    (tester) async {
      final state = await boot(tester, layout: seedLayout());
      final metrics = _metrics(tester);
      final gesture = await tester.startGesture(
        tester.getCenter(tileFinder('chats')),
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(HomeTileMenu), findsOneWidget);
      await _moveByInFrames(
        tester,
        gesture,
        Offset(metrics.cellW * 2, metrics.cellH),
      );
      expect(find.byType(HomeTileMenu), findsNothing);
      expect(find.byType(HomeGhost), findsOneWidget);
      expect(_liftedStatus, findsOneWidget);
      expect(_frame(tester, 'chats').hidden, isTrue);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(
        (_frame(tester, 'chats').tile.x, _frame(tester, 'chats').tile.y),
        (2, 1),
      );
      _expectClean(tester);
      expect(_outline(tester, 'chats'), BorderSide.none);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      final saved = state.homeLayout.tileById('chats')!;
      expect((saved.x, saved.y), (2, 1));
    },
  );

  testWidgets(
    'repeated selected pan drags settle without stale selection or ghost',
    (tester) async {
      final state = await boot(tester, layout: seedLayout());
      await enterEdit(tester);
      final metrics = _metrics(tester);
      for (final (x, y) in [(1, 1), (2, 1), (3, 1), (2, 3), (1, 4), (0, 4)]) {
        await tester.tap(tileFinder('chats'));
        await tester.pump();
        _expectHandles(visible: true);
        final before = _frame(tester, 'chats').tile;
        final gesture = await tester.startGesture(
          tester.getCenter(tileFinder('chats')),
        );
        await _moveByInFrames(
          tester,
          gesture,
          Offset(
            (x - before.x) * metrics.cellW,
            (y - before.y) * metrics.cellH,
          ),
        );
        expect(find.byType(HomeGhost), findsOneWidget);
        expect(_liftedStatus, findsOneWidget);
        expect(_frame(tester, 'chats').hidden, isTrue);
        expect(_status(tester, 'chats').selected, isFalse);
        _expectHandles(visible: false);
        await gesture.up();
        await tester.pumpAndSettle();
        final after = _frame(tester, 'chats').tile;
        expect((after.x, after.y), (x, y));
        _expectClean(tester);
        expect(_outline(tester, 'chats'), BorderSide.none);
        expect(_status(tester, 'chats').editing, isTrue);
      }
      expect(state.homeLayout.tileById('chats')!.y, 0);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      final saved = state.homeLayout.tileById('chats')!;
      expect((saved.x, saved.y), (0, 4));
      _expectClean(tester);
    },
  );

  testWidgets('cancelling a second finger swipe preserves the active carry', (
    tester,
  ) async {
    final layout = HomeLayout(
      columns: 4,
      rows: 6,
      pages: [
        seedLayout().pages.single,
        const HomePage(id: 'p1'),
      ],
    );
    final state = await boot(tester, layout: layout);
    final metrics = _metrics(tester);
    final hold = await tester.startGesture(
      tester.getCenter(tileFinder('chats')),
      pointer: 1,
    );
    await tester.pump(const Duration(milliseconds: 600));
    await _moveByInFrames(tester, hold, Offset(metrics.cellW, metrics.cellH));
    expect(_liftedStatus, findsOneWidget);

    final swipe = await tester.startGesture(const Offset(370, 650), pointer: 2);
    await swipe.moveBy(const Offset(-180, 0));
    await tester.pump(const Duration(milliseconds: 16));
    await swipe.cancel();
    await tester.pumpAndSettle();
    expect(find.byType(HomeGhost), findsOneWidget);
    expect(_liftedStatus, findsOneWidget);
    final source = tester
        .widgetList<HomeTileFrame>(
          find.byType(HomeTileFrame, skipOffstage: false),
        )
        .singleWhere((frame) => frame.tile.id == 'chats');
    expect(source.hidden, isTrue);
    expect(source.selected, isFalse);
    expect(source.canDrag, isTrue);
    final currentPage = tester.widget<Semantics>(
      find.bySemanticsLabel('Page 1 of 2'),
    );
    expect(
      currentPage.properties.selected,
      isTrue,
      reason: 'a cancelled swipe must not turn the page',
    );

    // The original pointer must still move and drop the tile after cancellation.
    final carriedBefore = tester.getTopLeft(_liftedStatus);
    await _moveByInFrames(tester, hold, Offset(metrics.cellW, 0));
    expect(
      tester.getTopLeft(_liftedStatus).dx - carriedBefore.dx,
      closeTo(metrics.cellW, 0.01),
    );
    await hold.up();
    await tester.pumpAndSettle();
    _expectClean(tester);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    final saved = state.homeLayout.tileById('chats')!;
    expect((saved.x, saved.y), (2, 1));
    expect(state.homeLayout.pageOf('chats'), 0);
  });

  testWidgets(
    'swiping from the hidden source cannot move or cancel the active carry',
    (tester) async {
      final seed = seedLayout();
      final layout = seed
          .update(seed.tileById('chats')!.copyWith(x: 2))!
          .addPage();
      final state = await boot(tester, layout: layout);
      final metrics = _metrics(tester);
      final sourceCenter = tester.getCenter(tileFinder('chats'));
      final hold = await tester.startGesture(sourceCenter, pointer: 1);
      await tester.pump(const Duration(milliseconds: 600));
      await _moveByInFrames(
        tester,
        hold,
        Offset(-metrics.cellW, metrics.cellH),
      );
      expect(_liftedStatus, findsOneWidget);
      expect(_frame(tester, 'chats').hidden, isTrue);
      expect(_frame(tester, 'chats').canDrag, isTrue);
      final carriedPosition = tester.getTopLeft(_liftedStatus);
      final landingRect = tester.getRect(find.byType(HomeGhost));

      // The hidden frame still receives touches. Its second recognizer must
      // not claim ownership of the long press already carrying this tile.
      final swipe = await tester.startGesture(sourceCenter, pointer: 2);
      for (var i = 0; i < 12; i++) {
        await swipe.moveBy(const Offset(-8, 0));
        await tester.pump(const Duration(milliseconds: 16));
        expect(_liftedStatus, findsOneWidget);
        expect(tester.getTopLeft(_liftedStatus), carriedPosition);
        expect(tester.getRect(find.byType(HomeGhost)), landingRect);
        expect(_frame(tester, 'chats').hidden, isTrue);
      }
      await swipe.cancel();
      await tester.pumpAndSettle();
      expect(_liftedStatus, findsOneWidget);
      expect(tester.getTopLeft(_liftedStatus), carriedPosition);
      expect(tester.getRect(find.byType(HomeGhost)), landingRect);
      expect(_frame(tester, 'chats').hidden, isTrue);
      expect(
        tester
            .widget<Semantics>(find.bySemanticsLabel('Page 1 of 2'))
            .properties
            .selected,
        isTrue,
      );

      // Only the original finger may continue moving and finally place it.
      await _moveByInFrames(tester, hold, Offset(metrics.cellW, 0));
      expect(
        tester.getTopLeft(_liftedStatus).dx - carriedPosition.dx,
        closeTo(metrics.cellW, 0.01),
      );
      await hold.up();
      await tester.pumpAndSettle();
      _expectClean(tester);
      expect(_outline(tester, 'chats'), BorderSide.none);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      final saved = state.homeLayout.tileById('chats')!;
      expect((saved.x, saved.y), (2, 1));
      expect(state.homeLayout.pageOf('chats'), 0);
    },
  );

  testWidgets(
    'cancelling the carry restores its source and permits another drag',
    (tester) async {
      final state = await boot(tester, layout: seedLayout());
      await enterEdit(tester);
      final metrics = _metrics(tester);
      await tester.tap(tileFinder('chats'));
      await tester.pump();
      final cancelled = await tester.startGesture(
        tester.getCenter(tileFinder('chats')),
      );
      await _moveByInFrames(
        tester,
        cancelled,
        Offset(metrics.cellW * 2, metrics.cellH),
      );
      expect(find.byType(HomeGhost), findsOneWidget);
      expect(_frame(tester, 'chats').hidden, isTrue);
      await cancelled.cancel();
      await tester.pumpAndSettle();
      _expectClean(tester);
      final restored = _frame(tester, 'chats').tile;
      expect((restored.x, restored.y), (0, 0));
      expect(_outline(tester, 'chats'), BorderSide.none);

      await tester.tap(tileFinder('chats'));
      await tester.pump();
      final next = await tester.startGesture(
        tester.getCenter(tileFinder('chats')),
      );
      await _moveByInFrames(tester, next, Offset(metrics.cellW, metrics.cellH));
      expect(find.byType(HomeGhost), findsOneWidget);
      await next.up();
      await tester.pumpAndSettle();
      _expectClean(tester);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      final saved = state.homeLayout.tileById('chats')!;
      expect((saved.x, saved.y), (1, 1));
    },
  );

  testWidgets(
    'carry frames preserve page identity and do not rebuild content',
    (tester) async {
      await boot(tester, layout: seedLayout());
      await enterEdit(tester);
      await tester.tap(tileFinder('chats'));
      await tester.pump();
      final gesture = await tester.startGesture(
        tester.getCenter(tileFinder('chats')),
      );
      await gesture.moveBy(const Offset(30, 30));
      await tester.pumpAndSettle();
      expect(_liftedStatus, findsOneWidget);
      final page = tester.widget<HomeGridPage>(find.byType(HomeGridPage).first);
      final carryStart = tester.getTopLeft(_liftedStatus);
      Element contentRoot(Finder status) {
        // Count the spec's cached content Builder and its descendants. The
        // overlay's wrapper may rebuild to return that retained content.
        return tester.element(
          find.descendant(of: status, matching: find.byType(Builder)).first,
        );
      }

      final stationaryContent = contentRoot(_statusFinder('prov'));
      final carriedContent = contentRoot(_liftedStatus);
      var stationaryBuilds = 0;
      var carriedBuilds = 0;
      bool isWithin(Element element, Element root) {
        if (identical(element, root)) return true;
        var found = false;
        element.visitAncestorElements((ancestor) {
          found = identical(ancestor, root);
          return !found;
        });
        return found;
      }

      final previousCallback = debugOnRebuildDirtyWidget;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        previousCallback?.call(element, builtOnce);
        if (isWithin(element, stationaryContent)) stationaryBuilds++;
        if (isWithin(element, carriedContent)) carriedBuilds++;
      };
      try {
        for (var i = 0; i < 12; i++) {
          await gesture.moveBy(const Offset(5, 2));
          await tester.pump(const Duration(milliseconds: 16));
          expect(
            tester.widget<HomeGridPage>(find.byType(HomeGridPage).first),
            same(page),
          );
          expect(contentRoot(_statusFinder('prov')), same(stationaryContent));
          expect(contentRoot(_liftedStatus), same(carriedContent));
        }
        expect(
          stationaryBuilds,
          0,
          reason: 'untouched content is stable during carry',
        );
        expect(
          carriedBuilds,
          0,
          reason: 'moving the overlay must not rebuild its body',
        );
        final travel = tester.getTopLeft(_liftedStatus) - carryStart;
        expect(travel.dx, closeTo(60, 0.01));
        expect(travel.dy, closeTo(24, 0.01));
      } finally {
        debugOnRebuildDirtyWidget = previousCallback;
      }
      await gesture.up();
      await tester.pumpAndSettle();
      _expectClean(tester);
    },
  );

  testWidgets(
    'dense grid keeps the selected shortcut centre available to drag',
    (tester) async {
      final layout = HomeLayout(
        columns: 8,
        rows: 10,
        pages: [
          const HomePage(
            id: 'dense',
            tiles: [
              HomeTile(
                id: 'chats',
                kind: HomeWidgetKind.quickOpen,
                x: 1,
                y: 1,
                config: {'target': 'chats'},
              ),
            ],
          ),
        ],
      );
      await boot(tester, layout: layout);
      await enterEdit(tester);
      await tester.tap(tileFinder('chats'));
      await tester.pump();
      final metrics = _metrics(tester);
      final gesture = await tester.startGesture(
        tester.getCenter(tileFinder('chats')),
      );
      await _moveByInFrames(
        tester,
        gesture,
        Offset(metrics.cellW * 2, metrics.cellH * 2),
      );
      expect(_liftedStatus, findsOneWidget);
      await gesture.up();
      await tester.pumpAndSettle();
      final tile = _frame(tester, 'chats').tile;
      expect((tile.x, tile.y, tile.w, tile.h), (3, 3, 1, 1));
      _expectClean(tester);
    },
  );

  for (final (fits, merge) in [(true, false), (false, false), (true, true)]) {
    testWidgets('landing preview is translucent: fits=$fits merge=$merge', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: HomeGhost(fits: fits, merge: merge),
        ),
      );
      final decoration =
          tester
                  .widget<DecoratedBox>(
                    find.descendant(
                      of: find.byType(HomeGhost),
                      matching: find.byType(DecoratedBox),
                    ),
                  )
                  .decoration
              as ShapeDecoration;
      expect(decoration.color!.a, greaterThan(0));
      expect(decoration.color!.a, lessThanOrEqualTo(0.12));
      final border = decoration.shape as OutlinedBorder;
      expect(border.side.color.a, greaterThan(decoration.color!.a));
      expect(border.side.color.a, lessThan(0.5));
    });
  }
}
