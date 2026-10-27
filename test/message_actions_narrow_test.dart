import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/chat_interface.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/widgets/message_bubble.dart';

void main() {
  testWidgets('compact action bar wraps and still dispatches actions', (
    tester,
  ) async {
    MessageAction? action;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 120,
            child: ListView(
              children: [
                MessageBubble(
                  message: ChatMessage(role: 'assistant', content: 'Hi.'),
                  ui: const ChatInterface(),
                  onAction: (value) => action = value,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Regenerate'));
    expect(action, MessageAction.regenerate);
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    expect(find.text('Copy'), findsOneWidget);
  });
  for (final width in [320.0, 800.0]) {
    for (final placement in TextPlacement.values) {
      for (final name in NamePosition.values) {
        for (final bar in ActionBarPlacement.values) {
          for (final avatar in [false, true]) {
            testWidgets(
              '$width ${placement.name} ${name.name} ${bar.name} avatar=$avatar',
              (tester) async {
                await tester.pumpWidget(
                  MaterialApp(
                    home: Scaffold(
                      body: Align(
                        alignment: Alignment.topLeft,
                        child: SizedBox(
                          width: width,
                          child: ListView(
                            children: [
                              for (final role in ['user', 'assistant'])
                                MessageBubble(
                                  message: ChatMessage(
                                    role: role,
                                    content: 'A short reply.',
                                  ),
                                  ui: ChatInterface(
                                    textPlacement: placement,
                                    actionBarPlacement: bar,
                                    showNames: true,
                                    userNameStyle: NameStyle(position: name),
                                    botNameStyle: NameStyle(position: name),
                                    userAvatar: AvatarStyle(
                                      show: avatar,
                                      size: 48,
                                    ),
                                    botAvatar: AvatarStyle(
                                      show: avatar,
                                      size: 48,
                                    ),
                                  ),
                                  onAction: (_) {},
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                );
                expect(tester.takeException(), isNull);
                await tester.pump();
                expect(find.byTooltip('More').hitTestable(), findsNWidgets(2));
              },
            );
          }
        }
      }
    }
  }
}
