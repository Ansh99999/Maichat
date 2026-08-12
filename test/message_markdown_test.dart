import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/widgets/message_markdown.dart';

const _emphasis = Color(0xFFFF0000);
const _quote = Color(0xFF0000FF);
const _codeBg = Color(0xFF222222);

const _styles = MarkdownStyles(
  base: TextStyle(color: Color(0xFF000000), fontSize: 16, height: 1.35),
  emphasis: _emphasis,
  quote: _quote,
  codeBackground: _codeBg,
  codeForeground: Color(0xFF000000),
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
}
