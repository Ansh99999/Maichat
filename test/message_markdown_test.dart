import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/widgets/message_markdown.dart';

const _emphasis = Color(0xFFFF0000);
const _quote = Color(0xFF0000FF);
const _codeBg = Color(0xFF222222);
const _link = Color(0xFF00AAFF);

const _styles = MarkdownStyles(
  base: TextStyle(color: Color(0xFF000000), fontSize: 16, height: 1.35),
  emphasis: _emphasis,
  quote: _quote,
  codeBackground: _codeBg,
  codeForeground: Color(0xFF000000),
  link: _link,
);

/// Flattens the span tree into leaf text spans.
List<TextSpan> _leaves(List<InlineSpan> spans) {
  final out = <TextSpan>[];
  void walk(InlineSpan s) {
    if (s is TextSpan) {
      if (s.text != null) out.add(s);
      s.children?.forEach(walk);
    }
  }

  spans.forEach(walk);
  return out;
}

TextSpan _spanWith(List<InlineSpan> spans, String text) =>
    _leaves(spans).firstWhere((s) => s.text == text);

String _plain(List<InlineSpan> spans) =>
    _leaves(spans).map((s) => s.text).join();

void main() {
  test('plain text is left alone', () {
    final spans = buildMessageSpans('just words here', _styles);
    expect(_plain(spans), 'just words here');
    expect(_leaves(spans).every((s) => s.style?.fontWeight == null), isTrue);
  });

  test('**bold** is bold and takes the emphasis colour', () {
    final spans = buildMessageSpans('a **strong** b', _styles);
    final bold = _spanWith(spans, 'strong');
    expect(bold.style?.fontWeight, FontWeight.bold);
    expect(bold.style?.color, _emphasis);
    expect(_plain(spans), 'a strong b'); // markers consumed
  });

  test('*italic* is italic', () {
    final spans = buildMessageSpans('an *emphasised* word', _styles);
    final it = _spanWith(spans, 'emphasised');
    expect(it.style?.fontStyle, FontStyle.italic);
    expect(it.style?.color, _emphasis);
  });

  test('***both*** is bold and italic', () {
    final spans = buildMessageSpans('***wow***', _styles);
    final s = _spanWith(spans, 'wow');
    expect(s.style?.fontWeight, FontWeight.bold);
    expect(s.style?.fontStyle, FontStyle.italic);
  });

  test('`code` uses the code background', () {
    final spans = buildMessageSpans('run `flutter test` now', _styles);
    final code = _spanWith(spans, 'flutter test');
    expect(code.style?.backgroundColor, _codeBg);
  });

  test('"quoted" text takes the quote colour, marks included', () {
    final spans = buildMessageSpans('she said "hello" then', _styles);
    final inner = _spanWith(spans, 'hello');
    expect(inner.style?.color, _quote);
    // The opening quote mark is coloured too.
    expect(_leaves(spans).any((s) => s.text == '"' && s.style?.color == _quote),
        isTrue);
  });

  test('headings are bold and larger', () {
    final spans = buildMessageSpans('# Title', _styles);
    final t = _spanWith(spans, 'Title');
    expect(t.style?.fontWeight, FontWeight.bold);
    expect(t.style!.fontSize! > 16, isTrue);
  });

  test('bullet lines get a bullet glyph', () {
    final spans = buildMessageSpans('- first\n- second', _styles);
    expect(_plain(spans).contains('•'), isTrue);
    expect(_plain(spans).contains('first'), isTrue);
  });

  test('snake_case is not treated as emphasis', () {
    final spans = buildMessageSpans('call foo_bar_baz please', _styles);
    expect(_plain(spans), 'call foo_bar_baz please');
    expect(_leaves(spans).every((s) => s.style?.fontStyle == null), isTrue);
  });

  test('a lone asterisk with spaces is literal', () {
    final spans = buildMessageSpans('2 * 3 = 6', _styles);
    expect(_plain(spans), '2 * 3 = 6');
    expect(_leaves(spans).every((s) => s.style?.fontStyle == null), isTrue);
  });

  test('an unmatched marker stays literal', () {
    final spans = buildMessageSpans('**oops no close', _styles);
    expect(_plain(spans), '**oops no close');
  });

  test('<b> renders bold with the emphasis colour', () {
    final spans = buildMessageSpans('a <b>strong</b> b', _styles);
    final b = _spanWith(spans, 'strong');
    expect(b.style?.fontWeight, FontWeight.bold);
    expect(b.style?.color, _emphasis);
    expect(_plain(spans), 'a strong b');
  });

  test('<i>/<em> render italic and <code> uses the code background', () {
    expect(_spanWith(buildMessageSpans('<i>x</i>', _styles), 'x').style?.fontStyle,
        FontStyle.italic);
    expect(
        _spanWith(buildMessageSpans('<code>y</code>', _styles), 'y')
            .style
            ?.backgroundColor,
        _codeBg);
  });

  test('<a> is a link colour and underlined', () {
    final spans = buildMessageSpans('see <a href="http://x">here</a>', _styles);
    final a = _spanWith(spans, 'here');
    expect(a.style?.color, _link);
    expect(a.style?.decoration, TextDecoration.underline);
  });

  test('<q> colours the quote and adds marks', () {
    final spans = buildMessageSpans('<q>hi</q>', _styles);
    expect(_spanWith(spans, 'hi').style?.color, _quote);
    expect(_plain(spans), '“hi”');
  });

  test('<br> and <p> become line breaks', () {
    expect(_plain(buildMessageSpans('a<br>b', _styles)), 'a\nb');
    final paras = buildMessageSpans('<p>one</p><p>two</p>', _styles);
    expect(_plain(paras).contains('one'), isTrue);
    expect(_plain(paras).contains('two'), isTrue);
    expect(_plain(paras).contains('\n'), isTrue);
  });

  test('<ul>/<li> become bullets', () {
    final spans = buildMessageSpans('<ul><li>a</li><li>b</li></ul>', _styles);
    expect(_plain(spans).contains('•'), isTrue);
    expect(_plain(spans).contains('a'), isTrue);
    expect(_plain(spans).contains('b'), isTrue);
  });

  test('HTML entities are decoded', () {
    expect(_plain(buildMessageSpans('a &amp; b &lt;x&gt; &#65;', _styles)),
        'a & b <x> A');
  });

  test('an unknown tag is left literal, as is a bare <', () {
    expect(_plain(buildMessageSpans('<foo>bar</foo>', _styles)),
        '<foo>bar</foo>');
    expect(_plain(buildMessageSpans('3 < 5 and x<y', _styles)), '3 < 5 and x<y');
  });

  test('nested markdown inside HTML still parses', () {
    final spans = buildMessageSpans('<b>very *very* bold</b>', _styles);
    final inner = _spanWith(spans, 'very');
    // The italic run keeps bold from the wrapper and adds italic.
    expect(inner.style?.fontStyle, FontStyle.italic);
    expect(inner.style?.fontWeight, FontWeight.bold);
  });

  test('italic wrapping a nested bold parses both, no dangling markers', () {
    final spans = buildMessageSpans('*Note **important** here*', _styles);
    expect(_spanWith(spans, 'Note ').style?.fontStyle, FontStyle.italic);
    expect(_spanWith(spans, 'important').style?.fontWeight, FontWeight.bold);
    // No stray markers left in the output.
    expect(_plain(spans).contains('*'), isFalse);
  });

  test('inline `code` is verbatim — entities are not decoded inside it', () {
    final spans = buildMessageSpans('`a &amp; b`', _styles);
    expect(_spanWith(spans, 'a &amp; b').style?.backgroundColor, _codeBg);
  });

  test('HTML shown inside inline code survives preprocessing', () {
    final spans = buildMessageSpans('Use the `<div>` tag', _styles);
    // The <div> is rendered as literal code, not turned into a line break.
    expect(_spanWith(spans, '<div>').style?.backgroundColor, _codeBg);
    expect(_plain(spans).contains('<div>'), isTrue);
  });

  test('<ol> renders numbered items', () {
    final spans = buildMessageSpans('<ol><li>a</li><li>b</li></ol>', _styles);
    final plain = _plain(spans);
    expect(plain.contains('1.'), isTrue);
    expect(plain.contains('2.'), isTrue);
  });

  test('an out-of-range numeric entity does not crash', () {
    // String.fromCharCode would throw above 0x10FFFF; it must be left literal.
    final spans = buildMessageSpans('oops &#9999999; and &#x110000; here', _styles);
    expect(_plain(spans).contains('oops'), isTrue);
    expect(_plain(spans).contains('here'), isTrue);
  });

  test('pathologically deep nesting is bounded, not a crash/hang', () {
    final deep = '${'<b>' * 200}x${'</b>' * 200}';
    final spans = buildMessageSpans(deep, _styles);
    expect(_plain(spans).contains('x'), isTrue);
  });
}
