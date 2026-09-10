import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/gallery_image.dart';
import 'package:maichat/models/view_prefs.dart';
import 'package:maichat/screens/gallery/gallery_screen.dart';
import 'package:maichat/screens/gallery/image_viewer_screen.dart';
import 'package:maichat/services/avatar_store.dart';
import 'package:maichat/state/app_state.dart';
import 'package:maichat/widgets/adaptive_mosaic.dart';
import 'package:maichat/widgets/avatar_image.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAA'
    'DUlEQVR42mP8z8DAwAAABQABg1z0GwAAAABJRU5ErkJggg==',
  );
  late Directory pictures;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    pictures = Directory.systemTemp.createTempSync('gallery-free-size');
    AvatarStore(pictures);
    clearAvatarImageCache();
  });

  tearDown(() {
    pictures.deleteSync(recursive: true);
    avatarDirectory = null;
    clearAvatarImageCache();
  });

  GalleryImage picture(String id, double ratio, {int minute = 0}) {
    File('${pictures.path}/$id.png').writeAsBytesSync(png);
    final ref = 'local:$id.png';
    noteAvatarRatio(ref, ratio);
    return GalleryImage(
      id: id,
      image: ref,
      title: id,
      createdAt: DateTime(2026, 4, 24, 12, minute),
    );
  }

  Future<AppState> seeded(
    List<GalleryImage> images, {
    bool freeSize = false,
  }) async {
    final state = AppState();
    await state.init();
    for (final image in images.reversed) {
      await state.saveGalleryImage(image);
    }
    if (freeSize) {
      await state.setFreeSizeCards(BrowseSection.gallery, true);
    }
    return state;
  }

  Future<void> pumpGallery(
    WidgetTester tester,
    AppState state, {
    Size size = const Size(400, 1400),
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: GalleryScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> chooseZoom(WidgetTester tester, String label) async {
    await tester.tap(find.byIcon(Icons.grid_view_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  Rect tileRect(WidgetTester tester, String id) =>
      tester.getRect(find.byKey(ValueKey<String>(id)));

  void expectClose(double actual, double expected) {
    expect(actual, moreOrLessEquals(expected, epsilon: 0.05));
  }

  testWidgets('legacy mode keeps fixed grids across the whole zoom ladder', (
    tester,
  ) async {
    final state = await seeded([picture('square', 1)]);
    await pumpGallery(tester, state);

    expect(find.byType(AdaptiveMosaicSliver<GalleryImage>), findsNothing);
    expect(find.byType(SliverGrid), findsOneWidget);

    for (final choice in <(String, int)>[
      ('One at a time, by day', 1),
      ('2 across, by day', 2),
      ('4 across, by week', 4),
      ('6 across, by month', 6),
    ]) {
      await chooseZoom(tester, choice.$1);
      final grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
      final delegate =
          grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
      expect(delegate.crossAxisCount, choice.$2);
      expect(find.byType(AdaptiveMosaicSliver<GalleryImage>), findsNothing);
    }
  });

  testWidgets('free size allocates one- and two-slot widths at every zoom', (
    tester,
  ) async {
    final state = await seeded([
      picture('wide', 16 / 9, minute: 3),
      picture('landscape', 4 / 3, minute: 2),
      picture('square', 1, minute: 1),
      picture('portrait', 3 / 4),
    ], freeSize: true);
    await pumpGallery(tester, state, size: const Size(400, 2200));

    expect(find.byType(AdaptiveMosaicSliver<GalleryImage>), findsOneWidget);
    expect(find.byType(SliverGrid), findsNothing);

    void expectWidths(double ordinary, double wide) {
      expectClose(tileRect(tester, 'wide').width, wide);
      expectClose(tileRect(tester, 'landscape').width, wide);
      expectClose(tileRect(tester, 'square').width, ordinary);
      expectClose(tileRect(tester, 'portrait').width, ordinary);
    }

    expectWidths(187, 380);

    await chooseZoom(tester, 'One at a time, by day');
    expectWidths(380, 380);

    await chooseZoom(tester, 'Up to 4 across, by week');
    expectWidths(90.5, 187);

    await chooseZoom(tester, 'Up to 6 across, by month');
    expectWidths(58.333, 122.667);
  });

  testWidgets('free-size frames retain every intrinsic aspect ratio', (
    tester,
  ) async {
    final state = await seeded([
      picture('wide', 16 / 9, minute: 3),
      picture('landscape', 4 / 3, minute: 2),
      picture('square', 1, minute: 1),
      picture('portrait', 3 / 4),
    ], freeSize: true);
    await pumpGallery(tester, state, size: const Size(400, 2200));

    for (final entry in <String, double>{
      'wide': 16 / 9,
      'landscape': 4 / 3,
      'square': 1,
      'portrait': 3 / 4,
    }.entries) {
      final rect = tileRect(tester, entry.key);
      expectClose(rect.width / rect.height, entry.value);
    }
  });

  testWidgets('caption room follows allocated width rather than slot count', (
    tester,
  ) async {
    final state = await seeded([
      picture('wide', 16 / 9, minute: 1),
      picture('square', 1),
    ], freeSize: true);
    await pumpGallery(tester, state);

    await chooseZoom(tester, 'Up to 4 across, by week');
    expect(find.text('wide'), findsOneWidget);
    expect(find.text('square'), findsNothing);

    await chooseZoom(tester, 'Up to 6 across, by month');
    expect(find.text('wide'), findsOneWidget);
    expect(find.text('square'), findsNothing);
  });

  testWidgets('viewer receives the exact width of the adaptive tile', (
    tester,
  ) async {
    final state = await seeded([picture('wide', 16 / 9)], freeSize: true);
    await pumpGallery(tester, state);
    final width = tileRect(tester, 'wide').width;

    await tester.tap(find.byKey(const ValueKey<String>('wide')));
    await tester.pumpAndSettle();

    final viewer = tester.widget<ImageViewerScreen>(
      find.byType(ImageViewerScreen),
    );
    expectClose(viewer.openedAt!, width);
  });
}
