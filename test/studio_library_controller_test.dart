import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/discover.dart';
import 'package:maichat/models/lorebook.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/models/scenario.dart';
import 'package:maichat/services/discover/discover_sources.dart';
import 'package:maichat/services/studio/studio_controller.dart';
import 'package:maichat/services/studio/studio_discover.dart';
import 'package:maichat/services/studio/studio_images.dart';
import 'package:maichat/services/studio/studio_store.dart';
import 'package:maichat/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Bringing things in, end to end: a real [AppState] and [StudioController]
/// driving the agent client against a loopback model that plays a script,
/// with the library the app really holds and Discover pointed at a loopback
/// stand-in for Chub. What is asserted is what the draft became, what the
/// model was told back, and what applying put in the library.
void main() {
  late HttpServer model;
  late HttpServer site;
  late Directory dir;
  late List<Map<String, dynamic>> requests;
  late List<List<Map<String, dynamic>>> script;
  late String siteBase;
  final siteRequests = <String>[];

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

  /// What the model was sent back for the call [id].
  Map<String, dynamic> resultOf(String id) {
    for (final r in requests) {
      for (final m in r['messages'] as List) {
        if (m is Map && m['role'] == 'tool' && m['tool_call_id'] == id) {
          return jsonDecode(m['content'] as String) as Map<String, dynamic>;
        }
      }
    }
    throw StateError('No result for $id');
  }

  Future<AppState> boot() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    requests = [];
    siteRequests.clear();
    dir = await Directory.systemTemp.createTemp('studio_library_controller');
    model = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    model.listen((request) async {
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
    site = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    siteBase = 'http://${site.address.host}:${site.port}';
    site.listen((request) async {
      final line = '${request.uri}';
      siteRequests.add(line);
      request.response.headers.contentType = ContentType.json;
      if (line.contains('/search')) {
        request.response.write(jsonEncode({
          'data': {
            'nodes': [
              {'fullPath': 'anon/aria', 'name': 'Aria', 'id': 7},
            ],
          },
        }));
      } else if (line.contains('/api/characters/anon/aria')) {
        request.response.write(jsonEncode({
          'node': {
            'id': 7,
            'name': 'Aria',
            'fullPath': 'anon/aria',
            'definition': {
              'name': 'Aria',
              'personality': 'A ranger of the northern wood.',
              'first_message': 'You hear a bowstring draw.',
            },
          },
        }));
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    });
    StudioDiscover.shared = StudioDiscover(
      sources: () => [
        ChubSource(
          apiBase: siteBase,
          avatarBase: '$siteBase/avatars',
          siteBase: siteBase,
        ),
      ],
      gap: Duration.zero,
    );
    StudioImages.shared = StudioImages(allowPrivate: true);
    final state = AppState();
    await state.init();
    await state.addProvider(Provider(
      id: 'p',
      name: 'local',
      kind: ProviderKind.openai,
      baseUrl: 'http://127.0.0.1:${model.port}/v1',
      model: 'builder',
      apiKey: 'k',
    ));
    return state;
  }

  tearDown(() async {
    StudioDiscover.shared.close();
    StudioDiscover.shared = StudioDiscover();
    StudioImages.shared = StudioImages();
    await model.close(force: true);
    await site.close(force: true);
    await dir.delete(recursive: true);
  });

  test('a library character and scenario come into the draft; applying adds '
      'a new character and leaves the original alone', () async {
    script = [
      [call('a', 'list_library', {'kind': 'characters', 'search': 'maren'})],
      [call('b', 'load_library_character', {'id': 'maren', 'mode': 'replace'})],
      [call('c', 'use_library_scenario', {'id': 'wreck'})],
      [call('d', 'set_fields', {'name': 'Maren the Younger'})],
      [words('She is built on Maren.')],
    ];
    final state = await boot();
    await state.addLorebook(Lorebook(id: 'coast', name: 'Coast', entries: [
      LorebookEntry(uid: 0, keys: ['lamp'], content: 'The lamp never sleeps.'),
    ]));
    await state.addCharacter(Character(
      id: 'maren',
      name: 'Maren',
      description: '{{char}} keeps the light.',
      lorebookIds: ['coast'],
    ));
    await state.addScenario(
        Scenario(id: 'wreck', name: 'Wreck', text: 'A ship runs aground.'));

    final session = newStudioSession();
    final controller = StudioController(
      state: state,
      store: StudioStore(dir),
      session: session,
    );
    addTearDown(controller.flush);
    await controller.send('Start from Maren, but younger.');
    await controller.flush();

    expect(controller.notice, isNull);
    final listed = resultOf('a')['characters'] as List;
    expect(listed.single['id'], 'maren');
    expect(resultOf('b')['ok'], isTrue);
    expect(resultOf('c')['ok'], isTrue);
    final ws = session.workspace;
    expect(ws.character.name, 'Maren the Younger');
    expect(ws.character.description, '{{char}} keeps the light.');
    expect(ws.character.scenarios.single.scenarioId, 'wreck');
    expect(ws.lorebooks.single.entries.single.content, 'The lamp never sleeps.');
    // Each import is a row in Changes.
    expect(
      session.ops.map((o) => o.tool),
      ['load_library_character', 'use_library_scenario', 'set_fields'],
    );

    await controller.apply();
    // The original and its book are as they were; the new one is beside it.
    expect(state.characters.map((c) => c.name).toSet(),
        {'Maren', 'Maren the Younger'});
    expect(state.characters.firstWhere((c) => c.id == 'maren').name, 'Maren');
    expect(state.lorebooks.map((b) => b.name).toList()..sort(), ['Coast', 'Coast']);
    expect(state.lorebooks.where((b) => b.id == 'coast'), hasLength(1));
  });

  test('a Discover search and import run through the real app', () async {
    script = [
      [call('a', 'discover_search', {'query': 'ranger'})],
      [
        call('b', 'discover_import',
            {'source': 'chub', 'id': 'anon/aria', 'as': 'base'}),
      ],
      [words('Started from Aria.')],
    ];
    final state = await boot();
    await state.updateDiscoverPrefs(const DiscoverPrefs(sourceId: 'chub'));
    final session = newStudioSession();
    final controller = StudioController(
      state: state,
      store: StudioStore(dir),
      session: session,
    );
    addTearDown(controller.flush);
    await controller.send('Find me a ranger to start from.');
    await controller.flush();

    expect(controller.notice, isNull);
    expect((resultOf('a')['results'] as List).single['id'], 'anon/aria');
    expect(resultOf('b')['ok'], isTrue);
    final c = session.workspace.character;
    expect(c.name, 'Aria');
    expect(c.description, 'A ranger of the northern wood.');
    // Whatever became of the picture, the draft holds no base64.
    expect(c.avatar.isEmpty || c.avatar.startsWith('local:'), isTrue,
        reason: c.avatar);
    // Adult results follow the app's own Discover switch.
    expect(siteRequests.first, contains('nsfw=false'));
    expect(session.ops.single.summary, contains('Aria'));
    // The tools were offered to the model.
    final tools = [
      for (final t in requests.first['tools'] as List) (t as Map)['function']['name'],
    ];
    expect(tools,
        containsAll(['discover_search', 'discover_read', 'discover_import']));
  });
}
