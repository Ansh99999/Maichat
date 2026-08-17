import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/chat_interface.dart';
import 'package:maichat/screens/chat_screen.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Drives the real [ChatScreen] to check the group bar wiring: the composer's
/// ⋮ opens the operations strip, its group symbol reveals the participant bar,
/// and the bar shows a chip per member plus its close control.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  Future<AppState> groupChat({bool enabled = true}) async {
    final state = AppState();
    await state.init();
    await state.updateChatInterface(
        ChatInterface(groupChatsEnabled: enabled));
    final alice = Character(id: 'alice', name: 'Alice', firstMes: 'Hi.');
    final bob = Character(id: 'bob', name: 'Bob');
    await state.addCharacter(alice);
    await state.addCharacter(bob);
    state.startChatWithCharacter(alice);
    await state.addParticipant(state.active.id, bob);
    return state;
  }

  Widget host(AppState state) => ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: ChatScreen()),
      );

  testWidgets('the group bar opens from the composer and lists members',
      (tester) async {
    final state = await groupChat();
    await tester.pumpWidget(host(state));
    await tester.pump();
    await tester.pump();

    // The operations button is present because group chats are enabled.
    expect(find.byKey(const Key('composer-ops-button')), findsOneWidget);
    await tester.tap(find.byKey(const Key('composer-ops-button')));
    await tester.pumpAndSettle();

    // The group operation symbol appears; tapping it (after the reveal has
    // settled, proving the animated strip does not clip its hit region) shows
    // the bar.
    expect(find.byIcon(Icons.groups_outlined), findsOneWidget);
    await tester.tap(find.byIcon(Icons.groups_outlined));
    await tester.pumpAndSettle();

    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('Add'), findsOneWidget);

    // The ✕ hides the bar again.
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.text('Bob'), findsNothing);
  });

  testWidgets('the operations button stays when group chats are switched off',
      (tester) async {
    final state = await groupChat(enabled: false);
    await tester.pumpWidget(host(state));
    await tester.pump();
    await tester.pump();

    // The button is a permanent home for per-chat actions, so it is here even
    // with the group feature off — but it offers no group operation.
    expect(find.byKey(const Key('composer-ops-button')), findsOneWidget);
    await tester.tap(find.byKey(const Key('composer-ops-button')));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.groups_outlined), findsNothing);
    expect(find.text('More actions coming soon'), findsOneWidget);
  });
}
