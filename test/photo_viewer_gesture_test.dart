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
  double scaleOf(WidgetTester tester) {
    final transform = tester.widget<Transform>(find
        .descendant(
          of: find.byType(PhotoSurface).first,
          matching: find.byType(Transform),
        )
        .first);
    return transform.transform.getMaxScaleOnAxis();
  }

  double pageOf(WidgetTester tester) =>
      tester.widget<PageView>(find.byType(PageView)).controller!.page ?? -1;

  bool stillOpen(WidgetTester tester) =>
      find.byType(ImageViewerScreen).evaluate().isNotEmpty;

  Offset centreOf(WidgetTester tester) =>
      tester.getCenter(find.byType(PhotoSurface).first);

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
