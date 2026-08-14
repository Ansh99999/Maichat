import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/widgets/message_html.dart';

void main() {
  group('font stacks resolve to a family the device has', () {
    test('the reported case: Times New Roman falls back to serif', () {
      expect(
        resolveFontFamilyList("'Times New Roman', serif"),
        'serif',
      );
    });

    test('quotes, spacing and case do not matter', () {
      expect(resolveFontFamilyList('"Courier New", monospace'), 'monospace');
      expect(resolveFontFamilyList('  ARIAL , sans-serif '), 'sans-serif');
      expect(resolveFontFamilyList('Comic Sans MS'), 'cursive');
    });

    test('a generic on its own is kept', () {
      expect(resolveFontFamilyList('monospace'), 'monospace');
      expect(resolveFontFamilyList('serif'), 'serif');
    });

    test('an unknown family is passed through in case it is installed', () {
      expect(resolveFontFamilyList("'Wingdings Deluxe'"), 'Wingdings Deluxe');
    });

    test('a later recognised name wins over an unknown first one', () {
      // The whole point: flutter_html keeps only the first name and drops the
      // rest of the stack, so the author's fallback has to be resolved here.
      expect(resolveFontFamilyList('Whatever Sans, Georgia'), 'serif');
    });

    test('an empty stack changes nothing', () {
      expect(resolveFontFamilyList('   '), isNull);
      expect(resolveFontFamilyList(''), isNull);
    });
  });

  group('rewriting HTML', () {
    test('inline style declarations are rewritten in place', () {
      const html = '<div style="font-family: \'Times New Roman\', serif;">'
          'Sumire\'s Apartment, Evening</div>';
      expect(
        resolveFontFamilies(html),
        '<div style="font-family: serif;">Sumire\'s Apartment, Evening</div>',
      );
    });

    test('other declarations in the same attribute survive', () {
      const html = '<span style="color: red; font-family: Georgia; '
          'font-size: 20px">x</span>';
      final out = resolveFontFamilies(html);
      expect(out, contains('color: red'));
      expect(out, contains('font-family: serif'));
      expect(out, contains('font-size: 20px'));
    });

    test('single-quoted attributes keep their quoting', () {
      const html = "<p style='font-family: Verdana'>x</p>";
      expect(resolveFontFamilies(html), "<p style='font-family: sans-serif'>x</p>");
    });

    test('a <font face> stack is resolved too', () {
      const html = '<font face="Times New Roman, serif">x</font>';
      expect(resolveFontFamilies(html), '<font face="serif">x</font>');
    });

    test('html without fonts is returned untouched', () {
      const html = '<p>plain <b>text</b></p>';
      expect(resolveFontFamilies(html), html);
    });

    test('messageToHtml applies the resolution end to end', () {
      const text = '<div style="font-family: \'Times New Roman\', serif;">'
          'Scene</div>\n\nand *prose*';
      final out = messageToHtml(text);
      expect(out, contains('font-family: serif'));
      expect(out, isNot(contains('Times New Roman')));
      expect(out, contains('<em>prose</em>'));
    });
  });

  group('render caching', () {
    testWidgets('an unchanged message keeps the same parsed subtree',
        (tester) async {
      const style = HtmlMessageStyle(
        base: Colors.black,
        emphasis: Colors.purple,
        quote: Colors.teal,
        codeBackground: Colors.black12,
        codeForeground: Colors.black,
        link: Colors.blue,
        fontSize: 15,
      );
      Widget host(String text) => MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(child: buildMessageHtml(text, style)),
            ),
          );

      await tester.pumpWidget(host('<p>one</p>'));
      final first = tester.widget<Html>(find.byType(Html));

      // A rebuild with the same text and style must hand back the very same
      // widget so Flutter skips the subtree — this is what stops every visible
      // turn from re-parsing on each streaming delta and each scroll.
      await tester.pumpWidget(host('<p>one</p>'));
      expect(identical(tester.widget<Html>(find.byType(Html)), first), isTrue);

      await tester.pumpWidget(host('<p>two</p>'));
      expect(identical(tester.widget<Html>(find.byType(Html)), first), isFalse);
    });
  });
}
