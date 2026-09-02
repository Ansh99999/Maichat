import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/chat_interface.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/widgets/html_image.dart';
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

  group('quoted spans', () {
    const url = 'https://x.tld/a.png';

    test('a quoted run is tinted, and crosses emphasis inside it', () {
      expect(messageToHtml('she said "hello" now'), contains('<q>"hello"</q>'));
      // One quotation, even though markdown put a tag in the middle of it.
      expect(messageToHtml('she said "hello **there**" now'),
          contains('<q>"hello <strong>there</strong>"</q>'));
      expect(messageToHtml('she said “hello” now'), contains('<q>"hello"</q>'));
    });

    // The bug: `("[^"]+")` paired a quote in the prose with the next quote
    // anywhere in the document, and an HTML document is full of quotes that
    // belong to attributes. One `"` a model never closed therefore paired with
    // the `"` opening `src="…"` and put a `<q>` around half the tag — the
    // picture vanished and `" alt="` was left showing as text.
    test('an unclosed quote cannot reach into a tag', () {
      for (final content in [
        'She said "hello.\n\n![]($url)',
        'She said "hello.\n\n![stuff]($url)',
        '"a" and "b" and "c\n\n![]($url)',
      ]) {
        final html = messageToHtml(content);
        expect(html, contains('<img src="$url"'),
            reason: 'the picture survives: $content');
        expect(html, isNot(contains('alt="</q>')));
        expect(html, isNot(contains('src="</q>')));
        expect(html, isNot(contains(' alt=</q>')));
        expect(html, isNot(contains('<q>" alt="</q>')));
      }
    });

    test('a bare picture link survives an unclosed quote too', () {
      // This one used to lose the picture outright: the `<a>` the auto-linker
      // made was cut in half before anything could turn it into an `<img>`.
      final html = messageToHtml('She said "hello.\n\n$url');
      expect(html, contains('<img src="$url"'));
    });

    test('an unpaired quote is left as the character it is', () {
      final html = messageToHtml('She said "hello.');
      expect(html, contains('She said "hello.'));
      expect(html, isNot(contains('<q>')));
    });

    test('a run never straddles two blocks', () {
      // A `<q>` spanning `</p><p>` is unbalanced markup, and flutter_html then
      // draws every following paragraph inside the quotation.
      final html = messageToHtml('"one\n\ntwo"');
      expect(html, isNot(contains('<q>')));
      expect(html, contains('<p>"one</p>'));
    });

    test('a quote in code is part of the code', () {
      final html = messageToHtml('use `"quoted"` here');
      expect(html, contains('<code>'));
      expect(html, isNot(contains('<q>')));
    });

    test('an attribute holding a quote is left intact', () {
      // The old pass folded every `&quot;` in the document — including the ones
      // markdown had escaped inside an attribute — which broke the attribute.
      final html = messageToHtml('![say "hi"]($url)');
      expect(html, contains('alt="say &quot;hi&quot;"'));
      expect(html, contains('<img src="$url"'));
      // A creator's own markup keeps its attributes, and its prose still tints.
      final card = messageToHtml('<div class="card">She said "hi"</div>');
      expect(card, contains('<div class="card">'));
      expect(card, contains('<q>"hi"</q>'));
    });

    test('a quotation may hold a picture', () {
      // `<img>` is inline, so a run is allowed through it — the alternative is
      // losing the tint on every quotation a picture happens to sit inside.
      final html = messageToHtml('She said "look ![]($url) at it" now');
      expect(html, contains('<q>"look <img src="$url" alt="" /> at it"</q>'));
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
  group('a picture in a turn', () {
    Widget host(Widget child) => MaterialApp(
          home: Scaffold(body: SizedBox(width: 400, height: 900, child: child)),
        );

    test('a message carrying a picture is routed to the HTML engine', () {
      // The reported bug: the lightweight inline renderer builds InlineSpans and
      // has nowhere to put a bitmap, so a turn with a picture in it showed the
      // link's characters. Routing is the fix, so routing is what is pinned.
      expect(messageNeedsHtml('look ![](https://files.catbox.moe/a.png)'),
          isTrue);
      expect(messageNeedsHtml('here it is: https://files.catbox.moe/a.png'),
          isTrue);
      expect(messageNeedsHtml('<img src="https://x.tld/a.png">'), isTrue);
      // And nothing else is dragged onto the expensive path.
      expect(messageNeedsHtml('just talking'), isFalse);
      expect(messageNeedsHtml('read https://example.com/article'), isFalse);
      expect(messageNeedsHtml('the file is called photo.png'), isFalse);
    });

    test('a bare picture link becomes a picture, a labelled one stays a link',
        () {
      expect(messageToHtml('see https://files.catbox.moe/a.jpg'),
          contains('<img src="https://files.catbox.moe/a.jpg"'));
      expect(messageToHtml('![her portrait](https://x.tld/p.png)'),
          contains('<img src="https://x.tld/p.png"'));
      final labelled = messageToHtml('[full size](https://x.tld/p.png)');
      expect(labelled, contains('<a href="https://x.tld/p.png">full size</a>'));
      expect(labelled, isNot(contains('<img')));
    });

    test('a picture URL shown as code stays code', () {
      final html = messageToHtml('use `https://files.catbox.moe/a.png` here');
      expect(html, contains('<code>'));
      expect(html, isNot(contains('<img')));
    });

    testWidgets('a markdown picture in a turn draws an image, not its link',
        (tester) async {
      await tester.pumpWidget(host(
        SingleChildScrollView(
          child: MessageBubble(
            message: ChatMessage(
              role: 'assistant',
              content: 'Here she is:\n\n'
                  '![portrait](https://files.catbox.moe/abc.png)',
            ),
            ui: const ChatInterface(),
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
      expect(find.byType(Html), findsOneWidget);
      expect(find.byType(HtmlInlineImage), findsOneWidget,
          reason: 'through the shared cache, not a full-resolution fetch');
      expect(find.textContaining('files.catbox.moe'), findsNothing,
          reason: 'the link is the picture now, not text');
    });

    testWidgets('a bare picture link in a turn draws an image too',
        (tester) async {
      await tester.pumpWidget(host(
        SingleChildScrollView(
          child: MessageBubble(
            message: ChatMessage(
              role: 'assistant',
              content: 'https://files.catbox.moe/abc.png',
            ),
            ui: const ChatInterface(),
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.takeException(), isNull);
      expect(find.byType(HtmlInlineImage), findsOneWidget);
    });

    // `![](…)` is valid markdown — an empty description is the ordinary way to
    // write a picture that needs no label, and it is what models emit. It was
    // reported as not showing while `![something](…)` did, so both spellings are
    // pinned here, side by side, at every step they could diverge: the HTML,
    // the widget, and what is left when the picture cannot be fetched.
    group('an empty description draws the same picture as a named one', () {
      const url = 'https://files.catbox.moe/abc.png';

      test('the HTML differs only in the alt attribute', () {
        expect(messageToHtml('![]($url)'),
            contains('<img src="$url" alt="" />'));
        expect(messageToHtml('![stuff]($url)'),
            contains('<img src="$url" alt="stuff" />'));
        expect(messageNeedsHtml('![]($url)'), isTrue);
      });

      for (final (name, content) in [
        ('empty', '![]($url)'),
        ('named', '![stuff]($url)'),
        ('empty, in prose', 'Here you go.\n\n![]($url)'),
        ('empty, after dialogue', '*She smiles.* "Look."\n\n![]($url)'),
      ]) {
        testWidgets('$name reaches the picture widget', (tester) async {
          await tester.pumpWidget(host(
            SingleChildScrollView(
              child: MessageBubble(
                message: ChatMessage(role: 'assistant', content: content),
                ui: const ChatInterface(),
              ),
            ),
          ));
          await tester.pump(const Duration(milliseconds: 100));
          expect(tester.takeException(), isNull);
          expect(find.byType(HtmlInlineImage), findsOneWidget);
          expect(find.textContaining('files.catbox.moe'), findsNothing,
              reason: 'the link is the picture now, not text');
        });
      }

      // A picture that cannot be drawn must leave a mark whether or not the
      // author wrote a description. Returning an empty box for `![](…)` hid the
      // failure completely, which is the whole reason the markdown got blamed.
      for (final (name, alt) in [('no', ''), ('a', 'stuff')]) {
        testWidgets('a failed picture with $name description is still visible',
            (tester) async {
          await tester.pumpWidget(MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 300,
                  child: HtmlInlineImage(
                    src: 'https://x.tld/gone.png',
                    alt: alt,
                    declaredWidth: null,
                    color: const Color(0xFFFFFFFF),
                  ),
                ),
              ),
            ),
          ));
          // The mock HTTP client every widget test gets answers 400, so the
          // fetch fails for real rather than being simulated.
          await tester.pump(const Duration(milliseconds: 100));
          expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
          expect(
              tester.getSize(find.byType(HtmlInlineImage)).height, greaterThan(0));
          if (alt.isNotEmpty) expect(find.text(alt), findsOneWidget);
        });
      }
    });
  });
}
