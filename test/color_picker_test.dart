import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/widgets/color_picker.dart';

void main() {
  group('hex helpers', () {
    test('hexOf renders the opaque #RRGGBB form', () {
      expect(hexOf(const Color(0xFF7C5CFF)), '#7C5CFF');
      expect(hexOf(const Color(0xFF000000)), '#000000');
    });

    test('parseHexColor accepts #RRGGBB, bare RRGGBB and AARRGGBB', () {
      expect(parseHexColor('#7C5CFF'), const Color(0xFF7C5CFF));
      expect(parseHexColor('7c5cff'), const Color(0xFF7C5CFF));
      expect(parseHexColor('  #10B981 '), const Color(0xFF10B981));
      expect(parseHexColor('807C5CFF'), const Color(0x807C5CFF));
    });

    test('parseHexColor rejects nonsense', () {
      expect(parseHexColor('nope'), isNull);
      expect(parseHexColor('#12'), isNull);
      expect(parseHexColor(''), isNull);
    });
  });

  testWidgets('tapping a preset swatch reports its colour', (tester) async {
    Color? picked;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ThemeColorPicker(
          value: kThemeSwatches.first,
          onChanged: (c) => picked = c,
        ),
      ),
    ));

    // The second swatch is a distinct preset from the (selected) first.
    await tester.tap(find.byType(InkWell).at(1));
    await tester.pumpAndSettle();
    expect(picked, kThemeSwatches[1]);
  });

  testWidgets('the custom entry opens the HSV dialog', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ThemeColorPicker(
          value: kThemeSwatches.first,
          onChanged: (_) {},
        ),
      ),
    ));

    // Last swatch is the custom-colour entry.
    await tester.tap(find.byType(InkWell).last);
    await tester.pumpAndSettle();
    expect(find.text('Theme colour'), findsOneWidget);
    expect(find.text('Hue'), findsOneWidget);
    // The dialog seeds its hex field + preview from the initial colour.
    expect(find.text('#7C5CFF'), findsWidgets);
  });

  testWidgets('disabled picker does not fire onChanged', (tester) async {
    Color? picked;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ThemeColorPicker(
          value: kThemeSwatches.first,
          enabled: false,
          onChanged: (c) => picked = c,
        ),
      ),
    ));

    await tester.tap(find.byType(InkWell).at(1));
    await tester.pumpAndSettle();
    expect(picked, isNull);
  });
}
