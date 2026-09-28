import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/agent_message.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/lorebook.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/models/studio.dart';
import 'package:maichat/models/usage.dart';
import 'package:maichat/services/agent_client.dart';
import 'package:maichat/services/studio/agent_runner.dart';
import 'package:maichat/services/studio/studio_store.dart';
import 'package:maichat/services/studio/studio_tools.dart';
import 'package:maichat/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeServices implements StudioServices {
  final List<String> delegated = <String>[];
  final List<List<String>> playtests = <List<String>>[];
  Completer<void>? holdDelegates;
  int delegatesRunning = 0;
  int mostDelegatesAtOnce = 0;

  @override
  int countTokens(String text) => (text.length / 4).ceil();

  @override
  List<Character> libraryCharacters = <Character>[];

  @override
  List<Lorebook> libraryLorebooks = <Lorebook>[];

  @override
  bool canGenerateImages = true;

  @override
  Future<String> generatePicture({
    required String prompt,
    required String characterId,
  }) async =>
      'local:painted.png';

  @override
  Future<List<String>> playtest({
    required Character character,
    required List<Lorebook> lorebooks,
    required List<String> userTurns,
    int greetingIndex = 0,
  }) async {
    playtests.add(userTurns);
    return [for (final t in userTurns) '${character.name} answers "$t"'];
  }

  @override
  Future<String> delegate({required String helper, required String task}) async {
    delegated.add('$helper: $task');
    delegatesRunning++;
    if (delegatesRunning > mostDelegatesAtOnce) {
      mostDelegatesAtOnce = delegatesRunning;
    }
    await holdDelegates?.future;
    delegatesRunning--;
    return '$helper did it';
  }
}

StudioSession _session() => StudioSession(
      id: 's1',
      title: '',
      workspace: StudioWorkspace(character: Character(id: 'c1', name: '')),
    );

Map<String, dynamic> _json(StudioToolResult r) =>
    jsonDecode(r.text) as Map<String, dynamic>;

