import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/text_wrap.dart';
import 'package:maichat/widgets/message_markdown.dart';

/// The composer's live formatter has one hard invariant: whatever it is given,
/// the visible text must come back **character for character**. It backs an
/// editable field, so a single dropped, added or reordered character desyncs
/// the caret from the glyphs. These tests hold that line across the whole grid
/// of markdown it recognises, and confirm the styling is actually applied.
void main() {
  const styles = MarkdownStyles(
    base: TextStyle(fontSize: 16, color: Color(0xFF000000)),
    emphasis: Color(0xFFAA0000),
    quote: Color(0xFF00AA00),
    codeBackground: Color(0xFF222222),
    codeForeground: Color(0xFFEEEEEE),
    link: Color(0xFF0000FF),
  );

  String rendered(String text, [MarkdownStyles s = styles]) =>
      TextSpan(children: buildComposerSpans(text, s)).toPlainText();

  // Flattens every leaf style, so a test can ask "is any run bold/italic/…".
  List<TextStyle> leafStyles(String text, [MarkdownStyles s = styles]) {
    final out = <TextStyle>[];
    void walk(InlineSpan span) {
      if (span is TextSpan) {
        if (span.text != null && span.text!.isNotEmpty && span.style != null) {
          out.add(span.style!);
        }
        for (final child in span.children ?? const <InlineSpan>[]) {
          walk(child);
        }
      }
    }

    for (final span in buildComposerSpans(text, s)) {
      walk(span);
    }
    return out;
  }

  setUp(clearMessageSpanCache);

  group('character preservation', () {
    const cases = <String>[
      '',
      'plain text with no markers',
      '**bold**',
      '*italic*',
      '***both***',
      '~~struck~~',
      '`code`',
      '"a quote"',
      '“smart quote”',
      'mix **bold** and *italic* and `code` and "quote" together',
      'nested **bold with *italic* inside**',
      'unterminated **bold that never closes',
      'a lone * asterisk and a stray ~ tilde',
      'snake_case_word stays literal',
      'trailing marker **',
      'emoji 🙂 and **bold 🎉**',
      'newlines\nkeep **their**\nplace',
    ];

    for (final input in cases) {
      test('reproduces ${input.isEmpty ? '<empty>' : jsonish(input)}', () {
        expect(rendered(input), input);
      });
    }

    test('a user wrap rule keeps its markers verbatim', () {
      const withWrap = MarkdownStyles(
        base: TextStyle(fontSize: 16, color: Color(0xFF000000)),
        emphasis: Color(0xFFAA0000),
        quote: Color(0xFF00AA00),
        codeBackground: Color(0xFF222222),
        codeForeground: Color(0xFFEEEEEE),
        link: Color(0xFF0000FF),
        wraps: [
          TextWrapRule(start: '<<', end: '>>', color: 0xFF3366CC),
        ],
      );
      const input = 'before <<wrapped content>> after';
      expect(rendered(input, withWrap), input);
    });

    test('a hide-markers wrap rule still keeps its markers in the composer', () {
      const hidden = MarkdownStyles(
        base: TextStyle(fontSize: 16, color: Color(0xFF000000)),
        emphasis: Color(0xFFAA0000),
        quote: Color(0xFF00AA00),
        codeBackground: Color(0xFF222222),
        codeForeground: Color(0xFFEEEEEE),
        link: Color(0xFF0000FF),
        wraps: [
          TextWrapRule(
              start: '::', end: '::', color: 0xFF3366CC, hideMarkers: true),
        ],
      );
      const input = 'say ::hidden:: here';
      // Hiding a character the controller still holds would move the caret, so
      // the composer keeps every marker even when the rendered bubble drops it.
      expect(rendered(input, hidden), input);
    });
  });

  group('styling is applied', () {
    test('bold gets a bold run', () {
      expect(
        leafStyles('a **bold** b').any((s) => s.fontWeight == FontWeight.bold),
        isTrue,
      );
    });

    test('italic gets an italic run', () {
      expect(
        leafStyles('a *it* b').any((s) => s.fontStyle == FontStyle.italic),
        isTrue,
      );
    });

    test('strike gets a line-through run', () {
      expect(
        leafStyles('a ~~no~~ b')
            .any((s) => s.decoration == TextDecoration.lineThrough),
        isTrue,
      );
    });

    test('code gets the monospace code colours', () {
      expect(
        leafStyles('a `x` b').any((s) =>
            s.fontFamily == 'monospace' && s.color == styles.codeForeground),
        isTrue,
      );
    });

    test('a quote is tinted with the quote colour', () {
      expect(
        leafStyles('say "hi" now').any((s) => s.color == styles.quote),
        isTrue,
      );
    });

    test('plain text is left in the base style', () {
      final only = leafStyles('nothing special here');
      expect(only, isNotEmpty);
      expect(only.every((s) => s.fontWeight != FontWeight.bold), isTrue);
      expect(only.every((s) => s.color == styles.base.color), isTrue);
    });
  });
}

/// A short readable label for a test name.
String jsonish(String s) => '"${s.length > 30 ? '${s.substring(0, 30)}…' : s}"';
