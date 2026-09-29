import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/agent_message.dart';
import 'package:maichat/models/message_image.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/models/studio.dart';
import 'package:maichat/services/agent_client.dart';
import 'package:maichat/services/studio/agent_runner.dart';
import 'package:maichat/services/studio/custom_agents.dart';
import 'package:maichat/services/studio/studio_context.dart';
import 'package:maichat/services/studio/studio_controller.dart';
import 'package:maichat/services/studio/studio_memory.dart';
import 'package:maichat/services/studio/studio_store.dart';
import 'package:maichat/services/studio/studio_tools.dart';
import 'package:maichat/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The context inspector, held to what actually goes out: a real [AppState]
/// and [StudioController] against a loopback model which, as each request
/// arrives, asks the controller what it would send next — and checks that it
/// is the same bytes. Plain `test()`s: a `testWidgets` in this file would
/// turn every real HTTP request into a 400 (see CLAUDE.md).
void main() {
  late HttpServer server;
  late Directory dir;
  late StudioController controller;
  var booted = false;

  /// The raw bodies that arrived, with who sent them.
  late List<({String who, String raw, Map<String, dynamic> body})> requests;

  /// Requests whose body was not what the inspector said it would be.
  late List<String> mismatches;

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

  String systemOf(Map<String, dynamic> body) =>
      ((body['messages'] as List).first as Map)['content'] as String;

  String whoSent(Map<String, dynamic> body) {
    final system = systemOf(body);
    if (system == kCompactionPrompt) return 'summary';
    if (system.contains('character-building team')) {
      final running = [
        for (final a in controller.subagents)
          if (a.running) a,
      ];
      return running.isEmpty ? 'sub?' : running.last.id;
    }
    return kMainAgent;
  }

  Future<AppState> boot({Map<String, String>? headers, String key = 'k'}) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    StudioMemory.resetShared();
    requests = [];
    mismatches = [];
    booted = true;
    dir = await Directory.systemTemp.createTemp('studio_context');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final raw = await utf8.decoder.bind(request).join();
      final body = jsonDecode(raw) as Map<String, dynamic>;
      final who = whoSent(body);
      requests.add((who: who, raw: raw, body: body));
      // The inspector's word for the request that is in flight right now.
      if (who != 'summary') {
        final preview = controller.nextRequestFor(who)?.wire?.body;
        if (preview == null || jsonEncode(preview) != raw) {
          mismatches.add('$who #${requests.length}');
        }
      }
      final events = await answer(body);
      request.response.headers.contentType = ContentType('text', 'event-stream');
      for (final e in events) {
        request.response.write('data: ${jsonEncode(e)}\n\n');
      }
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
      apiKey: key,
      customHeaders: headers,
    ));
    return state;
  }

  tearDown(() async {
    if (!booted) return;
    booted = false;
    await controller.flush();
    await server.close(force: true);
    await dir.delete(recursive: true);
  });

  StudioController controllerFor(AppState state, [StudioSession? session]) =>
      controller = StudioController(
        state: state,
        store: StudioStore(dir),
        session: session ?? newStudioSession(),
      );

  test('what the inspector shows is what the main agent sends, byte for byte',
      () async {
    answer = (body) {
      final hasResults =
          (body['messages'] as List).any((m) => (m as Map)['role'] == 'tool');
      return hasResults
          ? [words('All done.')]
          : [calls([('g1', 'get_draft', <String, dynamic>{})])];
    };
    final state = await boot();
    controllerFor(state);
    await controller.send('Build a keeper.');
    expect(requests.map((r) => r.who), [kMainAgent, kMainAgent]);
    expect(mismatches, isEmpty);
  });

  test('and what a sub-agent sends', () async {
    answer = (body) {
      if (systemOf(body).contains('character-building team')) {
        return [words('Wrote the greeting.')];
      }
      final hasResults =
          (body['messages'] as List).any((m) => (m as Map)['role'] == 'tool');
      return hasResults
          ? [words('Done.')]
          : [
              calls([
                (
                  't1',
                  'task',
                  {
                    'description': 'Greeting',
                    'prompt': 'Write the first message.',
                    'agent_type': 'writer',
                  },
                ),
              ]),
            ];
    };
    final state = await boot();
    controllerFor(state);
    await controller.send('go');
    final sub = controller.subagents.single;
    expect(requests.where((r) => r.who == sub.id), hasLength(1));
    expect(requests.where((r) => r.who == kMainAgent), hasLength(2));
    expect(mismatches, isEmpty);
    // And for an agent that is not there, nothing.
    expect(controller.nextRequestFor('nobody'), isNull);
  });

  test('and after the older conversation has been summarised', () async {
    answer = (body) {
      if (systemOf(body) == kCompactionPrompt) {
        return [words('SUMMARY_OF_EARLIER_TALK')];
      }
      return [words('Carrying on.')];
    };
    final state = await boot();
    await state.updateStudioConfig(
      state.studioConfig.copyWith(contextBudget: kStudioMinContextBudget),
    );
    final session = newStudioSession();
    final long = List.filled(260, 'The lighthouse keeper remembers.').join(' ');
    for (var i = 0; i < 12; i++) {
      session.transcript
        ..add(AgentMessage.user('Turn $i: $long'))
        ..add(AgentMessage(role: AgentRole.assistant, text: 'Noted $i.'));
    }
    controllerFor(state, session);
    final before = controller.contextFor(kMainAgent)!;
    expect(before.wouldCompact, isTrue);
    await controller.send('go on');
    expect(requests.map((r) => r.who), ['summary', kMainAgent]);
    expect(mismatches, isEmpty);
    expect(requests.last.raw, contains('SUMMARY_OF_EARLIER_TALK'));
    final after = controller.contextFor(kMainAgent)!;
    expect(after.summarisedTurns, greaterThan(0));
    final summary = after.section(StudioContextCategory.summary)!;
    expect(summary.items.single.full, contains('SUMMARY_OF_EARLIER_TALK'));
    expect(after.total, lessThan(before.total));
  });

  test('the host’s own count is kept beside the estimate, and saved', () async {
    answer = (body) => [words('Hello.'), usage(1234, 5)];
    final state = await boot();
    controllerFor(state);
    await controller.send('hi');
    final last = controller.session.lastRequest!;
    expect(last.reported, 1234);
    expect(last.estimated, greaterThan(0));
    expect(controller.contextFor(kMainAgent)!.lastRequest!.reported, 1234);
    final back = StudioSession.fromJson(
      jsonDecode(jsonEncode(controller.session.toJson())) as Map<String, dynamic>,
    );
    expect(back.lastRequest!.reported, 1234);
    expect(back.lastRequest!.estimated, last.estimated);
  });

  test('a host that reports no usage leaves the comparison out', () async {
    answer = (body) => [words('Hello.')];
    final state = await boot();
    controllerFor(state);
    await controller.send('hi');
    expect(controller.session.lastRequest, isNull);
  });

  test('stale tool output shows as shortened, and costs what the wire sends',
      () async {
    final state = await boot();
    final session = newStudioSession();
    final big = 'x' * 3000;
    for (var i = 0; i < 3; i++) {
      final call = ToolCall(id: 'c$i', name: 'get_draft');
      session.transcript
        ..add(AgentMessage(role: AgentRole.assistant, toolCalls: [call]))
        ..add(AgentMessage.toolResult(call, big));
    }
    controllerFor(state, session);
    final results = controller
        .contextFor(kMainAgent)!
        .section(StudioContextCategory.toolResults)!
        .items;
    expect(results, hasLength(3));
    expect(results.first.note, contains('Shortened on the wire'));
    expect(results.first.full, contains('tokens truncated'));
    expect(results.first.tokens, lessThan(results.last.tokens));
    expect(results.last.note, isNull);
  });

  test('web, memory and agent-type sections appear only when they are on',
      () async {
    final state = await boot();
    final memory = await StudioMemory.forDirectory(dir);
    expect(memory.add('Prefers second person.'), isNull);
    controllerFor(state);
    // Let the controller's own read of the memory land.
    await Future<void>.delayed(const Duration(milliseconds: 20));

    Set<StudioContextCategory> shown() => {
          for (final s in controller.contextFor(kMainAgent)!.sections) s.category,
        };

    expect(shown(), containsAll([
      StudioContextCategory.instructions,
      StudioContextCategory.web,
      StudioContextCategory.memory,
      StudioContextCategory.tools,
    ]));
    expect(shown(), isNot(contains(StudioContextCategory.agentTypes)));
    expect(
      controller
          .contextFor(kMainAgent)!
          .section(StudioContextCategory.memory)!
          .items
          .single
          .full,
      contains('Prefers second person.'),
    );

    await state.updateStudioConfig(state.studioConfig.copyWith(
      webTools: false,
      memoryEnabled: false,
      customAgents: const [
        StudioAgentType(
          id: 'voice_coach',
          label: 'Voice coach',
          description: 'Tunes how the character talks.',
        ),
      ],
    ));
    expect(shown(), isNot(contains(StudioContextCategory.web)));
    expect(shown(), isNot(contains(StudioContextCategory.memory)));
    expect(shown(), contains(StudioContextCategory.agentTypes));
  });

  test('categories add up to the total, and every part of the request is in one',
      () async {
    final state = await boot();
    final session = newStudioSession();
    const call = ToolCall(id: 'a', name: 'get_draft');
    session.transcript.addAll([
      AgentMessage.user('Make her older.'),
      AgentMessage(role: AgentRole.assistant, text: 'On it.', toolCalls: const [call]),
      AgentMessage.toolResult(call, '{"character":{}}'),
      AgentMessage(role: AgentRole.assistant, text: 'Done.'),
    ]);
    session.queued.add(StudioQueuedMessage(id: 'q', text: 'Also taller.'));
    controllerFor(state, session);
    final report = controller.contextFor(kMainAgent)!;
    expect(
      report.total,
      report.sections.fold<int>(0, (n, s) => n + s.tokens),
    );
    final conversation = report.section(StudioContextCategory.conversation)!;
    expect(conversation.items.map((i) => i.label), ['You', 'Agent', 'Agent']);
    expect(report.section(StudioContextCategory.toolResults)!.items, hasLength(1));
    // The queued message is in the next request, as a waiting turn.
    expect(
      report.section(StudioContextCategory.waiting)!.items.single.full,
      'Also taller.',
    );
    final raw = jsonEncode(controller.nextRequestFor(kMainAgent)!.wire!.body);
    expect(raw, contains('Also taller.'));
    // Tool definitions are counted one by one.
    final tools = report.section(StudioContextCategory.tools)!;
    expect(tools.items.map((i) => i.label), contains('get_draft'));
    expect(tools.items.every((i) => i.tokens > 0), isTrue);
    expect(report.budget, state.studioConfig.contextBudget);
  });

  test('the raw request never shows a key or a secret header', () async {
    final state = await boot(
      key: 'sk-live-SECRETKEY',
      headers: {'X-Gateway-Token': 'gw-SECRET2', 'X-Trace': 'visible-trace'},
    );
    controllerFor(state);
    final text = controller.nextRequestFor(kMainAgent)!.wire!.preview();
    expect(text, isNot(contains('SECRETKEY')));
    expect(text, isNot(contains('SECRET2')));
    expect(text, contains('<redacted>'));
    expect(text, contains('X-Trace: visible-trace'));
    expect(text, startsWith('POST http://127.0.0.1:'));
    expect(text, contains('"model": "builder"'));
  });

  test('picture data is left out of the raw request, not out of the body', () {
    final data = List.filled(400, 'QUJD').join();
    final wire = AgentWireRequest(
      provider: Provider(
        id: 'p',
        name: 'x',
        kind: ProviderKind.openai,
        baseUrl: 'https://host.tld/v1',
        model: 'm',
        apiKey: 'k',
      ),
      messages: [
        AgentMessage.user('Look', images: [
          MessageImage(ref: 'local:a.png', mime: 'image/png', data: data),
        ]),
      ],
      tools: const [],
      params: const AgentParams(),
    );
    expect(jsonEncode(wire.body), contains(data));
    final text = wire.preview();
    expect(text, isNot(contains(data)));
    expect(text, contains('base64 characters elided'));
  });

  test('a 200-turn session is counted once, however often it is looked at', () {
    var calls = 0;
    int counting(String text) {
      calls++;
      return (text.length / 4).ceil();
    }

    final counter = StudioContextCounter(counting);
    final transcript = <AgentMessage>[];
    for (var i = 0; i < 100; i++) {
      final call = ToolCall(id: 'c$i', name: 'get_draft');
      transcript
        ..add(AgentMessage(role: AgentRole.assistant, text: 'Step $i', toolCalls: [call]))
        ..add(AgentMessage.toolResult(call, 'result $i ${'y' * 900}'));
    }
    final parts = [(StudioPromptPart.instructions, 'You build characters.')];
    final tools = studioToolsFor('studio');
    StudioAgentRequest request() => StudioAgentRequest(
          agentId: kMainAgent,
          promptParts: parts,
          systemPrompt: joinPromptParts(parts),
          tools: tools,
          transcript: transcript,
          waiting: 0,
          latest: null,
          messages: AgentRunner.buildRequest(
            joinPromptParts(parts),
            transcript,
            null,
          ),
          budget: 120000,
          wire: null,
        );

    final first = buildContextReport(request(), counter);
    final firstCalls = calls;
    // Each turn is counted once (its words, its call's name and arguments),
    // plus the shortened copies, the instructions and each tool — not more.
    expect(firstCalls, lessThan(200 * 3 + tools.length + 10));
    calls = 0;
    final second = buildContextReport(request(), counter);
    expect(calls, 0);
    expect(second.total, first.total);
  });
}
