import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/chat_interface.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/widgets/message_bubble.dart';
import 'package:maichat/widgets/message_html.dart';

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
    test('wraps "quoted" spans in <q>', () {
      expect(messageToHtml('she said "hello" now'), contains('<q>hello</q>'));
    });
    test('builds tables from markdown', () {
      final html = messageToHtml('| a | b |\n|---|---|\n| 1 | 2 |');
      expect(html, contains('<table>'));
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
}
