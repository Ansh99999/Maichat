import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/agent_message.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/studio.dart';
import 'package:maichat/models/usage.dart';
import 'package:maichat/screens/studio/studio_screen.dart';
import 'package:maichat/screens/studio/studio_settings_page.dart';
import 'package:maichat/services/agent_client.dart';
import 'package:maichat/services/studio/studio_controller.dart';
import 'package:maichat/services/studio/studio_store.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart' hide Provider;
import 'package:shared_preferences/shared_preferences.dart';

/// An AppState whose Studio model never finishes its turn: whatever is put on
/// [turns] streams in as the main agent's reply, so a test can hold the lead
/// mid-reply for as long as it likes.
class _HeldState extends AppState {
  /// Buffered until the run listens: one turn, so one listener.
  final StreamController<AgentDelta> turns = StreamController<AgentDelta>();

  @override
  Stream<AgentDelta> streamAgentTurn({
    required AgentClient client,
    required List<AgentMessage> messages,
    required List<ToolSpec> tools,
    bool toolsOff = false,
    void Function(TokenUsage usage, double cost)? onSpend,
    String? model,
  }) =>
      turns.stream;
}

/// The Studio conversation's two ways around a long transcript (the
/// fast-scroll thumb and the jump back to the newest turn), and its two looks
/// (bubbles and document), over the real shell so the chrome's insets are the
/// ones a phone gets.
void main() {
  late Directory dir;
  var serial = 0;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    dir = Directory.systemTemp.createTempSync('studio_transcript');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  const long = 'The tide came in grey over the marsh, and the lamp turned, '
      'and turned, and the keeper wrote down every ship she did not see. ';

  /// [turns] exchanges, each a request, a long answer and a tool call: many
  /// screens of conversation. "Turn 0" is the oldest.
  List<AgentMessage> exchanges(int turns, String who) => [
        for (var i = 0; i < turns; i++) ...[
          AgentMessage.user('$who turn $i asks for more.'),
          AgentMessage(
            role: AgentRole.assistant,
            text: '$who turn $i answers. ${long * 3}',
            toolCalls: [
              ToolCall(
                id: '$who-call-$i',
                name: 'set_fields',
                arguments: const {'description': 'x'},
              ),
            ],
          ),
          AgentMessage.toolResult(
            ToolCall(
              id: '$who-call-$i',
              name: 'set_fields',
              arguments: const {'description': 'x'},
            ),
            '{"ok":true}',
          ),
        ],
      ];

  StudioSession session({
    int turns = 1,
    bool withSubagent = false,
    int subagentTurns = 1,
    bool subagentRunning = false,
  }) {
    final s = StudioSession(
      id: 'transcript-${serial++}',
      title: 'Keeper',
      workspace: StudioWorkspace(character: Character(id: 'c', name: 'Maren')),
    );
    s.transcript.addAll(exchanges(turns, 'Main'));
    if (withSubagent) {
      const task = ToolCall(id: 'task1', name: 'task', arguments: {
        'description': 'Greetings',
        'prompt': 'Write three alternate greetings for Maren.',
        'agent_type': 'writer',
      });
      s.transcript.addAll([
        AgentMessage(role: AgentRole.assistant, toolCalls: const [task]),
        if (!subagentRunning) AgentMessage.toolResult(task, '{"report":"done"}'),
      ]);
      final now = DateTime.now();
      final transcript = [
        AgentMessage.user('Write three alternate greetings for Maren.'),
        // A sub-agent's later turns are its own tool round-trips; the
        // exchanges' user turns stand in for them here.
        ...exchanges(subagentTurns, 'Sub').skip(1),
      ];
      s.subagents.add(StudioSubagent(
        id: 'sa1',
        number: 1,
        description: 'Greetings',
        prompt: 'Write three alternate greetings for Maren.',
        callId: 'task1',
        role: 'writer',
        startedAt: now.subtract(const Duration(minutes: 2)),
        endedAt: subagentRunning ? null : now,
        status: subagentRunning
            ? StudioAgentStatus.running
            : StudioAgentStatus.done,
        transcript: transcript,
      ));
    }
    return s;
  }

  Future<AppState> boot({
    StudioTranscriptStyle style = StudioTranscriptStyle.bubbles,
    AppState? state,
  }) async {
    final s = state ?? AppState();
    await s.init();
    await s.updateStudioConfig(s.studioConfig.copyWith(transcriptStyle: style));
    return s;
  }

  Widget host(AppState state, Widget child) =>
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(home: child),
      );

  /// Pumps the shell. A spinner (a running agent) never settles, so [settle]
  /// is off for those.
  Future<void> open(
    WidgetTester tester,
    AppState state,
    StudioSession s, {
    bool settle = true,
  }) async {
    await tester.pumpWidget(
      host(state, StudioScreen(store: StudioStore(dir), session: s)),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }
  }

  Finder transcript() => find.byType(ListView).first;
  ScrollPosition position(WidgetTester tester) =>
      tester.widget<ListView>(transcript()).controller!.position;
  final thumb = find.byKey(const Key('studio-scroll-thumb'));
  final jump = find.byKey(const Key('studio-jump-latest'));

  /// Whether the thumb is out on the page (rather than slid off its edge).
  bool thumbShown(WidgetTester tester) =>
      tester.getRect(thumb).left < tester.getSize(find.byType(StudioScreen)).width;

  /// Drags the thumb by [dy] in small steps, the way a finger moves.
  Future<void> dragThumb(WidgetTester tester, double dy) async {
    final gesture = await tester.startGesture(tester.getCenter(thumb));
    const steps = 30;
    for (var i = 0; i < steps; i++) {
      await gesture.moveBy(Offset(0, dy / steps));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pump();
  }

  group('the scroller', () {
    testWidgets('a long conversation gets a thumb, clear of the chrome',
        (tester) async {
      final state = await boot();
      await open(tester, state, session(turns: 30));
      final screen = tester.getSize(find.byType(StudioScreen));

      // Hidden until the list moves: slid off the right edge, not faded.
      expect(thumb, findsOneWidget);
      expect(thumbShown(tester), isFalse);
      expect(tester.getRect(thumb).left, greaterThanOrEqualTo(screen.width));

      await tester.drag(transcript(), const Offset(0, 400));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(thumbShown(tester), isTrue);
      final rect = tester.getRect(thumb);
      expect(rect.right, lessThanOrEqualTo(screen.width));
      // A generous grip.
      expect(rect.width, greaterThanOrEqualTo(48));
      expect(rect.height, greaterThanOrEqualTo(48));
      // Below the floating squares' row, above the composer.
      final menu = tester.getRect(find.byKey(const Key('studio-menu')));
      expect(rect.top, greaterThanOrEqualTo(menu.bottom));
      final composer =
          tester.getTopLeft(find.byKey(const Key('studio-composer-field')));
      expect(rect.bottom, lessThanOrEqualTo(composer.dy));

      // Left alone, it slides away again.
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(thumbShown(tester), isFalse);
    });

    testWidgets('dragging the thumb moves through the whole conversation',
        (tester) async {
      final state = await boot();
      await open(tester, state, session(turns: 30));
      expect(position(tester).pixels, 0);
      expect(find.text('Main turn 0 asks for more.'), findsNothing);

      await tester.drag(transcript(), const Offset(0, 300));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // To the top of the track: the start of the conversation.
      await dragThumb(tester, -3000);
      await tester.pumpAndSettle();
      final p = position(tester);
      expect(p.pixels, p.maxScrollExtent);
      expect(find.text('Main turn 0 asks for more.'), findsOneWidget);

      // To the bottom: the newest turn, where it started.
      await dragThumb(tester, 3000);
      await tester.pumpAndSettle();
      expect(position(tester).pixels, 0);
      expect(find.textContaining('Main turn 29 answers.'), findsOneWidget);
    });

    testWidgets('jump to latest comes up away from the newest turn',
        (tester) async {
      final state = await boot();
      await open(tester, state, session(turns: 30));
      // At the newest turn there is nothing to jump to.
      expect(tester.getRect(jump).width, 0);

      await tester.drag(transcript(), const Offset(0, 1500));
      await tester.pumpAndSettle();
      expect(position(tester).pixels, greaterThan(0));
      final button = tester.getRect(jump);
      expect(button.width, closeTo(48, 0.01));
      // It floats over the conversation, above the composer.
      final composer =
          tester.getTopLeft(find.byKey(const Key('studio-composer-field')));
      expect(button.bottom, lessThanOrEqualTo(composer.dy));

      await tester.tap(jump);
      await tester.pumpAndSettle();
      expect(position(tester).pixels, 0);
      expect(tester.getRect(jump).width, 0);
    });

    testWidgets('a short conversation has no thumb to show', (tester) async {
      final state = await boot();
      await open(tester, state, session(turns: 1));
      await tester.drag(transcript(), const Offset(0, 200));
      await tester.pump(const Duration(milliseconds: 300));
      expect(thumbShown(tester), isFalse);
      await tester.pumpAndSettle();
    });

    testWidgets("a sub-agent's chat has the thumb too", (tester) async {
      final state = await boot();
      await open(
        tester,
        state,
        session(turns: 1, withSubagent: true, subagentTurns: 30),
      );
      await tester.tap(find.byKey(const Key('open-agent-sa1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('studio-viewing-bar')), findsOneWidget);

      await tester.drag(transcript(), const Offset(0, 300));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(thumbShown(tester), isTrue);
      final bar = tester.getTopLeft(find.byKey(const Key('studio-viewing-bar')));
      expect(tester.getRect(thumb).bottom, lessThanOrEqualTo(bar.dy));
      await dragThumb(tester, -3000);
      await tester.pumpAndSettle();
      // The top of a sub-agent's chat is the task it was given.
      expect(find.textContaining('Task from Main'), findsOneWidget);
    });
  });

  group('the look', () {
    test('a document look is saved, and bubbles stay the unwritten default',
        () {
      const plain = StudioConfig();
      expect(plain.transcriptStyle, StudioTranscriptStyle.bubbles);
      expect(plain.toJson().containsKey('transcriptStyle'), isFalse);
      final doc = plain.copyWith(transcriptStyle: StudioTranscriptStyle.document);
      expect(doc.toJson()['transcriptStyle'], 'document');
      expect(StudioConfig.fromJson(doc.toJson()).transcriptStyle,
          StudioTranscriptStyle.document);
      expect(StudioConfig.fromJson({'transcriptStyle': 'nonsense'})
          .transcriptStyle, StudioTranscriptStyle.bubbles);
    });

    testWidgets('it is chosen in Studio settings', (tester) async {
      final state = await boot();
      await tester.pumpWidget(host(state, const StudioSettingsPage()));
      await tester.pumpAndSettle();
      final picker = find.byKey(const Key('studio-transcript-style'));
      expect(picker, findsOneWidget);
      await tester.tap(find.descendant(of: picker, matching: find.text('Document')));
      await tester.pumpAndSettle();
      expect(state.studioConfig.transcriptStyle, StudioTranscriptStyle.document);
      await tester.tap(find.descendant(of: picker, matching: find.text('Bubbles')));
      await tester.pumpAndSettle();
      expect(state.studioConfig.transcriptStyle, StudioTranscriptStyle.bubbles);
    });

    // Every look × whose chat × whether its agent is mid-reply.
    for (final style in StudioTranscriptStyle.values) {
      for (final sub in [false, true]) {
        for (final streaming in [false, true]) {
          final name = '${style.name} · ${sub ? 'sub-agent' : 'main'} · '
              '${streaming ? 'streaming' : 'settled'}';
          testWidgets(name, (tester) async {
            final held = _HeldState();
            final state = await boot(style: style, state: held);
            final s = session(
              turns: 1,
              withSubagent: sub,
              subagentTurns: 1,
              subagentRunning: sub && streaming,
            );
            await open(tester, state, s, settle: !streaming);
            final controller = StudioHub.instance.find(s.id)!;
            if (streaming && !sub) {
              // The lead, really running, with half a reply streamed in. Its
              // run reads memory and skills off disk before the first request,
              // through futures of both zones: real time and frames, in turn.
              unawaited(controller.send('And a fourth?'));
              Future<void> settleRealWork() async {
                for (var i = 0; i < 40; i++) {
                  await tester.runAsync(() =>
                      Future<void>.delayed(const Duration(milliseconds: 20)));
                  await tester.pump(const Duration(milliseconds: 20));
                }
              }

              await settleRealWork();
              held.turns.add(const AgentDelta(text: 'Half a sentence'));
              await settleRealWork();
              expect(controller.running, isTrue, reason: controller.notice);
            }
            if (sub) {
              if (streaming) {
                // Read when its chat is opened, just below.
                controller.liveFor('sa1').text = 'Half a sentence';
              }
              await tester.tap(find.byKey(const Key('open-agent-sa1')));
            }
            for (var i = 0; i < 8; i++) {
              await tester.pump(const Duration(milliseconds: 100));
            }

            final document = style == StudioTranscriptStyle.document;
            final list = transcript();
            Finder inList(Finder f) => find.descendant(of: list, matching: f);
            final who = sub ? 'Sub' : 'Main';
            final callId = '$who-call-0';

            if (streaming) {
              expect(inList(find.textContaining('Half a sentence')),
                  findsOneWidget);
            }
            // Tool calls: a filled chip, or a compact line in the text.
            expect(inList(find.byKey(Key('studio-tool-chip-$callId'))),
                document ? findsNothing : findsOneWidget);
            expect(inList(find.byKey(Key('studio-doc-tool-$callId'))),
                document ? findsOneWidget : findsNothing);
            // Speakers are named only in a document.
            expect(inList(find.byKey(const Key('studio-doc-speaker'))),
                document ? findsWidgets : findsNothing);

            if (!sub) {
              // The user's turn: a bubble at the right, or full width.
              final bubble = inList(find.byKey(const Key('studio-user-bubble')));
              final paragraph = inList(find.byKey(const Key('studio-doc-user')));
              expect(bubble, document ? findsNothing : findsWidgets);
              expect(paragraph, document ? findsWidgets : findsNothing);
              final listRect = tester.getRect(list);
              if (document) {
                final words = tester.getRect(find.descendant(
                  of: paragraph.first,
                  matching: find.byType(Container),
                ).first);
                // The page's width, less its margins.
                expect(words.width, closeTo(listRect.width - 32, 0.5));
                expect(inList(find.text('You')), findsWidgets);
                final names = inList(find.text('Studio'));
                expect(names, findsWidgets);
                if (streaming) {
                  // The reply in progress sits under its speaker.
                  expect(
                    tester.getTopLeft(names.last).dy,
                    lessThan(tester
                        .getTopLeft(inList(find.textContaining('Half a sentence')))
                        .dy),
                  );
                }
              } else {
                expect(inList(find.text('You')), findsNothing);
                final words = tester.getRect(find.descendant(
                  of: bubble.first,
                  matching: find.byType(Container),
                ).first);
                // Kept to the right, short of the left edge.
                expect(words.right, closeTo(listRect.right - 12, 0.5));
                expect(words.left, greaterThan(listRect.left + 48));
              }
            } else {
              expect(inList(find.byKey(const Key('studio-doc-task-brief'))),
                  document ? findsOneWidget : findsNothing);
              expect(inList(find.textContaining('Task from Main')),
                  findsOneWidget);
              expect(inList(find.text('Subagent 1')),
                  document ? findsOneWidget : findsNothing);
            }

            if (streaming && !sub) {
              await held.turns.close();
              for (var i = 0; i < 20; i++) {
                await tester.runAsync(() =>
                    Future<void>.delayed(const Duration(milliseconds: 20)));
                await tester.pump(const Duration(milliseconds: 20));
              }
            }
            await tester.pumpWidget(const SizedBox());
            await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 50)));
          });
        }
      }
    }
  });
}
