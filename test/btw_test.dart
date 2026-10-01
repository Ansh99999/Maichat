import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/agent_message.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/screens/studio/shell/slash_commands.dart';
import 'package:maichat/services/btw.dart';
import 'package:maichat/services/preset_io.dart';
import 'package:maichat/services/studio/studio_commands.dart';
import 'package:maichat/services/studio/studio_controller.dart';
import 'package:maichat/services/studio/studio_memory.dart';
import 'package:maichat/services/studio/studio_skills.dart';
import 'package:maichat/services/studio/studio_store.dart';
import 'package:maichat/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _NoStarters implements StarterSkillSource {
  @override
  Future<Map<String, Map<String, String>>> load() async => const {};
}

/// `/btw` end to end: the real [AppState] / [StudioController] and the real
/// clients against a loopback model, asserting the bytes that leave the app —
/// and that nothing of the side question is left behind for a later request.
///
/// Plain `test()`s only: a `testWidgets` in this file would make every real
/// HTTP request in it answer 400 (see CLAUDE.md).
void main() {
  group('btwQuestion', () {
    test('reads a /btw line and nothing else', () {
      expect(btwQuestion('/btw what is her name?'), 'what is her name?');
      expect(btwQuestion('/BTW  spaced  out '), 'spaced  out');
      expect(btwQuestion('/btw\nover two\nlines'), 'over two\nlines');
      expect(btwQuestion('/btw'), '');
      expect(btwQuestion('  /btw leading space'), 'leading space');
      expect(btwQuestion('/btwx no'), isNull);
      expect(btwQuestion('btw no slash'), isNull);
      expect(btwQuestion('I said /btw mid-line'), isNull);
      expect(btwQuestion('/help'), isNull);
    });

    test('BtwRun runs its hooks once, and at once when already cancelled', () {
      final run = BtwRun();
      var calls = 0;
      run.onCancel(() => calls++);
      run.cancel();
      run.cancel();
      expect(calls, 1);
      run.onCancel(() => calls++);
      expect(calls, 2);
      expect(run.cancelled, isTrue);
    });
  });

  group('in a chat', () {
    late HttpServer server;
    late List<Map<String, dynamic>> requests;
    // When set, a request that is not the side question waits for it.
    Completer<void>? gate;
    Completer<void>? mainArrived;

    Future<AppState> boot({bool preset = true}) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      requests = [];
      gate = null;
      mainArrived = null;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final body = jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>;
        requests.add(body);
        final aside = jsonEncode(body).contains('BTW_Q');
        if (!aside) {
          mainArrived?.complete();
          await gate?.future;
        }
        request.response.headers.contentType =
            ContentType('text', 'event-stream');
        request.response.write('data: ${jsonEncode({
              'choices': [
                {
                  'delta': {'content': aside ? 'SIDE_ANSWER' : 'MAIN_REPLY'}
                }
              ]
            })}\n\n');
        request.response.write('data: [DONE]\n\n');
        await request.response.close();
      });
      final state = AppState();
      await state.init();
      await state.addProvider(Provider(
        id: 'p',
        name: 'local',
        kind: ProviderKind.openai,
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        model: 'test-model',
        apiKey: 'k',
      ));
      if (preset) {
        final p = importPreset(jsonDecode(
          File('test/fixtures/marinara_spaghetti.json').readAsStringSync(),
        ) as Map<String, dynamic>);
        await state.addPreset(p);
        await state.setDefaultPreset(p.id);
      }
      final alice = Character(
        id: 'alice',
        name: 'Alice',
        description: 'DESC_TOKEN a curious explorer.',
        firstMes: 'GREET_TOKEN hello there.',
      );
      await state.addCharacter(alice);
      state.startChatWithCharacter(alice);
      return state;
    }

    tearDown(() => server.close(force: true));

    List<Map<String, dynamic>> wire(Map<String, dynamic> body) =>
        (body['messages'] as List).cast<Map<String, dynamic>>();

    /// Everything in the store but the usage ledger, which a side question
    /// rightly adds to.
    Future<Map<String, Object?>> store() async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      return {
        for (final k in prefs.getKeys().toList()..sort())
          if (k != 'usage') k: prefs.get(k),
      };
    }

    for (final withPreset in [true, false]) {
      test(
          'the side question is the chat\'s own request plus one last user '
          'turn, and leaves nothing behind (${withPreset ? 'preset' : 'no preset'})',
          () async {
        final state = await boot(preset: withPreset);
        await state.send('TURN_ONE my name is Ansh.');
        final turns = jsonEncode(state.active.messages);
        final before = await store();
        requests.clear();

        final progress = <String>[];
        final answer = await state.askAside(
          'BTW_Q what did I say my name was?',
          onProgress: progress.add,
        );
        expect(answer, 'SIDE_ANSWER');
        expect(progress.last, 'SIDE_ANSWER');

        final msgs = wire(requests.single);
        // Exactly one system message, at the front, carrying the character.
        expect(msgs.first['role'], 'system');
        expect(msgs.where((m) => m['role'] == 'system'), hasLength(1));
        expect(msgs.first['content'], contains('DESC_TOKEN'));
        // The conversation is context…
        expect(jsonEncode(msgs), contains('TURN_ONE'));
        expect(jsonEncode(msgs), contains('MAIN_REPLY'));
        // …and the question is the very last user turn.
        expect(msgs.last['role'], 'user');
        final last = msgs.last['content'] as String;
        expect(last.trim(), endsWith('BTW_Q what did I say my name was?'));
        expect(last, contains('side question'));
        for (var i = 1; i < msgs.length; i++) {
          expect(msgs[i]['role'], isNot(msgs[i - 1]['role']),
              reason: 'adjacent wire turns at $i share a role');
        }

        // Nothing landed in the chat or the store.
        expect(jsonEncode(state.active.messages), turns);
        expect(await store(), before);

        // And the next real send knows nothing of it.
        requests.clear();
        await state.send('TURN_TWO carry on.');
        final next = jsonEncode(requests.single);
        expect(next, isNot(contains('BTW_Q')));
        expect(next, isNot(contains('SIDE_ANSWER')));
        expect(next, isNot(contains('side question')));
        expect(next, contains('TURN_ONE'));
        expect(state.active.messages.map((m) => m.content).join('\n'),
            isNot(contains('SIDE_ANSWER')));
      });
    }

    test('asked while a reply streams, it leaves that reply alone', () async {
      final state = await boot();
      gate = Completer<void>();
      mainArrived = Completer<void>();
      final sending = state.send('TURN_ONE tell me a story.');
      await mainArrived!.future;
      expect(state.streaming, isTrue);

      final answer = await state.askAside('BTW_Q quick one');
      expect(answer, 'SIDE_ANSWER');
      expect(state.streaming, isTrue, reason: 'the reply is still going');
      // The half-written turn is not context: no empty assistant turn after
      // the user's line, which some hosts reject.
      // (The question shares the user's last turn: the wire never carries two
      // turns of one role in a row.)
      final side = wire(requests.last);
      final last = side.last['content'] as String;
      expect(side.last['role'], 'user');
      expect(last, contains('TURN_ONE'));
      expect(last.indexOf('TURN_ONE'), lessThan(last.indexOf('BTW_Q')));
      expect(
        side.where((m) =>
            m['role'] == 'assistant' && '${m['content']}'.trim().isEmpty),
        isEmpty,
      );

      gate!.complete();
      await sending;
      expect(state.active.messages.last.content, 'MAIN_REPLY');
      expect(state.active.messages.where((m) => m.content.contains('SIDE')),
          isEmpty);
    });

    test('a cancelled question returns quietly and records no error', () async {
      final state = await boot();
      final run = BtwRun()..cancel();
      final answer = await state.askAside('BTW_Q never mind', run: run);
      expect(answer, '');
      expect(requests, isEmpty);
    });
  });

  group('in the Studio', () {
    late HttpServer server;
    late Directory dir;
    late List<Map<String, dynamic>> requests;

    Map<String, dynamic> words(String text) => {
          'choices': [
            {
              'delta': {'content': text},
            },
          ],
        };

    Future<(AppState, StudioController)> boot() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      StudioSkillLibrary.resetShared();
      StudioCommandStore.resetShared();
      StudioMemory.resetShared();
      requests = [];
      dir = await Directory.systemTemp.createTemp('studio_btw');
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final body = jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>;
        requests.add(body);
        final aside = jsonEncode(body).contains('BTW_Q');
        request.response.headers.contentType =
            ContentType('text', 'event-stream');
        request.response.write(
            'data: ${jsonEncode(words(aside ? 'SIDE_ANSWER' : 'Done.'))}\n\n');
        request.response.write('data: [DONE]\n\n');
        await request.response.close();
      });
      final state = AppState();
      await state.init();
      await state.addProvider(Provider(
        id: 'p',
        name: 'local',
        kind: ProviderKind.openai,
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        model: 'builder',
        apiKey: 'k',
      ));
      await StudioSkillLibrary.forDirectory(dir, starters: _NoStarters());
      await StudioCommandStore.forDirectory(dir);
      final controller = StudioController(
        state: state,
        store: StudioStore(dir),
        session: newStudioSession(),
      );
      addTearDown(controller.flush);
      return (state, controller);
    }

    tearDown(() async {
      await server.close(force: true);
      StudioSkillLibrary.resetShared();
      StudioCommandStore.resetShared();
      StudioMemory.resetShared();
      if (dir.existsSync()) await dir.delete(recursive: true);
    });

    List<Map> wire(Map<String, dynamic> body) =>
        (body['messages'] as List).cast<Map>();

    test('/btw is a built-in, routed to the sheet, and never sent as a turn',
        () async {
      final (_, controller) = await boot();
      final asked = <String>[];
      final toasts = <String>[];
      final runner = StudioSlashCommands(
        controller: controller,
        onHelp: () {},
        onSkills: () {},
        onContext: () {},
        onAgents: () {},
        onNewSession: () async {},
        onToast: toasts.add,
        onUnknown: (_, _, name) => fail('/$name was not known'),
        onBtw: (q, _) => asked.add(q),
      );
      controller.onSlashCommand = runner.handle;
      expect(runner.commands.map((c) => c.name), contains('btw'));
      expect(matchCommands(runner.commands, 'bt').first.name, 'btw');

      await controller.send('/btw BTW_Q how long is the description?');
      await controller.send('/btw');
      expect(asked, ['BTW_Q how long is the description?']);
      expect(toasts.single, contains('/btw <question>'));
      expect(requests, isEmpty);
      expect(controller.session.transcript, isEmpty);
      expect(controller.session.queued, isEmpty);
    });

    test('the side question is the agent\'s next request plus one user turn, '
        'tools off, and leaves the session untouched', () async {
      final (_, controller) = await boot();
      await controller.send('STUDIO_ONE a lighthouse keeper.');
      await controller.flush();
      final saved = jsonEncode(controller.session.toJson());
      final next = jsonEncode(controller.nextRequestFor(kMainAgent)!.messages
          .map((m) => m.toJson())
          .toList());
      requests.clear();

      final answer = await controller.askAside('BTW_Q what have we got?');
      expect(answer, 'SIDE_ANSWER');

      final body = requests.single;
      final msgs = wire(body);
      expect(msgs.first['role'], 'system');
      expect(msgs.first['content'], contains('Character Studio'));
      expect(msgs.where((m) => m['role'] == 'system'), hasLength(1));
      expect(jsonEncode(msgs), contains('STUDIO_ONE'));
      expect(msgs.last['role'], 'user');
      expect((msgs.last['content'] as String).trim(),
          endsWith('BTW_Q what have we got?'));
      // Tools stay declared (the history may hold calls) but cannot be used.
      expect(body['tools'], isNotEmpty);
      expect(body['tool_choice'], 'none');

      await controller.flush();
      expect(jsonEncode(controller.session.toJson()), saved);
      expect(
        jsonEncode(controller.nextRequestFor(kMainAgent)!.messages
            .map((m) => m.toJson())
            .toList()),
        next,
      );

      requests.clear();
      await controller.send('STUDIO_TWO carry on.');
      final later = jsonEncode(requests.single);
      expect(later, isNot(contains('BTW_Q')));
      expect(later, isNot(contains('SIDE_ANSWER')));
      expect(later, contains('STUDIO_ONE'));
    });

    test('a call still running is answered in the copy only', () async {
      final (_, controller) = await boot();
      const call = ToolCall(id: 'c1', name: 'get_draft');
      controller.session.transcript.addAll([
        AgentMessage.user('STUDIO_ONE build her.'),
        AgentMessage(
          role: AgentRole.assistant,
          text: 'Looking.',
          toolCalls: const [call],
        ),
      ]);
      await controller.askAside('BTW_Q are you nearly done?');

      final msgs = wire(requests.single);
      final result = msgs.indexWhere((m) => m['role'] == 'tool');
      expect(result, greaterThan(0));
      expect(msgs[result]['tool_call_id'], 'c1');
      expect(msgs[result]['content'], contains('Still running'));
      expect(msgs.last['content'], contains('BTW_Q'));
      // The real transcript still waits for the real result.
      expect(controller.session.transcript, hasLength(2));
      expect(controller.session.transcript.last.role, AgentRole.assistant);
    });
  });
}
