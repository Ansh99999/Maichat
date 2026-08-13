import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/chat_interface.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/widgets/message_bubble.dart';
import 'package:maichat/widgets/thinking_block.dart';

/// The in-chat thinking disclosure: what the bar says, and that it opens and
/// shuts on tap.
void main() {
  Widget host(Widget child) => MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 400, height: 800, child: child),
        ),
      );

  ChatMessage thinker({
    String content = 'The answer.',
    String reasoning = 'Let me work through it.',
    int? thinkingMs = 12400,
  }) =>
      ChatMessage(
        role: 'assistant',
        content: content,
        reasoning: reasoning,
        thinkingMs: thinkingMs,
      );

  testWidgets('a turn with thinking gets a collapsed bar above the reply',
      (tester) async {
    await tester.pumpWidget(host(ListView(children: [
      MessageBubble(message: thinker(), ui: const ChatInterface()),
    ])));

    expect(find.byType(ThinkingBlock), findsOneWidget);
    expect(find.text('Thought for 12 seconds'), findsOneWidget);
    // Collapsed: the reasoning itself is not on screen yet.
    expect(find.text('Let me work through it.'), findsNothing);
    expect(find.text('The answer.'), findsOneWidget);
  });

  testWidgets('tapping the bar opens the thinking, tapping again shuts it',
      (tester) async {
    await tester.pumpWidget(host(ListView(children: [
      MessageBubble(message: thinker(), ui: const ChatInterface()),
    ])));

    await tester.tap(find.text('Thought for 12 seconds'));
    await tester.pumpAndSettle();
    expect(find.text('Let me work through it.'), findsOneWidget);

    await tester.tap(find.text('Thought for 12 seconds'));
    await tester.pumpAndSettle();
    expect(find.text('Let me work through it.'), findsNothing);
  });

  testWidgets('a turn without thinking gets no bar at all', (tester) async {
    await tester.pumpWidget(host(ListView(children: [
      MessageBubble(
        message: ChatMessage(role: 'assistant', content: 'Plain reply'),
        ui: const ChatInterface(),
      ),
    ])));

    expect(find.byType(ThinkingBlock), findsNothing);
  });

  testWidgets('thinking in progress reads as live and starts open',
      (tester) async {
    await tester.pumpWidget(host(ListView(children: [
      MessageBubble(
        message: thinker(content: '', thinkingMs: null),
        ui: const ChatInterface(),
        pending: true,
      ),
    ])));

    expect(find.text('Thinking…'), findsOneWidget);
    // Open while it happens, so the thinking is visible as it arrives.
    expect(find.text('Let me work through it.'), findsOneWidget);
  });

  testWidgets('thinking with no recorded duration still names itself',
      (tester) async {
    await tester.pumpWidget(host(ListView(children: [
      MessageBubble(
        message: thinker(thinkingMs: null),
        ui: const ChatInterface(),
      ),
    ])));

    expect(find.text('Thinking process'), findsOneWidget);
  });

  // The bar sits inside the message column, so it has to lay out under every
  // avatar/text arrangement.
  for (final placement in TextPlacement.values) {
    testWidgets('lays out with the ${placement.name} text placement',
        (tester) async {
      await tester.pumpWidget(host(ListView(children: [
        MessageBubble(
          message: thinker(),
          ui: ChatInterface(
            textPlacement: placement,
            showNames: true,
            botAvatar: const AvatarStyle(show: true),
          ),
        ),
      ])));

      expect(tester.takeException(), isNull);
      expect(find.byType(ThinkingBlock), findsOneWidget);
    });
  }
}
