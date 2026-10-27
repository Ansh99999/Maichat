import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/chat_tool.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/screens/chat_screen.dart';
import 'package:maichat/state/app_state.dart';
import 'package:maichat/widgets/chat_tool_results.dart';
import 'package:provider/provider.dart' hide Provider;
import 'package:shared_preferences/shared_preferences.dart';

/// The chat transcript draws [ChatToolResults] under a reply that made tool
/// calls — unless the user hid the tool UI. The hide switch is behaviour held
/// on the resolved tool config, so both app-wide and per-chat values are the
/// same code path once `chatToolConfigFor` resolves them.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Future<AppState> boot({bool hide = false}) async {
    final state = AppState();
    await state.init();
    await state.addProvider(
      Provider(
        id: 'p',
        name: 'local',
        kind: ProviderKind.openai,
        baseUrl: 'https://host.tld/v1',
        model: 'm',
        apiKey: 'k',
      ),
    );
    final alice = Character(
      id: 'alice',
      name: 'Alice',
      description: 'Curious.',
    );
    await state.addCharacter(alice);
    state.startChatWithCharacter(alice);
    await state.saveChatToolConfig(
      ChatToolConfig(enabled: true, hideToolCallsInChat: hide),
    );
    state.active.messages
      ..clear()
      ..add(ChatMessage(role: 'user', content: 'Roll the dice'))
      ..add(
        ChatMessage(
          role: 'assistant',
          content: 'An eleven!',
          toolRun: ChatToolRun(
            id: 'run-1',
            status: 'completed',
            history: const [],
          ),
        ),
      );
    return state;
  }

  Widget host(AppState state) => ChangeNotifierProvider<AppState>.value(
    value: state,
    child: const MaterialApp(home: ChatScreen()),
  );

  testWidgets('a reply with a tool run shows the tool results', (tester) async {
    final state = await boot();
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    expect(find.text('An eleven!'), findsOneWidget);
    expect(find.byType(ChatToolResults), findsOneWidget);
    state.dispose();
  });

  testWidgets('hiding the tool UI keeps the reply but drops the panel', (
    tester,
  ) async {
    final state = await boot(hide: true);
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    expect(find.text('An eleven!'), findsOneWidget);
    expect(find.byType(ChatToolResults), findsNothing);
    state.dispose();
  });

  for (final placement in ['message', 'pinned', 'hidden']) {
    testWidgets('hidden calls preserve trackers at $placement placement', (
      tester,
    ) async {
      final state = await boot(hide: true);
      state.active.messages.last = ChatMessage(
        role: 'assistant',
        content: 'An eleven!',
        swipes: [
          MessageVariant(content: 'Another roll'),
          MessageVariant(
            content: 'An eleven!',
            toolRun: ChatToolRun(
              id: 'tracker-run',
              status: 'completed',
              effects: const [
                ChatToolEffect(
                  key: 'tracker:excitement',
                  after: {'label': 'Excitement', 'value': 50, 'unit': '%'},
                ),
              ],
            ),
          ),
        ],
        swipeIndex: 1,
      );
      await state.saveChatToolConfig(
        state
            .chatToolConfigFor(state.active)
            .copyWith(trackerPlacement: placement),
      );
      await tester.pumpWidget(host(state));
      await tester.pumpAndSettle();
      expect(find.byType(ChatToolResults), findsNothing);
      final tracker = find.text('Excitement: 50%', findRichText: true);
      expect(tracker, placement == 'hidden' ? findsNothing : findsOneWidget);
      if (placement == 'message') {
        expect(
          tester.getTopLeft(tracker).dy,
          greaterThan(tester.getTopLeft(find.text('An eleven!')).dy),
        );
        expect(
          tester.getTopLeft(tracker).dy,
          lessThan(tester.getTopLeft(find.text('2 / 2')).dy),
        );
      }
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    });
  }

  testWidgets('toggling hide repaints cached bubbles', (tester) async {
    final state = await boot();
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();
    expect(find.byType(ChatToolResults), findsOneWidget);

    // The bubble is cached; the hide flag is part of the cache signature, so
    // flipping it must repaint the cached bubble rather than keep the panel.
    await state.saveChatToolConfig(
      state.chatToolConfigFor(state.active).copyWith(hideToolCallsInChat: true),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('An eleven!'), findsOneWidget);
    expect(find.byType(ChatToolResults), findsNothing);
    state.dispose();
  });
}
