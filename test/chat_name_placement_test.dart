import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/chat_interface.dart';
import 'package:maichat/screens/chat_screen.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The settings preview and the real chat are not the same tree: the chat wires an
/// action bar per message and its avatars belong to a real character. Every name
/// placement bug so far has been invisible in the preview and obvious in the chat,
/// so this drives the actual [ChatScreen].
void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  Future<AppState> chatWith(ChatInterface ui) async {
    final state = AppState();
    // The chat screen holds a startup gate until the store has been read.
    await state.init();
    final character = Character.empty()
      ..name = 'Aria'
      ..firstMes = 'A greeting long enough to wrap onto a couple of lines so the '
          'bubble is taller than the avatar beside it.';
    await state.addCharacter(character);
    state.startChatWithCharacter(character);
    await state.updateChatInterface(ui);
    return state;
  }

  Widget host(AppState state) => ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: ChatScreen()),
      );

  Future<Rect> labelRect(WidgetTester tester, ChatInterface ui) async {
    final state = await chatWith(ui);
    await tester.pumpWidget(host(state));
    // Two frames: enough for the avatar's measured height to reach the label's
    // anchor. (Not pumpAndSettle — the chat's frosted menu button animates.)
    await tester.pump();
    await tester.pump();
    return tester.getRect(find.text('Aria').last);
  }

  const base = ChatInterface(
    showNames: true,
    textPlacement: TextPlacement.below,
    botNameStyle: NameStyle(position: NamePosition.below),
    botAvatar: AvatarStyle(size: 56, side: ChatSide.left),
  );

  testWidgets('a name nudge moves the label by exactly that much in a chat',
      (tester) async {
    final plain = await labelRect(tester, base);
    final small = await labelRect(
        tester, base.copyWith(botNameStyle: base.botNameStyle.copyWith(offsetY: 4)));
    final large = await labelRect(
        tester, base.copyWith(botNameStyle: base.botNameStyle.copyWith(offsetY: 80)));

    // 4 px means 4 px, and 80 px is a further 76 below it — not "somewhere at the
    // bottom" for both, which is what a guessed anchor produced.
    expect(small.top - plain.top, closeTo(4, 0.5));
    expect(large.top - plain.top, closeTo(80, 0.5));
  });

  testWidgets('the measured anchor settles instead of oscillating',
      (tester) async {
    final state = await chatWith(
        base.copyWith(botNameStyle: base.botNameStyle.copyWith(offsetY: 20)));
    await tester.pumpWidget(host(state));
    await tester.pump();
    await tester.pump();

    // Measuring the avatar rebuilds the turn once. If that rebuild changed the
    // measurement again the chat would repaint forever, so the position has to be
    // stable from here on.
    final settled = tester.getRect(find.text('Aria').last);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(tester.getRect(find.text('Aria').last), settled);
  });

  testWidgets('the label sits under the avatar, action bar and all',
      (tester) async {
    final state = await chatWith(base);
    await tester.pumpWidget(host(state));
    await tester.pump();
    await tester.pump();

    final avatar = tester.getRect(find.byType(Image).evaluate().isEmpty
        ? find.text('A').first // monogram avatar
        : find.byType(Image).first);
    final label = tester.getRect(find.text('Aria').last);
    expect(label.top, greaterThan(avatar.top));
  });

  testWidgets('the same holds with the action bar hanging under the avatar',
      (tester) async {
    final withBar =
        base.copyWith(actionBarPlacement: ActionBarPlacement.besideAvatar);
    final plain = await labelRect(tester, withBar);
    final nudged = await labelRect(tester,
        withBar.copyWith(botNameStyle: withBar.botNameStyle.copyWith(offsetY: 25)));
    expect(nudged.top - plain.top, closeTo(25, 0.5));
  });
}
