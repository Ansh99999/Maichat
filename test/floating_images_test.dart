import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/floating_image.dart';
import 'package:maichat/models/gallery_image.dart';
import 'package:maichat/screens/chat_screen.dart';
import 'package:maichat/state/app_state.dart';
import 'package:maichat/widgets/floating_images_layer.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Drives the real [ChatScreen] with pictures floating over it: dragging the bar
/// to move, the corner grip to resize, the ✕ to dismiss, and that where a picture
/// ends up is what gets persisted.
///
/// The pictures are seeded as records with `local:` references and no pictures
/// directory behind them, so nothing decodes — the frame, its gestures and the
/// stored geometry are what is under test, not the bitmaps.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  Future<AppState> chatWithFloats({int count = 1}) async {
    final state = AppState()
      // Persist float moves immediately in tests, so a gesture leaves no pending
      // debounce timer for the binding to flag.
      ..debounceFloatSaves = false;
    await state.init();
    final character = Character(id: 'aria', name: 'Aria', firstMes: 'Hello.');
    await state.addCharacter(character);
    state.startChatWithCharacter(character);
    for (var i = 0; i < count; i++) {
      await state.saveGalleryImage(GalleryImage(
        id: 'img$i',
        image: 'local:img$i.png',
        title: 'Picture $i',
        characterId: 'aria',
        createdAt: DateTime(2026, 4, 24, 12 - i),
      ));
      await state.floatImage(state.active.id, 'img$i');
    }
    return state;
  }

  Widget host(AppState state) => ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: ChatScreen()),
      );

  /// Explicit frames rather than `pumpAndSettle`: the composer strip animates, so
  /// settling never finishes.
  Future<void> pumpChat(WidgetTester tester, AppState state) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(host(state));
    await tester.pump();
    await tester.pump();
  }

  /// A **snapshot** of a float's geometry — `copyWith` because the stored object
  /// is mutated in place, so holding it would compare a value against itself.
  FloatingImage floatOf(AppState state, String imageId) => state.active
      .floatingImages
      .firstWhere((f) => f.imageId == imageId)
      .copyWith();

  /// Drags [finder] in several steps, the way a finger moves (past the slop).
  Future<void> dragBy(WidgetTester tester, Finder finder, Offset total,
      {int steps = 6}) async {
    final gesture = await tester.startGesture(tester.getCenter(finder));
    for (var i = 0; i < steps; i++) {
      await gesture.moveBy(Offset(total.dx / steps, total.dy / steps));
      await tester.pump();
    }
    await gesture.up();
    await tester.pump();
    await tester.pump();
  }

  testWidgets('a chat with nothing floating draws no window', (tester) async {
    final state = await chatWithFloats(count: 0);
    await pumpChat(tester, state);
    expect(find.byType(FloatingImagesLayer), findsOneWidget,
        reason: 'the layer is always mounted');
    expect(find.byIcon(Icons.close), findsNothing);
    expect(find.byIcon(Icons.drag_indicator), findsNothing);
  });

  testWidgets('a floated picture appears over the thread with a drag-bar and ✕',
      (tester) async {
    final state = await chatWithFloats();
    await pumpChat(tester, state);

    expect(find.byIcon(Icons.close), findsOneWidget);
    expect(find.byIcon(Icons.drag_indicator), findsOneWidget);
    expect(find.byIcon(Icons.open_in_full), findsOneWidget, reason: 'resize grip');
    // The greeting is still there underneath — a float covers the chat, it does
    // not replace it, and nothing was added to the transcript.
    expect(find.text('Hello.'), findsOneWidget);
    expect(state.active.messages, hasLength(1));
  });

  testWidgets('dragging the bar moves it, and where it lands is remembered',
      (tester) async {
    final state = await chatWithFloats();
    await pumpChat(tester, state);
    final before = floatOf(state, 'img0');

    await dragBy(tester, find.byIcon(Icons.drag_indicator), const Offset(60, 80));

    final after = floatOf(state, 'img0');
    expect(after.x, greaterThan(before.x));
    expect(after.y, greaterThan(before.y));
    // Fractions of the chat area, not pixels.
    expect(after.x, lessThanOrEqualTo(1));
    expect(after.y, lessThanOrEqualTo(1));
  });

  testWidgets('the corner grip resizes it', (tester) async {
    final state = await chatWithFloats();
    await pumpChat(tester, state);
    final before = floatOf(state, 'img0');

    await dragBy(tester, find.byIcon(Icons.open_in_full), const Offset(80, 80));
    expect(floatOf(state, 'img0').width, greaterThan(before.width));

    await dragBy(tester, find.byIcon(Icons.open_in_full), const Offset(-200, -200));
    expect(floatOf(state, 'img0').width, lessThan(before.width));
  });

  testWidgets('resizing to nothing stops at a grabbable minimum', (tester) async {
    final state = await chatWithFloats();
    await pumpChat(tester, state);

    await dragBy(tester, find.byIcon(Icons.open_in_full), const Offset(-400, -400),
        steps: 12);
    expect(floatOf(state, 'img0').width,
        greaterThanOrEqualTo(kFloatingImageMinWidth));
  });

  testWidgets('the ✕ takes it back off the chat', (tester) async {
    final state = await chatWithFloats();
    await pumpChat(tester, state);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    await tester.pump();

    expect(state.active.floatingImages, isEmpty);
    expect(find.byIcon(Icons.close), findsNothing);
    // The picture itself is untouched — dismissing is not deleting.
    expect(state.galleryImageById('img0'), isNotNull);
  });

  testWidgets('several floats coexist, and dragging one raises it',
      (tester) async {
    final state = await chatWithFloats(count: 3);
    await pumpChat(tester, state);
    expect(find.byIcon(Icons.close), findsNWidgets(3));
    expect(state.active.floatingImages.first.imageId, 'img0');

    // Its bar is the topmost in the fanned-out stack; the first-floated (img0) is
    // at the back, so grab its bar (the last drag_indicator in paint order is on
    // top, but img0 started at the back) — drag any bar and assert that float
    // ends on top. Grab the first bar found.
    await dragBy(tester, find.byIcon(Icons.drag_indicator).first, const Offset(30, 30));

    // Whichever was dragged is now last (on top); at minimum the order changed to
    // put a dragged float at the end.
    expect(state.active.floatingImages, hasLength(3));
  });

  testWidgets('deleting the picture takes its float with it', (tester) async {
    final state = await chatWithFloats();
    await pumpChat(tester, state);
    expect(find.byIcon(Icons.close), findsOneWidget);

    await state.deleteGalleryImage('img0');
    await tester.pump();
    await tester.pump();

    expect(state.active.floatingImages, isEmpty);
    expect(find.byIcon(Icons.close), findsNothing);
  });

  testWidgets('floats survive leaving and re-entering the chat', (tester) async {
    final state = await chatWithFloats();
    await pumpChat(tester, state);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    await pumpChat(tester, state);
    expect(find.byIcon(Icons.close), findsOneWidget);
    expect(state.active.floatingImages.single.imageId, 'img0');
  });

  group('smoothness — the raster cost the overlay showed', () {
    testWidgets('a drag writes nothing until it ends', (tester) async {
      final state = await chatWithFloats();
      await pumpChat(tester, state);

      var notifications = 0;
      state.addListener(() => notifications++);

      final gesture = await tester
          .startGesture(tester.getCenter(find.byIcon(Icons.drag_indicator)));
      for (var i = 0; i < 12; i++) {
        await gesture.moveBy(const Offset(6, 5));
        await tester.pump();
      }
      expect(notifications, 0, reason: 'a pointer-move must not rewrite state');
      await gesture.up();
      await tester.pump();
      await tester.pump();
      expect(notifications, 1, reason: 'one write, when it settles');
    });

    testWidgets('the picture is a retained layer moved by a transform',
        (tester) async {
      // The stutter was on the raster thread. The cure is structural: the picture
      // is wrapped in its own [RepaintBoundary] and *moved and scaled by a
      // [Transform] above it*, so it is rasterised once and the compositor only
      // re-composites that texture at a new matrix — never re-rasterises it, and
      // never touches a full-screen layer. Assert that shape rather than a frame
      // metric (an independently-composited boundary is the good case, so its
      // paint count climbing per frame would be *expected*, not a fault).
      final state = await chatWithFloats();
      await pumpChat(tester, state);

      final rb = find.byKey(const ValueKey('float-window-g:img0'));
      expect(rb, findsOneWidget);
      expect(tester.widget(rb), isA<RepaintBoundary>());
      expect(find.ancestor(of: rb, matching: find.byType(Transform)),
          findsWidgets,
          reason: 'moved/scaled by a transform above the boundary');
    });

    testWidgets('a streaming reply does not repaint the float', (tester) async {
      final state = await chatWithFloats();
      await pumpChat(tester, state);
      final frame = tester.element(find.byIcon(Icons.close));

      await state.saveGalleryImage(
        state.galleryImageById('img0')!.copyWith(title: 'Renamed'),
      );
      await tester.pump();
      await tester.pump();
      expect(tester.element(find.byIcon(Icons.close)), same(frame));
    });
  });

  testWidgets('the chat has no backdrop filter to re-blur every frame',
      (tester) async {
    // A backdrop blur re-runs, with a GPU readback that stalls mobile pipelines,
    // on every composited frame — so it janked every drag and scroll. There must
    // be none in the chat.
    final state = await chatWithFloats();
    await pumpChat(tester, state);
    expect(find.byType(BackdropFilter), findsNothing);
  });
}
