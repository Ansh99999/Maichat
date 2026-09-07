import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/widgets/smooth_image.dart';

import 'screenshots/png.dart';

class _ControlledImageProvider extends ImageProvider<_ControlledImageProvider> {
  final Completer<ImageInfo> _frame = Completer<ImageInfo>.sync();
  int loadCount = 0;

  @override
  Future<_ControlledImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<_ControlledImageProvider>(this);
  }

  @override
  ImageStreamCompleter loadImage(
    _ControlledImageProvider key,
    ImageDecoderCallback decode,
  ) {
    loadCount += 1;
    return OneFrameImageStreamCompleter(_frame.future);
  }

  void complete(ui.Image image) {
    _frame.complete(ImageInfo(image: image.clone()));
  }
}

Widget _app(Widget child) => MaterialApp(home: Center(child: child));

void main() {
  late ui.Image testImage;

  setUpAll(() async {
    final codec = await ui.instantiateImageCodec(
      demoArt(width: 1, height: 1, hue: 220),
    );
    final frame = await codec.getNextFrame();
    testImage = frame.image;
    codec.dispose();
  });

  setUp(() {
    imageCache.clear();
    imageCache.clearLiveImages();
  });

  tearDownAll(() => testImage.dispose());

  testWidgets('a first asynchronous frame fades smoothly into view', (
    tester,
  ) async {
    final provider = _ControlledImageProvider();
    await tester.pumpWidget(_app(SmoothImage(image: provider)));

    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      0,
    );

    provider.complete(testImage);
    await tester.pump();
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      1,
    );

    await tester.pump(const Duration(milliseconds: 100));
    final fade = tester.widget<FadeTransition>(
      find.descendant(
        of: find.byType(SmoothImage),
        matching: find.byType(FadeTransition),
      ),
    );
    expect(fade.opacity.value, inExclusiveRange(0, 1));

    await tester.pump(const Duration(milliseconds: 100));
    expect(
      tester
          .widget<FadeTransition>(
            find.descendant(
              of: find.byType(SmoothImage),
              matching: find.byType(FadeTransition),
            ),
          )
          .opacity
          .value,
      1,
    );
  });

  testWidgets('a decoded cache hit paints immediately without a fade', (
    tester,
  ) async {
    final provider = _ControlledImageProvider();
    await tester.pumpWidget(_app(Image(image: provider)));
    provider.complete(testImage);
    await tester.pump();
    await tester.pumpWidget(_app(const SizedBox.shrink()));
    await tester.pump();

    await tester.pumpWidget(_app(SmoothImage(image: provider)));

    expect(provider.loadCount, 1);
    expect(find.byType(AnimatedOpacity), findsNothing);
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('a gapless provider swap never dips back to transparent', (
    tester,
  ) async {
    final first = _ControlledImageProvider();
    final second = _ControlledImageProvider();

    await tester.pumpWidget(
      _app(SmoothImage(image: first, gaplessPlayback: true)),
    );
    first.complete(testImage);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    await tester.pumpWidget(
      _app(SmoothImage(image: second, gaplessPlayback: true)),
    );

    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      1,
    );
    second.complete(testImage);
    await tester.pump();
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      1,
    );
  });
}
