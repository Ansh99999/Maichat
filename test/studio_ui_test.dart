import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/agent_message.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/chat_interface.dart';
import 'package:maichat/models/lorebook.dart';
import 'package:maichat/models/studio.dart';
import 'package:maichat/screens/character_actions.dart';
import 'package:maichat/screens/studio/shell/shell_format.dart';
import 'package:maichat/screens/studio/studio_changes_view.dart';
import 'package:maichat/screens/studio/studio_draft_view.dart';
import 'package:maichat/screens/studio/studio_home_screen.dart';
import 'package:maichat/screens/studio/studio_screen.dart';
import 'package:maichat/services/studio/studio_store.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart' hide Provider;
import 'package:shared_preferences/shared_preferences.dart';

/// The Studio's shell, over a session seeded the way a finished run leaves one:
/// a request, the agent's words, its tool calls and their results — and, where
/// a test wants them, the sub-agents it spawned. The Draft and Changes pages
/// have tests of their own (`studio_draft_ui_test.dart`); here they are only
/// switched to.
void main() {
  late Directory dir;
  var serial = 0;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    dir = Directory.systemTemp.createTempSync('studio_ui');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  const taskCall = ToolCall(id: 'task1', name: 'task', arguments: {
    'description': 'Greetings',
    'prompt': 'Write three alternate greetings for Maren.',
    'agent_type': 'writer',
  });

  StudioSession seeded({bool withSubagents = false, bool running = false}) {
    final session = StudioSession(
      // Unique per test: open controllers are shared through StudioHub.
      id: 'ui-${serial++}',
      title: 'Keeper',
      workspace: StudioWorkspace(character: Character(id: 'c', name: '')),
    );
    session.edit('set_fields', 'Set name, description', (ws) {
      ws.character
        ..name = 'Maren'
        ..description = 'She keeps the Saltmarsh light.';
    });
    session.edit('create_lorebook', 'Created lorebook "Saltmarsh"', (ws) {
      ws.lorebooks.add(Lorebook(id: 'b', name: 'Saltmarsh', entries: [
        LorebookEntry(uid: 0, keys: ['marsh'], content: 'Grey and hungry.'),
      ]));
      ws.character.lorebookIds.add('b');
    });
    const setFields = ToolCall(
      id: 't1',
      name: 'set_fields',
      arguments: {'name': 'Maren', 'description': 'She keeps the light.'},
    );
    const broken = ToolCall(id: 't2', name: 'edit_field', arguments: {
      'field': 'description',
      'find': 'nope',
      'replace': 'x',
    });
    session.transcript.addAll([
      AgentMessage.user('A lighthouse keeper on a haunted coast.'),
      AgentMessage(
        role: AgentRole.assistant,
        text: 'Building her now.',
        toolCalls: const [setFields, broken],
      ),
      AgentMessage.toolResult(setFields, '{"ok":true,"changed":["name"]}'),
      AgentMessage.toolResult(broken, '{"error":"That passage is not there."}',
          isError: true),
    ]);
    if (withSubagents) {
      final now = DateTime.now();
      session.transcript.addAll([
        AgentMessage(role: AgentRole.assistant, toolCalls: const [taskCall]),
        if (!running) AgentMessage.toolResult(taskCall, '{"report":"done"}'),
      ]);
      session.subagents.addAll([
        StudioSubagent(
          id: 'sa1',
          number: 1,
          description: 'Greetings',
          prompt: 'Write three alternate greetings for Maren.',
          callId: 'task1',
          role: 'writer',
          startedAt: now.subtract(const Duration(minutes: 4, seconds: 20)),
          endedAt: running ? null : now,
          status: running ? StudioAgentStatus.running : StudioAgentStatus.done,
          inputTokens: 15000,
          outputTokens: 5000,
          transcript: [
            AgentMessage.user('Write three alternate greetings for Maren.'),
            AgentMessage(
              role: AgentRole.assistant,
              text: 'Wrote three greetings in her voice.',
            ),
          ],
        ),
        StudioSubagent(
          id: 'sa2',
          number: 2,
          description: 'Marsh lore',
          prompt: 'Build the Saltmarsh lorebook.',
          callId: 'task2',
          role: 'lore_writer',
          startedAt: now.subtract(const Duration(minutes: 6, seconds: 19)),
          endedAt: now,
          status: StudioAgentStatus.failed,
          inputTokens: 40000,
          outputTokens: 9500,
        ),
      ]);
    } else {
      session.transcript.add(
          AgentMessage(role: AgentRole.assistant, text: 'Maren is **ready**.'));
    }
    return session;
  }

  Future<AppState> boot() async {
    final state = AppState();
    await state.init();
    return state;
  }

  Widget host(AppState state, Widget child) =>
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(home: child),
      );

  Future<void> open(WidgetTester tester, AppState state, StudioSession s) async {
    await tester.pumpWidget(
      host(state, StudioScreen(store: StudioStore(dir), session: s)),
    );
    await tester.pumpAndSettle();
  }

  /// ⋯ → More actions → Show (or Hide) other areas.
  Future<void> toggleAreas(WidgetTester tester, String label) async {
    await tester.tap(find.byKey(const Key('studio-composer-ops')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('More actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  test('times and token counts read as the panel shows them', () {
    expect(formatElapsed(const Duration(minutes: 4, seconds: 20)), '4m 20s');
    expect(formatElapsed(const Duration(seconds: 35)), '35s');
    expect(formatElapsed(const Duration(hours: 1, minutes: 4)), '1h 4m');
    expect(formatTokens(812), '812');
    expect(formatTokens(20000), '20k');
    expect(formatTokens(49500), '49.5k');
    expect(formatTokens(1200000), '1.2M');
  });

  testWidgets('the chat shows the conversation and its tool calls',
      (tester) async {
    final state = await boot();
    await open(tester, state, seeded());

    // A chat, not tabs.
    expect(find.byType(TabBar), findsNothing);
    expect(find.text('A lighthouse keeper on a haunted coast.'), findsOneWidget);
    expect(find.textContaining('Building her now.'), findsOneWidget);
    // Markdown is rendered, not shown raw.
    expect(find.textContaining('**ready**'), findsNothing);
    expect(find.textContaining('ready'), findsOneWidget);
    expect(find.text('Set name, description'), findsOneWidget);
    expect(find.text('Edited description'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget);

    await tester.tap(find.text('Edited description'));
    await tester.pumpAndSettle();
    expect(find.text('Sent'), findsOneWidget);
    expect(find.text('Failed'), findsOneWidget);
    expect(find.textContaining('That passage is not there.'), findsOneWidget);
    // No sub-agents yet: no button for them.
    expect(find.byTooltip('Sub-agents'), findsNothing);
  });

  testWidgets('an empty session offers openings that fill the composer',
      (tester) async {
    final state = await boot();
    final session = StudioSession(
      id: 'ui-empty-${serial++}',
      title: '',
      workspace: StudioWorkspace(character: Character(id: 'e', name: '')),
    );
    await open(tester, state, session);
    expect(find.text('What are we making?'), findsOneWidget);
    expect(find.textContaining('Set up a provider'), findsOneWidget);
    await tester.tap(find.byType(ActionChip).first);
    await tester.pump();
    final field = tester.widget<TextField>(
      find.byKey(const Key('studio-composer-field')),
    );
    expect(field.controller!.text, contains('lighthouse'));
  });

  testWidgets('the hamburger opens Home, Settings and Sessions',
      (tester) async {
    final state = await boot();
    await open(tester, state, seeded());
    await tester.tap(find.byKey(const Key('studio-menu')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('studio-drawer')), findsOneWidget);
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Sessions'), findsOneWidget);

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Studio settings'), findsOneWidget);
  });

  testWidgets('the composer follows the chat composer style', (tester) async {
    final state = await boot();
    await open(tester, state, seeded());
    // Expressive by default: the field sits in the rounded box, with no
    // persona avatar or name beside it.
    expect(state.chatInterface.composerStyle, ComposerStyle.expressive);
    expect(find.byKey(const Key('studio-composer-field')), findsOneWidget);
    expect(find.text('You'), findsNothing);

    await state.updateChatInterface(
      state.chatInterface.copyWith(composerStyle: ComposerStyle.legacy),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('studio-composer-field')), findsOneWidget);
    expect(find.byKey(const Key('studio-send')), findsOneWidget);
    expect(find.byKey(const Key('studio-composer-ops')), findsOneWidget);
  });

  testWidgets('⋯ offers Add image, from the gallery or the device',
      (tester) async {
    final state = await boot();
    await open(tester, state, seeded());
    await tester.tap(find.byKey(const Key('studio-composer-ops')));
    await tester.pumpAndSettle();
    expect(find.text('Add image'), findsOneWidget);
    expect(find.text('More actions'), findsOneWidget);
    await tester.tap(find.text('Add image'));
    await tester.pumpAndSettle();
    expect(find.text('From gallery'), findsOneWidget);
    expect(find.text('From device'), findsOneWidget);
  });

  testWidgets('Show other areas raises the capsule, which switches pages',
      (tester) async {
    final state = await boot();
    await open(tester, state, seeded());
    expect(find.byKey(const Key('studio-area-capsule')), findsNothing);

    await toggleAreas(tester, 'Show other areas');
    expect(find.byKey(const Key('studio-area-capsule')), findsOneWidget);
    expect(find.text('Interface'), findsOneWidget);
    expect(find.text('Draft'), findsOneWidget);
    expect(find.text('Changes 2'), findsOneWidget);

    await tester.tap(find.byKey(const Key('studio-area-draft')));
    await tester.pumpAndSettle();
    expect(find.byType(StudioDraftView), findsOneWidget);
    expect(tester.getTopLeft(find.byType(StudioDraftView)).dx, 0);

    await tester.tap(find.byKey(const Key('studio-area-changes')));
    await tester.pumpAndSettle();
    expect(find.byType(StudioChangesView), findsOneWidget);
    expect(tester.getTopLeft(find.byType(StudioChangesView)).dx, 0);

    await tester.tap(find.byKey(const Key('studio-area-interface')));
    await tester.pumpAndSettle();
    expect(find.text('A lighthouse keeper on a haunted coast.'), findsOneWidget);

    // The same menu hides it again.
    await toggleAreas(tester, 'Hide other areas');
    expect(find.byKey(const Key('studio-area-capsule')), findsNothing);
  });

  testWidgets('the sub-agents panel lists Main and every sub-agent',
      (tester) async {
    final state = await boot();
    await open(tester, state, seeded(withSubagents: true));
    expect(find.byTooltip('Sub-agents'), findsOneWidget);
    expect(find.byKey(const Key('studio-subagent-list')), findsNothing);

    await tester.tap(find.byTooltip('Sub-agents'));
    await tester.pumpAndSettle();
    final list = find.byKey(const Key('studio-subagent-list'));
    expect(list, findsOneWidget);
    Finder inList(String text) =>
        find.descendant(of: list, matching: find.text(text));
    expect(inList('Main'), findsOneWidget);
    expect(inList('Subagent 1 — Greetings'), findsOneWidget);
    expect(inList('4m 20s • 20k tokens'), findsOneWidget);
    expect(inList('Subagent 2 — Marsh lore'), findsOneWidget);
    expect(inList('6m 19s • 49.5k tokens'), findsOneWidget);
    expect(find.byIcon(Icons.error), findsOneWidget);

    // Tapping outside drains it back into the button.
    await tester.tapAt(const Offset(400, 560));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('studio-subagent-list')), findsNothing);
  });

  testWidgets('tapping a sub-agent teleports to its chat; Main returns',
      (tester) async {
    final state = await boot();
    await open(tester, state, seeded(withSubagents: true));
    await tester.tap(find.byTooltip('Sub-agents'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Subagent 1 — Greetings'));
    await tester.pumpAndSettle();

    expect(find.text('Wrote three greetings in her voice.'), findsOneWidget);
    expect(find.textContaining('Task from Main'), findsOneWidget);
    expect(find.text('A lighthouse keeper on a haunted coast.'), findsNothing);
    // Read-only: the composer gives way to a bar back to Main.
    expect(find.byKey(const Key('studio-composer-field')), findsNothing);
    expect(find.byKey(const Key('studio-viewing-bar')), findsOneWidget);

    await tester.tap(find.byKey(const Key('studio-back-to-main')));
    await tester.pumpAndSettle();
    expect(find.text('A lighthouse keeper on a haunted coast.'), findsOneWidget);
    expect(find.byKey(const Key('studio-composer-field')), findsOneWidget);

    // The panel's Main row does the same.
    await tester.tap(find.byTooltip('Sub-agents'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Subagent 1 — Greetings'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('studio-viewing-bar')), findsOneWidget);
    await tester.tap(find.byTooltip('Sub-agents'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('studio-agent-row-main')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('studio-composer-field')), findsOneWidget);
  });

  testWidgets('a task chip names its sub-agent and opens its chat',
      (tester) async {
    final state = await boot();
    await open(tester, state, seeded(withSubagents: true));
    expect(find.text('Subagent 1 · Writer — Greetings'), findsOneWidget);
    expect(find.text('4m 20s • 20k tokens'), findsOneWidget);
    await tester.tap(find.byKey(const Key('open-agent-sa1')));
    await tester.pumpAndSettle();
    expect(find.text('Wrote three greetings in her voice.'), findsOneWidget);
  });

  testWidgets("the agent's plan shows at the foot of its chat", (tester) async {
    final state = await boot();
    final session = seeded();
    session.todos.addAll(const [
      StudioTodo(content: 'Write the card', status: StudioTodoStatus.completed),
      StudioTodo(content: 'Build the lore', status: StudioTodoStatus.inProgress),
      StudioTodo(content: 'Playtest'),
    ]);
    await open(tester, state, session);
    expect(find.byKey(const Key('studio-plan')), findsOneWidget);
    expect(find.text('Plan · 1 of 3 done'), findsOneWidget);
    expect(find.text('Build the lore'), findsOneWidget);
  });

  testWidgets('a running sub-agent ticks without the frame ever settling',
      (tester) async {
    final state = await boot();
    // A spinner and a ticking clock: pump, never pumpAndSettle.
    await tester.pumpWidget(host(
      state,
      StudioScreen(
        store: StudioStore(dir),
        session: seeded(withSubagents: true, running: true),
      ),
    ));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.byTooltip('Sub-agents'));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final list = find.byKey(const Key('studio-subagent-list'));
    expect(list, findsOneWidget);
    expect(
      find.descendant(of: list, matching: find.text('Subagent 1 — Greetings')),
      findsOneWidget,
    );
    // The running count rides on the button.
    expect(
      find.descendant(of: find.byType(Badge), matching: find.text('1')),
      findsWidgets,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('apply asks first, then saves the draft to the library',
      (tester) async {
    final state = await boot();
    await open(tester, state, seeded());
    await tester.tap(find.byTooltip('Apply to library'));
    await tester.pumpAndSettle();
    expect(find.text('Apply to library'), findsOneWidget);
    expect(find.textContaining('Adds Maren'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
    await tester.pumpAndSettle();
    expect(state.characters.single.name, 'Maren');
    expect(state.lorebooks.single.name, 'Saltmarsh');
    expect(find.textContaining('Saved Maren'), findsOneWidget);
    expect(find.byTooltip('Applied — nothing new to save'), findsOneWidget);
  });

  testWidgets('the session list starts empty and offers a first session',
      (tester) async {
    final state = await boot();
    await tester.runAsync(() async {
      await tester.pumpWidget(
        host(state, StudioHomeScreen(store: StudioStore(dir))),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    expect(find.text('Describe a character, get one'), findsOneWidget);
    expect(find.text('New session'), findsOneWidget);
  });

  test('characters can be opened in the Studio from their menu', () {
    expect(CharacterAction.values.map((a) => a.label), contains('Open in Studio'));
  });
}
