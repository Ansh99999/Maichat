import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/screens/chat_screen.dart';
import 'package:maichat/state/app_state.dart';
import 'package:maichat/widgets/message_bubble.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A chat must open on its newest message, not its oldest, and offer a
/// jump-to-latest button once it is scrolled well back. The thread is a
/// *reversed* list — the newest turn sits at scroll offset 0 and older turns lie
/// at greater offsets — so "at the bottom" means `pixels ≈ 0`. Opening at the
/// top with no way down but dragging shipped once; these drive the real
/// [ChatScreen] and assert against the scroll offset.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  /// A chat seeded with enough turns to overflow the viewport several times, so
  /// there is a real bottom to be pinned to and scrolled away from.
  Future<AppState> longChat({int turns = 80}) async {
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
    await tester.pump(); // first frame
    await tester.pump(const Duration(milliseconds: 250));

    final position = scroll(tester);
    expect(position.maxScrollExtent, greaterThan(0),
        reason: 'the thread must be taller than the viewport to have history');
    expect(position.pixels, moreOrLessEquals(0, epsilon: 1),
        reason: 'a reversed thread opens at offset 0 — the newest message');
  });

  testWidgets('a huge chat opens without building every message', (tester) async {
    // The crash this guards: a forward list jumped to its bottom makes
    // RenderSliverList build all N turns in one pass. Reversed, only a
    // viewport-worth are ever built, so a 600-turn thread opens like a small one.
    final state = await longChat(turns: 600);

    await tester.pumpWidget(host(state));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(scroll(tester).pixels, moreOrLessEquals(0, epsilon: 1));
    final built = find.byType(MessageBubble).evaluate().length;
    expect(built, lessThan(40),
        reason: 'only the visible turns should be built, not all 600 '
            '(was $built)');
  });

  testWidgets('the jump-to-latest button appears only when scrolled back, and '
      'returns to the bottom', (tester) async {
    final state = await longChat();

    await tester.pumpWidget(host(state));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    // Opened at the newest turn: nothing to jump to.
    expect(jumpButtonVisible(tester), isFalse);

    // Scroll back into older turns (away from offset 0).
    scroll(tester).jumpTo(1000);
    await tester.pump();

    expect(scroll(tester).pixels, greaterThan(320),
        reason: 'we should now sit well above the newest message');
    expect(jumpButtonVisible(tester), isTrue);

    // Tapping the button glides back to the newest message.
    await tester.tap(find.byIcon(Icons.arrow_downward));
    await tester.pumpAndSettle();

    expect(scroll(tester).pixels, moreOrLessEquals(0, epsilon: 1));
    expect(jumpButtonVisible(tester), isFalse);
  });
}
