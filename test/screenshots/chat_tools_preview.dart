// Generate previews explicitly; this file is intentionally outside the default suite.
// flutter test test/screenshots/chat_tools_preview.dart --update-goldens
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/main.dart';
import 'package:maichat/models/agent_message.dart';
import 'package:maichat/models/chat_tool.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/screens/chat_screen.dart';
import 'package:maichat/screens/settings/chat_tools_page.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'shot.dart';

void main() {
  setUpAll(loadShotFonts);
  for (final chat in [false, true]) {
    testWidgets(chat ? 'chat tool results preview' : 'tool settings preview', (
      tester,
    ) async {
      usePhone(tester);
      SharedPreferences.setMockInitialValues({});
      final state = AppState();
      await tester.runAsync(state.init);
      await tester.runAsync(
        () => state.saveChatToolConfig(const ChatToolConfig(enabled: true)),
      );
      const roll = ToolCall(
        id: 'roll',
        name: 'roll_dice',
        arguments: {'formula': '2d6+3'},
      );
      const tracker = ToolCall(
        id: 'health',
        name: 'define_tracker',
        arguments: {
          'id': 'health',
          'label': 'Health',
          'value': 72,
          'unit': '%',
        },
      );
      state.active.messages.addAll([
        ChatMessage(
          role: 'user',
          content:
              'I draw my sword and strike. Roll for the attack and track my health.',
        ),
        ChatMessage(
          role: 'assistant',
          content:
              'Your blade catches the bandit across the shoulder. He stumbles back, leaving the path to the bridge clear.',
          toolRun: ChatToolRun(
            id: 'preview',
            status: 'completed',
            history: [
              AgentMessage(
                role: AgentRole.assistant,
                toolCalls: const [roll, tracker],
              ),
              AgentMessage.toolResult(
                roll,
                '{"formula":"2d6+3","rolls":[4,4],"modifier":3,"total":11}',
              ),
              AgentMessage.toolResult(
                tracker,
                '{"id":"health","label":"Health","value":72,"unit":"%"}',
              ),
            ],
            effects: const [
              ChatToolEffect(
                key: 'tracker:health',
                after: {
                  'label': 'Health',
                  'value': 72,
                  'unit': '%',
                  'min': 0,
                  'max': 100,
                },
              ),
            ],
          ),
        ),
      ]);
      final theme = MaiChatApp.themeFor(
        null,
        Brightness.light,
        Colors.teal,
        expressive: true,
      );
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: state,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme.copyWith(
              textTheme: theme.textTheme.apply(fontFamily: 'Roboto'),
              primaryTextTheme: theme.primaryTextTheme.apply(
                fontFamily: 'Roboto',
              ),
            ),
            home: chat ? const ChatScreen() : const ChatToolsPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile(
          '../../docs/previews/${chat ? 'chat-tool-results' : 'chat-tool-calls'}.png',
        ),
      );
      debugDisableShadows = true;
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    });
  }
}
