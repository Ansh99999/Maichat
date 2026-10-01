import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/agent_message.dart';
import 'package:maichat/models/message_image.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/models/studio.dart';
import 'package:maichat/services/studio/studio_controller.dart';
import 'package:maichat/services/studio/studio_memory.dart';
import 'package:maichat/services/studio/studio_prompt.dart';
import 'package:maichat/services/studio/studio_store.dart';
import 'package:maichat/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The user talking to a sub-agent directly: a working one reads it at its
/// next step, a finished (or cut-off) one is carried on with it, and the main
/// agent hears about it without being started by it. Driven through the real
/// [AppState], [StudioController] and agent client against a loopback model.
/// Plain `test()`s only: a `testWidgets` in this file would make every real
/// HTTP request in it answer 400.
void main() {
  late HttpServer server;
  late Directory dir;
  late List<({String raw, Map<String, dynamic> body})> requests;
  var booted = false;

  late FutureOr<List<Object>> Function(Map<String, dynamic> body) answer;

  Map<String, dynamic> calls(List<(String, String, Map<String, dynamic>)> list) => {
        'choices': [
          {
            'delta': {
              'tool_calls': [
                for (var i = 0; i < list.length; i++)
                  {
                    'index': i,
                    'id': list[i].$1,
                    'type': 'function',
                    'function': {
                      'name': list[i].$2,
                      'arguments': jsonEncode(list[i].$3),
                    },
                  },
              ],
            },
          },
        ],
      };

  Map<String, dynamic> words(String text) => {
        'choices': [
          {
            'delta': {'content': text},
          },
        ],
      };

  List<Map> messagesOf(Map<String, dynamic> body) =>
      (body['messages'] as List).cast<Map>();
  String systemOf(Map<String, dynamic> body) =>
      messagesOf(body).first['content'] as String;
  bool fromSubagent(Map<String, dynamic> body) =>
      systemOf(body).contains('character-building team');
  bool fromLead(Map<String, dynamic> body) => !fromSubagent(body);
  List<String> userTexts(Map<String, dynamic> body) => [
        for (final m in messagesOf(body))
          if (m['role'] == 'user') m['content'].toString(),
      ];
  Iterable<Map<String, dynamic>> leadBodies() =>
      requests.map((r) => r.body).where(fromLead);
  Iterable<Map<String, dynamic>> subBodies() =>
      requests.map((r) => r.body).where(fromSubagent);

  Future<AppState> boot() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StudioMemory.resetShared();
    requests = [];
    booted = true;
    dir = await Directory.systemTemp.createTemp('studio_subchat');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final raw = await utf8.decoder.bind(request).join();
      final body = jsonDecode(raw) as Map<String, dynamic>;
      requests.add((raw: raw, body: body));
      List<Object> events;
      try {
        events = await answer(body);
      } catch (_) {
        return;
      }
      try {
        request.response.headers.contentType =
            ContentType('text', 'event-stream');
        for (final e in events) {
          request.response.write('data: ${jsonEncode(e)}\n\n');
        }
        request.response.write('data: [DONE]\n\n');
        await request.response.close();
      } catch (_) {
        // The client went away (a stop).
      }
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
    return state;
  }

  tearDown(() async {
    if (!booted) return;
    booted = false;
    await server.close(force: true);
    await dir.delete(recursive: true);
  });

  StudioController controllerFor(AppState state, [StudioSession? session]) {
    final controller = StudioController(
      state: state,
      store: StudioStore(dir),
      session: session ?? newStudioSession(),
    );
    addTearDown(() async {
      controller.stop();
      await controller.flush();
    });
    return controller;
  }

  Future<void> until(bool Function() done, [String what = '']) async {
    for (var i = 0; i < 400; i++) {
      if (done()) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('Timed out waiting ${what.isEmpty ? '' : 'for $what'}');
  }

  test('a finished sub-agent is carried on with what the user wrote; the main '
      'agent hears its reply next time, and is not started by it', () async {
    var subTurns = 0;
    var leadTurns = 0;
    answer = (body) async {
      if (fromSubagent(body)) {
        subTurns++;
        return [words(subTurns == 1 ? 'Three greetings.' : 'Made them darker.')];
      }
      leadTurns++;
      if (leadTurns == 1) {
        return [
          calls([
            ('t1', 'task', {
              'description': 'Greetings',
              'prompt': 'Write three greetings.',
              'agent_type': 'writer',
            }),
          ]),
        ];
      }
      return [words(leadTurns == 2 ? 'Greetings are in.' : 'Noted.')];
    };
    final state = await boot();
    final controller = controllerFor(state);
    await controller.send('Build her.');
    expect(leadTurns, 2);
    final sub = controller.subagents.single;
    expect(sub.status, StudioAgentStatus.done);

    await controller.sendToSubagent(sub.id, 'Make them darker.');
    // Carried on at once, in the background, with its own conversation.
    expect(sub.running, isTrue);
    expect(sub.background, isTrue);
    await controller.idle;

    expect(subTurns, 2);
    final second = subBodies().last;
    expect(userTexts(second).last, '$kFromUserPrefix Make them darker.');
    // Its first run is still in front of it.
    expect(userTexts(second).first, 'Write three greetings.');
    expect(
      sub.transcript.where((m) => m.text == '$kFromUserPrefix Make them darker.'),
      hasLength(1),
    );
    expect(sub.queued, isEmpty);
    expect(sub.report, contains('> Make them darker.'));
    expect(sub.report, endsWith('Made them darker.'));

    // The main agent did not run to hear it…
    expect(leadTurns, 2);
    expect(controller.running, isFalse);
    // …but its next request carries the reply, and the inspector says so.
    final next = controller.nextRequestFor(kMainAgent)!;
    expect(next.waiting, 1);
    expect(next.transcript.last.text,
        startsWith('[Studio note] Subagent 1 (task_id "${sub.id}") replied to the user'));

    await controller.send('Carry on.');
    final lead = leadBodies().last;
    final texts = userTexts(lead);
    expect(texts.last, 'Carry on.');
    final note = texts[texts.length - 2];
    expect(note, startsWith('[Studio note] Subagent 1 (task_id "${sub.id}") '
        'replied to the user'));
    expect(note, contains('> Make them darker.'));
    expect(note, contains('Made them darker.'));
  });

  test('a working sub-agent reads what the user wrote at its next step, and '
      'its report to the main agent says the user stepped in', () async {
    final subFirst = Completer<void>();
    var subTurns = 0;
    var leadTurns = 0;
    answer = (body) async {
      if (fromSubagent(body)) {
        subTurns++;
        if (subTurns == 1) {
          await subFirst.future;
          return [calls([('s1', 'get_draft', <String, dynamic>{})])];
        }
        return [words('Named her Maren.')];
      }
      leadTurns++;
      if (leadTurns == 1) {
        return [
          calls([
            ('t1', 'task', {
              'description': 'Greetings',
              'prompt': 'Write greetings.',
              'agent_type': 'writer',
              'background': true,
            }),
          ]),
        ];
      }
      return [words(leadTurns == 2 ? 'Working on it.' : 'Heard back.')];
    };
    final state = await boot();
    final controller = controllerFor(state);
    await controller.send('Go.');
    final sub = controller.subagents.single;
    await until(() => subTurns == 1, 'the sub-agent to start');
    expect(sub.running, isTrue);

    await controller.sendToSubagent(sub.id, 'Call her Maren.');
    expect(sub.queued.single.text, 'Call her Maren.');
    expect(controller.queuedForUser(sub.id), hasLength(1));
    // The inspector's next request for it carries the message.
    final next = controller.nextRequestFor(sub.id)!;
    expect(next.waiting, 1);
    expect(next.transcript.last.text, '$kFromUserPrefix Call her Maren.');
    expect(jsonEncode(next.wire!.body), contains('$kFromUserPrefix Call her Maren.'));

    subFirst.complete();
    await until(() => leadTurns == 3, 'the main agent to hear the report');
    await controller.idle;

    expect(userTexts(subBodies().last).last, '$kFromUserPrefix Call her Maren.');
    expect(sub.queued, isEmpty);
    // A run the main agent started still reports the usual way — with the
    // user's word at the top.
    final note = userTexts(leadBodies().last).last;
    expect(note, contains('finished in the background'));
    expect(note, contains('The user wrote to it directly during this run'));
    expect(note, contains('> Call her Maren.'));
  });

  test('the request a carried-on sub-agent sends is the one the inspector '
      'showed', () async {
    answer = (body) async => [words('Done.')];
    final state = await boot();
    final session = newStudioSession()
      ..subagents.add(StudioSubagent(
        id: 'sa1',
        number: 1,
        description: 'Greetings',
        prompt: 'Write greetings.',
        callId: 't1',
        role: 'writer',
        transcript: [
          AgentMessage.user('Write greetings.'),
          AgentMessage(role: AgentRole.assistant, text: 'Wrote three.'),
        ],
        status: StudioAgentStatus.done,
      ));
    final controller = controllerFor(state, session);
    // The memory is read as the controller starts; the run reads it too.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await controller.sendToSubagent('sa1', 'Shorter, please.');
    final shown = jsonEncode(controller.nextRequestFor('sa1')!.wire!.body);
    await controller.idle;
    expect(subBodies(), hasLength(1));
    expect(requests.single.raw, shown);
  });

  test('a message to a sub-agent survives the app closing, and is read when '
      'the user carries it on', () async {
    answer = (body) async => [words('Back on it.')];
    final state = await boot();
    // As the app saved it: the sub-agent mid-call, with a message from the
    // user not yet read.
    final saved = newStudioSession()
      ..active = true
      ..subagents.add(StudioSubagent(
        id: 'sa1',
        number: 1,
        description: 'Greetings',
        prompt: 'Write greetings.',
        callId: 't1',
        role: 'writer',
        transcript: [
          AgentMessage.user('Write greetings.'),
          AgentMessage(
            role: AgentRole.assistant,
            toolCalls: const [ToolCall(id: 's1', name: 'get_draft')],
          ),
        ],
        queued: [StudioQueuedMessage(id: 'q1', text: 'Keep them short.')],
      ));
    final session = StudioSession.fromJson(
      jsonDecode(jsonEncode(saved.toJson())) as Map<String, dynamic>,
    );
    final sub = session.subagents.single;
    expect(sub.interrupted, isTrue);
    expect(sub.running, isFalse);
    expect(sub.queued.single.text, 'Keep them short.');

    final controller = controllerFor(state, session);
    await controller.sendToSubagent('sa1', 'And sad.');
    await controller.idle;

    final body = subBodies().single;
    final texts = userTexts(body);
    expect(texts.sublist(texts.length - 2), [
      '$kFromUserPrefix Keep them short.',
      '$kFromUserPrefix And sad.',
    ]);
    // The cut-off call was answered before anything was sent again.
    final tool = messagesOf(body).where((m) => m['role'] == 'tool');
    expect(tool, hasLength(1));
    expect(sub.interrupted, isFalse);
    expect(sub.status, StudioAgentStatus.done);
    expect(sub.queued, isEmpty);
    // Saved, on disk, with the conversation it now has.
    await controller.flush();
    final reloaded = (await StudioStore(dir).list()).single.subagents.single;
    expect(reloaded.queued, isEmpty);
    expect(reloaded.transcript.last.text, 'Back on it.');
  });

  test('stopping a sub-agent stops it alone, and leaves what was queued for '
      'it until the user writes again', () async {
    final hold = Completer<void>();
    var leadTurns = 0;
    answer = (body) async {
      if (fromSubagent(body)) {
        await hold.future;
        return [words('Never.')];
      }
      leadTurns++;
      return [words('Fine.')];
    };
    final state = await boot();
    final session = newStudioSession()
      ..subagents.add(StudioSubagent(
        id: 'sa1',
        number: 1,
        description: 'Greetings',
        prompt: 'Write greetings.',
        callId: 't1',
        transcript: [AgentMessage.user('Write greetings.')],
        status: StudioAgentStatus.done,
      ));
    final controller = controllerFor(state, session);
    await controller.sendToSubagent('sa1', 'Go on.');
    await until(() => subBodies().isNotEmpty, 'the sub-agent to start');
    await controller.sendToSubagent('sa1', 'And another.');
    controller.stopSubagent('sa1');
    await controller.idle;

    final sub = controller.subagent('sa1')!;
    expect(sub.status, StudioAgentStatus.cancelled);
    expect(sub.queued.single.text, 'And another.');
    await Future<void>.delayed(const Duration(milliseconds: 80));
    // Not started again, and the main agent never ran.
    expect(subBodies(), hasLength(1));
    expect(leadTurns, 0);
    hold.complete();
  });

  test('the picture sweep keeps a picture sent to a sub-agent and not yet '
      'read', () async {
    dir = await Directory.systemTemp.createTemp('studio_subchat_refs');
    addTearDown(() => dir.delete(recursive: true));
    final store = StudioStore(dir);
    final session = newStudioSession()
      ..subagents.add(StudioSubagent(
        id: 'sa1',
        number: 1,
        description: 'Greetings',
        prompt: 'Write greetings.',
        callId: 't1',
        queued: [
          StudioQueuedMessage(
            id: 'q1',
            text: 'Like this one.',
            images: const [MessageImage(ref: 'local:pic.png', mime: 'image/png')],
          ),
        ],
      ));
    await store.save(session);
    expect(await store.pictureRefs(), contains('local:pic.png'));
  });
}
