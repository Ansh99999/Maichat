import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/agent_message.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/chat_interface.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/models/studio.dart';
import 'package:maichat/screens/studio/studio_screen.dart';
import 'package:maichat/services/studio/studio_context.dart';
import 'package:maichat/services/studio/studio_controller.dart';
import 'package:maichat/services/studio/studio_store.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart' hide Provider;
import 'package:shared_preferences/shared_preferences.dart';

/// The context inspector on screen: the ring in the composer (both styles) and
/// on a sub-agent's viewing bar, the drawer's Context entry, and the sheet —
/// switching agents, opening a category, reading the raw request. The numbers
/// themselves are held to the real request in `studio_context_test.dart`.
void main() {
  late Directory dir;
  var serial = 0;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    dir = Directory.systemTemp.createTempSync('studio_context_ui');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  StudioSession seeded({bool withSubagent = false}) {
    final session = StudioSession(
      id: 'ctx-ui-${serial++}',
      title: 'Keeper',
      workspace: StudioWorkspace(character: Character(id: 'c', name: 'Maren')),
    );
    const call = ToolCall(id: 't1', name: 'get_draft');
    session.transcript.addAll([
      AgentMessage.user('A lighthouse keeper on a haunted coast.'),
      AgentMessage(
        role: AgentRole.assistant,
        text: 'Reading the draft.',
        toolCalls: const [call],
      ),
      AgentMessage.toolResult(call, '{"character":{"name":"Maren"}}'),
      AgentMessage(role: AgentRole.assistant, text: 'Maren is ready.'),
    ]);
    if (withSubagent) {
      final now = DateTime.now();
      session.subagents.add(StudioSubagent(
        id: 'sa1',
        number: 1,
        description: 'Greetings',
        prompt: 'Write three alternate greetings for Maren.',
        callId: 'task1',
        role: 'writer',
        startedAt: now.subtract(const Duration(minutes: 2)),
        endedAt: now,
        status: StudioAgentStatus.done,
        transcript: [
          AgentMessage.user('Write three alternate greetings for Maren.'),
          AgentMessage(
            role: AgentRole.assistant,
            text: 'Wrote three greetings in her voice.',
          ),
        ],
      ));
    }
    return session;
  }

  Future<AppState> boot() async {
    final state = AppState();
    await state.init();
    // A provider, so there is a request to show — nothing is sent.
    await state.addProvider(Provider(
      id: 'p',
      name: 'local',
      kind: ProviderKind.openai,
      baseUrl: 'https://host.tld/v1',
      model: 'builder',
      apiKey: 'sk-live-SECRETKEY',
    ));
    return state;
  }

  Future<void> open(WidgetTester tester, AppState state, StudioSession s) async {
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        home: StudioScreen(store: StudioStore(dir), session: s),
      ),
    ));
    await tester.pumpAndSettle();
  }

  final mainMeter = find.byKey(const Key('studio-context-meter-$kMainAgent'));

  /// What the main agent's ring says of itself.
  String ringLabel(WidgetTester tester) => tester
      .widget<Tooltip>(find.ancestor(of: mainMeter, matching: find.byType(Tooltip)).first)
      .message!;

  testWidgets('the ring sits in the Expressive composer and opens the sheet',
      (tester) async {
    final state = await boot();
    await open(tester, state, seeded());
    expect(mainMeter, findsOneWidget);
    expect(ringLabel(tester), matches(RegExp(r'^Context \d+% used$')));

    await tester.tap(mainMeter);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('studio-context-sheet')), findsOneWidget);
    expect(find.text('What goes where'), findsOneWidget);
    // No sub-agents: no agent switcher.
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.textContaining('of 120k tokens'), findsOneWidget);
    expect(find.byKey(const Key('studio-context-bar')), findsOneWidget);
  });

  testWidgets('the ring is in the Legacy composer too', (tester) async {
    final state = await boot();
    await state.updateChatInterface(
      state.chatInterface.copyWith(composerStyle: ComposerStyle.legacy),
    );
    await open(tester, state, seeded());
    expect(mainMeter, findsOneWidget);
  });

  testWidgets('a category opens onto its items, and an item reads whole',
      (tester) async {
    final state = await boot();
    await open(tester, state, seeded());
    await tester.tap(mainMeter);
    await tester.pumpAndSettle();

    final results = find.byKey(const Key('studio-context-section-toolResults'));
    await tester.scrollUntilVisible(results, 200,
        scrollable: find.descendant(
          of: find.byKey(const Key('studio-context-sheet')),
          matching: find.byType(Scrollable),
        ).first);
    expect(find.text('get_draft'), findsNothing);
    await tester.tap(results);
    await tester.pumpAndSettle();
    expect(find.text('get_draft'), findsOneWidget);
    await tester.tap(find.text('get_draft'));
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    expect(dialog, findsOneWidget);
    expect(
      find.descendant(of: dialog, matching: find.textContaining('"name":"Maren"')),
      findsOneWidget,
    );
  });

  testWidgets('the raw request is shown with its key redacted, and copies',
      (tester) async {
    final state = await boot();
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await open(tester, state, seeded());
    await tester.tap(mainMeter);
    await tester.pumpAndSettle();

    final view = find.byKey(const Key('studio-context-view-raw'));
    await tester.scrollUntilVisible(view, 300,
        scrollable: find.descendant(
          of: find.byKey(const Key('studio-context-sheet')),
          matching: find.byType(Scrollable),
        ).first);
    await tester.tap(view);
    await tester.pumpAndSettle();
    expect(find.text('Raw request'), findsOneWidget);
    final shown = tester
        .widgetList<SelectableText>(find.descendant(
          of: find.byKey(const Key('studio-context-raw')),
          matching: find.byType(SelectableText),
        ))
        .map((t) => t.data ?? '')
        .join();
    expect(shown, contains('"model": "builder"'));
    expect(shown, contains('<redacted>'));
    expect(shown, isNot(contains('SECRETKEY')));

    await tester.tap(find.byTooltip('Copy raw request').last);
    await tester.pump();
    expect(copied, isNotNull);
    expect(copied, isNot(contains('SECRETKEY')));
    expect(copied, contains('A lighthouse keeper on a haunted coast.'));
    await tester.pumpAndSettle();
  });

  testWidgets('the sheet switches between Main and a sub-agent', (tester) async {
    final state = await boot();
    await open(tester, state, seeded(withSubagent: true));
    await tester.tap(mainMeter);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ChoiceChip, 'Main'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, 'Subagent 1'), findsOneWidget);

    // The first row, which is always built: whose request the sheet reads.
    Finder conversation(String agent) =>
        find.byKey(ValueKey('ctx-$agent-instructions'));
    expect(conversation(kMainAgent), findsOneWidget);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Subagent 1'));
    await tester.pumpAndSettle();
    expect(conversation('sa1'), findsOneWidget);
    expect(conversation(kMainAgent), findsNothing);
    // The sub-agent never read the draft, so it carries no tool results.
    final controller = StudioHub.instance.find('ctx-ui-${serial - 1}')!;
    expect(
      controller.contextFor('sa1')!.section(StudioContextCategory.toolResults),
      isNull,
    );
  });

  testWidgets('a sub-agent\'s viewing bar carries its own ring',
      (tester) async {
    final state = await boot();
    await open(tester, state, seeded(withSubagent: true));
    await tester.tap(find.byTooltip('Sub-agents'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Subagent 1 — Greetings'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('studio-viewing-bar')), findsOneWidget);
    final ring = find.byKey(const Key('studio-context-meter-sa1'));
    expect(ring, findsOneWidget);
    await tester.tap(ring);
    await tester.pumpAndSettle();
    // Opened on that sub-agent.
    final chip = tester.widget<ChoiceChip>(
      find.widgetWithText(ChoiceChip, 'Subagent 1'),
    );
    expect(chip.selected, isTrue);
  });

  testWidgets('the drawer has Context, for whichever agent is on screen',
      (tester) async {
    final state = await boot();
    await open(tester, state, seeded());
    await tester.tap(find.byKey(const Key('studio-menu')));
    await tester.pumpAndSettle();
    expect(find.text('Context'), findsOneWidget);
    await tester.tap(find.text('Context'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('studio-context-sheet')), findsOneWidget);
  });

  testWidgets('the ring follows what the next request will carry',
      (tester) async {
    final state = await boot();
    final session = seeded();
    await open(tester, state, session);
    final controller = StudioHub.instance.find(session.id)!;
    final before = ringLabel(tester);
    // A long message waiting to be read makes the next request bigger. A burst
    // of changes, as a streamed reply makes, is drawn once it settles.
    session.queued.add(StudioQueuedMessage(id: 'q', text: 'word ' * 20000));
    for (var i = 0; i < 5; i++) {
      controller.dismissNotice();
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(ringLabel(tester), isNot(before));
  });
}
