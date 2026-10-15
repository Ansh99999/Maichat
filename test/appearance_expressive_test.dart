import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/main.dart';
import 'package:maichat/models/appearance.dart';
import 'package:maichat/services/tokenizer.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('Appearance', () {
    test('expressive and palette round-trip, and default to off', () {
      const a = Appearance(expressive: true, palette: AppPalette.vibrant);
      final back = Appearance.fromJson(
        jsonDecode(jsonEncode(a.toJson())) as Map<String, dynamic>,
      );
      expect(back, a);
      // A store written before these existed reads as the calm baseline, and
      // the defaults write nothing new — the stored JSON is unchanged.
      final old = Appearance.fromJson(const {'dynamicColor': true});
      expect(old.expressive, isFalse);
      expect(old.palette, AppPalette.tonal);
      expect(const Appearance().toJson().containsKey('expressive'), isFalse);
      expect(const Appearance().toJson().containsKey('palette'), isFalse);
      expect(AppPalette.byName('nonsense'), AppPalette.tonal);
    });
  });

  group('themeFor', () {
    const seed = Color(kDefaultSeedColor);

    test('the baseline keeps Material 3 defaults', () {
      final t = MaiChatApp.themeFor(null, Brightness.light, seed);
      expect(t.useMaterial3, isTrue);
      expect(t.cardTheme.shape, isNull);
      expect(t.switchTheme.thumbIcon, isNull);
    });

    for (final brightness in Brightness.values) {
      test('Expressive reshapes and emphasises (${brightness.name})', () {
        final t = MaiChatApp.themeFor(
          null,
          brightness,
          seed,
          expressive: true,
        );
        expect(t.colorScheme.brightness, brightness);
        expect(t.cardTheme.shape, isA<RoundedSuperellipseBorder>());
        expect(t.dialogTheme.shape, isA<RoundedSuperellipseBorder>());
        expect(t.textTheme.headlineSmall?.fontWeight, FontWeight.w700);
        expect(t.switchTheme.thumbIcon, isNotNull);
        expect(
          t.pageTransitionsTheme.builders[TargetPlatform.android],
          isA<PredictiveBackPageTransitionsBuilder>(),
        );
        // A different, livelier scheme from the same seed.
        final calm = MaiChatApp.themeFor(null, brightness, seed);
        expect(t.colorScheme.primary, isNot(calm.colorScheme.primary));
      });
    }

    test('AMOLED stays true black under Expressive', () {
      final t = MaiChatApp.themeFor(
        null,
        Brightness.dark,
        seed,
        amoled: true,
        expressive: true,
      );
      expect(t.colorScheme.surface, const Color(0xFF000000));
    });

    test('a palette other than tonal re-seeds a dynamic scheme', () {
      final wallpaper = ColorScheme.fromSeed(seedColor: Colors.teal);
      final tonal = MaiChatApp.themeFor(wallpaper, Brightness.light, seed);
      final vibrant = MaiChatApp.themeFor(
        wallpaper,
        Brightness.light,
        seed,
        palette: AppPalette.vibrant,
      );
      expect(vibrant.colorScheme, isNot(tonal.colorScheme));
    });
  });

  testWidgets('MaterialApp keeps the same theme objects across rebuilds',
      (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'flutter.appearance': '{"dynamicColor":false,"expressive":true}',
    });
    await tester.pumpWidget(const MaiChatApp());
    await tester.pumpAndSettle();
    final first = tester.widget<MaterialApp>(find.byType(MaterialApp)).theme;
    expect(first?.cardTheme.shape, isA<RoundedSuperellipseBorder>());
    // Anything that notifies rebuilds MaterialApp; the theme must not change.
    await tester.tap(find.byTooltip('Menu'));
    await tester.pumpAndSettle();
    final second = tester.widget<MaterialApp>(find.byType(MaterialApp)).theme;
    expect(identical(first, second), isTrue);
  });

  test('the tokenizer warms up off the UI isolate and counts after', () async {
    await AppTokenizer.warmUp(BpeEncoding.cl100k);
    expect(AppTokenizer.isWarm(BpeEncoding.cl100k), isTrue);
    final tok = AppTokenizer(
      config: () => const TokenizerConfig(
        kind: TokenizerKind.custom,
        customEncoding: BpeEncoding.cl100k,
      ),
      model: () => '',
    );
    expect(tok.estimate('hello world'), 2);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
