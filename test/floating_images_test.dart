import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/floating_image.dart';
import 'package:maichat/models/gallery_image.dart';
import 'package:maichat/screens/chat_screen.dart';
import 'package:maichat/screens/gallery/image_viewer_screen.dart';
import 'package:maichat/state/app_state.dart';
import 'package:maichat/widgets/avatar_image.dart';
import 'package:maichat/widgets/floating_images_layer.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Drives the real [ChatScreen] with pictures floating over it: the drag, the
/// two-finger resize and turn, the ✕, and that where a picture ends up is what
/// gets persisted.
///
/// The pictures are seeded as records with `local:` references and no pictures
/// directory behind them, so nothing decodes — the frame, its gestures and the
/// stored geometry are what is under test, not the bitmaps.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  Future<AppState> chatWithFloats({int count = 1}) async {
    final state = AppState()
      // Save float positions immediately in tests, so a gesture leaves no
      // pending debounce timer for the binding to flag.
      ..debounceFloatSaves = false;
    // The chat screen holds a startup gate until the store has been read.
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

  /// Pumps the chat. Explicit frames rather than `pumpAndSettle`: the frosted menu
  /// button and the composer strip animate, so settling never finishes.
  Future<void> pumpChat(WidgetTester tester, AppState state) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // A settled float persists on a debounce timer; cancel/flush it at teardown
    // so it does not trip the "timer still pending" check.
    addTearDown(state.flushPendingSaves);
    await tester.pumpWidget(host(state));
    await tester.pump();
    await tester.pump();
  }

  /// A **snapshot** of a float's geometry.
  ///
  /// `copyWith` matters: the stored [FloatingImage] is mutable and
  /// `moveFloatingImage` edits it in place, so holding the object itself as a
  /// "before" value would compare it against itself and every assertion would
  /// pass trivially — or, as it did here, fail claiming nothing moved.
  FloatingImage floatOf(AppState state, String imageId) => state
      .active.floatingImages
      .firstWhere((f) => f.imageId == imageId)
      .copyWith();

  testWidgets('a chat with nothing floating draws no layer', (tester) async {
    final state = await chatWithFloats(count: 0);
    await pumpChat(tester, state);
    expect(find.byType(FloatingImagesLayer), findsOneWidget,
        reason: 'the layer is always mounted');
    expect(find.byIcon(Icons.close), findsNothing,
        reason: 'but it draws nothing');
  });

  testWidgets('a floated picture appears over the thread with a dismiss control',
      (tester) async {
    final state = await chatWithFloats();
    await pumpChat(tester, state);

    expect(find.byIcon(Icons.close), findsOneWidget);
    // The greeting is still there underneath — a float covers the chat, it does
    // not replace it, and nothing was added to the transcript.
    expect(find.text('Hello.'), findsOneWidget);
    expect(state.active.messages, hasLength(1));
  });

  testWidgets('resize and turn pivot about the centre, not the corner',
      (tester) async {
    // The "funky" rotation and the runaway zoom: rotation and scale used to be
    // folded into the positioning matrix, which pivoted them about the picture's
    // top-left corner. A small turn then swept the picture through a wide arc and
    // a pinch grew it away toward the bottom-right — a light two-finger touch
    // shoved the picture a long way across the chat. Pivoting about the centre
    // instead keeps the picture where it is and only turns/grows it in place.
    //
    // With the two fingers moved symmetrically about their midpoint the focal
    // point does not translate, so a centre pivot leaves the picture's centre
    // fixed while a corner pivot swings it. The frame's on-screen bounding box
    // shares its centre with the picture, so its centre must barely move.
    final state = await chatWithFloats();
    await pumpChat(tester, state);

    final frame = find
        .descendant(
          of: find.byType(FloatingImagesLayer),
          matching: find.byType(RawGestureDetector),
        )
        .first;
    final centreBefore = tester.getRect(frame).center;

    final anchor =
        tester.getCenter(find.byIcon(Icons.close)) + const Offset(-40, 60);
    final left = await tester.startGesture(anchor - const Offset(40, 0));
    final right = await tester.startGesture(anchor + const Offset(40, 0));
    // Symmetric about the midpoint: turns and spreads without dragging the focal
    // point, so the only thing that could move the centre is the pivot.
    for (var i = 0; i < 6; i++) {
      await left.moveBy(const Offset(-5, -6));
      await right.moveBy(const Offset(5, 6));
      await tester.pump();
    }
    final centreDuring = tester.getRect(frame).center;
    await left.up();
    await right.up();
    await tester.pump();
    await tester.pump();

    // It really did manipulate the picture...
    expect(state.active.floatingImages.single.width, greaterThan(180),
        reason: 'the fingers spread, so it grew');
    expect(state.active.floatingImages.single.rotation, isNot(0),
        reason: 'and turned');
    // ...but its centre stayed put. The old corner pivot moved it tens of pixels
    // for a manipulation this size; a centre pivot keeps it within a hair.
    expect((centreDuring - centreBefore).distance, lessThan(12),
        reason: 'a centre pivot leaves the picture where it is');
  });

  testWidgets('the message list is its own retained layer, isolated from floats',
      (tester) async {
    // Moving a float must not force the whole thread to re-record on the UI
    // thread every frame. The message viewport sits behind its own repaint
    // boundary so a float's repaint composites one cached layer instead of
    // walking every visible bubble. What proves isolation is not that *a*
    // boundary exists above the list (the framework has plenty) but that the
    // closest one wraps the list *without* also enclosing the float layer — so
    // the two are on separate layers. Guards against the drag/pinch stutter on a
    // long chat.
    final state = await chatWithFloats();
    await pumpChat(tester, state);
    final listBoundary = find
        .ancestor(
          of: find.byType(ListView),
          matching: find.byType(RepaintBoundary),
        )
        .first;
    expect(listBoundary, findsOneWidget);
    expect(
      find.descendant(
        of: listBoundary,
        matching: find.byType(FloatingImagesLayer),
      ),
      findsNothing,
      reason: 'the thread and the floats over it are on separate layers',
    );
  });

  testWidgets('the picture is drawn bare while being manipulated, framed at rest',
      (tester) async {
    // The measured fix for the stutter: transforming the framed picture
    // (rounded clip + blurred shadow) re-rasterises it every frame (~16ms raster,
    // most frames over budget); drawing the *bare* bitmap under the transform is
    // a GPU texture sample (~5ms, no spikes). So while a touch is manipulating the
    // picture it drops to bare — no clip, no shadow, no ✕ — and the frame returns
    // the instant the fingers leave. The ✕ (only on the framed picture) is the
    // visible tell. It must stay put for a plain tap, so the swap waits for the
    // first move, not the first touch.
    final state = await chatWithFloats();
    await pumpChat(tester, state);
    expect(find.byIcon(Icons.close), findsOneWidget, reason: 'framed at rest');

    final grip =
        tester.getCenter(find.byIcon(Icons.close)) + const Offset(0, 40);
    final gesture = await tester.startGesture(grip);
    for (var i = 0; i < 4; i++) {
      await gesture.moveBy(const Offset(8, 6));
      await tester.pump();
    }
    expect(find.byIcon(Icons.close), findsNothing,
        reason: 'bare (no frame/✕) while being moved');

    await gesture.up();
    await tester.pump();
    await tester.pump();
    expect(find.byIcon(Icons.close), findsOneWidget,
        reason: 'framed again the moment it is placed');
  });

  testWidgets('a finger left over from a pinch does not drag it away',
      (tester) async {
    // The intermittent "glitch away on release": lifting two fingers is never
    // perfectly simultaneous, and the last finger slides as the hand leaves. The
    // scale recogniser would apply that slide as a drag, flinging the picture to
    // a new spot. Once a gesture has had two fingers, a lone remaining finger
    // must no longer move it.
    final state = await chatWithFloats();
    await pumpChat(tester, state);
    final frame = find
        .descendant(
          of: find.byType(FloatingImagesLayer),
          matching: find.byType(RawGestureDetector),
        )
        .first;

    final anchor =
        tester.getCenter(find.byIcon(Icons.close)) + const Offset(-40, 60);
    final a = await tester.startGesture(anchor - const Offset(40, 0));
    final b = await tester.startGesture(anchor + const Offset(40, 0));
    // A small two-finger pinch, so this is unambiguously a two-finger gesture.
    for (var i = 0; i < 4; i++) {
      await a.moveBy(const Offset(-4, -2));
      await b.moveBy(const Offset(4, 2));
      await tester.pump();
    }
    // One finger lifts — the pinch is over.
    await b.up();
    await tester.pump();
    final centreAfterPinch = tester.getRect(frame).center;

    // The remaining finger now slides a long way. It must NOT drag the picture.
    for (var i = 0; i < 10; i++) {
      await a.moveBy(const Offset(16, 11));
      await tester.pump();
    }
    await a.up();
    await tester.pump();
    await tester.pump();

    expect((tester.getRect(frame).center - centreAfterPinch).distance, lessThan(6),
        reason: 'the leftover finger must not carry the picture off');
  });

  testWidgets('a placed float does not slide away when the fingers leave',
      (tester) async {
    // The on-device "shifting thing": a float jumped away from where it was put
    // the instant the fingers lifted. Cause — a pinch scaled the picture about
    // its centre (correct), but the stored anchor was the top-left *corner*, so
    // on release the picture was re-laid-out pinned to that corner and slid by
    // half the size change. Anchoring the centre makes the held position and the
    // settled position the same point.
    final state = await chatWithFloats();
    await pumpChat(tester, state);
    final frame = find
        .descendant(
          of: find.byType(FloatingImagesLayer),
          matching: find.byType(RawGestureDetector),
        )
        .first;

    // Grow it with a symmetric two-finger spread: the focal point does not move,
    // so nothing but the release could shift its centre.
    final anchor =
        tester.getCenter(find.byIcon(Icons.close)) + const Offset(-40, 60);
    final left = await tester.startGesture(anchor - const Offset(40, 0));
    final right = await tester.startGesture(anchor + const Offset(40, 0));
    for (var i = 0; i < 8; i++) {
      await left.moveBy(const Offset(-6, -4));
      await right.moveBy(const Offset(6, 4));
      await tester.pump();
    }
    final centreWhileHeld = tester.getRect(frame).center;
    await left.up();
    await right.up();
    await tester.pump();
    await tester.pump();
    final centreAfterRelease = tester.getRect(frame).center;

    expect(state.active.floatingImages.single.width, greaterThan(180),
        reason: 'it really did resize');
    expect((centreAfterRelease - centreWhileHeld).distance, lessThan(6),
        reason: 'the picture stays where it was placed when the fingers leave');
  });

  testWidgets('one finger drags it, and where it lands is remembered',
      (tester) async {
    final state = await chatWithFloats();
    await pumpChat(tester, state);
    final before = floatOf(state, 'img0');

    final grip = tester.getCenter(find.byIcon(Icons.close)) +
        const Offset(0, 40); // On the picture, clear of the ✕.
    final gesture = await tester.startGesture(grip);
    // Past the drag slop in several steps, the way a finger moves.
    for (var i = 0; i < 5; i++) {
      await gesture.moveBy(const Offset(12, 16));
      await tester.pump();
    }
    await gesture.up();
    await tester.pump();
    await tester.pump();

    final after = floatOf(state, 'img0');
    expect(after.x, greaterThan(before.x));
    expect(after.y, greaterThan(before.y));
    // Fractions of the chat area, not pixels, so the same float lands in the same
    // visual place on a different screen.
    expect(after.x, lessThanOrEqualTo(1));
    expect(after.y, lessThanOrEqualTo(1));
  });

  testWidgets('two fingers resize and turn it', (tester) async {
    final state = await chatWithFloats();
    await pumpChat(tester, state);
    final before = floatOf(state, 'img0');
    expect(before.rotation, 0);

    final centre =
        tester.getCenter(find.byIcon(Icons.close)) + const Offset(-40, 60);
    final left = await tester.startGesture(centre - const Offset(40, 0));
    final right = await tester.startGesture(centre + const Offset(40, 0));
    // Apart and around: bigger and turned in one motion, which is the point of
    // driving all three from one recogniser.
    for (var i = 0; i < 6; i++) {
      await left.moveBy(const Offset(-6, -3));
      await right.moveBy(const Offset(6, 3));
      await tester.pump();
    }
    await left.up();
    await right.up();
    await tester.pump();
    await tester.pump();

    final after = floatOf(state, 'img0');
    expect(after.width, greaterThan(before.width));
    expect(after.rotation, isNot(0));
  });

  testWidgets('a pinch scales on the transform, without relaying out the picture',
      (tester) async {
    // The resize/rotate freeze: changing the picture's *layout* width every pinch
    // frame re-rasterised it and its blurred shadow each time. Now the width is
    // fixed for the gesture and the size rides a transform scale — so the laid-out
    // box does not change mid-pinch (no relayout, no re-raster), only the painted
    // rect grows. The real width is committed once, on release.
    final state = await chatWithFloats();
    await pumpChat(tester, state);
    final box = find
        .descendant(
          of: find.byType(FloatingImagesLayer),
          matching: find.byType(RawGestureDetector),
        )
        .first;

    final layoutBefore = tester.getSize(box);
    final paintedBefore = tester.getRect(box);

    final centre =
        tester.getCenter(find.byIcon(Icons.close)) + const Offset(-40, 60);
    final left = await tester.startGesture(centre - const Offset(40, 0));
    final right = await tester.startGesture(centre + const Offset(40, 0));
    for (var i = 0; i < 8; i++) {
      await left.moveBy(const Offset(-6, -3));
      await right.moveBy(const Offset(6, 3));
      await tester.pump();
    }

    // Mid-pinch: the box is the same size it was laid out at (nothing relaid
    // out), but it is painted larger (the transform scaled it).
    expect(tester.getSize(box), layoutBefore,
        reason: 'the picture is not re-laid-out during a pinch');
    expect(tester.getRect(box).width, greaterThan(paintedBefore.width + 1),
        reason: 'it grows on the transform instead');

    await left.up();
    await right.up();
    await tester.pump();
    await tester.pump();

    // On release the scale is baked into a real width.
    expect(state.active.floatingImages.single.width, greaterThan(180));
  });

  testWidgets('resizing stops at the bounds rather than vanishing',
      (tester) async {
    final state = await chatWithFloats();
    await pumpChat(tester, state);

    final centre =
        tester.getCenter(find.byIcon(Icons.close)) + const Offset(-40, 60);
    final left = await tester.startGesture(centre - const Offset(120, 0));
    final right = await tester.startGesture(centre + const Offset(120, 0));
    // Squeezed hard: a float must stay big enough to grab and dismiss.
    for (var i = 0; i < 10; i++) {
      await left.moveBy(const Offset(11, 0));
      await right.moveBy(const Offset(-11, 0));
      await tester.pump();
    }
    await left.up();
    await right.up();
    await tester.pump();
    await tester.pump();

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

  testWidgets('several floats coexist, and touching one raises it',
      (tester) async {
    final state = await chatWithFloats(count: 3);
    // Spread them apart so a touch lands on one unambiguously. Fanned-out
    // defaults overlap by design, and a computed point in the pile hits whichever
    // float happens to be on top there — which is what a geometry-guessing
    // version of this test kept doing.
    final chat = state.active.id;
    for (var i = 0; i < 3; i++) {
      await state.settleFloatingImage(
        chat,
        state.active.floatingImages.firstWhere((f) => f.imageId == 'img$i'),
        x: 0.05,
        y: 0.04 + i * 0.28,
        width: 90,
      );
    }
    await pumpChat(tester, state);
    expect(state.active.floatingImages, hasLength(3));
    expect(find.byIcon(Icons.close), findsNWidgets(3));

    // The first-floated is at the back; dragging it should bring it to the front.
    expect(state.active.floatingImages.first.imageId, 'img0');
    final grip =
        tester.getCenter(find.byIcon(Icons.close).first) + const Offset(-20, 40);
    final gesture = await tester.startGesture(grip);
    // Well past kPanSlop (36 logical pixels) in total, or the scale recogniser
    // never claims the pointer and neither onStart nor onEnd fires — the float
    // would not be raised because it was never really dragged.
    for (var i = 0; i < 8; i++) {
      await gesture.moveBy(const Offset(6, 5));
      await tester.pump();
    }
    await gesture.up();
    await tester.pump();
    await tester.pump();

    expect(state.active.floatingImages.last.imageId, 'img0');
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

  group('the gesture must not write to state', () {
    // This is the bug that made floats unusable on a real phone in v1.14.0: both
    // the raise-to-front at gesture start and the position at every pointer-move
    // went through `_editConversation`, which notifies every listener and
    // re-encodes the whole conversation store. On a device that stalls the frames
    // the drag needs, so the picture cannot be moved at all. A widget test cannot
    // feel jank — so it counts the writes instead.

    testWidgets('a one-finger drag persists where it lands, not per move',
        (tester) async {
      final state = await chatWithFloats();
      await pumpChat(tester, state);
      final startX = floatOf(state, 'img0').x;

      final grip = tester.getCenter(find.byIcon(Icons.close)) +
          const Offset(0, 40);
      final gesture = await tester.startGesture(grip);
      for (var i = 0; i < 12; i++) {
        await gesture.moveBy(const Offset(6, 5));
        await tester.pump();
      }
      // Twelve pointer-moves in, the stored float has not moved: the live
      // transform is local to the layer, so a pointer-move never writes to the
      // chat store.
      expect(floatOf(state, 'img0').x, startX,
          reason: 'a pointer-move must not rewrite the stored float');

      await gesture.up();
      await tester.pump();
      await tester.pump();

      // On release the landing position is persisted (once). Note it does NOT
      // notify listeners — settling a float must not rebuild the whole chat (the
      // ~18ms UI-thread build a device profile pinned as the jank).
      expect(floatOf(state, 'img0').x, greaterThan(startX),
          reason: 'the landing position is saved on release');
    });

    testWidgets('a pinch persists only when the whole touch ends',
        (tester) async {
      // The float lag a device profile pinned to the UI thread: settling rebuilt
      // the whole ChatScreen (every message bubble). Now a settle persists the
      // geometry WITHOUT notifying — and only once, when the last finger leaves.
      final state = await chatWithFloats();
      await pumpChat(tester, state);
      final startWidth = floatOf(state, 'img0').width;

      final centre =
          tester.getCenter(find.byIcon(Icons.close)) + const Offset(-40, 60);
      final left = await tester.startGesture(centre - const Offset(40, 0));
      final right = await tester.startGesture(centre + const Offset(40, 0));

      for (var i = 0; i < 20; i++) {
        await left.moveBy(const Offset(-4, -2));
        await right.moveBy(const Offset(4, 2));
        await tester.pump();
      }
      // One finger lifts mid-manipulation — still nothing persisted.
      await left.up();
      await tester.pump();
      expect(floatOf(state, 'img0').width, startWidth,
          reason: 'a finger lift mid-manipulation must not persist');

      // The last finger leaves: persisted once, now.
      await right.up();
      await tester.pump();
      await tester.pump();

      expect(floatOf(state, 'img0').width, greaterThan(startWidth),
          reason: 'the whole touch persists once, at the end');
    });

    testWidgets('the message list does not rebuild while a float is dragged',
        (tester) async {
      // The other half of the cost: every AppState notification rebuilt the whole
      // thread, because ChatScreen watches it. If a drag notifies nothing, the
      // bubbles are not touched either.
      final state = await chatWithFloats();
      await pumpChat(tester, state);

      final bubbleBefore = tester.element(find.text('Hello.'));
      final grip = tester.getCenter(find.byIcon(Icons.close)) +
          const Offset(0, 40);
      final gesture = await tester.startGesture(grip);
      for (var i = 0; i < 8; i++) {
        await gesture.moveBy(const Offset(5, 5));
        await tester.pump();
      }
      // The same element, never rebuilt out from under the drag.
      expect(tester.element(find.text('Hello.')), same(bubbleBefore));
      await gesture.up();
      await tester.pump();
      await tester.pump();
    });

    testWidgets('a streaming reply does not rebuild the floats', (tester) async {
      // The inverse: the layer subscribes narrowly, so a reply arriving does not
      // rebuild pictures that have not changed.
      final state = await chatWithFloats();
      await pumpChat(tester, state);
      final frameBefore = tester.element(find.byIcon(Icons.close));

      // Something that notifies AppState without touching the floats.
      await state.saveGalleryImage(
        state.galleryImageById('img0')!.copyWith(title: 'Renamed'),
      );
      await tester.pump();
      await tester.pump();

      expect(tester.element(find.byIcon(Icons.close)), same(frameBefore));
    });

    testWidgets('raising a float mid-drag keeps the gesture alive',
        (tester) async {
      // The freeze in 1.14.0 and 1.14.1. Touching a float raises it, which
      // reorders the layer's children — and the `ValueKey` used to sit on the
      // picture *inside* each `Positioned`. Reconciliation matches children by key
      // at the level of the list being rebuilt, so unkeyed `Positioned`s matched
      // slot-for-slot, found a different key beneath each one, and rebuilt all
      // three from scratch. That destroyed the `State` — and its gesture
      // recogniser — of the float being dragged, on the first pointer-move.
      //
      // The symptom was a float that could not be moved at all. The measurable
      // fact is that the drag stops being delivered, so this asserts the picture
      // keeps moving *after* the raise.
      final state = await chatWithFloats(count: 3);
      final chat = state.active.id;
      // Spread them so a touch lands on one unambiguously.
      for (var i = 0; i < 3; i++) {
        await state.settleFloatingImage(
          chat,
          state.active.floatingImages.firstWhere((f) => f.imageId == 'img$i'),
          x: 0.05,
          y: 0.04 + i * 0.28,
          width: 90,
        );
      }
      await pumpChat(tester, state);

      // The one at the back, so touching it genuinely reorders the children.
      expect(state.active.floatingImages.first.imageId, 'img0');
      final grip = tester.getCenter(find.byIcon(Icons.close).first) +
          const Offset(-20, 40);
      final gesture = await tester.startGesture(grip);

      // Past the slop, which is when the raise happens.
      for (var i = 0; i < 8; i++) {
        await gesture.moveBy(const Offset(6, 5));
        await tester.pump();
      }
      // Then keep going a long way. If the state object was replaced by the
      // raise, these updates reach a dead recogniser and the float stops here.
      for (var i = 0; i < 20; i++) {
        await gesture.moveBy(const Offset(8, 6));
        await tester.pump();
      }
      await gesture.up();
      await tester.pump();
      await tester.pump();

      final moved = state.active.floatingImages
          .firstWhere((f) => f.imageId == 'img0');
      // 28 moves of ~7px across a 400px chat is well past a third of the way, so
      // this cannot pass on the first eight moves alone.
      expect(moved.x, greaterThan(0.35),
          reason: 'the drag must survive the raise');
      expect(state.active.floatingImages.last.imageId, 'img0',
          reason: 'and it is on top afterwards');
    });

    testWidgets('each float has its own picture boundary, no layer-wide one',
        (tester) async {
      // Every float's picture sits behind its own RepaintBoundary so it
      // rasterises once and the compositor moves that small texture. There is no
      // single boundary over the whole layer — that screen-sized texture,
      // re-rasterised per frame, was the old raster-thread stutter. The default
      // mode adds no extra per-float boundary (it measured slower on device), so
      // it is exactly one boundary per float.
      final state = await chatWithFloats(count: 2);
      await pumpChat(tester, state);

      final boundaries = find.descendant(
        of: find.byType(FloatingImagesLayer),
        matching: find.byType(RepaintBoundary),
      );
      expect(boundaries, findsNWidgets(2),
          reason: 'one picture boundary per float, and no layer-wide one');
    });

    testWidgets('dragging a float does not re-rasterise the chat behind it',
        (tester) async {
      // The stutter was on the raster thread. The chat's real content sits behind
      // its own repaint boundaries (the message list's viewport, the background
      // picture), so what must be true is that moving a float does not force those
      // *retained layers* to re-rasterise. A `CustomPaint` wrapped in its own
      // `RepaintBoundary` stands in for that content, and its painter counts
      // repaints: it must not climb while a float is dragged. (The chat's cheap
      // display list *does* re-record on the UI thread — that is the deliberate
      // trade for not keeping a full-screen float layer on the GPU.)
      final state = await chatWithFloats();
      await tester.binding.setSurfaceSize(const Size(400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      var paints = 0;
      await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                // Retained, like the real message list / background.
                RepaintBoundary(
                  child: CustomPaint(
                    painter: _CountingPainter(() => paints++),
                    child: const SizedBox.expand(),
                  ),
                ),
                Positioned.fill(
                  child: FloatingImagesLayer(conversationId: state.active.id),
                ),
              ],
            ),
          ),
        ),
      ));
      await tester.pump();
      await tester.pump();

      final baseline = paints;
      final grip =
          tester.getCenter(find.byIcon(Icons.close)) + const Offset(-20, 40);
      final gesture = await tester.startGesture(grip);
      for (var i = 0; i < 20; i++) {
        await gesture.moveBy(const Offset(8, 6));
        await tester.pump(const Duration(milliseconds: 16));
      }
      final duringDrag = paints;
      await gesture.up();
      await tester.pump();

      expect(state.active.floatingImages.single.x, greaterThan(0.08),
          reason: 'the picture did move');
      expect(duringDrag, baseline,
          reason: 'retained chat content is never re-rasterised by a float drag');
    });
  });

  testWidgets('the chat has no backdrop filter to re-blur every frame',
      (tester) async {
    // The last thing making floats stutter was not the floats at all: the
    // always-present frosted menu button ran a `BackdropFilter` blur, and a
    // backdrop blur re-runs — with a GPU framebuffer readback that stalls mobile
    // pipelines — on every composited frame. So any drag, pinch or scroll that
    // produced frames janked for as long as it lasted. There must be no backdrop
    // filter in the chat.
    final state = await chatWithFloats();
    await pumpChat(tester, state);
    expect(find.byType(BackdropFilter), findsNothing);
  });

  /// The picture's own box: what it was laid out at, and where it is painted.
  Finder pictureBox() => find
      .descendant(
        of: find.byType(FloatingImagesLayer),
        matching: find.byType(RawGestureDetector),
      )
      .first;

  group('a drag follows the finger, whatever the picture is turned to', () {
    // The reported "it doesn't even move diagonally", and the displacement left
    // behind after turning a picture and moving it.
    //
    // The recogniser has to live *inside* the live transform, or fingers cannot
    // hit the picture where it is drawn. But `ScaleUpdateDetails.focalPointDelta`
    // is the one figure in those details measured in the **receiver's local
    // space** — so a turned float received its drag along its *own* axes: push
    // right on a picture turned 90° and it went up the screen. Worse, the
    // recogniser converts through the transform of whichever pointer delivered
    // the last event, and each pointer's transform is frozen at its own
    // touch-down — so a second finger added after the picture had moved made
    // consecutive updates convert one focal point through two different
    // matrices, inventing a large constant delta from a still hand (the
    // ~104px-per-frame rows in the 1.16.0 trace).
    //
    // Every rotation × axis is here because the previous three attempts at this
    // each fixed one configuration and shipped the others broken.
    for (final degrees in <double>[0, 45, 90, 135, 180, -60]) {
      for (final sideways in <bool>[true, false]) {
        testWidgets('turned $degrees°, dragged ${sideways ? 'across' : 'down'}',
            (tester) async {
          final state = await chatWithFloats();
          await state.settleFloatingImage(
            state.active.id,
            state.active.floatingImages.single,
            x: 0.5,
            y: 0.5,
            rotation: degrees * 3.1415926535 / 180,
          );
          await pumpChat(tester, state);
          final before = floatOf(state, 'img0');

          // The centre of the picture: on it at every rotation, and clear of the
          // ✕ in its corner.
          final gesture = await tester.startGesture(
            tester.getRect(pictureBox()).center,
          );
          final step = sideways ? const Offset(12, 0) : const Offset(0, 12);
          for (var i = 0; i < 8; i++) {
            await gesture.moveBy(step);
            await tester.pump();
          }
          await gesture.up();
          await tester.pump();
          await tester.pump();

          final after = floatOf(state, 'img0');
          // A fraction of a 400x900 chat. ~48px of the 96px dragged survives the
          // pan slop, so ~0.12 across and ~0.053 down; the point of the test is
          // the axis, not the distance.
          if (sideways) {
            expect(after.x, greaterThan(before.x + 0.05),
                reason: 'a sideways drag moves it sideways');
            expect(after.y, closeTo(before.y, 0.01),
                reason: 'and not up or down the screen');
          } else {
            expect(after.y, greaterThan(before.y + 0.02),
                reason: 'a drag down the screen moves it down');
            expect(after.x, closeTo(before.x, 0.01),
                reason: 'and not sideways');
          }
        });
      }
    }
  });

  testWidgets('a float wider than the chat is laid out at its real width',
      (tester) async {
    // "It stops getting bigger at a certain size." The float was positioned with
    // an `Align`, which only *loosens* the layer's constraints — it keeps their
    // maxima — and a `SizedBox` enforces its width against what it is handed. So
    // a float wider than the chat was silently laid out at the chat's width, and
    // no amount of pinching could make it any bigger.
    final state = await chatWithFloats();
    await state.settleFloatingImage(
      state.active.id,
      state.active.floatingImages.single,
      width: 900, // The chat is 400 wide.
    );
    await pumpChat(tester, state);

    expect(tester.getSize(pictureBox()).width, closeTo(900, 1),
        reason: 'the laid-out width is the width, not the chat\'s');
  });

  testWidgets('placing an oversized float does not change its size',
      (tester) async {
    // The other half of the same bug, and the one that was visible: the live
    // size rides a transform scale of `width / _baseWidth`. Once the layout was
    // clamped to the chat width but `_baseWidth` was not, the drawn size stopped
    // matching the geometry — so every release re-baked a width the layout would
    // not honour and the picture snapped to a different size. Here a big float is
    // pinched smaller; what it is drawn at while held must be what it is drawn at
    // once let go.
    final state = await chatWithFloats();
    await state.settleFloatingImage(
      state.active.id,
      state.active.floatingImages.single,
      x: 0.5,
      y: 0.5,
      width: 900,
    );
    await pumpChat(tester, state);

    final centre = tester.getRect(pictureBox()).center;
    final left = await tester.startGesture(centre - const Offset(90, 0));
    final right = await tester.startGesture(centre + const Offset(90, 0));
    // Squeezed to roughly two thirds.
    for (var i = 0; i < 6; i++) {
      await left.moveBy(const Offset(5, 0));
      await right.moveBy(const Offset(-5, 0));
      await tester.pump();
    }
    final heldWidth = tester.getRect(pictureBox()).width;
    await left.up();
    await right.up();
    await tester.pump();
    await tester.pump();

    expect(state.active.floatingImages.single.width, lessThan(900),
        reason: 'it really did shrink');
    expect(tester.getRect(pictureBox()).width, closeTo(heldWidth, 8),
        reason: 'the size it was let go at is the size it keeps');
  });

  testWidgets('pinching past the size cap leaves the cap again immediately',
      (tester) async {
    // "It restricts to a specific size and after that it displaces to a
    // different size each time." Clamping the *output* while measuring the pinch
    // from a fixed reference banks up a dead zone: spread to three times the cap
    // and the fingers have to travel all the way back before the size responds at
    // all, so the picture settles at a size with no relation to where the fingers
    // are. Re-anchoring the reference at the bound keeps it pinned there and lets
    // it leave the moment the fingers reverse.
    final state = await chatWithFloats();
    await state.settleFloatingImage(
      state.active.id,
      state.active.floatingImages.single,
      x: 0.5,
      y: 0.5,
      width: 1200, // Near the 1600 ceiling.
    );
    await pumpChat(tester, state);

    final centre = tester.getRect(pictureBox()).center;
    final left = await tester.startGesture(centre - const Offset(60, 0));
    final right = await tester.startGesture(centre + const Offset(60, 0));
    // Well past the ceiling: span 120 -> 300, so 2.5x on a picture already at
    // three quarters of the cap.
    for (var i = 0; i < 9; i++) {
      await left.moveBy(const Offset(-10, 0));
      await right.moveBy(const Offset(10, 0));
      await tester.pump();
    }
    expect(state.active.floatingImages.single.width, 1200,
        reason: 'nothing is persisted mid-pinch');

    // Now bring them back in — nowhere near the span they started at, but a
    // clear reversal. The picture must shrink.
    for (var i = 0; i < 5; i++) {
      await left.moveBy(const Offset(9, 0));
      await right.moveBy(const Offset(-9, 0));
      await tester.pump();
    }
    await left.up();
    await right.up();
    await tester.pump();
    await tester.pump();

    expect(state.active.floatingImages.single.width,
        lessThan(kFloatingImageMaxWidth),
        reason: 'reversing the pinch leaves the cap at once, with no dead zone');
  });

  testWidgets('a float has one decode size, warmed before it is drawn',
      (tester) async {
    // The blink on first float. An `Image` whose provider is not in the image
    // cache paints *nothing* until the decode lands, and the framed and bare
    // pictures live in different subtrees, so `gaplessPlayback` cannot carry a
    // frame across the swap on touch-down: a cold bucket is a picture that
    // vanishes for a frame or two. It is warmed as soon as the float is mounted.
    //
    // There is deliberately only **one** size to warm. The layer used to drop to
    // a ~512 device-px working texture for the duration of a touch, which is half
    // the bucket a normal float sits in — that is the pixelation reported from a
    // phone, and it also made the swap a second thing that could be cold.
    //
    // (The blink itself is an on-device observation; what is checkable here is
    // that the bitmap is asked for before anything draws it.)
    imageCache.clear();
    imageCache.clearLiveImages();
    clearAvatarImageCache();
    final state = AppState()..debounceFloatSaves = false;
    await state.init();
    final character = Character(id: 'aria', name: 'Aria', firstMes: 'Hello.');
    await state.addCharacter(character);
    state.startChatWithCharacter(character);
    // A real, decodable picture — 1x1 base64, floated by reference.
    await state.floatPictureRef(state.active.id, _png);
    await pumpChat(tester, state);
    await tester.pump();

    final atRest = avatarImage(
      _png,
      displaySize: kFloatingImageDefaultWidth,
      devicePixelRatio: tester.view.devicePixelRatio,
    );
    expect(atRest, isNotNull);
    final key = await atRest!.obtainKey(ImageConfiguration.empty);
    expect(imageCache.containsKey(key), isTrue,
        reason: 'the bitmap is decoded before it is drawn');

    // And it is the bitmap the framed picture actually draws.
    expect(
      tester
          .widget<Image>(find.descendant(
            of: find.byType(FloatingImagesLayer),
            matching: find.byType(Image),
          ))
          .image,
      same(atRest),
    );
  });

  testWidgets('a touched float keeps its full-resolution bitmap, sampled '
      'smoothly', (tester) async {
    // The reported pixelation: a float was crisp at rest and went blocky for as
    // long as a finger was on it. Two causes, both here. It swapped to a ~512
    // device-px working texture — half the bucket it sits in at rest — and it
    // sampled that texture nearest-neighbour, which shows every missing pixel.
    // Neither was buying anything measurable: [avatarImage] already caps the
    // decode at the display bucket rather than source resolution, bilinear
    // filtering is what a GPU's texture unit does in hardware, and the 16ms-a-
    // frame cost the bare picture was written to avoid was re-rasterising the
    // blurred shadow under a changing scale — which it still drops.
    imageCache.clear();
    clearAvatarImageCache();
    final state = AppState()..debounceFloatSaves = false;
    await state.init();
    final character = Character(id: 'aria', name: 'Aria', firstMes: 'Hello.');
    await state.addCharacter(character);
    state.startChatWithCharacter(character);
    await state.floatPictureRef(state.active.id, _png);
    await pumpChat(tester, state);
    // A widget test's codec never produces an image, so let the decode run to its
    // failure in the real zone: the `Image` then falls back to its error box,
    // which has area to put a finger on. What is under test is which provider the
    // widget is handed and how it is sampled, not the bitmap.
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pump();

    final picture = find.descendant(
      of: find.byType(FloatingImagesLayer),
      matching: find.byType(Image),
    );
    final framed = tester.widget<Image>(picture).image;

    final gesture = await tester.startGesture(
        tester.getCenter(find.byIcon(Icons.close)) + const Offset(0, 40));
    for (var i = 0; i < 4; i++) {
      await gesture.moveBy(const Offset(8, 6));
      await tester.pump();
    }
    expect(find.byIcon(Icons.close), findsNothing, reason: 'now bare');

    final bare = tester.widget<Image>(picture);
    expect(bare.image, same(framed),
        reason: 'a touched float keeps the bitmap it was already drawing');
    expect(bare.filterQuality, FilterQuality.low,
        reason: 'bilinear, not the nearest-neighbour that made it blocky');

    await gesture.up();
    await tester.pump();
    await tester.pump();
  });

  testWidgets('Send to chat decodes the picture before the viewer closes',
      (tester) async {
    // The other way a picture is floated, and the one the blink was reported
    // from: the viewer is showing this picture full size, and taps Send. It pops
    // straight back to the chat — so unless the float's own (smaller, separately
    // keyed) bitmap is decoded first, the picture goes off screen with the route
    // and the float has to fetch it while the chat is already visible.
    imageCache.clear();
    imageCache.clearLiveImages();
    clearAvatarImageCache();
    final state = AppState()..debounceFloatSaves = false;
    await state.init();
    final character = Character(id: 'aria', name: 'Aria', firstMes: 'Hello.');
    await state.addCharacter(character);
    state.startChatWithCharacter(character);
    await state.saveGalleryImage(GalleryImage(
      id: 'img0',
      image: _png,
      title: 'Picture',
      createdAt: DateTime(2026, 4, 24),
    ));
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(state.flushPendingSaves);

    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => openImageViewer(
              context,
              images: state.gallery,
              index: 0,
              extra: ViewerExtra.sendToChat,
              conversationId: state.active.id,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final provider = avatarImage(
      _png,
      displaySize: kFloatingImageDefaultWidth,
      devicePixelRatio: tester.view.devicePixelRatio,
    );
    final key = await provider!.obtainKey(ImageConfiguration.empty);
    bool? readyOnArrival;
    state.addListener(() {
      if (readyOnArrival == null && state.active.floatingImages.isNotEmpty) {
        readyOnArrival = imageCache.containsKey(key);
      }
    });

    // Real async, because a real decode is what is being waited for.
    await tester.runAsync(() async {
      await tester.tap(find.text('Send'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();

    expect(state.active.floatingImages.single.imageId, 'img0');
    expect(readyOnArrival, isTrue,
        reason: 'the float-sized bitmap is decoded before the route pops');
  });
}

/// 1x1 PNGs, for the tests that need a picture that really decodes.
const _png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
    'z8DAwAAABQABg1z0GwAAAABJRU5ErkJggg==';

/// Counts how many times it is painted — a stand-in for "the chat behind the
/// float", used to prove a drag does not repaint it.
class _CountingPainter extends CustomPainter {
  _CountingPainter(this.onPaint);

  final void Function() onPaint;

  @override
  void paint(Canvas canvas, Size size) => onPaint();

  // Never repaints because the *widget* changed — so any repaint the test counts
  // came from the enclosing boundary being re-recorded, which is exactly what a
  // confined drag must avoid.
  @override
  bool shouldRepaint(covariant _CountingPainter oldDelegate) => false;
}
