import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/agent_message.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/models/studio.dart';
import 'package:maichat/services/agent_client.dart';
import 'package:maichat/services/studio/agent_runner.dart';
import 'package:maichat/services/studio/studio_controller.dart';
import 'package:maichat/services/studio/studio_store.dart';
import 'package:maichat/services/studio/studio_tools.dart';
import 'package:maichat/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The Studio's runtime: compaction, steering, surviving the app closing, and
/// background sub-agents with their messaging tools — driven through the real
/// [AppState], [StudioController] and agent client against a loopback model
/// that answers each request by who is asking.
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

  List<Map> messagesOf(Map<String, dynamic> body) =>
      (body['messages'] as List).cast<Map>();

  String systemOf(Map<String, dynamic> body) =>
      messagesOf(body).first['content'] as String;

  bool isCompaction(Map<String, dynamic> body) =>
      systemOf(body) == kCompactionPrompt;
  bool fromSubagent(Map<String, dynamic> body) =>
      systemOf(body).contains('character-building team');
  bool fromLead(Map<String, dynamic> body) =>
      !isCompaction(body) && !fromSubagent(body);

  /// The tool results in a request, newest last.
  List<Map> toolResults(Map<String, dynamic> body) =>
      [for (final m in messagesOf(body)) if (m['role'] == 'tool') m];

  List<String> userTexts(Map<String, dynamic> body) => [
        for (final m in messagesOf(body))
          if (m['role'] == 'user') m['content'].toString(),
      ];

  Future<AppState> boot({StudioConfig? config}) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    requests = [];
    booted = true;
    dir = await Directory.systemTemp.createTemp('studio_runtime');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final body = jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>;
      requests.add(body);
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
    if (config != null) await state.updateStudioConfig(config);
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

  /// Waits (in real time) until [done] holds, failing after a few seconds.
  Future<void> until(bool Function() done, [String what = '']) async {
    for (var i = 0; i < 400; i++) {
      if (done()) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('Timed out waiting ${what.isEmpty ? '' : 'for $what'}');
  }

  // --- compaction ------------------------------------------------------------

  group('compaction', () {
    /// A long history of rounds: a user turn, a call, its result.
    List<AgentMessage> history(int rounds, {int size = 2000}) {
      final out = <AgentMessage>[];
      for (var i = 0; i < rounds; i++) {
        final call = ToolCall(id: 'c$i', name: 'get_draft');
        out
          ..add(AgentMessage.user('Round $i: ${'x' * size}'))
          ..add(AgentMessage(role: AgentRole.assistant, text: 'On it $i.', toolCalls: [call]))
          ..add(AgentMessage.toolResult(call, 'draft $i ${'y' * size}'));
      }
      return out;
    }

    test('the boundary never lands between a call and its result', () {
      final transcript = history(6);
      int cost(AgentMessage m) => AgentCompactor.roughTokens(m.text);
      for (var keep = 0; keep < 4000; keep += 137) {
        final b = AgentRunner.compactionBoundary(
          transcript,
          from: 0,
          keepTokens: keep,
          cost: cost,
        );
        if (b == null) continue;
        expect(transcript[b].role, isNot(AgentRole.tool), reason: 'keep $keep');
        // Every result after the boundary has its call after it too.
        final tail = transcript.sublist(b);
        final callIds = {for (final m in tail) for (final c in m.toolCalls) c.id};
        for (final m in tail.where((m) => m.role == AgentRole.tool)) {
          expect(callIds, contains(m.toolCallId));
        }
      }
      // Too little to summarise: nothing.
      expect(
        AgentRunner.compactionBoundary(
          history(1),
          from: 0,
          keepTokens: 0,
          cost: cost,
        ),
        isNull,
      );
    });

    test('crossing the threshold compacts once; the wire sends the summary and '
        'the rest', () async {
      final transcript = history(8);
      final compactions = <StudioCompaction>[];
      final sent = <List<AgentMessage>>[];
      final offered = <int>[];
      final runner = AgentRunner(
        name: 'studio',
        systemPrompt: 'SYS',
        tools: studioToolsFor('studio'),
        context: StudioToolContext(
          session: StudioSession(
            id: 's',
            title: '',
            workspace: StudioWorkspace(character: Character(id: 'c', name: '')),
          ),
          services: _NoServices(),
        ),
        compactor: AgentCompactor(budget: 6000, compactions: compactions),
        turn: (client, messages, tools) async* {
          sent.add(List.of(messages));
          offered.add(tools.length);
          if (messages.first.text == kCompactionPrompt) {
            yield const AgentDelta(text: 'SUMMARY: building a keeper.');
          } else {
            yield const AgentDelta(text: 'Carrying on.');
          }
        },
      );
      final before = List.of(transcript);
      await runner.run(transcript);

      expect(compactions, hasLength(1));
      final c = compactions.single;
      expect(c.summary, 'SUMMARY: building a keeper.');
      expect(transcript[c.upTo].role, isNot(AgentRole.tool));
      // The summariser was offered no tools and saw the older part as text.
      expect(offered.first, 0);
      expect(sent.first[1].text, contains('The conversation to summarise'));
      expect(sent.first[1].text, contains('Round 0'));
      expect(sent.first.any((m) => m.toolCalls.isNotEmpty), isFalse);
      // The agent's own request: system, the summary note, then the transcript
      // from the boundary on.
      final request = sent.last;
      expect(request[0].role, AgentRole.system);
      expect(request[1].text, startsWith('[Studio note] Summary of earlier'));
      expect(request[1].text, contains('SUMMARY: building a keeper.'));
      expect(request[2].text, transcript[c.upTo].text);
      expect(request.length, 2 + (before.length - c.upTo));
      // The transcript itself is whole: nothing was cut for display.
      expect(transcript.take(before.length).map((m) => m.text),
          before.map((m) => m.text));
      expect(transcript.last.text, 'Carrying on.');
      // One compaction: the request after it fits.
      expect(sent.where((m) => m.first.text == kCompactionPrompt), hasLength(1));
    });

    test('a compacted session saves and loads with its summary', () {
      final session = StudioSession(
        id: 's',
        title: '',
        workspace: StudioWorkspace(character: Character(id: 'c', name: '')),
        compactions: [StudioCompaction(summary: 'S', upTo: 4, tokensBefore: 99)],
      );
      final sub = StudioSubagent(
        id: 'a',
        number: 1,
        description: 'd',
        prompt: 'p',
        callId: 'k',
        status: StudioAgentStatus.done,
        compactions: [StudioCompaction(summary: 'T', upTo: 2)],
      );
      session.subagents.add(sub);
      final back = StudioSession.fromJson(
        jsonDecode(jsonEncode(session.toJson())) as Map<String, dynamic>,
      );
      expect(back.compactions.single.summary, 'S');
      expect(back.compactions.single.upTo, 4);
      expect(back.compactions.single.tokensBefore, 99);
      expect(back.subagents.single.compactions.single.summary, 'T');
    });

    test('end to end: a long session is summarised on the real wire', () async {
      answer = (body) => isCompaction(body)
          ? [words('SUMMARY of the long talk.')]
          : [words('Done.')];
      final state = await boot(
        config: const StudioConfig(contextBudget: kStudioMinContextBudget),
      );
      final session = newStudioSession();
      for (var i = 0; i < 12; i++) {
        session.transcript
          ..add(AgentMessage.user('Old request $i ${'z' * 3000}'))
          ..add(AgentMessage(role: AgentRole.assistant, text: 'Old answer $i'));
      }
      final controller = controllerFor(state, session);
      await controller.send('One more change.');
      final compactions = requests.where(isCompaction).toList();
      expect(compactions, hasLength(1));
      expect(compactions.single.containsKey('tools'), isFalse);
      final lead = requests.where(fromLead).single;
      final texts = userTexts(lead);
      expect(texts.first, contains('SUMMARY of the long talk.'));
      expect(texts.last, 'One more change.');
      expect(texts.any((t) => t.contains('Old request 0 ')), isFalse);
      expect(session.compactions, hasLength(1));
      // Its spend is counted like any turn.
      expect(session.inputTokens, greaterThan(0));
      // And it is on disk.
      await controller.flush();
      final saved = await StudioStore(dir).read(session.id);
      expect(saved!.compactions.single.summary, 'SUMMARY of the long talk.');
      expect(saved.transcript.length, session.transcript.length);
    });
  });

  // --- steering --------------------------------------------------------------

  group('steering', () {
    test('a message sent mid-run is queued and taken in at the next step',
        () async {
      final gate = Completer<void>();
      var leadTurns = 0;
      answer = (body) async {
        leadTurns++;
        if (leadTurns == 1) {
          await gate.future;
          return [calls([('g1', 'get_draft', <String, dynamic>{})])];
        }
        return [words('Got it.')];
      };
      final state = await boot();
      final controller = controllerFor(state);
      final run = controller.send('Build a keeper.');
      await until(() => requests.isNotEmpty, 'the first request');
      await controller.send('Make her older.');
      expect(controller.queued.single.text, 'Make her older.');
      expect(controller.running, isTrue);
      gate.complete();
      await run;

      expect(requests, hasLength(2));
      final second = messagesOf(requests[1]);
      // The queued turn sits after the tool result, before the next reply.
      final roles = [for (final m in second) m['role']];
      expect(roles, ['system', 'user', 'assistant', 'tool', 'user']);
      expect(second.last['content'], 'Make her older.');
      expect(controller.queued, isEmpty);
      expect(controller.session.transcript.last.text, 'Got it.');
    });

    test('a message queued as the answer streams is answered in the same go',
        () async {
      final gate = Completer<void>();
      var turns = 0;
      answer = (body) async {
        turns++;
        if (turns == 1) {
          await gate.future;
          return [words('Here she is.')];
        }
        return [words('Older now.')];
      };
      final state = await boot();
      final controller = controllerFor(state);
      final run = controller.send('Build a keeper.');
      await until(() => requests.isNotEmpty);
      await controller.send('Make her older.');
      gate.complete();
      await run;
      await controller.idle;
      expect(requests, hasLength(2));
      expect(userTexts(requests[1]).last, 'Make her older.');
      expect(controller.session.transcript.last.text, 'Older now.');
      expect(controller.running, isFalse);
    });

    test('a queued message can be taken back before it is read', () async {
      final gate = Completer<void>();
      var turns = 0;
      answer = (body) async {
        turns++;
        if (turns == 1) {
          await gate.future;
          return [calls([('g1', 'get_draft', <String, dynamic>{})])];
        }
        return [words('Done.')];
      };
      final state = await boot();
      final controller = controllerFor(state);
      final run = controller.send('Build.');
      await until(() => requests.isNotEmpty);
      await controller.send('Actually, no.');
      controller.cancelQueued(controller.queued.single.id);
      gate.complete();
      await run;
      expect(userTexts(requests.last), isNot(contains('Actually, no.')));
      expect(
        controller.session.transcript.any((m) => m.text == 'Actually, no.'),
        isFalse,
      );
    });
  });

  // --- surviving the app closing ---------------------------------------------

  group('interruption', () {
    /// A session as the app would have saved it mid-run: the main agent had
    /// called three tools (one answered) and one of them started a sub-agent,
    /// which had called a tool of its own.
    Map<String, dynamic> savedMidRun() {
      final session = newStudioSession();
      const draft = ToolCall(id: 'c1', name: 'get_draft');
      const edit = ToolCall(
        id: 'c2',
        name: 'set_fields',
        arguments: {'name': 'Maren'},
      );
      const task = ToolCall(
        id: 'c3',
        name: 'task',
        arguments: {'description': 'Greetings', 'prompt': 'Write greetings.'},
      );
      session.transcript.addAll([
        AgentMessage.user('Build a keeper.'),
        AgentMessage(
          role: AgentRole.assistant,
          text: 'Starting.',
          toolCalls: const [draft, edit, task],
        ),
        AgentMessage.toolResult(draft, '{"character":{}}'),
      ]);
      const subCall = ToolCall(id: 's1', name: 'get_draft');
      session.subagents.add(StudioSubagent(
        id: 'sub-1',
        number: 1,
        description: 'Greetings',
        prompt: 'Write greetings.',
        callId: 'c3',
        role: 'writer',
        transcript: [
          AgentMessage.user('Write greetings.'),
          AgentMessage(role: AgentRole.assistant, toolCalls: const [subCall]),
        ],
      ));
      session.active = true;
      return jsonDecode(jsonEncode(session.toJson())) as Map<String, dynamic>;
    }

    test('a session saved mid-run loads interrupted, with every call answered',
        () {
      final session = StudioSession.fromJson(savedMidRun());
      expect(session.interrupted, isTrue);
      expect(session.active, isFalse);
      final sub = session.subagents.single;
      expect(sub.interrupted, isTrue);
      expect(sub.running, isFalse);
      expect(sub.endedAt, isNotNull);
      expect(session.interruptedSubagents.single.id, 'sub-1');

      final results = [
        for (final m in session.transcript)
          if (m.role == AgentRole.tool) m,
      ];
      expect(results.map((m) => m.toolCallId), ['c1', 'c2', 'c3']);
      expect(results[1].isError, isTrue);
      expect(results[1].text, kInterruptedCallResult);
      final task = jsonDecode(results[2].text) as Map;
      expect(task['subagent'], 'Subagent 1');
      expect(task['task_id'], 'sub-1');
      expect(task['status'], 'interrupted');
      expect(task['report'], contains('task_id "sub-1"'));
      expect(sub.transcript.last.role, AgentRole.tool);
      expect(sub.transcript.last.toolCallId, 's1');
    });

    test('the repaired transcript pairs every call in all four dialects', () {
      final session = StudioSession.fromJson(savedMidRun());
      final messages = [AgentMessage.system('SYS'), ...session.transcript];
      Provider p(ProviderKind kind) => Provider(
            id: 'p',
            name: 'p',
            kind: kind,
            baseUrl: 'http://x/v1',
            model: 'm',
          );
      const params = AgentParams();

      final openai = AgentClient.body(p(ProviderKind.openai), messages, const [], params);
      final asked = [
        for (final m in (openai['messages'] as List).cast<Map>())
          for (final c in (m['tool_calls'] as List? ?? const [])) (c as Map)['id'],
      ];
      final answered = [
        for (final m in (openai['messages'] as List).cast<Map>())
          if (m['role'] == 'tool') m['tool_call_id'],
      ];
      expect(answered, asked);

      final responses =
          AgentClient.body(p(ProviderKind.openaiResponses), messages, const [], params);
      final input = (responses['input'] as List).cast<Map>();
      expect(
        [for (final i in input) if (i['type'] == 'function_call_output') i['call_id']],
        [for (final i in input) if (i['type'] == 'function_call') i['call_id']],
      );

      final anthropic =
          AgentClient.body(p(ProviderKind.anthropic), messages, const [], params);
      final turns = (anthropic['messages'] as List).cast<Map>();
      for (var i = 0; i < turns.length; i++) {
        final uses = [
          for (final b in (turns[i]['content'] is List ? turns[i]['content'] as List : const []))
            if ((b as Map)['type'] == 'tool_use') b['id'],
        ];
        if (uses.isEmpty) continue;
        final next = (turns[i + 1]['content'] as List).cast<Map>();
        expect(
          [for (final b in next) if (b['type'] == 'tool_result') b['tool_use_id']],
          uses,
        );
        // Results come first in that turn.
        expect(next.first['type'], 'tool_result');
      }

      final gemini = AgentClient.body(p(ProviderKind.gemini), messages, const [], params);
      final contents = (gemini['contents'] as List).cast<Map>();
      for (var i = 0; i < contents.length; i++) {
        final parts = (contents[i]['parts'] as List).cast<Map>();
        final fnCalls = parts.where((x) => x.containsKey('functionCall')).length;
        if (fnCalls == 0) continue;
        final next = (contents[i + 1]['parts'] as List).cast<Map>();
        expect(next.where((x) => x.containsKey('functionResponse')).length, fnCalls);
      }
    });

    test('resume carries on from the saved state and names who was cut off',
        () async {
      answer = (body) => [words('Picking up again.')];
      final state = await boot();
      final session = StudioSession.fromJson(savedMidRun());
      final controller = controllerFor(state, session);
      expect(controller.interrupted, isTrue);
      // Nothing runs until asked.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(requests, isEmpty);

      await controller.resume();
      expect(controller.interrupted, isFalse);
      expect(requests, hasLength(1));
      final body = requests.single;
      final texts = userTexts(body);
      expect(texts.last, contains('The app was closed while you were working'));
      expect(texts.last, contains('Subagent 1 (task_id "sub-1"'));
      // The request is a valid one: every call it carries is answered.
      final msgs = messagesOf(body);
      final asked = [
        for (final m in msgs)
          for (final c in (m['tool_calls'] as List? ?? const [])) (c as Map)['id'],
      ];
      expect([for (final m in msgs) if (m['role'] == 'tool') m['tool_call_id']], asked);
      expect(session.transcript.last.text, 'Picking up again.');
    });

    test('a new message after an interruption carries the note too', () async {
      answer = (body) => [words('Ok.')];
      final state = await boot();
      final session = StudioSession.fromJson(savedMidRun());
      final controller = controllerFor(state, session);
      await controller.send('Just the greetings, please.');
      final texts = userTexts(requests.single);
      expect(texts[texts.length - 2], contains('The app was closed'));
      expect(texts.last, 'Just the greetings, please.');
      expect(controller.interrupted, isFalse);
    });

    test('a session saved while an agent works is marked active', () async {
      final gate = Completer<void>();
      answer = (body) async {
        await gate.future;
        return [words('Done.')];
      };
      final state = await boot();
      final controller = controllerFor(state);
      final run = controller.send('Go.');
      await until(() => requests.isNotEmpty);
      await controller.flush();
      final mid = await StudioStore(dir).read(controller.session.id);
      // Read back, it is a session the app closed on.
      expect(mid!.interrupted, isTrue);
      gate.complete();
      await run;
      await controller.flush();
      final after = await StudioStore(dir).read(controller.session.id);
      expect(after!.interrupted, isFalse);
    });
  });

  // --- background sub-agents ---------------------------------------------------

  group('background sub-agents', () {
    Map<String, dynamic> background(String description) => {
          'description': description,
          'prompt': 'Write three greetings for Maren.',
          'agent_type': 'writer',
          'background': true,
        };

    test('task in the background returns at once; the report arrives as a '
        'note that wakes the idle main agent', () async {
      final subGate = Completer<void>();
      var leadTurns = 0;
      answer = (body) async {
        if (fromSubagent(body)) {
          await subGate.future;
          return [words('Three greetings written.')];
        }
        leadTurns++;
        return switch (leadTurns) {
          1 => [calls([('t1', 'task', background('Greetings'))])],
          2 => [words('It is working on greetings; I will wait.')],
          _ => [words('The greetings are in.')],
        };
      };
      final state = await boot();
      final controller = controllerFor(state);
      await controller.send('Build her, greetings in the background.');

      // The main agent finished its run while the sub-agent still works.
      expect(controller.running, isFalse);
      expect(controller.busy, isTrue);
      final sub = controller.subagents.single;
      expect(sub.running, isTrue);
      expect(sub.background, isTrue);
      final started = jsonDecode(
          toolResults(requests.where(fromLead).elementAt(1)).single['content'] as String);
      expect(started['status'], 'running');
      expect(started['task_id'], sub.id);

      subGate.complete();
      await until(() => leadTurns == 3, 'the main agent to hear the report');
      await controller.idle;
      final note = userTexts(requests.where(fromLead).last).last;
      expect(note, startsWith('[Studio note] Subagent 1 (task_id "${sub.id}") '
          'finished in the background'));
      expect(note, contains('Three greetings written.'));
      expect(controller.session.transcript.last.text, 'The greetings are in.');
      expect(sub.status, StudioAgentStatus.done);
    });

    test('wait_agents returns the report, which is then not delivered again',
        () async {
      final subGate = Completer<void>();
      var leadTurns = 0;
      String? taskId;
      answer = (body) async {
        if (fromSubagent(body)) {
          await subGate.future;
          return [words('Lore written.')];
        }
        leadTurns++;
        if (leadTurns == 1) {
          return [calls([('t1', 'task', background('Lore'))])];
        }
        if (leadTurns == 2) {
          taskId = (jsonDecode(toolResults(body).last['content'] as String)
              as Map)['task_id'] as String;
          // Released while the wait is on.
          Timer(const Duration(milliseconds: 60), subGate.complete);
          return [
            calls([
              ('w1', 'wait_agents', {'task_ids': [taskId], 'timeout_seconds': 30}),
            ]),
          ];
        }
        return [words('Lore is done.')];
      };
      final state = await boot();
      final controller = controllerFor(state);
      await controller.send('Lore in the background, then wait.');
      await controller.idle;

      expect(leadTurns, 3);
      final waited = jsonDecode(toolResults(requests.last).last['content'] as String)
          as Map;
      expect(waited['all_finished'], isTrue);
      final agents = (waited['agents'] as List).cast<Map>();
      expect(agents.single['task_id'], taskId);
      expect(agents.single['report'], 'Lore written.');
      // No fourth turn for a note repeating what the wait already said.
      expect(requests.where(fromLead), hasLength(3));
      expect(
        controller.session.transcript.any((m) => m.text.contains('finished in the background')),
        isFalse,
      );
    });

    test('wait_agents gives up at its timeout and says so', () async {
      var leadTurns = 0;
      answer = (body) async {
        if (fromSubagent(body)) {
          await Completer<void>().future; // never answers
        }
        leadTurns++;
        if (leadTurns == 1) return [calls([('t1', 'task', background('Slow'))])];
        if (leadTurns == 2) {
          return [
            calls([('w1', 'wait_agents', {'timeout_seconds': 1})]),
          ];
        }
        return [words('Still going; I will check later.')];
      };
      final state = await boot();
      final controller = controllerFor(state);
      await controller.send('Go.');
      final waited = jsonDecode(toolResults(requests.last).last['content'] as String)
          as Map;
      expect(waited['all_finished'], isFalse);
      expect(waited['timed_out'], isTrue);
      expect(((waited['agents'] as List).single as Map)['status'], 'running');
    });

    test('send_message reaches a working sub-agent at its next step', () async {
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
          return [words('Used the name Maren.')];
        }
        leadTurns++;
        if (leadTurns == 1) return [calls([('t1', 'task', background('Greetings'))])];
        if (leadTurns == 2) {
          final id = (jsonDecode(toolResults(body).last['content'] as String)
              as Map)['task_id'];
          return [
            calls([
              ('m1', 'send_message', {'task_id': id, 'message': 'Use the name Maren.'}),
            ]),
          ];
        }
        if (leadTurns == 3) {
          subFirst.complete();
          return [words('Told it.')];
        }
        return [words('All done.')];
      };
      final state = await boot();
      final controller = controllerFor(state);
      await controller.send('Go.');
      final sent = jsonDecode(toolResults(requests.where(fromLead).elementAt(2)).last['content'] as String)
          as Map;
      expect(sent['status'], 'queued');
      await until(() => subTurns == 2, 'the sub-agent\'s second step');
      final subSecond = requests.where(fromSubagent).last;
      expect(
        userTexts(subSecond).last,
        '[Message from the main agent] Use the name Maren.',
      );
      await controller.idle;
    });

    test('send_message to a finished sub-agent carries it on in the background',
        () async {
      var subTurns = 0;
      var leadTurns = 0;
      String? id;
      answer = (body) async {
        if (fromSubagent(body)) {
          subTurns++;
          return [words(subTurns == 1 ? 'First pass done.' : 'Second pass done.')];
        }
        leadTurns++;
        if (leadTurns == 1) {
          return [
            calls([
              ('t1', 'task', {'description': 'Greetings', 'prompt': 'Write them.'}),
            ]),
          ];
        }
        if (leadTurns == 2) {
          id = (jsonDecode(toolResults(body).last['content'] as String) as Map)['task_id']
              as String;
          return [
            calls([('m1', 'send_message', {'task_id': id, 'message': 'Shorter.'})]),
          ];
        }
        return [words('Ok.')];
      };
      final state = await boot();
      final controller = controllerFor(state);
      await controller.send('Go.');
      await controller.idle;
      expect(subTurns, 2);
      final sub = controller.subagent(id!)!;
      expect(sub.transcript.where((m) => m.text == 'Shorter.'), hasLength(1));
      expect(sub.report, 'Second pass done.');
      expect(sub.resumeCallIds, contains('m1'));
    });

    test('list_agents lists them', () async {
      var leadTurns = 0;
      answer = (body) async {
        if (fromSubagent(body)) {
          await Completer<void>().future;
        }
        leadTurns++;
        if (leadTurns == 1) return [calls([('t1', 'task', background('Greetings'))])];
        if (leadTurns == 2) return [calls([('l1', 'list_agents', <String, dynamic>{})])];
        return [words('Ok.')];
      };
      final state = await boot();
      final controller = controllerFor(state);
      await controller.send('Go.');
      final listed = jsonDecode(toolResults(requests.last).last['content'] as String)
          as Map;
      final row = (listed['agents'] as List).single as Map;
      expect(row['label'], 'Subagent 1');
      expect(row['agent_type'], 'writer');
      expect(row['status'], 'running');
      expect(row['background'], isTrue);
    });

    test('stop cancels background sub-agents; nothing wakes the main agent',
        () async {
      var leadTurns = 0;
      answer = (body) async {
        if (fromSubagent(body)) {
          await Completer<void>().future;
        }
        leadTurns++;
        if (leadTurns == 1) return [calls([('t1', 'task', background('Greetings'))])];
        return [words('Waiting for it.')];
      };
      final state = await boot();
      final controller = controllerFor(state);
      await controller.send('Go.');
      expect(controller.busy, isTrue);
      await until(() => requests.any(fromSubagent), 'the sub-agent to start');
      controller.stop();
      await controller.idle;
      final sub = controller.subagents.single;
      expect(sub.status, StudioAgentStatus.cancelled);
      expect(controller.busy, isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(requests.where(fromLead), hasLength(2));
    });

    test('sub-agents never get the runtime tools; the main agent does', () async {
      answer = (body) async {
        if (fromSubagent(body)) return [words('Done.')];
        if (requests.where(fromLead).length == 1) {
          return [
            calls([
              ('t1', 'task', {'description': 'X', 'prompt': 'Do X.', 'agent_type': 'general'}),
            ]),
          ];
        }
        return [words('Ok.')];
      };
      final state = await boot();
      final controller = controllerFor(state);
      await controller.send('Go.');
      List<String> tools(Map<String, dynamic> b) =>
          [for (final t in b['tools'] as List) (t as Map)['function']['name'] as String];
      final lead = tools(requests.firstWhere(fromLead));
      expect(lead, containsAll(['send_message', 'wait_agents', 'list_agents']));
      final general = tools(requests.firstWhere(fromSubagent));
      expect(general, isNot(contains('send_message')));
      expect(general, isNot(contains('wait_agents')));
      expect(general, isNot(contains('task')));
    });
  });
}

/// Services no test in the compaction group reaches.
class _NoServices implements StudioServices {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
