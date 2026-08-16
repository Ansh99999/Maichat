import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/chat_interface.dart';
import 'package:maichat/screens/chat_screen.dart';
import 'package:maichat/state/app_state.dart';
import 'package:maichat/widgets/message_bubble.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Settings that belong to one chat have to actually reach that chat's screen —
/// storing them is the easy half. This drives the real [ChatScreen].
void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  Future<AppState> chat() async {
    final state = AppState();
    // The chat screen holds a startup gate until the store has been read.
    await state.init();
    final character = Character.empty()
      ..name = 'Aria'
      ..firstMes = 'Evening.';
    await state.addCharacter(character);
    state.startChatWithCharacter(character);
    return state;
  }

  Widget host(AppState state) => ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: ChatScreen()),
      );

  ChatInterface bubbleUi(WidgetTester tester) =>
      tester.widget<MessageBubble>(find.byType(MessageBubble).first).ui;

  testWidgets('a chat with its own style is drawn with it, not the app-wide one',
      (tester) async {
    final state = await chat();
    await state.updateChatInterface(
      state.chatInterface.copyWith(fontSize: 13, showNames: false),
    );
    await state.saveChatInterfaceOverride(
      state.active.id,
      state.chatInterface.copyWith(fontSize: 25, showNames: true),
    );

    await tester.pumpWidget(host(state));
    await tester.pump();
    await tester.pump();

    expect(bubbleUi(tester).fontSize, 25);
    expect(bubbleUi(tester).showNames, isTrue);
  });

  testWidgets('dropping the override puts the chat back on the app-wide style',
      (tester) async {
    final state = await chat();
    await state.saveChatInterfaceOverride(
      state.active.id,
      state.chatInterface.copyWith(fontSize: 25),
    );
    await state.clearChatInterfaceOverride(state.active.id);

    await tester.pumpWidget(host(state));
    await tester.pump();
    await tester.pump();

    expect(bubbleUi(tester).fontSize, state.chatInterface.fontSize);
  });

  testWidgets('a background picture is drawn behind the thread, faded',
      (tester) async {
    final state = await chat();
    await state.setChatBackground(
      state.active.id,
      'https://example.com/bg.png',
      opacity: 0.3,
    );

    await tester.pumpWidget(host(state));
    await tester.pump();
    await tester.pump();

    final image = find.byType(Image);
    expect(image, findsOneWidget);
    expect(tester.widget<Image>(image).fit, BoxFit.cover);
    // The fade is the point: a photograph at full strength behind running text
    // cannot be read over.
    final opacity = find.ancestor(
      of: image,
      matching: find.byType(Opacity),
    );
    expect(tester.widget<Opacity>(opacity.first).opacity, 0.3);
  });

  testWidgets('no background means no picture layer at all', (tester) async {
    final state = await chat();
    await tester.pumpWidget(host(state));
    await tester.pump();
    await tester.pump();

    expect(find.byType(Image), findsNothing);
  });
}
