import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/chat_interface.dart';
import 'package:maichat/screens/settings/chat_interface_preview.dart';
import 'package:maichat/state/app_state.dart';
import 'package:maichat/widgets/message_bubble.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The preview is where avatars and name labels are positioned by hand, so the
/// drags have to survive the real page: a scrolling list, the provider round
/// trip, and the clamps.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  Widget host(AppState state) => ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: ChatInterfacePreviewPage()),
      );

  // The drawn label of the first mock turn. A nudged label leaves an invisible
  // placeholder in its original slot, so the drawn one is the later match.
  Finder firstName() => find
      .descendant(
        of: find.byType(MessageBubble).first,
        matching: find.text('Aria'),
      )
      .last;

  testWidgets('dragging a name label moves it and keeps moving it',
      (tester) async {
    final state = AppState();
    state.updateChatInterface(const ChatInterface(showNames: true));
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    await tester.drag(firstName(), const Offset(40, 45));
    await tester.pumpAndSettle();

    final moved = state.chatInterface.botNameStyle;
    expect(moved.offsetY, greaterThan(0), reason: 'dragged down');
    expect(moved.offsetX, greaterThan(0), reason: 'dragged right');
    // The user's own label is untouched while the two are independent.
    expect(state.chatInterface.userNameStyle.isNudged, isFalse);

    // Dragging again from its new spot keeps moving it — the label must not go
    // unreachable the moment it leaves its original slot, which is exactly what
    // a paint-only nudge did.
    await tester.drag(firstName(), const Offset(0, 30));
    await tester.pumpAndSettle();
    expect(state.chatInterface.botNameStyle.offsetY, greaterThan(moved.offsetY));
  });

  testWidgets('a name nudge stops at the bound rather than running away',
      (tester) async {
    final state = AppState();
    state.updateChatInterface(const ChatInterface(showNames: true));
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    for (var i = 0; i < 8; i++) {
      await tester.drag(firstName(), const Offset(0, 60));
      await tester.pumpAndSettle();
    }
    expect(state.chatInterface.botNameStyle.offsetY, kMaxNameOffset);
  });

  testWidgets('synced names move together', (tester) async {
    final state = AppState();
    state.updateChatInterface(
        const ChatInterface(showNames: true, syncNames: true));
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    await tester.drag(firstName(), const Offset(0, 45));
    await tester.pumpAndSettle();

    final bot = state.chatInterface.botNameStyle;
    expect(bot.offsetY, greaterThan(0));
    expect(state.chatInterface.userNameStyle.offsetY, bot.offsetY);
  });

  testWidgets('dragging works with the avatar above the text too',
      (tester) async {
    final state = AppState();
    // The layout where the name lives inside the message column rather than in a
    // band around it — the one where a nudge used to be silently dropped, so
    // neither dragging nor the sliders did anything.
    state.updateChatInterface(const ChatInterface(
      showNames: true,
      textPlacement: TextPlacement.below,
      botNameStyle: NameStyle(position: NamePosition.below),
    ));
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    final before = tester.getRect(firstName());
    await tester.drag(firstName(), const Offset(0, 45));
    await tester.pumpAndSettle();

    expect(state.chatInterface.botNameStyle.offsetY, greaterThan(0));
    // And it actually moved on screen, not just in the settings.
    expect(tester.getRect(firstName()).top, greaterThan(before.top));
  });

  testWidgets('dragging an avatar still moves it', (tester) async {
    final state = AppState();
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    await tester.drag(find.byIcon(Icons.person).first, const Offset(10, 40));
    await tester.pumpAndSettle();
    expect(state.chatInterface.userAvatar.offsetY, greaterThan(0));
  });
}
