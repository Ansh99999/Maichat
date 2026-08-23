import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:maichat/widgets/brand_mark.dart';

/// The brand mark has to behave like an icon, not a picture: it takes its size
/// and colour from the surrounding Material scheme, so the same asset works on
/// light, dark, AMOLED and any wallpaper-derived palette. These tests pin that
/// down, because a hardcoded colour would only show up as "the logo is invisible
/// in dark mode" on a device — and there is no device here.
void main() {
  /// Pumps [child] under a scheme seeded from [seed], with [brightness].
  Future<ColorScheme> pumpThemed(
    WidgetTester tester,
    Widget child, {
    Color seed = const Color(0xFF7C5CFF),
    Brightness brightness = Brightness.light,
  }) async {
    final scheme =
        ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(colorScheme: scheme, useMaterial3: true),
      home: Scaffold(body: child),
    ));
    await tester.pumpAndSettle();
    return scheme;
  }

  /// The colour filter [MaiChatMark] resolved, read off the widget it renders.
  /// [ColorFilter] has no getters but it does implement `==`, so the assertions
  /// compare whole filters rather than picking a colour back out of one.
  ColorFilter filterOf(WidgetTester tester, {int at = 0}) {
    final svg = tester.widgetList<SvgPicture>(find.byType(SvgPicture)).elementAt(at);
    return svg.colorFilter!;
  }

  /// What [filterOf] should equal for a mark tinted [color].
  ColorFilter tint(Color color) => ColorFilter.mode(color, BlendMode.srcIn);

  group('MaiChatMark', () {
    testWidgets('falls back to onSurfaceVariant with no ambient icon theme',
        (tester) async {
      final scheme = await pumpThemed(tester, const MaiChatMark());
      expect(filterOf(tester), tint(scheme.onSurfaceVariant));
    });

    testWidgets('takes the ambient IconTheme colour and size', (tester) async {
      await pumpThemed(
        tester,
        const IconTheme(
          data: IconThemeData(color: Color(0xFF00FF00), size: 40),
          child: MaiChatMark(),
        ),
      );
      expect(filterOf(tester), tint(const Color(0xFF00FF00)));
      final svg = tester.widget<SvgPicture>(find.byType(SvgPicture));
      expect(svg.width, 40);
      expect(svg.height, 40);
    });

    testWidgets('an explicit colour beats the icon theme', (tester) async {
      await pumpThemed(
        tester,
        const IconTheme(
          data: IconThemeData(color: Color(0xFF00FF00)),
          child: MaiChatMark(color: Color(0xFFFF0000)),
        ),
      );
      expect(filterOf(tester), tint(const Color(0xFFFF0000)));
    });

    testWidgets('follows a ListTile leading slot, selected and not',
        (tester) async {
      // This is the real arrangement in every format picker: the mark sits in
      // the leading slot, where ListTile publishes a state-dependent colour.
      final scheme = await pumpThemed(
        tester,
        const Column(children: [
          ListTile(leading: MaiChatMark(), title: Text('plain')),
          ListTile(
              leading: MaiChatMark(), title: Text('picked'), selected: true),
        ]),
      );
      expect(find.byType(SvgPicture), findsNWidgets(2));
      expect(filterOf(tester), tint(scheme.onSurfaceVariant));
      // A selected row tints its leading with the primary colour, and the mark
      // has to come along or it reads as a different, dead icon.
      expect(filterOf(tester, at: 1), tint(scheme.primary));
    });

    testWidgets('the resolved tint tracks light vs dark', (tester) async {
      final light = await pumpThemed(tester, const MaiChatMark());
      expect(filterOf(tester), tint(light.onSurfaceVariant));
      final dark = await pumpThemed(tester, const MaiChatMark(),
          brightness: Brightness.dark);
      expect(filterOf(tester), tint(dark.onSurfaceVariant));
      expect(dark.onSurfaceVariant, isNot(light.onSurfaceVariant));
    });

    testWidgets('a different seed gives a different tint — Material You',
        (tester) async {
      final purple = await pumpThemed(tester, const MaiChatMark());
      expect(filterOf(tester), tint(purple.onSurfaceVariant));
      final teal = await pumpThemed(tester, const MaiChatMark(),
          seed: const Color(0xFF00796B));
      expect(filterOf(tester), tint(teal.onSurfaceVariant));
      expect(teal.onSurfaceVariant, isNot(purple.onSurfaceVariant));
    });

    testWidgets('the asset is a real, declared, monochrome vector',
        (tester) async {
      final data = await rootBundle.loadString(kMaiChatMarkAsset);
      expect(data, contains('<svg'));
      // One colour, named so the file says so — and no baked-in black to fight
      // the tint.
      expect(data, contains('currentColor'));
      expect(data.contains('#000000'), isFalse,
          reason: 'the mark still has a baked-in black');
      // The traced lines are hairlines; the widening is what keeps them legible
      // at the 18–24 dp the mark is mostly drawn at.
      expect(data, contains('stroke-width'));
    });
  });

  group('BrandedText', () {
    testWidgets('puts one mark before each mention of the name',
        (tester) async {
      await pumpThemed(
          tester, const BrandedText('A SillyTavern log or a MaiChat chat'));
      expect(find.byType(MaiChatMark), findsOneWidget);
      // The words survive intact — the mark is added, nothing is replaced.
      final text = tester.widget<Text>(find.byType(Text));
      expect(text.textSpan!.toPlainText(includePlaceholders: false),
          'A SillyTavern log or a MaiChat chat');
    });

    testWidgets('marks every mention, not just the first', (tester) async {
      await pumpThemed(tester,
          const BrandedText('MaiChat reads a MaiChat file'));
      expect(find.byType(MaiChatMark), findsNWidgets(2));
    });

    testWidgets('text with no mention renders as a plain Text', (tester) async {
      await pumpThemed(tester, const BrandedText('SillyTavern / Agnai'));
      expect(find.byType(MaiChatMark), findsNothing);
      expect(find.text('SillyTavern / Agnai'), findsOneWidget);
    });

    testWidgets('the mark inherits the text colour', (tester) async {
      await pumpThemed(
        tester,
        const DefaultTextStyle(
          style: TextStyle(fontSize: 20, color: Color(0xFF123456)),
          child: BrandedText('MaiChat'),
        ),
      );
      expect(filterOf(tester), tint(const Color(0xFF123456)));
      // …and scales with the font size it sits beside.
      final svg = tester.widget<SvgPicture>(find.byType(SvgPicture));
      expect(svg.width, closeTo(20 * 1.35, 0.01));
    });

    testWidgets('the mark grows with the platform font scale', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: DefaultTextStyle(
              style: TextStyle(fontSize: 16),
              child: BrandedText('MaiChat'),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      final svg = tester.widget<SvgPicture>(find.byType(SvgPicture));
      expect(svg.width, closeTo(32 * 1.35, 0.01));
    });

    testWidgets('a screen reader hears the sentence, not the picture',
        (tester) async {
      final handle = tester.ensureSemantics();
      await pumpThemed(tester, const BrandedText('Import a MaiChat file'));
      expect(find.bySemanticsLabel('Import a MaiChat file'), findsOneWidget);
      handle.dispose();
    });
  });
}
