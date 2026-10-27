// Generate previews explicitly; this file is intentionally outside the default suite.
// flutter test test/screenshots/chat_tool_editor_preview.dart --update-goldens
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/main.dart';
import 'package:maichat/models/chat_tool.dart';
import 'package:maichat/screens/settings/chat_tools_edit_screen.dart';
import 'package:maichat/screens/settings/chat_tools_test_screen.dart';
import 'package:maichat/services/chat_tools/definitions.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'shot.dart';

void main() {
  setUpAll(() async {
    await loadShotFonts();
    final monospace = FontLoader('monospace')
      ..addFont(
        Future.value(
          ByteData.sublistView(
            File(
              '/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf',
            ).readAsBytesSync(),
          ),
        ),
      );
    await monospace.load();
  });

  testWidgets('custom tool editor tags preview', (tester) async {
    usePhone(tester);
    SharedPreferences.setMockInitialValues({});
    final state = AppState();
    await tester.runAsync(state.init);
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
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      ),
    );
    await tester.pump();
    Navigator.of(tester.element(find.byType(Scaffold))).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const ChatToolEditScreen(
          initial: ChatToolDefinition(
            name: 'travel_roll',
            description:
                'Rolls one d20, adds the journey bonus, and returns the dice '
                'details for combat or travel checks.',
            parameters: {
              'type': 'object',
              'properties': {
                'bonus': {
                  'type': 'integer',
                  'description': 'Situational modifier for the check.',
                  'minimum': -20,
                  'maximum': 20,
                },
              },
              'required': ['bonus'],
              'additionalProperties': false,
            },
            action: {
              'call': 'roll_dice',
              'arguments': {
                'formula': {'template': '1d20+{args.bonus}'},
              },
            },
            tags: ['Combat', 'Travel'],
          ),
          existingNames: {'roll_dice'},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('../../docs/previews/chat-tool-tags.png'),
    );
    debugDisableShadows = true;
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets('full-screen tool test preview', (tester) async {
    usePhone(tester);
    SharedPreferences.setMockInitialValues({});
    final state = AppState();
    await tester.runAsync(state.init);
    final tool = chatToolBuiltIns.singleWhere(
      (definition) => definition.name == 'roll_dice',
    );
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
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      ),
    );
    await tester.pump();
    Navigator.of(tester.element(find.byType(Scaffold))).push<void>(
      MaterialPageRoute<void>(
        builder: (_) =>
            ChatToolTestScreen(tool: tool, conversationId: state.active.id),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('chat-tool-test-arguments')),
      '{"formula":"d1"}',
    );
    await tester.tap(find.byKey(const Key('chat-tool-test-run')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('chat-tool-test-result')), findsOneWidget);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('../../docs/previews/chat-tool-test.png'),
    );
    debugDisableShadows = true;
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });
}
