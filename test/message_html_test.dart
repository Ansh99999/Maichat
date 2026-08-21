import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/chat_interface.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/widgets/message_bubble.dart';
import 'package:maichat/widgets/message_html.dart';
import 'package:maichat/widgets/thinking_block.dart';

void main() {
  group('looksLikeHtml', () {
    test('detects real tags', () {
      expect(looksLikeHtml('<div>hi</div>'), isTrue);
      expect(looksLikeHtml('a <b>bold</b> word'), isTrue);
      expect(looksLikeHtml('<img src="x.png">'), isTrue);
    });
    test('ignores plain text and comparisons', () {
      expect(looksLikeHtml('just some words'), isFalse);
      expect(looksLikeHtml('2 < 3 and 4 > 1'), isFalse);
      expect(looksLikeHtml('score: 3<5'), isFalse);
    });
  });

  group('messageToHtml', () {
    test('converts markdown emphasis', () {
      expect(messageToHtml('**bold**'), contains('<strong>'));
      expect(messageToHtml('*italic*'), contains('<em>'));
    });
    test('passes raw HTML through', () {
      expect(messageToHtml('<b>x</b>'), contains('<b>'));
    });
    test('wraps "quoted" spans in <q>, marks kept', () {
      // flutter_html has no q::before/::after, so the marks have to be in the
      // element or they vanish from the message.
      expect(messageToHtml('she said "hello" now'), contains('<q>"hello"</q>'));
    });
    test('builds tables from markdown', () {
      final html = messageToHtml('| a | b |\n|---|---|\n| 1 | 2 |');
      expect(html, contains('<table>'));
    });
  });

  group('text wrapping rules', () {
    const yellow = TextWrapRule(start: '<', end: '>', color: 0xFFFFCC00);

    test('a hidden-marker rule becomes a coloured span, markers dropped', () {
      final html = messageToHtml('he was <furious> then', wraps: [yellow]);
      expect(html, contains("<span style='color: #ffcc00'>furious</span>"));
      expect(html, isNot(contains('&lt;furious&gt;')));
    });

    test('a shown-marker rule keeps its markers, escaped', () {
      final html = messageToHtml('he was <furious> then',
          wraps: [yellow.copyWith(hideMarkers: false)]);
      expect(html, contains('&lt;furious&gt;'));
    });

    test('markdown inside a wrapped run still renders', () {
      final html = messageToHtml('<a *very* bad idea>', wraps: [yellow]);
      expect(html, contains('<em>very</em>'));
    });

    test('rules do not touch code runs', () {
      final html = messageToHtml('use `<div>` here', wraps: [yellow]);
      expect(html, contains('&lt;div&gt;'));
      expect(html, isNot(contains("color: #ffcc00")));
    });

    test('a rule with no colour just hides its markers', () {
      final html = messageToHtml('a <b c> d',
          wraps: [const TextWrapRule(start: '<', end: '>')]);
      expect(html, contains('a b c d'));
      expect(html, isNot(contains('<span')));
    });

    test('an unmatched opener is left as typed', () {
      expect(messageToHtml('5 < 7 always', wraps: [yellow]),
          isNot(contains('<span')));
    });

    test('an invalid rule is ignored', () {
      const empty = TextWrapRule(start: '', end: '>');
      expect(empty.isValid, isFalse);
      expect(applyWrapRules('anything at all', const [empty]),
          'anything at all');
    });

    test('nested rules both apply', () {
      final html = messageToHtml('<outer (inner) done>', wraps: [
        yellow,
        const TextWrapRule(start: '(', end: ')', color: 0xFF00FF00),
      ]);
      expect(html, contains('#ffcc00'));
      expect(html, contains('#00ff00'));
    });

    test('a run crossing a blank line is left alone', () {
      final html = messageToHtml('<one\n\ntwo>', wraps: [yellow]);
      expect(html, isNot(contains('#ffcc00')));
    });

    test('a single-quote rule does not repaint ordinary prose', () {
      const single = TextWrapRule(start: "'", end: "'", color: 0xFF0000FF);
      final html = messageToHtml(
        'She said "hello there" and it\'s fine, isn\'t it?',
        wraps: const [single],
      );
      // The contractions are punctuation, not delimiters…
      expect(html, isNot(contains('<span')));
      // …and the quoted run is still the quoted run.
      expect(html, contains('<q>"hello there"</q>'));
    });

    test('a single-quoted phrase is still wrapped', () {
      const single = TextWrapRule(start: "'", end: "'", color: 0xFF0000FF);
      expect(messageToHtml("she thought 'not again' then", wraps: const [single]),
          contains("<span style='color: #0000ff'>not again</span>"));
    });
  });

  group('MessageBubble routing', () {
    Widget host(Widget child) => MaterialApp(
          home: Scaffold(body: SizedBox(width: 400, height: 800, child: child)),
        );

    const style = HtmlMessageStyle(
      base: Color(0xFF000000),
      emphasis: Color(0xFFFF0000),
      quote: Color(0xFF0000FF),
      codeBackground: Color(0xFF222222),
      codeForeground: Color(0xFFFFFFFF),
      link: Color(0xFF00AAFF),
      fontSize: 16,
    );

    testWidgets('an HTML message renders via the full engine', (tester) async {
      await tester.pumpWidget(host(
        MessageBubble(
          message: ChatMessage(
              role: 'assistant', content: '<b>Hi</b> <i>there</i> and a table'),
          ui: const ChatInterface(),
        ),
      ));
      expect(tester.takeException(), isNull);
      expect(find.byType(Html), findsOneWidget);
    });

    testWidgets('a plain markdown message stays on the inline renderer',
        (tester) async {
      await tester.pumpWidget(host(
        MessageBubble(
          message: ChatMessage(role: 'assistant', content: 'just **bold** here'),
          ui: const ChatInterface(),
        ),
      ));
      expect(tester.takeException(), isNull);
      expect(find.byType(Html), findsNothing);
      expect(find.byType(SelectableText), findsOneWidget);
    });

    testWidgets('buildMessageHtml renders standalone without error',
        (tester) async {
      await tester.pumpWidget(host(
        buildMessageHtml('<p>Hello <b>world</b></p><ul><li>one</li></ul>', style),
      ));
      expect(tester.takeException(), isNull);
      expect(find.byType(Html), findsOneWidget);
    });
  });

  group('stripReasoningWrappers', () {
    test('drops <thinking> and <antthinking> blocks, keeps the reply', () {
      const raw = '<thinking>plan the scene, decide the beat</thinking>'
          '<antthinking>secret</antthinking>The door creaked open.';
      final out = stripReasoningWrappers(raw);
      expect(out, 'The door creaked open.');
    });

    test('leaves the app\'s own <think> reasoning tag alone', () {
      // <think> is stripped upstream by splitReasoning, not here; and it must
      // not be confused with the <thinking> wrapper.
      const raw = '<think>quick</think>hello';
      expect(stripReasoningWrappers(raw), contains('<think>quick</think>'));
    });

    test('plain prose is untouched', () {
      expect(stripReasoningWrappers('just talking'), 'just talking');
    });
  });

  group('tameRichCss on a real model card', () {
    const style = HtmlMessageStyle(
      base: Color(0xFFE6E6E6),
      emphasis: Color(0xFFB0A0FF),
      quote: Color(0xFF80C0FF),
      codeBackground: Color(0xFF1E1E1E),
      codeForeground: Color(0xFFE6E6E6),
      link: Color(0xFF80C0FF),
      fontSize: 16,
    );
    final card =
        File('test/fixtures/styled_card_message.txt').readAsStringSync();
    final html = messageToHtml(card);

    test('the full-bleed dark backdrop band is dropped', () {
      // The outer flex wrapper's near-black background is the "big black
      // section"; it must not survive.
      expect(html, isNot(contains('#0a0a0a')));
      expect(html.toLowerCase(), isNot(contains('display: flex')));
      expect(html.toLowerCase(), isNot(contains('display:flex')));
    });

    test('the inner card keeps its own palette so it still reads as a card', () {
      expect(html, contains('#1a1010')); // its background
      expect(html, contains('#4a0000')); // its border colour
      expect(html, contains('#cc9999')); // its text colour
    });

    test('properties flutter_html cannot draw are stripped', () {
      expect(html.toLowerCase(), isNot(contains('box-shadow')));
      expect(RegExp(r'[\d.]+\s*rem').hasMatch(html), isFalse,
          reason: 'rem sizes must be converted to px');
    });

    test('text-transform is applied to the text itself', () {
      expect(html, contains('DAY NINETY-FOUR'));
    });

    test('leaked reasoning wrappers are gone', () {
      expect(html.toLowerCase(), isNot(contains('<thinking')));
      expect(html.toLowerCase(), isNot(contains('antthinking')));
    });

    testWidgets('renders the card without throwing and shows its content',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 2000,
            child: SingleChildScrollView(child: buildMessageHtml(card, style)),
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
      expect(find.byType(Html), findsOneWidget);
      expect(find.textContaining('DAY NINETY-FOUR'), findsOneWidget);
    });
  });

  group('a thinking + HTML-card turn', () {
    Widget host(Widget child) => MaterialApp(
          home: Scaffold(body: SizedBox(width: 400, height: 900, child: child)),
        );

    testWidgets('shows the "Thought for" bar above the rendered card',
        (tester) async {
      await tester.pumpWidget(host(
        SingleChildScrollView(
          child: MessageBubble(
            message: ChatMessage(
              role: 'assistant',
              content:
                  '<div style="background-color:#1a1010; border:2px solid #4a0000; '
                  'width:200px; color:#cc9999;">A Card</div>\n\nAnd a reply.',
              reasoning: 'I considered the options.',
              thinkingMs: 4200,
            ),
            ui: const ChatInterface(),
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
      // The thinking disclosure is present…
      expect(find.byType(ThinkingBlock), findsOneWidget);
      expect(find.textContaining('Thought for'), findsOneWidget);
      // …and the card renders through the HTML engine, not as a black slate.
      expect(find.byType(Html), findsOneWidget);
      expect(find.textContaining('A Card'), findsOneWidget);
    });
  });
}
