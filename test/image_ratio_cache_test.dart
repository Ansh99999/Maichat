import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/services/image_ratio_cache.dart';
import 'package:maichat/services/storage.dart';
import 'package:maichat/state/app_state.dart';
import 'package:maichat/widgets/avatar_image.dart';
import 'package:maichat/widgets/natural_image.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _CountingStorage extends Storage {
  int ratioWrites = 0;

  @override
  Future<void> saveImageRatios(Map<String, double> ratios) async {
    ratioWrites++;
    await super.saveImageRatios(ratios);
  }
}

class _DelayedRatioStorage extends Storage {
  final saveStarted = Completer<void>();
  final releaseSave = Completer<void>();

  @override
  Future<void> saveImageRatios(Map<String, double> ratios) async {
    if (!saveStarted.isCompleted) saveStarted.complete();
    await releaseSave.future;
    await super.saveImageRatios(ratios);
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    clearAvatarImageCache();
  });

  tearDown(clearAvatarImageCache);

  group('intrinsic ratio cache', () {
    test('keeps exact safe references but never persists image data', () {
      final cache = ImageRatioCache();
      cache.note('local:card.png', 16 / 9);
      cache.note('https://example.com/a.png?revision=2', 4 / 3);
      cache.note('aGVsbG8=', 1);
      cache.note('local:../escape.png', 2);

      expect(cache.ratioOf('local:card.png'), 16 / 9);
      expect(cache.ratioOf('https://example.com/a.png?revision=2'), 4 / 3);
      expect(cache.ratioOf('aGVsbG8='), 1);
      expect(cache.durableSnapshot(), <String, double>{
        'local:card.png': 16 / 9,
        'https://example.com/a.png?revision=2': 4 / 3,
      });
      expect(cache.durableSnapshot().keys.join(), isNot(contains('aGV')));
    });

    test('rejects bad ratios and caps the durable LRU', () {
      final cache = ImageRatioCache(maxEntries: 3);
      cache.note('local:a.png', 1);
      cache.note('local:b.png', 2);
      cache.note('local:c.png', 3);
      cache.note('local:bad.png', double.nan);
      cache.note('local:zero.png', 0);

      expect(cache.ratioOf('local:a.png'), 1); // a is newest now.
      cache.note('local:d.png', 4);

      expect(cache.ratioOf('local:b.png'), isNull);
      expect(cache.durableSnapshot().keys, [
        'local:c.png',
        'local:a.png',
        'local:d.png',
      ]);
    });

    test('replacement seeding filters data without scheduling a save', () {
      final cache = ImageRatioCache(maxEntries: 2);
      var changes = 0;
      cache.bindDurableChanged(() => changes++);

      cache.replaceDurable(<String, double>{
        'local:first.png': 1,
        'not-a-ref': 8,
        'https://example.com/second.png': 2,
        'local:third.png': 3,
      });

      expect(changes, 0);
      expect(cache.ratioOf('local:first.png'), isNull);
      expect(cache.durableSnapshot(), <String, double>{
        'https://example.com/second.png': 2,
        'local:third.png': 3,
      });
      cache.note('local:third.png', 3);
      expect(changes, 0);
      cache.note('local:third.png', 4);
      expect(changes, 1);
    });
  });

  group('storage and app startup', () {
    test('malformed stored metadata degrades to a filtered cache', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.imageRatios': jsonEncode(<String, Object?>{
          'local:good.png': 1.5,
          'local:string.png': '2',
          'local:zero.png': 0,
          'local:negative.png': -1,
          'base64-like': 2,
        }),
      });

      expect(await Storage().loadImageRatios(), <String, double>{
        'local:good.png': 1.5,
      });

      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.imageRatios': '{broken',
      });
      expect(await Storage().loadImageRatios(), isEmpty);
    });

    test('hydrates known geometry before init reports ready', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'flutter.imageRatios': jsonEncode(<String, double>{
          'local:wide.png': 16 / 9,
          'https://example.com/portrait.png': 3 / 4,
        }),
      });
      final state = AppState();
      addTearDown(state.dispose);

      await state.init();

      expect(state.ready, isTrue);
      expect(avatarRatio('local:wide.png'), 16 / 9);
      expect(avatarRatio('https://example.com/portrait.png'), 3 / 4);
    });

    test('coalesces discoveries without notifying app listeners', () async {
      final storage = _CountingStorage();
      final state = AppState(storage: storage);
      addTearDown(state.dispose);
      await state.init();
      var notifications = 0;
      state.addListener(() => notifications++);

      noteAvatarRatio('local:one.png', 1);
      noteAvatarRatio('local:two.png', 2);
      noteAvatarRatio('https://example.com/three.png', 3);
      await Future<void>.delayed(const Duration(milliseconds: 550));

      expect(storage.ratioWrites, 1);
      expect(notifications, 0);
      expect(await storage.loadImageRatios(), <String, double>{
        'local:one.png': 1,
        'local:two.png': 2,
        'https://example.com/three.png': 3,
      });
    });

    test(
      'flush writes pending ratios and clear cache removes both copies',
      () async {
        final storage = _CountingStorage();
        final state = AppState(storage: storage);
        addTearDown(state.dispose);
        await state.init();

        noteAvatarRatio('local:known.png', 4 / 3);
        await state.flushPendingSaves();
        expect(storage.ratioWrites, 1);
        expect(await storage.loadImageRatios(), isNotEmpty);

        await state.clearCaches();
        expect(avatarRatio('local:known.png'), isNull);
        expect(await storage.loadImageRatios(), isEmpty);
      },
    );

    test('clear cannot be undone by an older in-flight save', () async {
      final storage = _DelayedRatioStorage();
      final state = AppState(storage: storage);
      addTearDown(state.dispose);
      await state.init();
      state.debounceFloatSaves = false;

      noteAvatarRatio('local:stale.png', 16 / 9);
      await storage.saveStarted.future;
      final clearing = state.clearCaches();
      await Future<void>.delayed(Duration.zero);
      expect(avatarRatio('local:stale.png'), isNull);

      storage.releaseSave.complete();
      await clearing;
      expect(await storage.loadImageRatios(), isEmpty);
    });
  });

  group('NaturalFrame reporting', () {
    Widget host({
      required String ref,
      required double width,
      required ValueChanged<double> callback,
    }) => MaterialApp(
      home: SizedBox(
        width: width,
        child: NaturalFrame(
          imageRef: ref,
          displayWidth: width,
          onRatioResolved: callback,
          builder: (_, size, image) => SizedBox.fromSize(size: size),
        ),
      ),
    );

    testWidgets('reports a known image once per image and callback', (
      tester,
    ) async {
      const first = 'https://example.com/first.png';
      const second = 'https://example.com/second.png';
      noteAvatarRatio(first, 16 / 9);
      noteAvatarRatio(second, 3 / 4);
      final reports = <double>[];
      void callback(double ratio) => reports.add(ratio);

      await tester.pumpWidget(host(ref: first, width: 200, callback: callback));
      await tester.pump();
      expect(reports, [16 / 9]);

      await tester.pumpWidget(host(ref: first, width: 180, callback: callback));
      await tester.pump();
      expect(reports, [16 / 9]);

      await tester.pumpWidget(
        host(ref: second, width: 180, callback: callback),
      );
      await tester.pump();
      expect(reports, [16 / 9, 3 / 4]);
    });

    testWidgets('a replacement callback receives the known ratio once', (
      tester,
    ) async {
      const ref = 'https://example.com/card.png';
      noteAvatarRatio(ref, 4 / 3);
      final first = <double>[];
      final second = <double>[];
      void firstCallback(double ratio) => first.add(ratio);
      void secondCallback(double ratio) => second.add(ratio);

      await tester.pumpWidget(
        host(ref: ref, width: 200, callback: firstCallback),
      );
      await tester.pump();
      await tester.pumpWidget(
        host(ref: ref, width: 200, callback: secondCallback),
      );
      await tester.pump();
      await tester.pump();

      expect(first, [4 / 3]);
      expect(second, [4 / 3]);
    });
  });
}
