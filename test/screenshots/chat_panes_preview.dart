// flutter test test/screenshots/chat_panes_preview.dart --update-goldens
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/main.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/conversation.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/screens/chat_screen.dart';
import 'package:maichat/services/btw.dart';
import 'package:maichat/services/chat_client.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'shot.dart';

class _PreviewState extends AppState {
  @override
  bool get isConfigured => true;

  @override
  Future<String> askAside(
    String question, {
    Conversation? conversation,
    List<ChatMessage> sideHistory = const [],
    ChatClient? client,
    BtwRun? run,
    void Function(String)? onProgress,
  }) async =>
      'Wren is Maren’s sister. She stayed at the old lighthouse while '
      'Maren came down to meet you at the harbour.\n\n'
      'You last heard from her in the letter with the blue seal.';
}

void main() {
  setUpAll(loadShotFonts);
  for (final view in ['btw-thread', 'chat-panes-wide', 'chat-menu-pane']) {
    testWidgets(view, (tester) async {
      usePhone(tester);
      addTearDown(() => debugDisableShadows = true);
      if (view == 'chat-panes-wide') {
        tester.view
          ..physicalSize = const Size(2560, 1600)
          ..devicePixelRatio = 2;
      }
      SharedPreferences.setMockInitialValues({});
      final state = _PreviewState();
      await tester.runAsync(state.init);
      final maren = Character(id: 'maren', name: 'Maren');
      await tester.runAsync(() => state.addCharacter(maren));
      state.startChatWithCharacter(maren);
      state.active.messages.addAll([
        ChatMessage(
          role: 'user',
          content: 'I unfold the letter. “Who sent this?”',
        ),
        ChatMessage(
          role: 'assistant',
          content:
              'Maren draws closer, a smile breaking through '
              'her worry. “My sister, Wren. She’s still at the lighthouse.”\n\n'
              'The blue wax seal catches the morning light. Beyond the harbour wall, '
              'gulls wheel over the quiet water. “She says she found something we need to see.”',
        ),
      ]);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme:
                MaiChatApp.themeFor(
                  null,
                  Brightness.light,
                  Colors.teal,
                  expressive: true,
                ).copyWith(
                  textTheme: shotTheme().textTheme,
                  primaryTextTheme: shotTheme().primaryTextTheme,
                ),
            home: const ChatScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (view == 'chat-menu-pane' || view == 'chat-panes-wide') {
        await tester.tap(find.byKey(chatMenuButtonKey));
        await tester.pumpAndSettle();
      }
      if (view != 'chat-menu-pane') {
        await tester.enterText(
          find.byKey(const Key('composer-field')),
          '/btw Who is Wren again?',
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('chat-ask-aside')));
        await tester.pumpAndSettle();
      }
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('../../docs/previews/$view.png'),
      );
      debugDisableShadows = true;
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    });
  }
}
