import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/agent_message.dart';
import 'package:maichat/models/message_image.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/models/studio.dart';
import 'package:maichat/services/avatar_store.dart';
import 'package:maichat/services/studio/agent_runner.dart';
import 'package:maichat/services/studio/studio_controller.dart';
import 'package:maichat/services/studio/studio_memory.dart';
import 'package:maichat/services/studio/studio_store.dart';
import 'package:maichat/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Sub-agents end to end: a real [AppState] and [StudioController] against a
/// loopback model that answers each request by who is asking — the main agent
/// or one of its sub-agents — so the whole spawn, run, report and resume path
/// is driven through the real client.
void main() {
  late HttpServer server;
  late Directory dir;
  late List<Map<String, dynamic>> requests;
  var booted = false;

  /// Decides the reply to one request body.
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

  Map<String, dynamic> usage(int input, int output) => {
        'choices': <Object>[],
        'usage': {'prompt_tokens': input, 'completion_tokens': output},
      };

  List<Map> messagesOf(Map<String, dynamic> body) =>
      (body['messages'] as List).cast<Map>();

  String systemOf(Map<String, dynamic> body) =>
      messagesOf(body).first['content'] as String;

  bool fromSubagent(Map<String, dynamic> body) =>
      systemOf(body).contains('character-building team');

  /// The first user turn — a sub-agent's task prompt.
  String taskOf(Map<String, dynamic> body) => messagesOf(body)
      .firstWhere((m) => m['role'] == 'user')['content']
      .toString();

  Future<AppState> boot({AvatarStore? avatars}) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    requests = [];
    booted = true;
    dir = await Directory.systemTemp.createTemp('studio_agents');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final body = jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>;
      requests.add(body);
      List<Object> events;
      try {
        events = await answer(body);
      } catch (_) {
        return; // The client went away (a stop).
      }
      try {
        request.response.headers.contentType =
            ContentType('text', 'event-stream');
        for (final e in events) {
          request.response.write('data: ${e is String ? e : jsonEncode(e)}\n\n');
        }
        request.response.write('data: [DONE]\n\n');
        await request.response.close();
      } catch (_) {
        // The client went away mid-reply.
      }
    });
    final state = AppState(avatars: avatars);
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

  StudioController controllerFor(AppState state) {
    final controller = StudioController(
      state: state,
      store: StudioStore(dir),
      session: newStudioSession(),
    );
    addTearDown(controller.flush);
    return controller;
  }

  test('a type the user defined runs with its own prompt, tools and model; '
      'memory reaches every agent', () async {
    StudioMemory.resetShared();
    answer = (body) {
      if (fromSubagent(body)) {
        return [words('Tuned the greeting.'), usage(50, 5)];
      }
      final hasResults = messagesOf(body).any((m) => m['role'] == 'tool');
      if (!hasResults) {
        return [
          calls([
            (
              'v1',
              'task',
              {
                'description': 'Voice pass',
                'prompt': 'Tune the first message.',
                'agent_type': 'voice_coach',
              },
            ),
          ]),
        ];
      }
      return [words('Done.')];
    };
    final state = await boot();
    await state.updateStudioConfig(state.studioConfig.copyWith(
      customAgents: const [
        StudioAgentType(
          id: 'voice_coach',
          label: 'Voice coach',
          description: 'Tunes how the character talks.',
          prompt: 'VOICE_COACH_RULES',
          toolGroups: {'read', 'character'},
          model: 'coach-model',
        ),
      ],
    ));
    final memory = await StudioMemory.forDirectory(dir);
    expect(memory.add('Prefers third-person present tense.'), isNull);

    final controller = controllerFor(state);
    await controller.send('Make her voice drier.');

    final lead = requests.first;
    final sub = requests.firstWhere(fromSubagent);
    // The main agent is told about the type and what the user prefers.
    expect(systemOf(lead), contains('voice_coach'));
    expect(systemOf(lead), contains('Prefers third-person present tense.'));
    // The sub-agent runs on its type's model, prompt and tools only.
    expect(sub['model'], 'coach-model');
    expect(lead['model'], 'builder');
    expect(systemOf(sub), contains('VOICE_COACH_RULES'));
    expect(systemOf(sub), contains('Prefers third-person present tense.'));
    final subTools = {
      for (final t in sub['tools'] as List) (t as Map)['function']['name'],
    };
    expect(subTools, containsAll(['get_draft', 'set_fields', 'edit_field']));
    expect(subTools, isNot(contains('upsert_lore_entry')));
    expect(subTools, isNot(contains('task')));
    expect(subTools, isNot(contains('remember')));
    expect(controller.subagents.single.status, StudioAgentStatus.done);
    expect(controller.subagents.single.role, 'voice_coach');
  });

  test('an unknown agent type is refused in words the model can fix', () async {
    answer = (body) {
      final hasResults = messagesOf(body).any((m) => m['role'] == 'tool');
      if (!hasResults) {
        return [
          calls([
            (
              'x1',
              'task',
              {'description': 'Nope', 'prompt': 'Do it.', 'agent_type': 'wizard'},
            ),
          ]),
        ];
      }
      return [words('Understood.')];
    };
    final state = await boot();
    final controller = controllerFor(state);
    await controller.send('go');
    final result = controller.session.transcript
        .firstWhere((m) => m.role == AgentRole.tool);
    expect(result.isError, isTrue);
    final error = (jsonDecode(result.text) as Map)['error'] as String;
    expect(error, contains('Unknown agent_type "wizard"'));
    expect(error, contains('critic'));
    expect(controller.subagents, isEmpty);
  });

  test('asking for five sub-agents runs five, side by side, and reports back',
      () async {
    var subsInFlight = 0;
    var mostAtOnce = 0;
    answer = (body) async {
      if (fromSubagent(body)) {
        subsInFlight++;
        if (subsInFlight > mostAtOnce) mostAtOnce = subsInFlight;
        await Future<void>.delayed(const Duration(milliseconds: 40));
        subsInFlight--;
        final task = taskOf(body);
        return [words('Report for $task'), usage(100, 10)];
      }
      // The main agent: first spawn, then sum up.
      final hasResults = messagesOf(body).any((m) => m['role'] == 'tool');
      if (!hasResults) {
        return [
          calls([
            for (var i = 1; i <= 5; i++)
              (
                't$i',
                'task',
                {
                  'description': 'Part $i',
                  'agent_type': i == 5 ? 'critic' : 'general',
                  'prompt': 'part $i',
                },
              ),
          ]),
          usage(1000, 50),
        ];
      }
      return [words('All five parts are done.'), usage(1500, 20)];
    };
    final state = await boot();
    final controller = controllerFor(state);
    final session = controller.session;

    await controller.send('Spawn 5 subagents to build her.');

    expect(controller.running, isFalse);
    expect(controller.notice, isNull);
    expect(controller.subagents, hasLength(5));
    expect(controller.subagents.map((a) => a.label),
        ['Subagent 1', 'Subagent 2', 'Subagent 3', 'Subagent 4', 'Subagent 5']);
    expect(mostAtOnce, 5);
    for (final a in controller.subagents) {
      expect(a.status, StudioAgentStatus.done);
      expect(a.endedAt, isNotNull);
      expect(a.report, startsWith('Report for'));
      expect(a.inputTokens, 100);
      expect(a.outputTokens, 10);
      // Its chat: the task, then its answer.
      expect(a.transcript.map((m) => m.role),
          [AgentRole.user, AgentRole.assistant]);
      expect(controller.transcriptFor(a.id), same(a.transcript));
      expect(controller.subagentForCall(a.callId), same(a));
    }
    expect(controller.subagents.last.role, 'critic');
    expect(controller.anySubagentRunning, isFalse);

    // The critic got the critic's tools; nobody below the main agent got task.
    final subRequests = requests.where(fromSubagent).toList();
    expect(subRequests, hasLength(5));
    for (final r in subRequests) {
      final tools = [for (final t in r['tools'] as List) t['function']['name']];
      expect(tools, isNot(contains('task')));
    }
    final critic = subRequests.firstWhere((r) => taskOf(r) == 'part 5');
    expect([for (final t in critic['tools'] as List) t['function']['name']],
        ['get_draft', 'read_document', 'playtest', 'todo_write']);

    // The reports came back to the main agent as data, one per call.
    final results = session.transcript.where((m) => m.role == AgentRole.tool);
    expect(results.map((m) => m.toolCallId), ['t1', 't2', 't3', 't4', 't5']);
    final first = jsonDecode(results.first.text) as Map;
    expect(first['subagent'], 'Subagent 1');
    expect(first['status'], 'done');
    expect(first['task_id'], controller.subagents.first.id);
    expect(session.transcript.last.text, 'All five parts are done.');

    // Spend: the main agent's two turns plus every sub-agent's.
    expect(session.inputTokens, 1000 + 1500 + 5 * 100);
    expect(session.outputTokens, 50 + 20 + 5 * 10);

    // And all of it is saved.
    await controller.flush();
    final saved = await StudioStore(dir).read(session.id);
    expect(saved!.subagents, hasLength(5));
    expect(saved.subagents.first.transcript, hasLength(2));
    expect(saved.subagents.first.report, startsWith('Report for'));
  });

  test('beyond the parallel limit, sub-agents wait for a place', () async {
    var inFlight = 0;
    var mostAtOnce = 0;
    answer = (body) async {
      if (fromSubagent(body)) {
        inFlight++;
        if (inFlight > mostAtOnce) mostAtOnce = inFlight;
        await Future<void>.delayed(const Duration(milliseconds: 30));
        inFlight--;
        return [words('ok')];
      }
      if (!messagesOf(body).any((m) => m['role'] == 'tool')) {
        return [
          calls([
            for (var i = 0; i < 5; i++)
              ('q$i', 'task', {'description': 'd', 'prompt': 'p$i'}),
          ]),
        ];
      }
      return [words('done')];
    };
    final state = await boot();
    await state.updateStudioConfig(
      state.studioConfig.copyWith(maxParallelSubagents: 2),
    );
    final controller = controllerFor(state);
    await controller.send('go');
    expect(mostAtOnce, 2);
    expect(controller.subagents, hasLength(5));
    expect(controller.subagents.every((a) => a.status == StudioAgentStatus.done),
        isTrue);
  });

  test('task_id carries a finished sub-agent on with its chat intact',
      () async {
    var leadTurn = 0;
    answer = (body) {
      if (fromSubagent(body)) {
        final users = messagesOf(body).where((m) => m['role'] == 'user').length;
        return [words(users == 1 ? 'First report.' : 'Second report.')];
      }
      leadTurn++;
      if (leadTurn == 1) {
        return [
          calls([
            ('a', 'task', {'description': 'Greetings', 'prompt': 'Write greetings.'}),
          ]),
        ];
      }
      if (leadTurn == 2) {
        final result = messagesOf(body).lastWhere((m) => m['role'] == 'tool');
        final id = (jsonDecode(result['content'] as String) as Map)['task_id'];
        return [
          calls([
            ('b', 'task', {
              'description': 'Greetings',
              'prompt': 'Make them darker.',
              'task_id': id,
            }),
          ]),
        ];
      }
      return [words('Done.')];
    };
    final state = await boot();
    final controller = controllerFor(state);
    await controller.send('go');

    expect(controller.subagents, hasLength(1));
    final a = controller.subagents.single;
    expect(a.report, 'Second report.');
    expect(a.transcript.map((m) => m.text), [
      'Write greetings.',
      'First report.',
      'Make them darker.',
      'Second report.',
    ]);
    expect(controller.subagentForCall('b'), same(a));
    // The second run was sent the whole conversation so far.
    final second = requests.where(fromSubagent).last;
    expect(messagesOf(second).where((m) => m['role'] == 'user'), hasLength(2));
  });

  test('an unknown task_id is an error the model can fix', () async {
    var leadTurn = 0;
    answer = (body) {
      leadTurn++;
      if (leadTurn == 1) {
        return [
          calls([
            ('a', 'task', {'description': 'x', 'prompt': 'y', 'task_id': 'nope'}),
          ]),
        ];
      }
      return [words('Sorry.')];
    };
    final state = await boot();
    final controller = controllerFor(state);
    await controller.send('go');
    final result = controller.session.transcript
        .firstWhere((m) => m.role == AgentRole.tool);
    expect(result.isError, isTrue);
    expect(result.text, contains('No sub-agent has task_id'));
    expect(controller.subagents, isEmpty);
  });

  test('stopping the main agent stops its sub-agents', () async {
    final hang = Completer<void>();
    addTearDown(() {
      if (!hang.isCompleted) hang.complete();
    });
    answer = (body) async {
      if (fromSubagent(body)) {
        await hang.future;
        return [words('too late')];
      }
      if (!messagesOf(body).any((m) => m['role'] == 'tool')) {
        return [
          calls([
            ('s1', 'task', {'description': 'd', 'prompt': 'p1'}),
            ('s2', 'task', {'description': 'd', 'prompt': 'p2'}),
          ]),
        ];
      }
      return [words('never')];
    };
    final state = await boot();
    final controller = controllerFor(state);
    final run = controller.send('go');
    for (var i = 0; i < 100 && controller.subagents.length < 2; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(controller.anySubagentRunning, isTrue);
    controller.stop();
    await run;
    expect(controller.running, isFalse);
    expect(controller.subagents, hasLength(2));
    for (final a in controller.subagents) {
      expect(a.status, StudioAgentStatus.cancelled);
      expect(a.endedAt, isNotNull);
    }
    // Every task call still has an answer.
    final transcript = controller.session.transcript;
    final asked = transcript
        .where((m) => m.role == AgentRole.assistant)
        .expand((m) => m.toolCalls)
        .map((c) => c.id)
        .toSet();
    final answered = transcript
        .where((m) => m.role == AgentRole.tool)
        .map((m) => m.toolCallId)
        .toSet();
    expect(answered, containsAll(asked));
  });

  test('the step limit ends with a summary turn that may not call tools',
      () async {
    answer = (body) {
      if (body['tool_choice'] == 'none') {
        return [words('Read the draft twice; nothing is built yet.')];
      }
      return [
        calls([('g${requests.length}', 'get_draft', <String, dynamic>{})]),
      ];
    };
    final state = await boot();
    await state.updateStudioConfig(state.studioConfig.copyWith(maxSteps: 3));
    final controller = controllerFor(state);
    await controller.send('go');
    expect(requests, hasLength(3));
    expect(requests[0].containsKey('tools'), isTrue);
    // The tools stay declared, so the tool calls in the history are valid on
    // every host; calling one is what is switched off.
    expect(requests[2].containsKey('tools'), isTrue);
    expect(requests[2]['tool_choice'], 'none');
    expect(requests[0].containsKey('tool_choice'), isFalse);
    expect(jsonEncode(requests[2]['messages']), contains('step limit'));
    expect(controller.session.transcript.last.text,
        'Read the draft twice; nothing is built yet.');
    expect(controller.notice, contains('Stopped after 3 steps'));
  });

  test('a picture sent to the Studio reaches the wire but not the session file',
      () async {
    final pictures = await Directory.systemTemp.createTemp('studio_pics');
    addTearDown(() => pictures.delete(recursive: true));
    File('${pictures.path}/pic.png').writeAsBytesSync([1, 2, 3, 4]);
    answer = (body) => [words('A grey coat, then.')];
    final state = await boot(avatars: AvatarStore(pictures));
    final controller = controllerFor(state);
    await controller.send(
      'Make her look like this.',
      images: const [MessageImage(ref: 'local:pic.png', mime: 'image/png')],
    );
    final user = messagesOf(requests.single)[1];
    final content = (user['content'] as List).cast<Map>();
    expect(content.first, {'type': 'text', 'text': 'Make her look like this.'});
    expect(content.last['type'], 'image_url');
    expect(content.last['image_url']['url'],
        'data:image/png;base64,${base64Encode([1, 2, 3, 4])}');

    await controller.flush();
    final file = File('${dir.path}/${controller.session.id}.json');
    final saved = file.readAsStringSync();
    expect(saved, contains('local:pic.png'));
    expect(saved, isNot(contains(base64Encode([1, 2, 3, 4]))));
    // The sweep keeps what a session refers to.
    expect(await StudioStore(dir).pictureRefs(), contains('local:pic.png'));
  });

  test("the picture sweep keeps what a Studio session refers to", () async {
    final pictures = await Directory.systemTemp.createTemp('studio_sweep');
    final sessions = await Directory.systemTemp.createTemp('studio_sweep_s');
    addTearDown(() async {
      await pictures.delete(recursive: true);
      await sessions.delete(recursive: true);
    });
    for (final name in ['sent.png', 'portrait.png', 'orphan.png']) {
      File('${pictures.path}/$name').writeAsBytesSync([1]);
    }
    final store = StudioStore(sessions);
    final session = newStudioSession();
    session.workspace.character.avatar = 'local:portrait.png';
    session.subagents.add(StudioSubagent(
      id: 'a',
      number: 1,
      description: 'd',
      prompt: 'p',
      callId: 'c',
      transcript: [
        AgentMessage.user('look', images: const [MessageImage(ref: 'local:sent.png')]),
      ],
    ));
    await store.save(session);
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final state = AppState(avatars: AvatarStore(pictures), studio: store);
    await state.init();
    // Any sweep will do; this one runs whether or not the chat exists.
    await state.clearChatCharacterOverride('none', 'none');
    expect(File('${pictures.path}/orphan.png').existsSync(), isFalse);
    expect(File('${pictures.path}/portrait.png').existsSync(), isTrue);
    expect(File('${pictures.path}/sent.png').existsSync(), isTrue);
  });

  test('stale tool output shortens from the middle', () {
    final text = 'HEAD${'x' * 1000}TAIL';
    final short = AgentRunner.shortenMiddle(text);
    expect(short, startsWith('HEAD'));
    expect(short, endsWith('TAIL'));
    expect(short, contains('tokens truncated'));
  });
}
