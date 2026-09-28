import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/agent_message.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/lorebook.dart';
import 'package:maichat/models/studio.dart';
import 'package:maichat/screens/character_actions.dart';
import 'package:maichat/screens/studio/studio_home_screen.dart';
import 'package:maichat/screens/studio/studio_screen.dart';
import 'package:maichat/services/studio/studio_store.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart' hide Provider;
import 'package:shared_preferences/shared_preferences.dart';

/// The Studio's screens, over a session seeded the way a finished run leaves
/// one: a request, the agent's words, its tool calls and their results.
void main() {
  late Directory dir;
  var serial = 0;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    dir = Directory.systemTemp.createTempSync('studio_ui');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  StudioSession seeded() {
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
      AgentMessage(role: AgentRole.assistant, text: 'Maren is **ready**.'),
    ]);
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

  testWidgets('the agent tab shows the conversation and its tool calls',
      (tester) async {
    final state = await boot();
    final session = seeded();
    await tester.pumpWidget(
      host(state, StudioScreen(store: StudioStore(dir), session: session)),
    );
    await tester.pumpAndSettle();

    expect(find.text('A lighthouse keeper on a haunted coast.'), findsOneWidget);
    expect(find.textContaining('Building her now.'), findsOneWidget);
    // Markdown is rendered, not shown raw.
    expect(find.textContaining('**ready**'), findsNothing);
    expect(find.textContaining('ready'), findsOneWidget);
    expect(find.text('Set name, description'), findsOneWidget);
    expect(find.text('Edited description'), findsOneWidget);
    // The failed call is marked as failed, the other as done.
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget);

    await tester.tap(find.text('Edited description'));
    await tester.pumpAndSettle();
    expect(find.text('Sent'), findsOneWidget);
    expect(find.text('Failed'), findsOneWidget);
    expect(find.textContaining('That passage is not there.'), findsOneWidget);
  });

  testWidgets('an empty session offers openings to start from', (tester) async {
    final state = await boot();
    final session = StudioSession(
      id: 'ui-empty-${serial++}',
      title: '',
      workspace: StudioWorkspace(character: Character(id: 'e', name: '')),
    );
    await tester.pumpWidget(
      host(state, StudioScreen(store: StudioStore(dir), session: session)),
    );
    await tester.pumpAndSettle();
    expect(find.text('What are we making?'), findsOneWidget);
    // No provider is set up, and the page says so rather than failing later.
    expect(find.textContaining('Set up a provider'), findsOneWidget);
    await tester.tap(find.byType(ActionChip).first);
    await tester.pump();
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, contains('lighthouse'));
  });

  testWidgets('the draft tab shows the card and edits by hand', (tester) async {
    final state = await boot();
    final session = seeded();
    await tester.pumpWidget(
      host(state, StudioScreen(store: StudioStore(dir), session: session)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Draft'));
    await tester.pumpAndSettle();

    expect(find.text('Maren'), findsWidgets);
    expect(find.text('She keeps the Saltmarsh light.'), findsOneWidget);
    expect(find.textContaining('permanent tokens'), findsOneWidget);

    await tester.tap(find.byTooltip('Edit personality'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Dry wit, iron patience.');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(session.workspace.character.personality, 'Dry wit, iron patience.');
    expect(session.ops.last.tool, 'manual');
    expect(find.text('Dry wit, iron patience.'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('Saltmarsh'), 200,
        scrollable: find.byType(Scrollable).last);
    expect(find.text('Saltmarsh'), findsOneWidget);
    expect(find.textContaining('1 entry'), findsOneWidget);
  });

  testWidgets('the changes tab rewinds to before a change', (tester) async {
    final state = await boot();
    final session = seeded();
    await tester.pumpWidget(
      host(state, StudioScreen(store: StudioStore(dir), session: session)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Changes (2)'), findsOneWidget);
    await tester.tap(find.text('Changes (2)'));
    await tester.pumpAndSettle();

    expect(find.text('Created lorebook "Saltmarsh"'), findsOneWidget);
    // Newest first: the lorebook's row is on top, so its Rewind is first.
    await tester.tap(find.text('Rewind').first);
    await tester.pumpAndSettle();
    expect(find.text('Rewind the draft?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Rewind'));
    await tester.pumpAndSettle();

    expect(session.workspace.lorebooks, isEmpty);
    expect(session.workspace.character.name, 'Maren');
    expect(session.ops.last.reverted, isTrue);
    expect(find.text('Changes (1)'), findsOneWidget);
    expect(session.transcript.last.text, startsWith('[Studio note]'));
  });

  testWidgets('apply asks first, then saves the draft to the library',
      (tester) async {
    final state = await boot();
    final session = seeded();
    await tester.pumpWidget(
      host(state, StudioScreen(store: StudioStore(dir), session: session)),
    );
    await tester.pumpAndSettle();
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