void main() {
  late _FakeServices services;
  late StudioSession session;
  late StudioToolContext ctx;

  setUp(() {
    services = _FakeServices();
    session = _session();
    ctx = StudioToolContext(session: session, services: services);
  });

  Future<StudioToolResult> call(String tool, Map<String, dynamic> args) =>
      kStudioTools[tool]!.call(ctx, args);

  group('character tools', () {
    test('set_fields writes several fields and records one change', () async {
      final r = await call('set_fields', {
        'name': 'Aria',
        'description': '{{char}} keeps the Saltmarsh light.',
        'tags': ['Horror', 'horror', 'Coastal'],
        'title': 'the last keeper',
      });
      expect(r.isError, isFalse);
      final c = session.workspace.character;
      expect(c.name, 'Aria');
      expect(c.description, contains('Saltmarsh'));
      // Tags are lower-cased and de-duplicated.
      expect(c.tags, ['horror', 'coastal']);
      // Writing a title switches it on, or it would never be seen.
      expect(c.titleShown, isTrue);
      expect(session.ops, hasLength(1));
      expect(session.ops.single.summary, contains('name'));
      expect(_json(r)['token_counts'], contains('description'));
    });

    test('set_fields names the fields when given only unknown ones', () async {
      final r = await call('set_fields', {'backstory': 'x'});
      expect(r.isError, isTrue);
      expect(r.text, contains('backstory'));
      expect(r.text, contains('description'));
      expect(session.ops, isEmpty);
    });

    test('edit_field needs an exact, unique match', () async {
      await call('set_fields', {'description': 'Tall. Quiet. Tall again.'});
      final missing = await call('edit_field',
          {'field': 'description', 'find': 'Short', 'replace': 'x'});
      expect(missing.isError, isTrue);
      expect(missing.text, contains('not in the description'));

      final twice = await call('edit_field',
          {'field': 'description', 'find': 'Tall', 'replace': 'Short'});
      expect(twice.isError, isTrue);
      expect(twice.text, contains('2 times'));

      final ok = await call('edit_field',
          {'field': 'description', 'find': 'Quiet', 'replace': 'Loud'});
      expect(ok.isError, isFalse);
      expect(session.workspace.character.description, 'Tall. Loud. Tall again.');

      final all = await call('edit_field', {
        'field': 'description',
        'find': 'Tall',
        'replace': 'Short',
        'replace_all': true,
      });
      expect(_json(all)['replaced'], 2);
      expect(session.workspace.character.description, 'Short. Loud. Short again.');
    });

    test('greetings: the first fills first_message, the rest are alternates',
        () async {
      await call('add_greeting', {'text': 'Hello.'});
      final second = await call('add_greeting', {'text': 'Evening.'});
      final c = session.workspace.character;
      expect(c.firstMes, 'Hello.');
      expect(c.alternateGreetings, ['Evening.']);
      expect(_json(second)['alternate_greeting_index'], 0);

      await call('edit_field', {
        'field': 'alternate_greeting',
        'index': 0,
        'find': 'Evening',
        'replace': 'Night',
      });
      expect(c.alternateGreetings, ['Night.']);
      final bad = await call('remove_greeting', {'index': 3});
      expect(bad.isError, isTrue);
      await call('remove_greeting', {'index': 0});
      expect(c.alternateGreetings, isEmpty);
    });

    test('scenarios are added, rewritten by id, and deleted', () async {
      final r = await call('upsert_scenario', {
        'name': 'Storm',
        'text': 'A storm has cut the causeway.',
        'greetings': [1],
      });
      final id = _json(r)['id'] as String;
      await call('upsert_scenario', {'id': id, 'name': 'Storm', 'text': 'Rewritten.'});
      final scenarios = session.workspace.character.scenarios;
      expect(scenarios, hasLength(1));
      expect(scenarios.single.text, 'Rewritten.');
      expect(scenarios.single.greetings, isEmpty);
      await call('delete_scenario', {'id': id});
      expect(session.workspace.character.scenarios, isEmpty);
    });

    test('get_draft reports the fields, counts and lore', () async {
      await call('set_fields', {'name': 'Aria', 'description': 'x' * 40});
      final r = _json(await call('get_draft', {}));
      expect(r['character']['name'], 'Aria');
      expect(r['character']['token_counts']['description'], 10);
      expect(r['lorebooks'], isEmpty);
      final only = _json(await call('get_draft', {'section': 'character'}));
      expect(only.containsKey('lorebooks'), isFalse);
    });
  });

  group('lore tools', () {
    Future<String> book() async => _json(await call(
          'create_lorebook',
          {'name': 'Saltmarsh'},
        ))['lorebook_id'] as String;

    test('a created book is attached to the character', () async {
      final id = await book();
      expect(session.workspace.lorebooks.single.name, 'Saltmarsh');
      expect(session.workspace.character.lorebookIds, [id]);
    });

    test('a new entry must be able to fire', () async {
      final id = await book();
      final noKeys = await call('upsert_lore_entry',
          {'lorebook_id': id, 'content': 'The marsh drowns the careless.'});
      expect(noKeys.isError, isTrue);
      expect(noKeys.text, contains('keys'));
      final noContent =
          await call('upsert_lore_entry', {'lorebook_id': id, 'keys': ['marsh']});
      expect(noContent.isError, isTrue);
      final constant = await call('upsert_lore_entry', {
        'lorebook_id': id,
        'content': 'Salt keeps the dead down.',
        'constant': true,
      });
      expect(constant.isError, isFalse);
    });

    test('rewriting by uid keeps what is not passed', () async {
      final id = await book();
      final r = await call('upsert_lore_entry', {
        'lorebook_id': id,
        'name': 'The marsh',
        'keys': 'marsh, Saltmarsh',
        'content': 'Flat and grey.',
        'order': 120,
        'position': 'at_depth',
        'depth': 2,
      });
      final uid = _json(r)['uid'] as int;
      await call('upsert_lore_entry', {
        'lorebook_id': id,
        'uid': uid,
        'content': 'Flat, grey and hungry.',
      });
      final entry = session.workspace.lorebook(id)!.entries.single;
      expect(entry.content, 'Flat, grey and hungry.');
      expect(entry.keys, ['marsh', 'Saltmarsh']);
      expect(entry.weight, 120);
      expect(entry.priority, 120);
      expect(entry.position, LorebookPosition.atDepth);
      expect(entry.depth, 2);
    });

    test('an unknown book or entry names what exists', () async {
      final id = await book();
      final r = await call('upsert_lore_entry',
          {'lorebook_id': 'nope', 'keys': ['a'], 'content': 'b'});
      expect(r.isError, isTrue);
      expect(r.text, contains(id));
      final e = await call('delete_lore_entry', {'lorebook_id': id, 'uid': 9});
      expect(e.isError, isTrue);
    });

    test('a library book is brought in by id and detaches on delete', () async {
      services.libraryLorebooks = [
        Lorebook(id: 'lib1', name: 'Old world', entries: [
          LorebookEntry(uid: 0, keys: ['ruin'], content: 'Ruins.'),
        ]),
      ];
      await call('attach_library_lorebook', {'id': 'lib1'});
      expect(session.workspace.lorebook('lib1')!.entries, hasLength(1));
      expect(session.workspace.character.lorebookIds, ['lib1']);
      // A copy: editing it leaves the library's own untouched until applied.
      await call('upsert_lore_entry',
          {'lorebook_id': 'lib1', 'keys': ['gate'], 'content': 'A gate.'});
      expect(services.libraryLorebooks.single.entries, hasLength(1));
      await call('delete_lorebook', {'lorebook_id': 'lib1'});
      expect(session.workspace.lorebooks, isEmpty);
      expect(session.workspace.character.lorebookIds, isEmpty);
    });
  });

  group('other tools', () {
    test('documents are written, read and removed', () async {
      final r = await call('upsert_document',
          {'name': 'History', 'text': 'Long ago the light was lit.'});
      final id = _json(r)['id'] as String;
      final read = _json(await call('read_document', {'id': id}));
      expect(read['text'], 'Long ago the light was lit.');
      await call('delete_document', {'id': id});
      expect(session.workspace.documents, isEmpty);
    });

    test('a new portrait keeps the old one in the pool', () async {
      session.workspace.character.avatar = 'local:old.png';
      await call('generate_avatar', {'prompt': 'a keeper at a lamp'});
      final c = session.workspace.character;
      expect(c.avatar, 'local:painted.png');
      expect(c.avatars, ['local:old.png']);
    });

    test('no image studio is reported, not attempted', () async {
      services.canGenerateImages = false;
      final r = await call('generate_avatar', {'prompt': 'x'});
      expect(r.isError, isTrue);
      expect(r.text, contains('image studio'));
    });

    test('playtest sends the turns and returns a transcript', () async {
      session.workspace.character.name = 'Aria';
      final r = _json(await call('playtest', {
        'messages': ['Who are you?', 'Why stay?'],
      }));
      expect(services.playtests.single, ['Who are you?', 'Why stay?']);
      final transcript = (r['transcript'] as List).cast<Map>();
      expect(transcript, hasLength(4));
      expect(transcript[1]['Aria'], 'Aria answers "Who are you?"');
      final tooMany =
          await call('playtest', {'messages': ['1', '2', '3', '4', '5']});
      expect(tooMany.isError, isTrue);
    });

    test('helpers get only their trade', () {
      List<String> names(String agent, {bool subAgents = true}) =>
          [for (final t in studioToolsFor(agent, subAgents: subAgents)) t.name];
      expect(names('critic'), ['get_draft', 'read_document', 'playtest']);
      expect(names('lore_writer'), isNot(contains('set_fields')));
      expect(names('writer'), isNot(contains('upsert_lore_entry')));
      for (final helper in kStudioHelpers.keys) {
        expect(names(helper), isNot(contains('delegate')));
      }
      expect(names('studio'), contains('delegate'));
      expect(names('studio', subAgents: false), isNot(contains('delegate')));
    });
  });

  group('changes and rewinding', () {
    test('rewinding restores the draft and undoes every later change', () async {
      await call('set_fields', {'name': 'Aria'});
      await call('set_fields', {'description': 'First.'});
      await call('set_fields', {'description': 'Second.'});
      final undone = session.rewindTo(1);
      expect(undone, hasLength(2));
      expect(session.workspace.character.name, 'Aria');
      expect(session.workspace.character.description, '');
      expect(session.ops.map((o) => o.reverted), [false, true, true]);
      // A reverted change cannot be rewound to again.
      expect(session.canRewindTo(2), isFalse);
      expect(session.rewindTo(2), isEmpty);
    });

    test('old snapshots are dropped past the limit, the rows are kept',
        () async {
      for (var i = 0; i < kStudioSnapshotLimit + 5; i++) {
        await call('set_fields', {'description': 'v$i'});
      }
      expect(session.ops, hasLength(kStudioSnapshotLimit + 5));
      expect(session.canRewindTo(0), isFalse);
      expect(session.canRewindTo(4), isFalse);
      expect(session.canRewindTo(5), isTrue);
      expect(session.canRewindTo(session.ops.length - 1), isTrue);
    });

    test('a session survives a save and load', () async {
      await call('set_fields', {'name': 'Aria'});
      final id = _json(await call('create_lorebook', {'name': 'B'}))['lorebook_id'];
      await call('upsert_lore_entry',
          {'lorebook_id': id, 'keys': ['k'], 'content': 'c'});
      session.transcript.add(AgentMessage.user('hi'));
      session.addUsage(const TokenUsage(inputTokens: 3), 0.5);
      final back = StudioSession.fromJson(
        jsonDecode(jsonEncode(session.toJson())) as Map<String, dynamic>,
      );
      expect(back.workspace.character.name, 'Aria');
      expect(back.workspace.lorebooks.single.entries.single.keys, ['k']);
      expect(back.ops, hasLength(3));
      expect(back.transcript.single.text, 'hi');
      expect(back.cost, 0.5);
      expect(back.rewindTo(0), hasLength(3));
      expect(back.workspace.character.name, '');
    });
  });

  group('the runner', () {
    /// A model that plays back [turns], one per request, recording what it was
    /// sent.
    AgentTurn scripted(
      List<List<AgentDelta>> turns,
      List<List<AgentMessage>> sent,
    ) {
      var i = 0;
      return (client, messages, tools) async* {
        sent.add(List.of(messages));
        final turn = i < turns.length ? turns[i++] : const <AgentDelta>[];
        for (final d in turn) {
          yield d;
        }
      };
    }

    test('runs calls, answers each, and ends on words', () async {
      final sent = <List<AgentMessage>>[];
      final runner = AgentRunner(
        name: 'studio',
        systemPrompt: 'SYS',
        tools: studioToolsFor('studio'),
        context: ctx,
        turn: scripted([
          [
            const AgentDelta(text: 'Naming her. '),
            const AgentDelta(toolCalls: [
              ToolCall(id: 'a', name: 'set_fields', arguments: {'name': 'Aria'}),
              ToolCall(id: 'b', name: 'no_such_tool'),
              ToolCall(id: 'c', name: 'get_draft', argumentError: 'bad json'),
            ]),
          ],
          [const AgentDelta(text: 'Done: Aria exists.')],
        ], sent),
      );
      final transcript = [AgentMessage.user('make a keeper')];
      final outcome = await runner.run(transcript);
      expect(outcome.end, AgentRunEnd.finished);
      expect(outcome.lastText, 'Done: Aria exists.');
      expect(transcript.map((m) => m.role), [
        AgentRole.user,
        AgentRole.assistant,
        AgentRole.tool,
        AgentRole.tool,
        AgentRole.tool,
        AgentRole.assistant,
      ]);
      expect(transcript[2].toolCallId, 'a');
      expect(transcript[2].isError, isFalse);
      expect(transcript[3].isError, isTrue);
      expect(transcript[3].text, contains('no tool called'));
      expect(transcript[4].text, 'bad json');
      expect(session.workspace.character.name, 'Aria');
      // Every request leads with the system prompt.
      expect(sent.every((m) => m.first.role == AgentRole.system), isTrue);
      expect(sent.first.first.text, 'SYS');
      // The second request carried the first round's results.
      expect(sent[1].where((m) => m.role == AgentRole.tool), hasLength(3));
    });

    test('stops at the step ceiling', () async {
      final loop = List.generate(
        10,
        (i) => [
          AgentDelta(toolCalls: [ToolCall(id: 'g$i', name: 'get_draft')]),
        ],
      );
      final runner = AgentRunner(
        name: 'studio',
        systemPrompt: '',
        tools: studioToolsFor('studio'),
        context: ctx,
        turn: scripted(loop, []),
        maxSteps: 3,
      );
      final transcript = <AgentMessage>[AgentMessage.user('go')];
      final outcome = await runner.run(transcript);
      expect(outcome.end, AgentRunEnd.stepLimit);
      // Three turns, each answered — the transcript can be sent again.
      expect(transcript.where((m) => m.role == AgentRole.assistant), hasLength(3));
      expect(transcript.where((m) => m.role == AgentRole.tool), hasLength(3));
    });

    test('a stop mid-stream keeps the words and drops the unanswered calls',
        () async {
      final gate = Completer<void>();
      late AgentRunner runner;
      runner = AgentRunner(
        name: 'studio',
        systemPrompt: '',
        tools: studioToolsFor('studio'),
        context: ctx,
        turn: (client, messages, tools) async* {
          yield const AgentDelta(text: 'Half a thought');
          runner.cancel();
          await gate.future.timeout(const Duration(milliseconds: 10),
              onTimeout: () {});
          yield const AgentDelta(toolCalls: [
            ToolCall(id: 'x', name: 'set_fields', arguments: {'name': 'Z'}),
          ]);
        },
      );
      final transcript = <AgentMessage>[AgentMessage.user('go')];
      final outcome = await runner.run(transcript);
      expect(outcome.end, AgentRunEnd.cancelled);
      expect(transcript.last.role, AgentRole.assistant);
      expect(transcript.last.text, 'Half a thought');
      expect(transcript.last.toolCalls, isEmpty);
      expect(session.workspace.character.name, '');
    });

    test('delegate calls in one turn run at the same time', () async {
      services.holdDelegates = Completer<void>();
      final runner = AgentRunner(
        name: 'studio',
        systemPrompt: '',
        tools: studioToolsFor('studio'),
        context: ctx,
        turn: scripted([
          [
            const AgentDelta(toolCalls: [
              ToolCall(
                id: 'd1',
                name: 'delegate',
                arguments: {'helper': 'writer', 'task': 'greetings'},
              ),
              ToolCall(
                id: 'd2',
                name: 'delegate',
                arguments: {'helper': 'lore_writer', 'task': 'the marsh'},
              ),
            ]),
          ],
          [const AgentDelta(text: 'Both done.')],
        ], []),
      );
      final transcript = <AgentMessage>[AgentMessage.user('go')];
      final done = runner.run(transcript);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(services.delegatesRunning, 2);
      services.holdDelegates!.complete();
      await done;
      expect(services.mostDelegatesAtOnce, 2);
      final results =
          transcript.where((m) => m.role == AgentRole.tool).toList();
      expect(results.map((m) => m.toolCallId), ['d1', 'd2']);
      expect(results.first.text, contains('writer did it'));
    });

    test('old tool output is shortened on the wire, not in the transcript', () {
      final big = 'x' * 2000;
      final transcript = <AgentMessage>[
        AgentMessage.user('go'),
        AgentMessage(role: AgentRole.assistant, toolCalls: const [
          ToolCall(id: '1', name: 'get_draft'),
        ]),
        AgentMessage.toolResult(const ToolCall(id: '1', name: 'get_draft'), big),
        AgentMessage(role: AgentRole.assistant, toolCalls: const [
          ToolCall(id: '2', name: 'get_draft'),
        ]),
        AgentMessage.toolResult(const ToolCall(id: '2', name: 'get_draft'), big),
        AgentMessage(role: AgentRole.assistant, toolCalls: const [
          ToolCall(id: '3', name: 'get_draft'),
        ]),
        AgentMessage.toolResult(const ToolCall(id: '3', name: 'get_draft'), big),
      ];
      final wire = AgentRunner.wireView(transcript);
      expect(wire[2].text.length, lessThan(600));
      expect(wire[2].text, contains('shortened'));
      expect(wire[2].toolCallId, '1');
      expect(wire[4].text, big);
      expect(wire[6].text, big);
      expect(transcript[2].text, big);
    });
  });

  test('the store saves, lists newest first, and deletes', () async {
    final dir = await Directory.systemTemp.createTemp('studio_store');
    addTearDown(() => dir.delete(recursive: true));
    final store = StudioStore(dir);
    final older = _session()..updatedAt = DateTime(2026, 1, 1);
    final newer = StudioSession(
      id: 's2',
      title: 'Newer',
      workspace: StudioWorkspace(character: Character(id: 'c2', name: 'B')),
      updatedAt: DateTime(2026, 2, 1),
    );
    await store.save(older);
    await store.save(newer);
    File('${dir.path}/junk.json').writeAsStringSync('{not json');
    final listed = await store.list();
    expect(listed.map((s) => s.id), ['s2', 's1']);
    expect((await store.read('s2'))!.title, 'Newer');
    await store.delete('s1');
    expect((await store.list()).map((s) => s.id), ['s2']);
  });

  group('against the real app', () {
    late HttpServer server;
    final bodies = <Map<String, dynamic>>[];

    Future<AppState> boot(List<Object> reply) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      bodies.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        bodies.add(jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>);
        request.response.headers.contentType =
            ContentType('text', 'event-stream');
        for (final e in reply) {
          request.response.write('data: ${e is String ? e : jsonEncode(e)}\n\n');
        }
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
      return state;
    }

    tearDown(() => server.close(force: true));

    test('an agent turn goes out with its tools and is metered', () async {
      final state = await boot([
        {
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 't',
                    'function': {'name': 'get_draft', 'arguments': '{}'},
                  },
                ],
              },
            },
          ],
        },
        {
          'choices': <Object>[],
          'usage': {'prompt_tokens': 50, 'completion_tokens': 7},
        },
        '[DONE]',
      ]);
      int? spentInput;
      final deltas = await state
          .streamAgentTurn(
            client: AgentClient(),
            messages: [AgentMessage.system('SYS'), AgentMessage.user('hi')],
            tools: [getDraftTool.spec],
            onSpend: (usage, cost) => spentInput = usage.inputTokens,
          )
          .toList();
      expect(deltas.expand((d) => d.toolCalls).single.name, 'get_draft');
      final body = bodies.single;
      expect(body['model'], 'test-model');
      expect((body['tools'] as List).single['function']['name'], 'get_draft');
      expect((body['messages'] as List).first,
          {'role': 'system', 'content': 'SYS'});
      expect(spentInput, 50);
    });

    test('the studio model overrides the provider model', () async {
      final state = await boot(['[DONE]']);
      await state.updateStudioConfig(const StudioConfig(model: 'builder-model'));
      await state
          .streamAgentTurn(
            client: AgentClient(),
            messages: [AgentMessage.user('hi')],
            tools: const [],
          )
          .toList();
      expect(bodies.single['model'], 'builder-model');
    });

    test('a playtest sends the draft and its lore through the real prompt',
        () async {
      final state = await boot([
        {
          'choices': [
            {
              'delta': {'content': 'The light must stay lit.'},
            },
          ],
        },
        '[DONE]',
      ]);
      final draft = Character(
        id: 'draft',
        name: 'Aria',
        description: 'DRAFT_DESC keeps the Saltmarsh light.',
        firstMes: 'You made it through the storm.',
        lorebookIds: ['book'],
      );
      final book = Lorebook(id: 'book', name: 'Marsh', entries: [
        LorebookEntry(uid: 0, keys: ['lighthouse'], content: 'LORE_TOKEN'),
      ]);
      final replies = await state.playtestCharacter(
        character: draft,
        lorebooks: [book],
        userTurns: ['Why do you tend the lighthouse?'],
      );
      expect(replies, ['The light must stay lit.']);
      final wire = jsonEncode(bodies.single['messages']);
      expect(wire, contains('DRAFT_DESC'));
      expect(wire, contains('LORE_TOKEN'));
      expect(wire, contains('You made it through the storm.'));
      expect(wire, contains('Why do you tend the lighthouse?'));
      // Still one leading system message: the playtest is a real send.
      final roles = [
        for (final m in bodies.single['messages'] as List) (m as Map)['role'],
      ];
      expect(roles.where((r) => r == 'system'), hasLength(1));
      expect(roles.first, 'system');
      // Nothing was stored.
      expect(state.characters, isEmpty);
      expect(state.lorebooks, isEmpty);
      expect(state.conversations, isEmpty);
    });
  });
}
