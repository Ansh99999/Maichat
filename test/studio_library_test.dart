import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/character_scenario.dart';
import 'package:maichat/models/discover.dart';
import 'package:maichat/models/gallery_image.dart';
import 'package:maichat/models/lorebook.dart';
import 'package:maichat/models/scenario.dart';
import 'package:maichat/models/studio.dart';
import 'package:maichat/services/discover/discover_sources.dart';
import 'package:maichat/services/studio/custom_agents.dart';
import 'package:maichat/services/studio/image_tools.dart';
import 'package:maichat/services/studio/library_tools.dart';
import 'package:maichat/services/studio/studio_discover.dart';
import 'package:maichat/services/studio/studio_images.dart';
import 'package:maichat/services/studio/studio_tools.dart';

/// The tools that bring things into the draft: from the user's library (a
/// character, a scenario, a lorebook's entries) and from Discover (search,
/// read, import). Plain `test()`s only — the Discover half talks to a
/// loopback stand-in for Chub and Character Tavern, and a `testWidgets` in
/// this file would make every real request answer 400.
class _Services
    implements
        StudioServices,
        StudioLibraryServices,
        StudioDiscoverServices,
        StudioPictureServices {
  _Services({StudioDiscover? discover, StudioImages? images})
      : discover = discover ?? StudioDiscover(sources: () => const []),
        images = images ?? StudioImages(allowPrivate: true);

  @override
  int countTokens(String text) => (text.length / 4).ceil();

  @override
  List<Character> libraryCharacters = <Character>[];

  @override
  List<Lorebook> libraryLorebooks = <Lorebook>[];

  @override
  List<Scenario> libraryScenarios = <Scenario>[];

  @override
  final StudioDiscover discover;

  @override
  bool discoverNsfw = false;

  @override
  String discoverSourceId = '';

  @override
  final StudioImages images;

  /// What was filed in the gallery, in order.
  final List<WebPicture> filed = <WebPicture>[];

  @override
  Future<GalleryImage?> fileWebPicture(
    WebPicture picture, {
    required String characterId,
    String title = '',
  }) async {
    filed.add(picture);
    return GalleryImage(
      id: 'g${filed.length}',
      image: 'local:filed${filed.length}.png',
      title: title,
      characterId: characterId,
      source: picture.source,
      credit: picture.credit,
    );
  }

  @override
  List<GalleryImage> get galleryPictures => const [];

  @override
  bool get canGenerateImages => false;

  @override
  Future<String> generatePicture({
    required String prompt,
    required String characterId,
  }) async =>
      throw UnimplementedError();

  @override
  Future<List<String>> playtest({
    required Character character,
    required List<Lorebook> lorebooks,
    required List<String> userTurns,
    int greetingIndex = 0,
    List<StudioPlaytestTurn> earlier = const <StudioPlaytestTurn>[],
    String scenario = '',
  }) async =>
      const [];

  @override
  Future<StudioTaskOutcome> runTask({
    required String agentType,
    required String description,
    required String prompt,
    required String callId,
    String? taskId,
  }) async =>
      throw UnimplementedError();
}

Map<String, dynamic> _json(StudioToolResult r) =>
    jsonDecode(r.text) as Map<String, dynamic>;

/// A 1x1 PNG.
final List<int> _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAABzenr0AAAADUlEQVR42mP8'
  '/5+BAQAI/AL+6nWJPwAAAABJRU5ErkJggg==',
);

