import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/agent_message.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/lorebook.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/models/studio.dart';
import 'package:maichat/services/studio/studio_controller.dart';
import 'package:maichat/services/studio/studio_store.dart';
import 'package:maichat/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The Studio end to end: a real [AppState] and [StudioController] driving the
/// real agent client against a loopback model that plays a script, one reply
/// per request. What is asserted is what the app sent, what the draft became,
/// what was saved, and what applying put in the library.
void main() {
  late HttpServer server;
  late Directory dir;
  late List<Map<String, dynamic>> requests;
  late List<List<Map<String, dynamic>>> script;

  Map<String, dynamic> call(String id, String name, Map<String, dynamic> args) => {
        'choices': [
          {
            'delta': {
              'tool_calls': [
                {
                  'index': 0,
                  'id': id,
                  'type': 'function',
                  'function': {'name': name, 'arguments': jsonEncode(args)},
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

  Future<AppState> boot() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    requests = [];
    dir = await Directory.systemTemp.createTemp('studio_controller');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final body = jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>;
      requests.add(body);
      final events = requests.length <= script.length
          ? script[requests.length - 1]
          : [words('(out of script)')];
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
      apiKey: 'k',
    ));
    return state;
  }

  tearDown(() async {
    await server.close(force: true);
    await dir.delete(recursive: true);
  });

  test('a message builds the draft through tools, and is saved', () async {
    script = [
      [
        words('Building her. '),
        call('a', 'set_fields', {
          'name': 'Maren',
          'description': '{{char}} keeps the Saltmarsh light.',
        }),
      ],
      [
        call('b', 'create_lorebook', {'name': 'Saltmarsh'}),
      ],
      [words('Maren is ready: a keeper with a lorebook.')],
    ];
    final state = await boot();
    final store = StudioStore(dir);
    final session = newStudioSession();
    final controller =
        StudioController(state: state, store: store, session: session);
    addTearDown(controller.flush);

    await controller.send('A lighthouse keeper on a haunted coast.');
    await controller.flush();

    expect(controller.running, isFalse);
    expect(controller.notice, isNull);
    expect(session.workspace.character.name, 'Maren');
    expect(session.workspace.lorebooks.single.name, 'Saltmarsh');
    expect(session.ops, hasLength(2));
    expect(
      session.transcript.map((m) => m.role),
      [
        AgentRole.user,
        AgentRole.assistant,
        AgentRole.tool,
        AgentRole.assistant,
        AgentRole.tool,
        AgentRole.assistant,
      ],
    );
    expect(session.transcript.last.text, contains('Maren is ready'));

    // Every request: the Studio's model, its instructions first, the tools.
    expect(requests, hasLength(3));
    for (final r in requests) {
      expect(r['model'], 'builder');
      final first = (r['messages'] as List).first as Map;
      expect(first['role'], 'system');
      expect(first['content'], contains('Character Studio'));
      final tools = [
        for (final t in r['tools'] as List) (t as Map)['function']['name'],
      ];
      expect(tools, containsAll(['get_draft', 'set_fields', 'delegate']));
    }
    // The third request carries both rounds of results.
    final third = (requests[2]['messages'] as List).cast<Map>();
    expect(third.where((m) => m['role'] == 'tool'), hasLength(2));

    // Spend is counted (estimated here — the stand-in reports no usage).
    expect(session.inputTokens, greaterThan(0));

    // And the session is on disk, whole.
    final saved = await store.read(session.id);
    expect(saved!.workspace.character.name, 'Maren');
    expect(saved.transcript, hasLength(6));
    expect(saved.title, isNotEmpty);
  });

  test('a failed request is reported and leaves the session usable', () async {
    script = [];
    final state = await boot();
    await server.close(force: true);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      await utf8.decoder.bind(request).join();
      request.response.statusCode = 400;
      request.response.write(jsonEncode({
        'error': {'message': 'this model does not support tools'},
      }));
      await request.response.close();
    });
    await state.updateProvider(Provider(
      id: 'p',
      name: 'local',
      kind: ProviderKind.openai,
      baseUrl: 'http://127.0.0.1:${server.port}/v1',
      model: 'builder',
      apiKey: 'k',
    ));
    final session = newStudioSession();
    final controller =
        StudioController(state: state, store: StudioStore(dir), session: session);
    addTearDown(controller.flush);
    await controller.send('go');
    expect(controller.running, isFalse);
    expect(controller.noticeIsError, isTrue);
    expect(controller.notice, contains('does not support tools'));
    expect(session.transcript.single.text, 'go');
  });

  test('hand edits are told to the agent with the next message', () async {
    script = [
      [words('Noted.')],
    ];
    final state = await boot();
    final session = newStudioSession();
    final controller =
        StudioController(state: state, store: StudioStore(dir), session: session);
    addTearDown(controller.flush);
    controller.editByHand('Edited the description by hand',
        (ws) => ws.character.description = 'Mine now.');
    await controller.send('Carry on.');
    final users = session.transcript
        .where((m) => m.role == AgentRole.user)
        .map((m) => m.text)
        .toList();
    expect(users.first, startsWith('[Studio note]'));
    expect(users.first, contains('Edited the description'));
    expect(users.last, 'Carry on.');
    expect(session.ops.single.tool, 'manual');
  });

  test('a rewind is told to the agent and restores the draft', () async {
    script = [
      [call('a', 'set_fields', {'name': 'Maren'})],
      [call('b', 'set_fields', {'name': 'Tamsin'})],
      [words('Renamed.')],
    ];
    final state = await boot();
    final session = newStudioSession();
    final controller =
        StudioController(state: state, store: StudioStore(dir), session: session);
    addTearDown(controller.flush);
    await controller.send('Name her.');
    expect(session.workspace.character.name, 'Tamsin');
    await controller.rewindTo(1);
    expect(session.workspace.character.name, 'Maren');
    expect(session.transcript.last.text, contains('rewound'));
    expect(session.transcript.last.text, contains('get_draft'));
  });

  test('applying adds the character, its books and a folder; again updates',
      () async {
    script = [];
    final state = await boot();
    final session = newStudioSession();
    session.workspace.character
      ..name = 'Maren'
      ..description = 'A keeper.';
    final book = Lorebook(id: 'book1', name: 'Saltmarsh', entries: [
      LorebookEntry(uid: 0, keys: ['marsh'], content: 'Grey.'),
    ]);
    session.workspace.lorebooks.add(book);
    session.workspace.character.lorebookIds.add('book1');
    session.workspace.documents
        .add(StudioDocument(id: 'd', name: 'History', text: 'Long ago.'));
    final controller =
        StudioController(state: state, store: StudioStore(dir), session: session);
    addTearDown(controller.flush);

    final first = await controller.apply(bundleFolder: true);
    expect(first.characterName, 'Maren');
    expect(first.lorebooks, 1);
    // Embeddings are off here, so the document is left out and says so.
    expect(first.documentsSkipped, 1);
    final stored = state.characterById(session.workspace.character.id)!;
    expect(stored.description, 'A keeper.');
    expect(stored.lorebookIds, ['book1']);
    expect(state.lorebookById('book1')!.entries.single.keys, ['marsh']);
    final folder = state.folders.single;
    expect(folder.characterIds, [stored.id]);
    expect(folder.lorebookIds, ['book1']);
    expect(session.appliedSinceChange, isTrue);

    // The library holds a copy: editing the draft does not reach it.
    controller.editByHand('x', (ws) => ws.character.description = 'Changed.');
    expect(state.characterById(stored.id)!.description, 'A keeper.');
    expect(session.appliedSinceChange, isFalse);

    await controller.apply(bundleFolder: true);
    expect(state.characters, hasLength(1));
    expect(state.characters.single.description, 'Changed.');
    expect(state.folders, hasLength(1));
  });

  test('a session opened from a library character applies back over it',
      () async {
    script = [];
    final state = await boot();
    final original = Character(
      id: 'lib',
      name: 'Old',
      description: 'Before.',
      lorebookIds: ['b'],
    );
    await state.saveLorebook(Lorebook(id: 'b', name: 'Book'));
    await state.saveCharacter(original);
    final session = studioSessionFor(state, state.characterById('lib')!);
    expect(session.workspace.lorebooks.single.id, 'b');
    expect(session.sourceCharacterId, 'lib');
    final controller =
        StudioController(state: state, store: StudioStore(dir), session: session);
    addTearDown(controller.flush);
    controller.editByHand('x', (ws) => ws.character.description = 'After.');
    // The library is untouched until apply.
    expect(state.characterById('lib')!.description, 'Before.');
    await controller.apply();
    expect(state.characters, hasLength(1));
    expect(state.characterById('lib')!.description, 'After.');
  });
}
