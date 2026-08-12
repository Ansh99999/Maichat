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
}