void main() {
  late _Services services;
  late StudioSession session;
  late StudioToolContext ctx;

  StudioSession fresh() => StudioSession(
        id: 's1',
        title: '',
        workspace: StudioWorkspace(
          character: Character(id: 'draft', name: 'Wren', description: 'A thief.'),
          lorebooks: [Lorebook(id: 'mine', name: 'My notes')],
          documents: [StudioDocument(id: 'd1', name: 'History', text: 'Long ago.')],
          notes: '## Ideas\nA thief with a conscience.',
        ),
      );

  Future<StudioToolResult> call(String tool, Map<String, dynamic> args,
          [StudioToolContext? as]) =>
      kStudioTools[tool]!.call(as ?? ctx, args);

  Lorebook libraryBook() => Lorebook(id: 'lib-book', name: 'Valeport', entries: [
        LorebookEntry(uid: 0, name: 'Docks', keys: ['docks'], content: 'Wet.'),
        LorebookEntry(uid: 1, name: 'Keep', keys: ['keep'], content: 'Old stone.'),
        LorebookEntry(uid: 2, name: 'Guild', keys: ['guild'], content: 'Thieves.'),
      ]);

  Character libraryCharacter() => Character(
        id: 'lib-char',
        name: 'Maren',
        description: '{{char}} keeps the light.',
        personality: 'Dry, patient.',
        firstMes: 'The lamp turns.',
        alternateGreetings: ['Fog again.', 'A ship!'],
        tags: ['coastal'],
        avatar: 'local:maren.png',
        avatars: ['local:maren2.png'],
        lorebookIds: ['lib-book'],
        scenarios: [CharacterScenario(id: 'cs1', name: 'Storm', text: 'A storm.')],
      );

  setUp(() {
    services = _Services();
    session = fresh();
    ctx = StudioToolContext(session: session, services: services);
    services.libraryCharacters = [libraryCharacter()];
    services.libraryLorebooks = [libraryBook()];
    services.libraryScenarios = [
      Scenario(id: 'sc1', name: 'Shipwreck', text: 'A ship runs aground.'),
      Scenario(
        id: 'sc2',
        name: 'Fair day',
        text: 'The town fair is on.',
        overwriteCharacterScenario: false,
      ),
    ];
  });

  group('the library', () {
    test('scenarios are listed and read like the other kinds', () async {
      final list = _json(await call('list_library', {'kind': 'scenarios'}));
      expect([for (final s in list['scenarios'] as List) s['id']], ['sc1', 'sc2']);
      final found = _json(
          await call('list_library', {'kind': 'scenarios', 'search': 'fair'}));
      expect((found['scenarios'] as List).single['name'], 'Fair day');
      final read =
          _json(await call('read_library_item', {'kind': 'scenario', 'id': 'sc2'}));
      expect(read['text'], 'The town fair is on.');
      expect(read['when_used_as_main'], contains('added after'));
      // A library character says which lorebooks it carries.
      final c = _json(
          await call('read_library_item', {'kind': 'character', 'id': 'lib-char'}));
      expect((c['lorebooks'] as List).single['name'], 'Valeport');
    });

    test('a library scenario becomes one of the card\'s own, or its main one',
        () async {
      final r = await call('use_library_scenario', {
        'id': 'sc1',
        'greetings': [0, 2],
      });
      expect(r.isError, isFalse, reason: r.text);
      final added = session.workspace.character.scenarios.single;
      expect(added.text, 'A ship runs aground.');
      expect(added.scenarioId, 'sc1');
      expect(added.greetings, [0, 2]);

      session.workspace.character.scenario = 'A port town.';
      await call('use_library_scenario', {'id': 'sc2', 'as': 'main'});
      // Set to add to the card's own: after it, not instead of it.
      expect(session.workspace.character.scenario,
          'A port town.\n\nThe town fair is on.');
      await call('use_library_scenario', {'id': 'sc1', 'as': 'main'});
      expect(session.workspace.character.scenario, 'A ship runs aground.');

      expect((await call('use_library_scenario', {'id': 'nope'})).isError, isTrue);
      expect(session.ops, hasLength(3));
      session.rewindTo(0);
      expect(session.workspace.character.scenarios, isEmpty);
    });

    test('replace starts a new character from a library one, with copies of '
        'its books, and rewinds', () async {
      final r = await call(
          'load_library_character', {'id': 'lib-char', 'mode': 'replace'});
      expect(r.isError, isFalse, reason: r.text);
      expect(_json(r)['applies_as'], contains('new character'));
      final ws = session.workspace;
      expect(ws.character.name, 'Maren');
      expect(ws.character.alternateGreetings, ['Fog again.', 'A ship!']);
      expect(ws.character.avatar, 'local:maren.png');
      // A new character, so applying cannot overwrite the library's.
      expect(ws.character.id, isNot('lib-char'));
      expect(ws.character.id, isNot('draft'));
      // Its book is a copy under a new id …
      final book = ws.lorebooks.single;
      expect(book.name, 'Valeport');
      expect(book.id, isNot('lib-book'));
      expect(ws.character.lorebookIds, [book.id]);
      // … so changing it leaves the library's alone.
      book.entries.first.content = 'Dry now.';
      expect(services.libraryLorebooks.single.entries.first.content, 'Wet.');
      // The draft's own book went with the old character; documents and notes
      // stay.
      expect(ws.lorebook('mine'), isNull);
      expect(ws.documents.single.name, 'History');
      expect(ws.notes, contains('conscience'));

      session.rewindTo(0);
      expect(session.workspace.character.name, 'Wren');
      expect(session.workspace.lorebooks.single.id, 'mine');
    });

    test('replace with edit_original keeps the ids, so apply updates it',
        () async {
      await call('load_library_character', {
        'id': 'lib-char',
        'mode': 'replace',
        'edit_original': true,
        'keep_lorebooks': true,
      });
      final ws = session.workspace;
      expect(ws.character.id, 'lib-char');
      expect(ws.lorebooks.map((b) => b.id), ['mine', 'lib-book']);
      expect(ws.character.lorebookIds, ['lib-book', 'mine']);
    });

    test('merge takes only the named parts', () async {
      final r = await call('load_library_character', {
        'id': 'lib-char',
        'mode': 'merge',
        'parts': ['personality', 'alternate_greetings', 'lorebooks', 'scenarios'],
      });
      expect(r.isError, isFalse, reason: r.text);
      final c = session.workspace.character;
      expect(c.name, 'Wren');
      expect(c.description, 'A thief.');
      expect(c.personality, 'Dry, patient.');
      expect(c.alternateGreetings, ['Fog again.', 'A ship!']);
      expect(c.scenarios.single.text, 'A storm.');
      expect(c.scenarios.single.id, isNot('cs1'));
      // Attached as attach_library_lorebook does: the library's own book.
      expect(session.workspace.lorebook('lib-book'), isNotNull);
      expect(c.lorebookIds, contains('lib-book'));
      expect(c.avatar, isEmpty);

      expect(
        _json(await call(
            'load_library_character', {'id': 'lib-char', 'mode': 'merge'}))['error'],
        contains('"parts"'),
      );
      expect(
        _json(await call('load_library_character', {
          'id': 'lib-char',
          'mode': 'merge',
          'parts': ['face'],
        }))['error'],
        contains('Unknown part "face"'),
      );
    });

    test('a replace over what another agent changed since is refused',
        () async {
      final helper = ctx.as('Subagent 1');
      await call('set_fields', {'description': 'A reformed thief.'}, helper);
      final refused = await call(
          'load_library_character', {'id': 'lib-char', 'mode': 'replace'});
      expect(refused.isError, isTrue);
      expect(refused.text, contains('Subagent 1'));
      expect(session.workspace.character.name, 'Wren');
      await call('get_draft', {});
      final ok = await call(
          'load_library_character', {'id': 'lib-char', 'mode': 'replace'});
      expect(ok.isError, isFalse, reason: ok.text);
    });

    test('lore entries are copied by search or uid, renumbered', () async {
      final r = await call('copy_lore_entries', {
        'from_id': 'lib-book',
        'lorebook_id': 'mine',
        'search': 'stone',
      });
      expect(_json(r)['copied'], 1);
      await call('copy_lore_entries', {
        'from_id': 'lib-book',
        'lorebook_id': 'mine',
        'uids': [0, 2],
      });
      final mine = session.workspace.lorebook('mine')!;
      expect(mine.entries.map((e) => e.name), ['Keep', 'Docks', 'Guild']);
      expect(mine.entries.map((e) => e.uid).toSet(), hasLength(3));
      expect(services.libraryLorebooks.single.entries, hasLength(3));
      final missing = await call('copy_lore_entries', {
        'from_id': 'lib-book',
        'lorebook_id': 'nope',
      });
      expect(missing.text, contains('mine (My notes)'));
    });

    test('each agent type gets what it should', () {
      Set<String> names(String type) =>
          {for (final t in studioToolsForType(type, const StudioConfig())) t.name};
      final reads = {'list_library', 'read_library_item', ...kLibraryReadToolNames};
      expect(names('studio'), containsAll({...reads, ...kLibraryImportToolNames}));
      expect(names('general'), containsAll({...reads, ...kLibraryImportToolNames}));
      expect(names('critic'), containsAll(reads));
      expect(names('critic').intersection(kLibraryImportToolNames.toSet()), isEmpty);
      expect(names('writer'),
          containsAll({'load_library_character', 'use_library_scenario'}));
      expect(names('lore_writer'),
          containsAll({'copy_lore_entries', 'attach_library_lorebook'}));
    });
  });

  group('Discover', () {
    late HttpServer server;
    late String base;
    late List<String> requests;
    late Map<String, Object Function(String base)> routes;

    setUp(() async {
      requests = [];
      routes = {};
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://${server.address.host}:${server.port}';
      server.listen((request) async {
        final line = '${request.uri}';
        requests.add(line);
        Object Function(String)? builder;
        for (final e in routes.entries) {
          if (line.contains(e.key)) {
            builder = e.value;
            break;
          }
        }
        if (builder == null) {
          request.response.statusCode = 404;
          await request.response.close();
          return;
        }
        final body = builder(base);
        if (body is List<int>) {
          request.response.headers.contentType = ContentType('image', 'png');
          request.response.add(body);
        } else {
          request.response.headers.contentType = ContentType.json;
          request.response.write(body);
        }
        await request.response.close();
      });
      final discover = StudioDiscover(
        sources: () => [
          ChubSource(apiBase: base, avatarBase: '$base/avatars', siteBase: base),
          CharacterTavernSource(apiBase: base, cardBase: '$base/ct'),
        ],
        gap: Duration.zero,
      );
      services = _Services(discover: discover);
      services.libraryCharacters = [libraryCharacter()];
      ctx = StudioToolContext(session: session, services: services);
    });

    tearDown(() async {
      services.discover.close();
      await server.close(force: true);
    });

    String chubSearch() => jsonEncode({
          'data': {
            'nodes': [
              {
                'fullPath': 'anon/aria',
                'name': 'Aria',
                'tagline': 'A ranger of the north.',
                'topics': ['fantasy'],
                'starCount': 12,
                'id': 7,
              },
            ],
          },
        });

    String chubCharacter(String base) => jsonEncode({
          'node': {
            'id': 7,
            'name': 'Aria',
            'fullPath': 'anon/aria',
            'max_res_url': '$base/aria.png',
            'definition': {
              'name': 'Aria',
              'personality': 'A ranger of the northern wood.',
              'tavern_personality': 'wry, watchful',
              'first_message': 'You hear a bowstring draw.',
              'alternate_greetings': ['A twig snaps.'],
              'embedded_lorebook': {
                'name': '',
                'entries': [
                  {
                    'keys': ['wood'],
                    'content': 'The northern wood.',
                    'enabled': true,
                  },
                ],
              },
            },
          },
        });

    test('a search lists ids, sorts and the other catalogues, adult off',
        () async {
      routes['/search'] = (_) => chubSearch();
      final r = await call('discover_search', {'query': 'ranger'});
      expect(r.isError, isFalse, reason: r.text);
      final out = _json(r);
      expect(out['source'], 'chub');
      expect((out['results'] as List).single['id'], 'anon/aria');
      expect((out['results'] as List).single['tagline'], 'A ranger of the north.');
      expect(out['other_sources'], ['ctavern']);
      expect(out['sorts'], isNotEmpty);
      expect(out['adult_results'], contains('off'));
      expect(requests.single, contains('nsfw=false'));
      expect(requests.single, contains('search=ranger'));

      // The user's own switch decides, never the agent.
      services.discoverNsfw = true;
      await call('discover_search', {'query': 'ranger', 'nsfw': true});
      expect(requests.last, contains('nsfw=true'));
    });

    test('the catalogue must exist and publish the kind', () async {
      final unknown = await call('discover_search', {'source': 'nowhere'});
      expect(unknown.text, contains('chub'));
      final noBooks =
          await call('discover_search', {'source': 'ctavern', 'kind': 'lorebook'});
      expect(noBooks.isError, isTrue);
      expect(noBooks.text, contains('Character Tavern has no lorebooks'));
      final badSort =
          await call('discover_search', {'source': 'ctavern', 'sort': 'random'});
      expect(badSort.text, contains('newest'));
      expect(requests, isEmpty);
    });

    test('a read shows the whole card and its book; an import reuses the '
        'download', () async {
      routes['/search'] = (_) => chubSearch();
      routes['/api/characters/anon/aria'] = chubCharacter;
      routes['/aria.png'] = (_) => _png;
      await call('discover_search', {});
      final read = _json(
          await call('discover_read', {'source': 'chub', 'id': 'anon/aria'}));
      final card = read['character'] as Map;
      expect((card['fields'] as Map)['description'], 'A ranger of the northern wood.');
      expect((card['fields'] as Map)['personality'], 'wry, watchful');
      expect(card['alternate_greetings'], ['A twig snaps.']);
      expect((read['lorebook'] as Map)['entry_count'], 1);
      expect(read['link'], '$base/characters/anon/aria');
      // The draft is untouched by reading.
      expect(session.ops, isEmpty);

      final r = await call(
          'discover_import', {'source': 'chub', 'id': 'anon/aria', 'as': 'base'});
      expect(r.isError, isFalse, reason: r.text);
      expect(
        requests.where((l) => l.contains('/api/characters/anon/aria')),
        hasLength(1),
      );
      final ws = session.workspace;
      expect(ws.character.name, 'Aria');
      expect(ws.character.firstMes, 'You hear a bowstring draw.');
      expect(ws.character.id, isNot('draft'));
      // The picture the card brought as bytes is a gallery file with its
      // source — never base64 in the draft.
      expect(ws.character.avatar, 'local:filed1.png');
      expect(services.filed.single.credit, 'Chub · by anon');
      expect(services.filed.single.source, '$base/characters/anon/aria');
      // Its own book came too, attached.
      final book = ws.lorebooks.single;
      expect(book.entries.single.content, 'The northern wood.');
      expect(ws.character.lorebookIds, [book.id]);
      expect(ws.notes, contains('conscience'));

      expect(session.ops.single.summary, contains('Aria'));
      session.rewindTo(0);
      expect(session.workspace.character.name, 'Wren');
    });

    test('as reference it goes into the notes; as lorebook, into the draft',
        () async {
      routes['/api/characters/anon/aria'] = chubCharacter;
      routes['/aria.png'] = (_) => _png;
      // Not listed first: the id alone is enough for Chub.
      final ref = await call('discover_import',
          {'source': 'chub', 'id': 'anon/aria', 'as': 'reference'});
      expect(ref.isError, isFalse, reason: ref.text);
      final ws = session.workspace;
      expect(ws.character.name, 'Wren');
      expect(ws.notes, contains('## From Discover: Aria'));
      expect(ws.notes, contains('A ranger of the northern wood.'));
      expect(ws.notes, contains('Source: Chub'));
      expect(ws.notes, contains('conscience'));

      final lore = await call('discover_import',
          {'source': 'chub', 'id': 'anon/aria', 'as': 'lorebook'});
      expect(lore.isError, isFalse, reason: lore.text);
      expect(ws.lorebooks.map((b) => b.name), ['My notes', "Aria's lorebook"]);
      expect(ws.character.lorebookIds, contains(_json(lore)['lorebook_id']));
      expect(ws.character.name, 'Wren');
    });

    test('a lorebook listing is searched and imported with its whole listing',
        () async {
      routes['namespace=lorebooks'] = (_) => jsonEncode({
            'data': {
              'nodes': [
                {'fullPath': 'lorebooks/anon/kingdom', 'name': 'Kingdom', 'id': 55},
              ],
            },
          });
      routes['sillytavern_raw.json'] = (_) => jsonEncode({
            'entries': {
              '0': {
                'uid': 0,
                'comment': 'Valeport',
                'content': 'Valeport is the capital.',
                'key': ['valeport'],
              },
            },
          });
      final found = _json(await call('discover_search', {'kind': 'lorebook'}));
      expect((found['results'] as List).single['id'], 'lorebooks/anon/kingdom');
      final r = await call('discover_import', {
        'source': 'chub',
        'kind': 'lorebook',
        'id': 'lorebooks/anon/kingdom',
        'as': 'lorebook',
      });
      expect(r.isError, isFalse, reason: r.text);
      // The project id came from the search, not a second lookup.
      expect(requests.last, contains('/api/v4/projects/55/'));
      final book = session.workspace.lorebooks.last;
      expect(book.name, 'Kingdom');
      expect(book.entries.single.content, 'Valeport is the capital.');
      final asBase = await call('discover_import', {
        'source': 'chub',
        'kind': 'lorebook',
        'id': 'lorebooks/anon/kingdom',
        'as': 'base',
      });
      expect(_json(asBase)['error'], contains('import it as "lorebook"'));
    });

    test('Character Tavern: the listing\'s art is fetched and filed', () async {
      routes['/api/search/cards'] = (_) => jsonEncode({
            'hits': [
              {
                'path': 'anon/bram',
                'name': 'Bram',
                'author': 'anon',
                'tags': ['sci-fi'],
              },
            ],
            'page': 1,
            'totalPages': 1,
          });
      routes['/ct/anon/bram.png?action=download'] = (_) => jsonEncode({
            'spec': 'chara_card_v2',
            'data': {
              'name': 'Bram',
              'description': '{{char}} runs a salvage tug.',
              'first_mes': 'The airlock hisses.',
            },
          });
      routes['/ct/anon/bram.png'] = (_) => _png;
      final found =
          _json(await call('discover_search', {'source': 'ctavern', 'query': 'tug'}));
      expect((found['results'] as List).single['id'], 'anon/bram');
      expect(requests.single, contains('exclude_tags=nsfw'));
      final r = await call('discover_import',
          {'source': 'ctavern', 'id': 'anon/bram', 'as': 'base'});
      expect(r.isError, isFalse, reason: r.text);
      final c = session.workspace.character;
      expect(c.name, 'Bram');
      expect(c.description, contains('salvage tug'));
      expect(c.avatar, 'local:filed1.png');
      expect(services.filed.single.url, '$base/ct/anon/bram.png');
      expect(services.filed.single.credit, 'Character Tavern · by anon');
      // No book on the card: none in the draft either.
      expect(session.workspace.lorebooks, isEmpty);
    });

    test('a site that wants a browser check says to use Discover itself',
        () async {
      final checked = StudioDiscover(
        sources: () => [_Checked()],
        gap: Duration.zero,
      );
      services = _Services(discover: checked);
      ctx = StudioToolContext(session: session, services: services);
      final r = await call('discover_read', {'source': 'checked', 'id': 'x'});
      expect(r.isError, isTrue);
      expect(r.text, contains('browser check'));
      expect(r.text, contains('Discover'));
    });

    test('a burst of searches reaches a site one at a time, spaced out',
        () async {
      routes['/search'] = (_) => chubSearch();
      final spaced = StudioDiscover(
        sources: () => [
          ChubSource(apiBase: base, avatarBase: '$base/avatars', siteBase: base),
        ],
        gap: const Duration(milliseconds: 150),
      );
      addTearDown(spaced.close);
      final source = spaced.sources.single;
      final times = <DateTime>[];
      await Future.wait([
        for (var i = 0; i < 3; i++)
          spaced
              .search(source, DiscoverQuery(search: 'q$i'))
              .then((_) => times.add(DateTime.now())),
      ]);
      expect(times, hasLength(3));
      for (var i = 1; i < times.length; i++) {
        expect(times[i].difference(times[i - 1]).inMilliseconds,
            greaterThanOrEqualTo(140));
      }
      // Remembered for a later read.
      expect(spaced.item('chub', DiscoverKind.character, 'anon/aria'), isNotNull);
    });
  });
}

/// A catalogue that only answers a real browser.
class _Checked extends DiscoverSource {
  @override
  String get id => 'checked';
  @override
  String get label => 'Checked';
  @override
  String get blurb => '';
  @override
  String get homeUrl => 'https://checked.example';
  @override
  Set<DiscoverKind> get kinds => const {DiscoverKind.character};
  @override
  List<DiscoverSort> sortsFor(DiscoverKind kind) => const [];
  @override
  Future<DiscoverPage> search(DiscoverQuery query) async =>
      const DiscoverPage.empty();
  @override
  Future<DiscoverPayload> fetch(DiscoverItem item) async =>
      throw const DiscoverChallengeException('Blocked.', 'https://checked.example/x');
}
