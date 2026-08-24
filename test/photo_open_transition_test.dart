import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/gallery_image.dart';
import 'package:maichat/screens/gallery/gallery_screen.dart';
import 'package:maichat/screens/gallery/image_viewer_screen.dart';
import 'package:maichat/services/avatar_store.dart';
import 'package:maichat/state/app_state.dart';
import 'package:maichat/widgets/avatar_image.dart';
import 'package:maichat/widgets/photo_surface.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Opening a picture grows the tile that was tapped into the full-screen photo,
/// and closing it puts the picture back where it came from.
///
/// This is the only gallery test with a **real pictures directory** behind it, and
/// it has to be: a [Hero] flies a laid-out box, so the fault this pins down is
/// invisible without bitmaps. The first cut wrapped the bare `Image` — which has
/// no size at all until it has decoded — and the picture flew into a *single point*
/// at the middle of the screen and disappeared. Measured here: the flight's rect
/// grew from the tile's 187px square to the full 400x900 surface.
void main() {
  /// A real 1x1 PNG, so the decoder has something to produce a size from.
  final png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAA'
      'DUlEQVR42mP8z8DAwAAABQABg1z0GwAAAABJRU5ErkJggg==');

  late Directory pictures;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    pictures = Directory.systemTemp.createTempSync('photo-open');
    // Constructing a store publishes its directory, which is what makes
    // `avatarImage` resolve a `local:` ref to a file.
    AvatarStore(pictures);
    clearAvatarImageCache();
  });
  tearDown(() {
    pictures.deleteSync(recursive: true);
    avatarDirectory = null;
    clearAvatarImageCache();
  });

  /// A gallery of three real pictures, newest first.
  Future<AppState> seeded() async {
    final state = AppState();
    await state.init();
    for (final id in ['c', 'b', 'a']) {
      File('${pictures.path}/$id.png').writeAsBytesSync(png);
      await state.saveGalleryImage(GalleryImage(
        id: id,
        image: 'local:$id.png',
        title: 'Pic $id',
        createdAt: DateTime(2026, 4, 24, 12),
      ));
    }
    return state;
  }

  Future<AppState> openGrid(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final state = await seeded();
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const MaterialApp(home: GalleryScreen()),
    ));
    await tester.pumpAndSettle();
    return state;
  }

  /// The rect of the picture that is flying, i.e. the one that is neither of the
  /// two tiles left sitting in the grid.
  Rect flyingRect(WidgetTester tester) {
    final rects = find
        .byType(Image)
        .evaluate()
        .map((element) => tester.getRect(find.byWidget(element.widget)))
        .toList();
    // The flight is the last child added to the overlay, so it is last here.
    return rects.last;
  }

  testWidgets('the picture grows out of the tile that was tapped',
      (tester) async {
    await openGrid(tester);
    final tile = tester.getRect(find.byType(Image).first);
    expect(tile.width, lessThan(200), reason: 'a grid tile, two across');

    await tester.tap(find.text('Pic a'));
    // One frame in, the flight has started from about the tile's size.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    final early = flyingRect(tester);
    expect(early.width, greaterThan(tile.width * 0.8));
    expect(early.width, lessThan(300),
        reason: 'still near the tile, not already full screen');

    await tester.pump(const Duration(milliseconds: 60));
    final middle = flyingRect(tester);
    expect(middle.width, greaterThan(early.width),
        reason: 'it is on its way out to the whole screen');

    await tester.pumpAndSettle();
    // Landed: the picture fills the surface it was flying to.
    expect(find.byType(ImageViewerScreen), findsOneWidget);
    final landed = tester.getRect(find.byType(PhotoSurface).first);
    expect(landed.size, const Size(400, 900));
  });

  testWidgets('opening is quick — no long cross-fade over the grid',
      (tester) async {
    await openGrid(tester);
    await tester.tap(find.text('Pic a'));
    await tester.pump();

    // A `Hero` flight lasts exactly the route's transition, so this is the number
    // that decides how long opening a photo *feels*: 180ms, down from 260ms plus a
    // full fade up from transparent. Deliberately not asserted through
    // `hasRunningAnimations` — the tapped tile's ink ripple runs for 640ms on its
    // own and would swamp the thing under test.
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(ImageViewerScreen), findsOneWidget);
    final landed = tester.getRect(find.byType(PhotoSurface).first);
    expect(landed.size, const Size(400, 900),
        reason: 'the picture is all the way open a fifth of a second in');

    // Half way through, it is already most of the way there rather than sitting
    // faint at tile size waiting for a fade to finish.
    await tester.pumpWidget(const SizedBox());
    await openGrid(tester);
    await tester.tap(find.text('Pic a'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    expect(flyingRect(tester).width, greaterThan(300));
  });

  testWidgets('the picture starts visible, never faded up from nothing',
      (tester) async {
    await openGrid(tester);
    await tester.tap(find.text('Pic a'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    // The route's fade begins at a third rather than at zero, so what is seen is
    // the picture flying — not a screen materialising over the grid. A photo that
    // fades up from transparent is the "weird fade-in" being removed.
    final fades = find.ancestor(
      of: find.byType(PhotoSurface),
      matching: find.byType(FadeTransition),
    );
    expect(fades, findsWidgets, reason: 'the route does fade something');
    for (final fade in tester.widgetList<FadeTransition>(fades)) {
      expect(fade.opacity.value, greaterThan(0.3));
    }
  });

  testWidgets('closing puts the picture back into its tile', (tester) async {
    await openGrid(tester);
    await tester.tap(find.text('Pic a'));
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewerScreen), findsOneWidget);

    await tester.fling(
        find.byType(PhotoSurface).first, const Offset(0, 320), 1200);
    // Mid-flight home: the picture is smaller than the screen and heading back.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final returning = flyingRect(tester);
    expect(returning.width, lessThan(400));

    await tester.pumpAndSettle();
    expect(find.byType(ImageViewerScreen), findsNothing);
    // And the grid has all three tiles again, none of them stranded mid-air.
    expect(find.byType(Image), findsNWidgets(3));
    for (final element in find.byType(Image).evaluate()) {
      expect(tester.getRect(find.byWidget(element.widget)).width,
          lessThan(200));
    }
  });

  testWidgets('a picture swiped to flies home into its own tile',
      (tester) async {
    await openGrid(tester);
    await tester.tap(find.text('Pic a'));
    await tester.pumpAndSettle();
    // Two pages along, so the tag that flies home is not the one that flew in —
    // only the page on screen may carry it, or two heroes share one tag.
    await tester.fling(
        find.byType(PhotoSurface).first, const Offset(-320, 0), 900);
    await tester.pumpAndSettle();
    expect(find.text('Pic b'), findsWidgets);

    await tester.fling(
        find.byType(PhotoSurface).first, const Offset(0, 320), 1200);
    await tester.pumpAndSettle();
    expect(find.byType(ImageViewerScreen), findsNothing);
    expect(find.byType(Image), findsNWidgets(3));
  });

  testWidgets('the viewer draws the bitmap the grid already decoded',
      (tester) async {
    // The "black blink". The viewer asks for a screen-sized decode of the file
    // while the grid tile holds a much smaller one — a *different*
    // `ImageProvider`, so opening a picture starts a decode from scratch and paints
    // nothing until it lands. The viewer is now told how wide the tile was and
    // draws that already-decoded bitmap underneath, with the sharp one over it.
    await openGrid(tester);
    final tileProvider = tester.widget<Image>(find.byType(Image).first).image;

    await tester.tap(find.text('Pic a'));
    await tester.pumpAndSettle();

    final inViewer = find.descendant(
      of: find.byType(PhotoSurface),
      matching: find.byType(Image),
    );
    // Two layers: the soft one that needs no work to paint, and the sharp one.
    expect(inViewer, findsNWidgets(2));
    expect(tester.widgetList<Image>(inViewer).first.image, same(tileProvider),
        reason: 'the very same provider the grid is already showing, so the '
            'first frame has a picture on it rather than black');
  });

  testWidgets('the two layers are a small decode under a full-size one',
      (tester) async {
    // Stated against an explicit `MediaQuery`, because the two decodes only differ
    // when the tile and the screen fall in different size buckets — and the test
    // binding's default logical size happens to put both in the top one, which
    // would let this pass for the wrong reason.
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final state = await seeded();
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(size: Size(400, 900), devicePixelRatio: 3),
          child: ImageViewerScreen(
            imageIds: ['a', 'b', 'c'],
            initialIndex: 0,
            // A tile in a two-across grid on this screen.
            openedAt: 100,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final layers = tester
        .widgetList<Image>(find.descendant(
          of: find.byType(PhotoSurface),
          matching: find.byType(Image),
        ))
        .toList();
    expect(layers, hasLength(2));
    final under = layers.first.image as ResizeImage;
    final over = layers.last.image as ResizeImage;
    expect(under.width, lessThan(over.width!),
        reason: 'the one underneath is the cheap decode the grid already has');
    expect(under.imageProvider, over.imageProvider,
        reason: 'and both are the same file, so no second read from disk');
  });

  testWidgets('a picture with no tile behind it still opens', (tester) async {
    // Opened without an `openedAt` — from a chat's avatar sheet, say. There is
    // then no smaller bitmap to draw first, and the viewer must simply show the
    // one picture rather than an empty stack.
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final state = await seeded();
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const MaterialApp(
        home: ImageViewerScreen(imageIds: ['a', 'b', 'c'], initialIndex: 0),
      ),
    ));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
          of: find.byType(PhotoSurface), matching: find.byType(Image)),
      findsOneWidget,
    );
  });
}
