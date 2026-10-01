import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/models/studio.dart';
import 'package:maichat/screens/chat_screen.dart';
import 'package:maichat/screens/studio/studio_screen.dart';
import 'package:maichat/services/btw.dart';
import 'package:maichat/services/chat_client.dart';
import 'package:maichat/services/studio/studio_commands.dart';
import 'package:maichat/services/studio/studio_skills.dart';
import 'package:maichat/services/studio/studio_store.dart';
import 'package:maichat/state/app_state.dart';
import 'package:maichat/widgets/btw_sheet.dart';
import 'package:provider/provider.dart' hide Provider;
import 'package:shared_preferences/shared_preferences.dart';

class _NoStarters implements StarterSkillSource {
  @override
  Future<Map<String, Map<String, String>>> load() async => const {};
}

/// The `/btw` surfaces: the sheet on its own (driven by a scripted answer),
/// and the chat and Studio composers that open it.
class _FakeClient extends ChatClient {
  Completer<void>? hold;

  @override
  Stream<ChatDelta> streamChat({
    required Provider provider,
    required List<ChatMessage> history,
    GenParams params = const GenParams(),
  }) async* {
    yield ChatDelta(text: 'MAIN_REPLY');
    final gate = hold;
    if (gate != null) await gate.future;
  }

  @override
  Future<List<String>> listModels(Provider provider) async => const ['m'];
}

