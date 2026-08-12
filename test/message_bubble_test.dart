import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/chat_interface.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/widgets/message_bubble.dart';

void main() {
  Widget host(Widget child) => MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 400, height: 800, child: child),
        ),
      );

  // Every placement × bubble mode should lay out without throwing (guards the
  // Row/Column/WidgetSpan layout and the flat-vs-bubble branches).
  for (final placement in TextPlacement.values) {
    for (final bubbles in [true, false]) {
      testWidgets('renders ${placement.name} placement, bubbles=$bubbles',
          (tester) async {
        await tester.pumpWidget(host(
          ListView(
            children: [
              MessageBubble(
                message: ChatMessage(role: 'assistant', content: 'Hello there'),
                ui: ChatInterface(textPlacement: placement, bubbles: bubbles),
              ),
              MessageBubble(
                message: ChatMessage(role: 'user', content: 'Hi back'),
                ui: ChatInterface(textPlacement: placement, bubbles: bubbles),
              ),
            ],
          ),
        ));
        expect(tester.takeException(), isNull);
        expect(find.byType(MessageBubble), findsNWidgets(2));
      });
    }
  }

  // Names stacked with the avatar (above/below) must lay out in every
  // placement, both with the avatar shown and hidden.
  for (final position in NamePosition.values) {
    for (final show in [true, false]) {
      testWidgets('renders name ${position.name}, avatar=$show',
          (tester) async {
        await tester.pumpWidget(host(
          ListView(
            children: [
              for (final placement in TextPlacement.values)
                MessageBubble(
                  message: ChatMessage(role: 'assistant', content: 'Hi'),
                  ui: ChatInterface(
                    textPlacement: placement,
                    showNames: true,
                    botNamePosition: position,
                    botAvatar: AvatarStyle(show: show, side: ChatSide.left),
                  ),
                ),
            ],
          ),
        ));
        expect(tester.takeException(), isNull);
        expect(find.text('Assistant'), findsNWidgets(TextPlacement.values.length));
      });
    }
  }

  testWidgets('interactive avatar reports drag and resize deltas',
      (tester) async {
    Offset? drag;
    double? resize;
    await tester.pumpWidget(host(
      MessageBubble(
        message: ChatMessage(role: 'assistant', content: 'Drag me'),
        ui: const ChatInterface(
          botAvatar: AvatarStyle(size: 60, side: ChatSide.left),
        ),
        interactive: true,
        onAvatarDrag: (d) => drag = d,
        onAvatarResize: (d) => resize = d,
      ),
    ));

    // Dragging the avatar body reports a movement delta.
    await tester.drag(
      find.byIcon(Icons.smart_toy_outlined),
      const Offset(28, 18),
    );
    await tester.pump();
    expect(drag, isNotNull);

    // Dragging the corner handle reports a resize delta.
    await tester.drag(find.byIcon(Icons.open_in_full), const Offset(24, 24));
    await tester.pump();
    expect(resize, isNotNull);
  });

  group('message action bar', () {
    Widget bubble({
      required bool isUser,
      void Function(MessageAction)? onAction,
      bool streaming = false,
      ChatInterface? ui,
    }) =>
        host(ListView(children: [
          MessageBubble(
            message: ChatMessage(
                role: isUser ? 'user' : 'assistant', content: 'Hi'),
            ui: ui ?? const ChatInterface(),
            onAction: onAction,
            streaming: streaming,
          ),
        ]));

    testWidgets('renders the configured inline actions for a bot turn',
        (tester) async {
      MessageAction? got;
      await tester.pumpWidget(bubble(isUser: false, onAction: (a) => got = a));
      expect(find.byIcon(Icons.refresh), findsOneWidget); // regenerate
      expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
      expect(find.byIcon(Icons.delete_outline), findsOneWidget);
      expect(find.byIcon(Icons.more_vert), findsOneWidget); // overflow

      await tester.tap(find.byIcon(Icons.refresh));
      expect(got, MessageAction.regenerate);
    });

    testWidgets('hides regenerate on a user turn', (tester) async {
      await tester.pumpWidget(bubble(isUser: true, onAction: (_) {}));
      expect(find.byIcon(Icons.refresh), findsNothing);
      expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
      expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    });

    testWidgets('overflow menu exposes the menu actions', (tester) async {
      MessageAction? got;
      await tester.pumpWidget(bubble(isUser: false, onAction: (a) => got = a));
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(find.text('Copy'), findsOneWidget);
      expect(find.text('Fork'), findsOneWidget);
      expect(find.text('View prompt'), findsOneWidget);
      expect(find.text('Info'), findsOneWidget);

      await tester.tap(find.text('View prompt'));
      await tester.pumpAndSettle();
      expect(got, MessageAction.prompt);
    });

    testWidgets('mutating actions are disabled while streaming',
        (tester) async {
      await tester.pumpWidget(
          bubble(isUser: false, onAction: (_) {}, streaming: true));
      final regen = tester.widget<IconButton>(
        find.ancestor(
          of: find.byIcon(Icons.refresh),
          matching: find.byType(IconButton),
        ),
      );
      expect(regen.onPressed, isNull);
    });

    testWidgets('no bar without a dispatcher or when disabled', (tester) async {
      await tester.pumpWidget(bubble(isUser: false)); // onAction null
      expect(find.byIcon(Icons.refresh), findsNothing);
      expect(find.byIcon(Icons.more_vert), findsNothing);

      await tester.pumpWidget(bubble(
        isUser: false,
        onAction: (_) {},
        ui: const ChatInterface(messageActionsEnabled: false),
      ));
      expect(find.byIcon(Icons.refresh), findsNothing);
      expect(find.byIcon(Icons.more_vert), findsNothing);
    });
  });
}
