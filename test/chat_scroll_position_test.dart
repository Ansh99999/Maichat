import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/screens/chat_screen.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A chat must open on its newest message, not its oldest, and offer a
/// jump-to-latest button once it is scrolled well back. Both were shipped wrong
/// once (the thread opened at the top and there was no way down but dragging),
/// so these drive the real [ChatScreen] and assert against the scroll offset.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  /// A chat seeded with enough turns to overflow the viewport several times, so
  /// there is a real bottom to be pinned to and scrolled away from.
  Future<AppState> longChat({int turns = 40}) async {
    final state = AppState();
    await state.init();
    final character = Character.empty()
      ..name = 'Aria'
      ..firstMes = 'Evening.';
    await state.addCharacter(character);
    state.startChatWithCharacter(character);
    for (var i = 0; i < turns; i++) {
      state.active.messages.add(
        ChatMessage(
          role: i.isEven ? 'user' : 'assistant',
          content: 'Message number $i in a long conversation.',
        ),
      );
    }
    return state;
  }

  Widget host(AppState state) => ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: ChatScreen()),
      );

  /// The message thread's scroll controller position.
  ScrollPosition scroll(WidgetTester tester) =>
      tester.widget<ListView>(find.byType(ListView).first).controller!.position;

  /// Whether the jump-to-latest button is live (not ignoring pointers).
  bool jumpButtonVisible(WidgetTester tester) => !tester
      .widget<IgnorePointer>(
        find
            .ancestor(
              of: find.byIcon(Icons.arrow_downward),
              matching: find.byType(IgnorePointer),
            )
            .first,
      )
      .ignoring;

  testWidgets('a chat opens pinned to its newest message', (tester) async {
    final state = await longChat();

    await tester.pumpWidget(host(state));
    await tester.pump(); // first frame + the post-frame jump
    await tester.pump(const Duration(milliseconds: 250)); // the re-jump

    final position = scroll(tester);
    expect(position.maxScrollExtent, greaterThan(0),
        reason: 'the thread must be taller than the viewport to have a bottom');
    expect(position.pixels, moreOrLessEquals(position.maxScrollExtent, epsilon: 1),
        reason: 'the chat should open at the bottom, not the top');
  });

  testWidgets('the jump-to-latest button appears only when scrolled back, and '
      'returns to the bottom', (tester) async {
    final state = await longChat();

    await tester.pumpWidget(host(state));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    // Opened at the bottom: nothing to jump to.
    expect(jumpButtonVisible(tester), isFalse);

    // Drag the thread downwards to reveal earlier turns.
    await tester.drag(find.byType(ListView).first, const Offset(0, 1200));
    await tester.pump();

    expect(scroll(tester).pixels,
        lessThan(scroll(tester).maxScrollExtent - 320),
        reason: 'the drag should leave us well above the bottom');
    expect(jumpButtonVisible(tester), isTrue);

    // Tapping the button glides back to the newest message.
    await tester.tap(find.byIcon(Icons.arrow_downward));
    await tester.pumpAndSettle();

    final position = scroll(tester);
    expect(position.pixels, moreOrLessEquals(position.maxScrollExtent, epsilon: 1));
    expect(jumpButtonVisible(tester), isFalse);
  });
}