void main() {
  group('the sheet', () {
    late Completer<String> reply;
    late void Function(String) progress;
    late BtwRun run;

    Widget host() => MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showBtwSheet(
                    context,
                    question: 'What was her sister called?',
                    ask: (r, onProgress) {
                      run = r;
                      progress = onProgress;
                      return reply.future;
                    },
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        );

    Future<void> open(WidgetTester tester) async {
      reply = Completer<String>();
      await tester.pumpWidget(host());
      await tester.tap(find.text('open'));
      // A progress bar runs while it waits, so the sheet never "settles".
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('shows the question, then the answer as it arrives',
        (tester) async {
      await open(tester);
      expect(find.byKey(const Key('btw-sheet')), findsOneWidget);
      expect(find.text('By the way'), findsOneWidget);
      expect(find.text('What was her sister called?'), findsOneWidget);
      expect(find.text('Not added to the conversation'), findsOneWidget);
      expect(find.byKey(const Key('btw-waiting')), findsOneWidget);
      expect(find.byTooltip('Copy answer'), findsNothing);

      progress('Her sister');
      await tester.pump(const Duration(milliseconds: 60));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('btw-answer')), findsOneWidget);
      expect(find.textContaining('Her sister', findRichText: true),
          findsOneWidget);

      reply.complete('Her sister was **Wren**.');
      await tester.pumpAndSettle();
      expect(find.textContaining('Wren', findRichText: true), findsOneWidget);
      expect(find.byTooltip('Copy answer'), findsOneWidget);
      expect(run.cancelled, isFalse);

      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('btw-sheet')), findsNothing);
      // Finished before it was put away: nothing to cancel.
      expect(run.cancelled, isFalse);
    });

    testWidgets('putting it away mid-answer cancels the question',
        (tester) async {
      await open(tester);
      expect(run.cancelled, isFalse);
      await tester.tap(find.text('Done'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('btw-sheet')), findsNothing);
      expect(run.cancelled, isTrue);
      reply.complete('');
    });

    testWidgets('a failed request says why', (tester) async {
      await open(tester);
      reply.completeError(ChatApiException('The host said no (401).'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('btw-error')), findsOneWidget);
      expect(find.text('The host said no (401).'), findsOneWidget);
      expect(find.byTooltip('Copy answer'), findsNothing);
    });

    testWidgets('an empty answer says so', (tester) async {
      await open(tester);
      reply.complete('');
      await tester.pumpAndSettle();
      expect(find.text('No answer came back.'), findsOneWidget);
    });
  });

  group('the chat composer', () {
    late _FakeClient client;

    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      client = _FakeClient();
    });

    Future<AppState> boot() async {
      final state = AppState(client: client);
      await state.init();
      await state.addProvider(Provider(
        id: 'p',
        name: 'local',
        kind: ProviderKind.openai,
        baseUrl: 'https://host.tld/v1',
        model: 'm',
        apiKey: 'k',
      ));
      final alice =
          Character(id: 'alice', name: 'Alice', description: 'Curious.');
      await state.addCharacter(alice);
      state.startChatWithCharacter(alice);
      state.active.messages
        ..clear()
        ..add(ChatMessage(role: 'user', content: 'Where are we?'))
        ..add(ChatMessage(role: 'assistant', content: 'The harbour at dawn'));
      return state;
    }

    Widget host(AppState state) => ChangeNotifierProvider<AppState>.value(
          value: state,
          child: const MaterialApp(home: ChatScreen()),
        );

    Finder composer() => find.byType(TextField).last;

    testWidgets('a /btw line turns Send into "Ask on the side"',
        (tester) async {
      final state = await boot();
      await tester.pumpWidget(host(state));
      await tester.pumpAndSettle();

      await tester.enterText(composer(), 'Hello');
      await tester.pump();
      expect(find.byTooltip('Send'), findsOneWidget);
      expect(find.byKey(const Key('chat-ask-aside')), findsNothing);

      await tester.enterText(composer(), '/btw where is this?');
      await tester.pump();
      expect(find.byKey(const Key('chat-ask-aside')), findsOneWidget);
      expect(find.byTooltip('Send'), findsNothing);

      await tester.enterText(composer(), '/btwx not a command');
      await tester.pump();
      expect(find.byTooltip('Send'), findsOneWidget);
    });

    testWidgets('asking opens the sheet and adds nothing to the thread',
        (tester) async {
      final state = await boot();
      await tester.pumpWidget(host(state));
      await tester.pumpAndSettle();
      final before = state.active.messages.map((m) => m.content).toList();

      await tester.enterText(composer(), '/btw where is this harbour?');
      await tester.pump();
      await tester.tap(find.byKey(const Key('chat-ask-aside')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byKey(const Key('btw-sheet')), findsOneWidget);
      expect(find.text('where is this harbour?'), findsOneWidget);
      expect(state.active.messages.map((m) => m.content).toList(), before);
      expect(state.streaming, isFalse);
      // The question moved into the sheet; the box is free again.
      expect(tester.widget<TextField>(composer()).controller!.text, isEmpty);

      await tester.tap(find.text('Done'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('btw-sheet')), findsNothing);
      expect(state.active.messages.map((m) => m.content).toList(), before);
    });

    testWidgets('a bare /btw asks for a question instead', (tester) async {
      final state = await boot();
      await tester.pumpWidget(host(state));
      await tester.pumpAndSettle();
      await tester.enterText(composer(), '/btw');
      await tester.pump();
      await tester.tap(find.byKey(const Key('chat-ask-aside')));
      await tester.pump();
      expect(find.text('Say what to ask: /btw <question>.'), findsOneWidget);
      expect(find.byKey(const Key('btw-sheet')), findsNothing);
      await tester.pumpAndSettle(const Duration(seconds: 5));
    });

    testWidgets('while a reply streams, a /btw line can still be asked',
        (tester) async {
      final state = await boot();
      await tester.pumpWidget(host(state));
      await tester.pumpAndSettle();
      client.hold = Completer<void>();
      // Not awaited: the reply is held open (see CLAUDE.md on state.send).
      unawaited(state.send('Tell me a story.'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(state.streaming, isTrue);
      expect(find.byTooltip('Stop'), findsOneWidget);
      final turns = state.active.messages.length;

      await tester.enterText(composer(), '/btw how long will this be?');
      await tester.pump();
      expect(find.byTooltip('Stop'), findsNothing);
      await tester.tap(find.byKey(const Key('chat-ask-aside')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('btw-sheet')), findsOneWidget);
      expect(state.streaming, isTrue, reason: 'the reply carries on');
      expect(state.active.messages, hasLength(turns));

      await tester.tap(find.text('Done'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      // With the box empty again, the button is Stop once more.
      expect(find.byTooltip('Stop'), findsOneWidget);
      client.hold!.complete();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(state.streaming, isFalse);
      expect(state.active.messages.last.content, 'MAIN_REPLY');
    });
  });

  group('the Studio composer', () {
    late Directory dir;

    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      StudioSkillLibrary.resetShared();
      StudioCommandStore.resetShared();
      dir = Directory.systemTemp.createTempSync('studio_btw_ui');
    });
    tearDown(() {
      StudioSkillLibrary.resetShared();
      StudioCommandStore.resetShared();
      dir.deleteSync(recursive: true);
    });

    testWidgets('/btw is offered in the panel and opens the sheet, keeping '
        'nothing', (tester) async {
      // No provider: the sheet's request fails at once, with the reason.
      final state = AppState();
      await state.init();
      await tester.runAsync(() async {
        await StudioSkillLibrary.forDirectory(dir, starters: _NoStarters());
        await StudioCommandStore.forDirectory(dir);
      });
      final session = StudioSession(
        id: 'btw-ui',
        title: 'Keeper',
        workspace: StudioWorkspace(character: Character(id: 'c', name: 'Maren')),
      );
      await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          home: StudioScreen(store: StudioStore(dir), session: session),
        ),
      ));
      await tester.pumpAndSettle();
      final field = find.byKey(const Key('studio-composer-field'));

      await tester.enterText(field, '/bt');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('studio-slash-panel')), findsOneWidget);
      expect(find.textContaining('/btw', findRichText: true), findsWidgets);

      await tester.enterText(field, '/btw what is her name so far?');
      await tester.pump();
      await tester.tap(find.byKey(const Key('studio-send')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('btw-sheet')), findsOneWidget);
      expect(find.text('what is her name so far?'), findsOneWidget);
      expect(find.byKey(const Key('btw-error')), findsOneWidget);
      expect(session.transcript, isEmpty);
      expect(session.queued, isEmpty);

      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('btw-sheet')), findsNothing);
      expect(session.transcript, isEmpty);
    });
  });
}
