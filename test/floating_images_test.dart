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

  testWidgets('a float is captured to a texture for the length of a touch',
      (tester) async {
    // The measured fix for the stutter/freeze: transforming a live picture
    // re-rasterises it every frame, so instead the frame is captured to one GPU
    // texture and only that is moved/scaled/turned. The capture must be on for
    // the WHOLE touch (from first finger down to last finger up) — toggling it
    // per gesture segment would re-capture repeatedly, which is why the first
    // attempt still stuttered. Off at rest, so the picture stays crisp.
    final state = await chatWithFloats();
    await pumpChat(tester, state);
    final snap = tester.widget<SnapshotWidget>(
      find
          .descendant(
            of: find.byType(FloatingImagesLayer),
            matching: find.byType(SnapshotWidget),
          )
          .first,
    );
    expect(snap.controller.allowSnapshotting, isFalse,
        reason: 'crisp at rest');

    final grip =
        tester.getCenter(find.byIcon(Icons.close)) + const Offset(0, 40);
    final gesture = await tester.startGesture(grip);
    for (var i = 0; i < 4; i++) {
      await gesture.moveBy(const Offset(8, 6));
      await tester.pump();
    }
    expect(snap.controller.allowSnapshotting, isTrue,
        reason: 'a single texture while the finger is down');

    await gesture.up();
    await tester.pump();
    await tester.pump();
    expect(snap.controller.allowSnapshotting, isFalse,
        reason: 'back to live, crisp again once the finger leaves');
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

    testWidgets('a one-finger drag notifies exactly once, at the end',
        (tester) async {
      final state = await chatWithFloats();
      await pumpChat(tester, state);

      var notifications = 0;
      state.addListener(() => notifications++);

      final grip = tester.getCenter(find.byIcon(Icons.close)) +
          const Offset(0, 40);
      final gesture = await tester.startGesture(grip);
      for (var i = 0; i < 12; i++) {
        await gesture.moveBy(const Offset(6, 5));
        await tester.pump();
      }
      // Twelve pointer-moves in, nothing has been written: the live transform is
      // local to the layer.
      expect(notifications, 0,
          reason: 'a pointer-move must not rewrite the chat store');

      await gesture.up();
      await tester.pump();
      await tester.pump();

      expect(notifications, 1, reason: 'exactly one write, when it settles');
      expect(state.active.floatingImages.single.x, greaterThan(0.08));
    });

    testWidgets('a pinch notifies per finger change, never per move',
        (tester) async {
      // A two-finger manipulation cannot cost exactly one write: adding or
      // lifting a finger makes the recogniser end this gesture and start another
      // for the pointers still down, and each of those ends settles. What matters
      // is that it is a couple of writes for the whole pinch rather than one for
      // every pointer-move, which is what stalled the frames on a device.
      final state = await chatWithFloats();
      await pumpChat(tester, state);

      var notifications = 0;
      state.addListener(() => notifications++);

      final centre =
          tester.getCenter(find.byIcon(Icons.close)) + const Offset(-40, 60);
      final left = await tester.startGesture(centre - const Offset(40, 0));
      // The second finger arriving reconfigures the gesture: one settle.
      final right = await tester.startGesture(centre + const Offset(40, 0));
      final afterSecondFinger = notifications;
      expect(afterSecondFinger, lessThanOrEqualTo(1));

      for (var i = 0; i < 20; i++) {
        await left.moveBy(const Offset(-4, -2));
        await right.moveBy(const Offset(4, 2));
        await tester.pump();
      }
      expect(notifications, afterSecondFinger,
          reason: 'twenty pointer-moves must not write anything');

      await left.up();
      await right.up();
      await tester.pump();
      await tester.pump();

      // Bounded by finger changes (three), not by the twenty moves.
      expect(notifications, lessThanOrEqualTo(3));
      expect(state.active.floatingImages.single.width, greaterThan(180));
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
}

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
