import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/gallery_image.dart';
import 'package:maichat/screens/gallery/image_viewer_screen.dart';
import 'package:maichat/state/app_state.dart';
import 'package:maichat/widgets/photo_surface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The full-screen photo viewer's gestures: pinch to zoom, drag to pan, swipe to
/// page, flick to put the picture away.
///
/// Every case here is written the way a hand actually does it, because the shapes
/// a hand makes are exactly what the old `InteractiveViewer`-inside-a-`PageView`
/// got wrong. A symmetric, perfectly horizontal pinch zoomed fine and passed a
/// naive test; a **staggered**, **drifting** or **thumb-anchored** pinch left the
/// scale at exactly 1.0, because the pager's horizontal drag claimed the pointer
/// after [kTouchSlop] while the scale recogniser was still waiting for its own
/// slop. That is the "extremely hard to zoom in at all" this file pins down — so
/// keep the asymmetry in these gestures.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  GalleryImage picture(String id) => GalleryImage(
        id: id,
        image: 'local:$id.png',
        createdAt: DateTime(2026, 4, 24, 12),
      );

  final images = [picture('a'), picture('b'), picture('c')];

  /// Opens the viewer through its real route, from a screen underneath — the
  /// see-through route and the flick-dismiss both only mean anything with
  /// something to go back to.
  ///
  /// No `AvatarStore` is installed, so `avatarImage` resolves nothing and each
  /// page draws its placeholder glyph. The gestures are what is under test, not
  /// the bitmaps, and the test binding's fake clock cannot run the decoder.
  ///
  /// Returns a box that ends up holding whatever the viewer popped with, so a
  /// test can check the caller is told which picture the user ended on.
  Future<List<String?>> open(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final state = AppState();
    await state.init();
    for (final image in images.reversed) {
      await state.saveGalleryImage(image);
    }
    final closedOn = <String?>[];

    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  final id =
                      await openImageViewer(context, images: images, index: 0);
                  closedOn.add(id);
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
    expect(find.byType(ImageViewerScreen), findsOneWidget);
    return closedOn;
  }

  /// How far the picture on screen is zoomed, read off the transform the surface
  /// actually paints with.
  ///
  /// `storage[0]` rather than `getMaxScaleOnAxis()`: the latter takes the largest
  /// scale on *any* axis and so reads 1.0 for a picture squeezed below fitted (the
  /// z axis stays 1), which is exactly the state a "stuck small" bug leaves behind
  /// — it must be visible here.
  double scaleOf(WidgetTester tester) {
    final transform = tester.widget<Transform>(find
        .descendant(
          of: find.byType(PhotoSurface).first,
          matching: find.byType(Transform),
        )
        .first);
    return transform.transform.storage[0];
  }

  double pageOf(WidgetTester tester) =>
      tester.widget<PageView>(find.byType(PageView)).controller!.page ?? -1;

  bool stillOpen(WidgetTester tester) =>
      find.byType(ImageViewerScreen).evaluate().isNotEmpty;

  Offset centreOf(WidgetTester tester) =>
      tester.getCenter(find.byType(PhotoSurface).first);

  /// A sideways swipe of [distance] pixels delivered over [frames] frames of 16ms.
  ///
  /// Timestamps are passed explicitly, and that is not incidental: `moveBy`
  /// defaults to `Duration.zero`, so without them every event shares one instant,
  /// any velocity tracker reads exactly zero, and a test of a *flick* silently
  /// becomes a test of a motionless drag. Velocity comes out of the timing here the
  /// way it does from a hand.
  Future<void> swipeSideways(
    WidgetTester tester, {
    required double distance,
    required int frames,
  }) async {
    var at = Duration.zero;
    final gesture = await tester.startGesture(centreOf(tester));
    for (var i = 0; i < frames; i++) {
      at += const Duration(milliseconds: 16);
      await gesture.moveBy(Offset(distance / frames, 0), timeStamp: at);
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up(timeStamp: at);
    await tester.pumpAndSettle();
  }

  group('pinch to zoom — the shapes a hand makes', () {
    testWidgets('both fingers spread evenly', (tester) async {
      await open(tester);
      final centre = centreOf(tester);
      final left = await tester.startGesture(centre - const Offset(60, 0));
      final right = await tester.startGesture(centre + const Offset(60, 0));
      await tester.pump(const Duration(milliseconds: 16));
      for (var i = 0; i < 12; i++) {
        await left.moveBy(const Offset(-8, 0));
        await right.moveBy(const Offset(8, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(scaleOf(tester), greaterThan(2));
      await left.up();
      await right.up();
      await tester.pumpAndSettle();
      // Stays where it was put: a zoom that springs back is not a zoom.
      expect(scaleOf(tester), greaterThan(2));
      expect(stillOpen(tester), isTrue);
    });

    testWidgets('the second finger lands late, after the first has drifted',
        (tester) async {
      await open(tester);
      final centre = centreOf(tester);
      final first = await tester.startGesture(centre - const Offset(40, 20));
      await tester.pump(const Duration(milliseconds: 30));
      // The roll of the first finger before the second arrives — enough to have
      // handed the pointer to the pager under the old code.
      await first.moveBy(const Offset(-8, -3));
      await tester.pump(const Duration(milliseconds: 30));
      final second = await tester.startGesture(centre + const Offset(40, 20));
      await tester.pump(const Duration(milliseconds: 16));
      for (var i = 0; i < 12; i++) {
        await first.moveBy(const Offset(-9, -5));
        await second.moveBy(const Offset(9, 5));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(scaleOf(tester), greaterThan(2));
      await first.up();
      await second.up();
      await tester.pumpAndSettle();
      expect(scaleOf(tester), greaterThan(2));
    });

    testWidgets('the whole pinch slides sideways as it spreads', (tester) async {
      await open(tester);
      final centre = centreOf(tester);
      final left = await tester.startGesture(centre - const Offset(50, 0));
      final right = await tester.startGesture(centre + const Offset(50, 0));
      await tester.pump(const Duration(milliseconds: 16));
      for (var i = 0; i < 12; i++) {
        // Net movement is rightwards: the focal point travels far enough
        // sideways that a pager's horizontal drag would have taken it.
        await left.moveBy(const Offset(-4, 0));
        await right.moveBy(const Offset(14, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(scaleOf(tester), greaterThan(2));
      // And it did not page while it was doing it.
      expect(pageOf(tester), 0);
      await left.up();
      await right.up();
      await tester.pumpAndSettle();
      expect(pageOf(tester), 0);
    });

    testWidgets('one finger anchors, the other opens away from it',
        (tester) async {
      await open(tester);
      final centre = centreOf(tester);
      final thumb = await tester.startGesture(centre - const Offset(30, 30));
      final finger = await tester.startGesture(centre + const Offset(30, 30));
      await tester.pump(const Duration(milliseconds: 16));
      for (var i = 0; i < 12; i++) {
        await finger.moveBy(const Offset(10, 10));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(scaleOf(tester), greaterThan(2));
      await thumb.up();
      await finger.up();
      await tester.pumpAndSettle();
      expect(scaleOf(tester), greaterThan(2));
    });

    testWidgets('a second pinch zooms further still', (tester) async {
      await open(tester);
      final centre = centreOf(tester);
      final left = await tester.startGesture(centre - const Offset(50, 0));
      final right = await tester.startGesture(centre + const Offset(50, 0));
      await tester.pump(const Duration(milliseconds: 16));
      for (var i = 0; i < 6; i++) {
        await left.moveBy(const Offset(-6, 0));
        await right.moveBy(const Offset(6, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await left.up();
      await right.up();
      await tester.pumpAndSettle();
      final first = scaleOf(tester);
      expect(first, greaterThan(1.2));

      final left2 = await tester.startGesture(centre - const Offset(50, 0));
      final right2 = await tester.startGesture(centre + const Offset(50, 0));
      await tester.pump(const Duration(milliseconds: 16));
      for (var i = 0; i < 6; i++) {
        await left2.moveBy(const Offset(-6, 0));
        await right2.moveBy(const Offset(6, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await left2.up();
      await right2.up();
      await tester.pumpAndSettle();
      // Picks up where the last one left off rather than restarting from fitted.
      expect(scaleOf(tester), greaterThan(first));
    });

    testWidgets('squeezing back in returns to fitted, and no further',
        (tester) async {
      await open(tester);
      final centre = centreOf(tester);
      // Zoom in first.
      var left = await tester.startGesture(centre - const Offset(40, 0));
      var right = await tester.startGesture(centre + const Offset(40, 0));
      await tester.pump(const Duration(milliseconds: 16));
      for (var i = 0; i < 12; i++) {
        await left.moveBy(const Offset(-10, 0));
        await right.moveBy(const Offset(10, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await left.up();
      await right.up();
      await tester.pumpAndSettle();
      expect(scaleOf(tester), greaterThan(2));

      // Then squeeze it back.
      left = await tester.startGesture(centre - const Offset(160, 0));
      right = await tester.startGesture(centre + const Offset(160, 0));
      await tester.pump(const Duration(milliseconds: 16));
      for (var i = 0; i < 14; i++) {
        await left.moveBy(const Offset(11, 0));
        await right.moveBy(const Offset(-11, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await left.up();
      await right.up();
      await tester.pumpAndSettle();
      expect(scaleOf(tester), closeTo(1, 0.001));
      // A squeeze that only undoes a zoom must not also close the picture.
      expect(stillOpen(tester), isTrue);
    });

    testWidgets('a squeeze from rest never shrinks the picture at all',
        (tester) async {
      // v1.15.10 let a squeeze go to 0.6 as "elastic give", and read a release
      // below 0.82 as "put it away". Two things went wrong on a real hand: the
      // dimming made an ordinary pinch-in look like the screen was closing, and
      // when both fingers lifted *without moving first* the scale recogniser
      // reconfigured instead of ending — no settle ever ran, and the picture was
      // left small and stuck over the gallery with no way back. Fitted is now the
      // floor, so there is nothing to get stuck in.
      await open(tester);
      final centre = centreOf(tester);
      final left = await tester.startGesture(centre - const Offset(140, 0));
      final right = await tester.startGesture(centre + const Offset(140, 0));
      await tester.pump(const Duration(milliseconds: 16));
      for (var i = 0; i < 12; i++) {
        await left.moveBy(const Offset(10, 0));
        await right.moveBy(const Offset(-10, 0));
        await tester.pump(const Duration(milliseconds: 16));
        expect(scaleOf(tester), closeTo(1, 0.001),
            reason: 'mid-squeeze, step $i');
      }
      // Lifted a beat apart with no move in between — the shape that stuck.
      await left.up();
      await tester.pump(const Duration(milliseconds: 20));
      await right.up();
      await tester.pumpAndSettle();
      expect(scaleOf(tester), closeTo(1, 0.001));
      expect(stillOpen(tester), isTrue,
          reason: 'a squeeze is a zoom, not a way out');
    });

    testWidgets('a zoom held to the last finger still settles', (tester) async {
      // Same reconfigure-instead-of-end path as above, from a zoom: the settle
      // now runs off raw pointer counts, so the picture cannot be left mid-flight.
      await open(tester);
      final centre = centreOf(tester);
      final left = await tester.startGesture(centre - const Offset(40, 0));
      final right = await tester.startGesture(centre + const Offset(40, 0));
      await tester.pump(const Duration(milliseconds: 16));
      for (var i = 0; i < 10; i++) {
        await left.moveBy(const Offset(-10, 0));
        await right.moveBy(const Offset(10, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await left.up();
      await tester.pump(const Duration(milliseconds: 20));
      await right.up();
      await tester.pumpAndSettle();
      expect(scaleOf(tester), greaterThan(2),
          reason: 'a zoom survives the hand leaving');
      expect(scaleOf(tester), lessThanOrEqualTo(6));
    });

    testWidgets('a hand that slides on its way in still pinches',
        (tester) async {
      // The one that "wasn't zoomable" on the phone. Reaching in with a thumb,
      // the hand slides 30 logical pixels before the second finger touches down —
      // nothing at all on a real screen. When the surface shared its arena with a
      // scrollable `PageView`, that drift crossed the pager's [kTouchSlop] of 18,
      // the pager won, and the surface was dropped from the arena: the second
      // finger was *never delivered*, so no pinch existed. Measured against a bare
      // `ScaleGestureRecognizer` inside a `PageView`: the recogniser was never
      // even started and the scale stayed at exactly 1.0.
      await open(tester);
      final centre = centreOf(tester);

      final first = await tester.startGesture(centre - const Offset(40, 0));
      await tester.pump(const Duration(milliseconds: 16));
      for (var i = 0; i < 6; i++) {
        await first.moveBy(const Offset(-5, 1));
        await tester.pump(const Duration(milliseconds: 16));
      }
      // Only now does the second finger arrive.
      final second = await tester.startGesture(centre + const Offset(40, 0));
      await tester.pump(const Duration(milliseconds: 16));
      for (var i = 0; i < 12; i++) {
        await first.moveBy(const Offset(-9, 0));
        await second.moveBy(const Offset(9, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(scaleOf(tester), greaterThan(2));
      await first.up();
      await second.up();
      await tester.pumpAndSettle();
      expect(scaleOf(tester), greaterThan(2));
      // And the drift did not carry the run on to another picture on the way.
      expect(pageOf(tester), 0);
    });

    testWidgets('a pinch that begins as a sideways drag becomes a pinch',
        (tester) async {
      // The drag is committed to paging, then a second finger lands. The touch has
      // to change its mind mid-flight, because a hand does.
      await open(tester);
      final centre = centreOf(tester);

      final first = await tester.startGesture(centre - const Offset(40, 0));
      await tester.pump(const Duration(milliseconds: 16));
      for (var i = 0; i < 5; i++) {
        await first.moveBy(const Offset(-10, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      final second = await tester.startGesture(centre + const Offset(40, 0));
      await tester.pump(const Duration(milliseconds: 16));
      for (var i = 0; i < 12; i++) {
        await first.moveBy(const Offset(-9, 0));
        await second.moveBy(const Offset(9, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(scaleOf(tester), greaterThan(2), reason: 'it turned into a pinch');
      await first.up();
      await second.up();
      await tester.pumpAndSettle();
      expect(scaleOf(tester), greaterThan(2));
      expect(pageOf(tester), 0, reason: 'and did not also turn the page');
    });
  });

  /// Swiping between pictures, at the sizes and speeds a hand actually produces.
  ///
  /// Every case here is small. That is the point: the earlier tests all swiped
  /// 320px on a 400px-wide screen, which is past half the width, so they landed on
  /// the next picture **on distance alone** and passed while velocity was being
  /// dropped entirely. A real swipe is 40–80px and relies on being quick.
  group('swiping between pictures the way a hand does', () {
    testWidgets('a quick little flick turns the page', (tester) async {
      await open(tester);
      // 80px in 64ms ≈ 1250px/s. Nowhere near half the screen.
      await swipeSideways(tester, distance: -80, frames: 4);
      expect(pageOf(tester), 1);
    });

    testWidgets('a gentle flick turns the page too', (tester) async {
      await open(tester);
      // 60px in 96ms ≈ 625px/s.
      await swipeSideways(tester, distance: -60, frames: 6);
      expect(pageOf(tester), 1);
    });

    testWidgets('even a lazy one, if it is a flick at all', (tester) async {
      await open(tester);
      // 50px in 128ms ≈ 390px/s — just over the threshold.
      await swipeSideways(tester, distance: -50, frames: 8);
      expect(pageOf(tester), 1);
    });

    testWidgets('a slow drag a quarter of the way across still turns',
        (tester) async {
      await open(tester);
      // 120px of a 400px screen in 480ms — 250px/s, well under a flick, but the
      // hand plainly meant it. Half a width was too much to ask.
      await swipeSideways(tester, distance: -120, frames: 30);
      expect(pageOf(tester), 1);
    });

    testWidgets('a small slow drag falls back to the picture it was on',
        (tester) async {
      await open(tester);
      // 40px in 160ms: neither fast enough nor far enough to mean anything.
      await swipeSideways(tester, distance: -40, frames: 10);
      expect(pageOf(tester), 0);
    });

    testWidgets('a flick backwards goes back a picture', (tester) async {
      await open(tester);
      await swipeSideways(tester, distance: -80, frames: 4);
      expect(pageOf(tester), 1);
      await swipeSideways(tester, distance: 80, frames: 4);
      expect(pageOf(tester), 0);
    });

    testWidgets('a decisive swipe moves exactly one picture, never two',
        (tester) async {
      await open(tester);
      // 260px is 65% of the width *and* a flick. Rounding to the nearest page
      // before adding the flick's page took this two along, skipping a picture.
      await swipeSideways(tester, distance: -260, frames: 8);
      expect(pageOf(tester), 1);
    });

    testWidgets('flicks in a row walk the run one picture at a time',
        (tester) async {
      await open(tester);
      for (final expected in [1, 2]) {
        await swipeSideways(tester, distance: -80, frames: 4);
        expect(pageOf(tester), expected);
      }
      // And the last picture is the end of it.
      await swipeSideways(tester, distance: -80, frames: 4);
      expect(pageOf(tester), 2);
    });
  });

  group('what the other gestures still do', () {
    testWidgets('a sideways swipe pages', (tester) async {
      await open(tester);
      await tester.fling(
          find.byType(PhotoSurface).first, const Offset(-320, 0), 900);
      await tester.pumpAndSettle();
      expect(pageOf(tester), 1);
      expect(stillOpen(tester), isTrue);
    });

    testWidgets('a short sideways drag falls back to the picture it was on',
        (tester) async {
      await open(tester);
      // Twenty pixels is a change of mind, not a page turn.
      final gesture = await tester.startGesture(centreOf(tester));
      for (var i = 0; i < 4; i++) {
        await gesture.moveBy(const Offset(-5, 0));
        await tester.pump(const Duration(milliseconds: 40));
      }
      await gesture.up();
      await tester.pumpAndSettle();
      expect(pageOf(tester), 0);
    });

    testWidgets('a swipe at the first picture cannot go back past it',
        (tester) async {
      await open(tester);
      await tester.fling(
          find.byType(PhotoSurface).first, const Offset(320, 0), 900);
      await tester.pumpAndSettle();
      // No rubber band, no blank page: it simply stays.
      expect(pageOf(tester), 0);
      expect(stillOpen(tester), isTrue);
    });

    testWidgets('a swipe at the last picture cannot go on past it',
        (tester) async {
      await open(tester);
      for (var i = 0; i < 2; i++) {
        await tester.fling(
            find.byType(PhotoSurface).first, const Offset(-320, 0), 900);
        await tester.pumpAndSettle();
      }
      expect(pageOf(tester), 2, reason: 'three pictures, so this is the last');
      await tester.fling(
          find.byType(PhotoSurface).first, const Offset(-320, 0), 900);
      await tester.pumpAndSettle();
      expect(pageOf(tester), 2);
    });

    testWidgets('a zoomed picture pans instead of paging', (tester) async {
      await open(tester);
      final centre = centreOf(tester);
      final left = await tester.startGesture(centre - const Offset(40, 0));
      final right = await tester.startGesture(centre + const Offset(40, 0));
      await tester.pump(const Duration(milliseconds: 16));
      for (var i = 0; i < 12; i++) {
        await left.moveBy(const Offset(-10, 0));
        await right.moveBy(const Offset(10, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await left.up();
      await right.up();
      await tester.pumpAndSettle();
      final zoomed = scaleOf(tester);

      await tester.drag(find.byType(PhotoSurface).first, const Offset(-120, 0));
      await tester.pumpAndSettle();
      // Same page, same zoom: the drag moved the picture inside its frame.
      expect(pageOf(tester), 0);
      expect(scaleOf(tester), closeTo(zoomed, 0.001));
    });

    testWidgets('a double tap zooms in, and again zooms out', (tester) async {
      await open(tester);
      final centre = centreOf(tester);
      await tester.tapAt(centre);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(centre);
      await tester.pumpAndSettle();
      expect(scaleOf(tester), greaterThan(2));

      await tester.tapAt(centre);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(centre);
      await tester.pumpAndSettle();
      expect(scaleOf(tester), closeTo(1, 0.001));
    });

    testWidgets('a single tap hides the chrome and shows it again',
        (tester) async {
      await open(tester);
      expect(find.text('1 / 3'), findsOneWidget);
      // A tap only counts once the double-tap window has closed, so the wait is
      // the behaviour, not the test being polite.
      await tester.tapAt(centreOf(tester));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('1 / 3'), findsNothing);
      await tester.tapAt(centreOf(tester));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('1 / 3'), findsOneWidget);
    });
  });

  group('flick it away', () {
    testWidgets('a hard flick down closes the picture', (tester) async {
      await open(tester);
      await tester.fling(
          find.byType(PhotoSurface).first, const Offset(0, 300), 1200);
      await tester.pumpAndSettle();
      expect(stillOpen(tester), isFalse);
      // Back to the gallery, not to a black screen.
      expect(find.text('open'), findsOneWidget);
    });

    testWidgets('a hard flick up closes it too', (tester) async {
      await open(tester);
      await tester.fling(
          find.byType(PhotoSurface).first, const Offset(0, -300), 1200);
      await tester.pumpAndSettle();
      expect(stillOpen(tester), isFalse);
    });

    testWidgets('dragged far enough it closes even when let go of slowly',
        (tester) async {
      await open(tester);
      final gesture = await tester.startGesture(centreOf(tester));
      // Well past the threshold, but crawling — no fling velocity at all.
      for (var i = 0; i < 20; i++) {
        await gesture.moveBy(const Offset(0, 12));
        await tester.pump(const Duration(milliseconds: 60));
      }
      await gesture.up();
      await tester.pumpAndSettle();
      expect(stillOpen(tester), isFalse);
    });

    testWidgets('a short drag springs back and keeps the picture', (tester) async {
      await open(tester);
      final gesture = await tester.startGesture(centreOf(tester));
      for (var i = 0; i < 5; i++) {
        await gesture.moveBy(const Offset(0, 8));
        await tester.pump(const Duration(milliseconds: 40));
      }
      await gesture.up();
      await tester.pumpAndSettle();
      expect(stillOpen(tester), isTrue);
      expect(scaleOf(tester), closeTo(1, 0.001));
    });

    testWidgets('a zoomed picture is panned down, not thrown away',
        (tester) async {
      await open(tester);
      final centre = centreOf(tester);
      final left = await tester.startGesture(centre - const Offset(40, 0));
      final right = await tester.startGesture(centre + const Offset(40, 0));
      await tester.pump(const Duration(milliseconds: 16));
      for (var i = 0; i < 12; i++) {
        await left.moveBy(const Offset(-10, 0));
        await right.moveBy(const Offset(10, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await left.up();
      await right.up();
      await tester.pumpAndSettle();

      await tester.fling(
          find.byType(PhotoSurface).first, const Offset(0, 300), 1200);
      await tester.pumpAndSettle();
      // Looking closely at the bottom of a photo must not close it.
      expect(stillOpen(tester), isTrue);
    });

    testWidgets('the backdrop thins as the picture is dragged away',
        (tester) async {
      await open(tester);
      double backdrop() => tester
          .widget<Opacity>(find.descendant(
            of: find.byType(PhotoBackdrop),
            matching: find.byType(Opacity),
          ))
          .opacity;
      expect(backdrop(), 1);

      final gesture = await tester.startGesture(centreOf(tester));
      for (var i = 0; i < 8; i++) {
        await gesture.moveBy(const Offset(0, 12));
        await tester.pump(const Duration(milliseconds: 40));
      }
      expect(backdrop(), lessThan(1));
      // Let go short of the threshold: it comes back.
      await gesture.up();
      await tester.pumpAndSettle();
      expect(backdrop(), 1);
    });

    testWidgets('the picture it closes on is what the gallery is told',
        (tester) async {
      final closedOn = await open(tester);
      await tester.fling(
          find.byType(PhotoSurface).first, const Offset(-320, 0), 900);
      await tester.pumpAndSettle();
      expect(pageOf(tester), 1);

      // Pops with the id of the page that was on screen, so the caller can
      // scroll to wherever the user ended up rather than back to where they
      // started.
      await tester.fling(
          find.byType(PhotoSurface).first, const Offset(0, 300), 1200);
      await tester.pumpAndSettle();
      expect(stillOpen(tester), isFalse);
      expect(closedOn, ['b']);
    });
  });
}
