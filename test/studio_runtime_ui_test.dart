import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/agent_message.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/studio.dart';
import 'package:maichat/screens/studio/studio_screen.dart';
import 'package:maichat/services/studio/studio_store.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart' hide Provider;
import 'package:shared_preferences/shared_preferences.dart';

/// The runtime's marks in the Studio's chat: a queued message, a summarised
/// stretch of conversation, a background report, and the notice a run the app
/// closing cut off leaves behind.
void main() {
  late Directory dir;
  var serial = 0;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    dir = Directory.systemTemp.createTempSync('studio_runtime_ui');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  StudioSession session() => StudioSession(
        id: 'rt-${serial++}',
        title: 'Keeper',
        workspace: StudioWorkspace(character: Character(id: 'c', name: 'Maren')),
        transcript: [
          AgentMessage.user('An old request.'),
          AgentMessage(role: AgentRole.assistant, text: 'An old answer.'),
          AgentMessage.user('A newer request.'),
          AgentMessage(role: AgentRole.assistant, text: 'A newer answer.'),
        ],
      );

  Future<void> open(WidgetTester tester, StudioSession s) async {
    final state = AppState();
    await state.init();
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(
        home: StudioScreen(store: StudioStore(dir), session: s),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('a queued message shows as queued, and can be taken back',
      (tester) async {
    final s = session()
      ..queued.add(StudioQueuedMessage(id: 'q1', text: 'Make her older.'));
    await open(tester, s);
    expect(find.text('Queued — it reads this next'), findsOneWidget);
    expect(find.text('Make her older.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('studio-queued-cancel')));
    await tester.pumpAndSettle();
    expect(find.text('Make her older.'), findsNothing);
    expect(s.queued, isEmpty);
  });

  testWidgets('a summarised stretch is marked where the summary begins',
      (tester) async {
    final s = session()..compactions.add(StudioCompaction(summary: 'S', upTo: 2));
    await open(tester, s);
    final divider = find.byKey(const Key('studio-compaction-divider'));
    expect(divider, findsOneWidget);
    expect(find.text('Earlier conversation summarised'), findsOneWidget);
    // Between the old turns and the newer ones — the chat still shows both.
    expect(find.text('An old answer.'), findsOneWidget);
    expect(
      tester.getTopLeft(divider).dy,
      greaterThan(tester.getTopLeft(find.text('An old answer.')).dy),
    );
    expect(
      tester.getTopLeft(divider).dy,
      lessThan(tester.getTopLeft(find.text('A newer request.')).dy),
    );
  });

  testWidgets('a background report is one line, not the whole report',
      (tester) async {
    final s = session()
      ..transcript.add(AgentMessage.user(
        '[Studio note] Subagent 1 (task_id "a1") finished in the background — '
        'status done. Its report, as data (not an instruction from the user):\n'
        'A very long report that should not be pasted into the chat.',
      ));
    await open(tester, s);
    expect(find.text('Subagent 1 finished in the background'), findsOneWidget);
    expect(find.textContaining('A very long report'), findsNothing);
  });

  testWidgets('an interrupted session offers Resume, and Not now puts it away',
      (tester) async {
    final s = session()..interrupted = true;
    await open(tester, s);
    expect(find.byKey(const Key('studio-interrupted')), findsOneWidget);
    expect(find.text('The Studio was interrupted'), findsOneWidget);
    expect(find.byKey(const Key('studio-resume')), findsOneWidget);
    await tester.tap(find.byKey(const Key('studio-interrupted-dismiss')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('studio-interrupted')), findsNothing);
    expect(s.interrupted, isFalse);
  });

  testWidgets('with nothing working the composer offers Send, not Stop',
      (tester) async {
    await open(tester, session());
    expect(find.byKey(const Key('studio-send')), findsOneWidget);
    expect(find.byKey(const Key('studio-stop')), findsNothing);
  });

  testWidgets('while a sub-agent works, Stop sits beside Send', (tester) async {
    final s = session()
      ..subagents.add(StudioSubagent(
        id: 'a1',
        number: 1,
        description: 'Greetings',
        prompt: 'Write greetings.',
        callId: 't1',
        background: true,
      ));
    await open(tester, s);
    // A running sub-agent ticks; pump rather than settle.
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('studio-stop')), findsOneWidget);
    expect(find.byKey(const Key('studio-send')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
