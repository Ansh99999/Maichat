// Part of the screenshot generator (see developer notes/screenshots.md). Not a
// test — the filename has no `_test.dart` suffix, so `flutter test` leaves it
// alone and CI never diffs these pixels.
//
// Regenerate with:
//   flutter test test/screenshots/generate.dart --update-goldens
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/main.dart';
import 'package:maichat/models/appearance.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart' hide Provider;

/// A 1080×2340 phone at 3× — the shape of the device this app is built for.
const Size kShotPhysical = Size(1080, 2340);
const double kShotRatio = 3.0;

/// Status bar and gesture bar, in physical pixels. The app draws edge to edge
/// and reads `viewPaddingOf`, so a screenshot taken without these would lay the
/// composer out somewhere a phone never puts it.
const FakeViewPadding kShotPadding =
    FakeViewPadding(top: 72, bottom: 36, left: 0, right: 0);

/// Loads the fonts the test binding does not have. Without this every glyph
/// renders as the filled box of the `Ahem` test font — the whole screenshot
/// becomes a Mondrian of black rectangles, which is exactly what the first
/// attempt produced.
Future<void> loadShotFonts() async {
  final fonts = _materialFonts();
  Future<ByteData> bytes(String name) async =>
      ByteData.sublistView(File('${fonts.path}/$name').readAsBytesSync());

  final roboto = FontLoader('Roboto');
  for (final face in const [
    'Roboto-Regular.ttf',
    'Roboto-Medium.ttf',
    'Roboto-Bold.ttf',
    'Roboto-Italic.ttf',
  ]) {
    roboto.addFont(bytes(face));
  }
  await roboto.load();
  final icons = FontLoader('MaterialIcons')
    ..addFont(bytes('MaterialIcons-Regular.otf'));
  await icons.load();
  // Roboto carries no arrows, and a couple of labels use one (Discover writes a
  // download count as "↓ 18k"). A phone falls back to Noto for that glyph; a
  // test host has no fallback list at all and draws a tofu box. DejaVu, when
  // the image ships it, covers the gap — registered as its own family and named
  // as a fallback by [shotTheme], which is the only mechanism the engine
  // actually consults.
  final dejavu = File('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf');
  if (dejavu.existsSync()) {
    final fallback = FontLoader(kShotFallbackFont)
      ..addFont(Future.value(ByteData.sublistView(dejavu.readAsBytesSync())));
    await fallback.load();
    _fallbackLoaded = true;
  }
}

/// The family name the symbol-coverage font is registered under.
const String kShotFallbackFont = 'ShotFallback';

/// Whether [kShotFallbackFont] was found on this machine. Nothing breaks when
/// it was not; a missing glyph simply draws as a box.
bool _fallbackLoaded = false;

/// Finds `bin/cache/artifacts/material_fonts` by climbing out of whichever
/// binary is running the test — which is `flutter_tester`, itself buried in
/// `artifacts/engine/<platform>/`. Climbing beats hardcoding the depth, since
/// that layout is the SDK's business and has changed before.
Directory _materialFonts() {
  var dir = File(Platform.resolvedExecutable).parent;
  for (var up = 0; up < 8; up++) {
    for (final candidate in [
      Directory('${dir.path}/artifacts/material_fonts'),
      Directory('${dir.path}/material_fonts'),
    ]) {
      if (candidate.existsSync()) return candidate;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError(
    'No material_fonts under ${Platform.resolvedExecutable}. Without Roboto '
    'every glyph renders as the Ahem test font\'s filled box.',
  );
}

/// The app's own theme, with every text style pinned to the font that was just
/// loaded. `ThemeData`'s defaults leave the family null, which sends the engine
/// back to `Ahem`.
ThemeData shotTheme({
  Brightness brightness = Brightness.light,
  bool amoled = false,
  int seed = kDefaultSeedColor,
}) {
  final base = MaiChatApp.themeFor(
    null,
    brightness,
    Color(seed),
    amoled: amoled,
  );
  final fallback = _fallbackLoaded ? const [kShotFallbackFont] : null;
  return base.copyWith(
    textTheme: base.textTheme
        .apply(fontFamily: 'Roboto', fontFamilyFallback: fallback),
    primaryTextTheme: base.primaryTextTheme
        .apply(fontFamily: 'Roboto', fontFamilyFallback: fallback),
  );
}

/// Sizes the surface like a phone, and puts shadows back. Call inside the test
/// body; [shoot] undoes the shadow part, because the binding asserts that a
/// painting debug flag is back at its default by the time the body returns.
void usePhone(WidgetTester tester) {
  tester.view
    ..physicalSize = kShotPhysical
    ..devicePixelRatio = kShotRatio
    ..viewPadding = kShotPadding
    ..padding = kShotPadding;
  addTearDown(tester.view.reset);
  // `testWidgets` flattens every shadow into a hard black outline so goldens
  // stay comparable across machines. Right for a test, wrong for a photograph:
  // it drew a black box around every search field and floating button.
  debugDisableShadows = false;
}

/// The real screen, under the real state, dressed in the real theme.
Widget shotHost(
  AppState state,
  Widget screen, {
  Brightness brightness = Brightness.light,
  bool amoled = false,
  int seed = kDefaultSeedColor,
}) =>
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: shotTheme(brightness: brightness, amoled: amoled, seed: seed),
        home: screen,
      ),
    );

/// Lets the real image codec run. A `MemoryImage` decodes on the engine's own
/// thread, which the fake clock inside `testWidgets` never advances — without
/// this every avatar in the shot is an empty coloured circle, which is how the
/// first batch came out.
Future<void> settleShots(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
    await tester.pump();
  }
}

/// Writes `docs/screenshots/<name>.png`. The path is relative to this file, and
/// the name is the contract the README depends on: replace the file with a
/// photograph from a real phone and nothing else has to change.
Future<void> shoot(WidgetTester tester, String name) async {
  await settleShots(tester);
  await expectLater(
    find.byType(MaterialApp),
    matchesGoldenFile('../../docs/screenshots/$name.png'),
  );
  // Back to the framework's default before the body returns, or the binding
  // fails the test for having left a painting flag changed.
  debugDisableShadows = true;
}

