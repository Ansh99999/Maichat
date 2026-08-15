import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/discover.dart';
import 'package:maichat/services/discover/chub_source.dart';
import 'package:maichat/services/discover/discover_source.dart';

/// Chub's API is the awkward one: its field names predate the V2 card spec and
/// cross over it (`definition.personality` is the description), its casing is
/// inconsistent per field, and a lorebook lives behind a double-escaped path in
/// a git repository. These tests pin all three, because every one of them is a
/// silent wrong-data bug rather than a crash.
void main() {
  group('request building', () {
    final source = ChubSource(apiBase: 'https://api.example');

    test('a character feed sends the parameters Chub expects', () {
      final uri = source.searchUri(const DiscoverQuery(
        search: 'elf ranger',
        sort: 'download_count',
        page: 2,
        nsfw: true,
        includeTags: ['fantasy', 'female'],
        excludeTags: ['gore'],
        pageSize: 24,
      ));
      final q = uri.queryParameters;

      expect(uri.host, 'api.example');
      expect(uri.path, '/search');
      expect(q['first'], '24');
      expect(q['page'], '2');
      expect(q['search'], 'elf ranger');
      expect(q['sort'], 'download_count');
      // The two adult tiers move together.
      expect(q['nsfw'], 'true');
      expect(q['nsfl'], 'true');
      expect(q['include_forks'], 'true');
      expect(q['venus'], 'false');
      expect(q['min_tokens'], '50');
      expect(q['topics'], 'fantasy,female');
      // Deliberately no underscore — that is the parameter's real name.
      expect(q['excludetopics'], 'gore');
      expect(q.containsKey('namespace'), isFalse);
    });

    test('relevance is an absent sort, not an empty one', () {
      final q = source.searchUri(const DiscoverQuery()).queryParameters;
      expect(q.containsKey('sort'), isFalse);
      expect(q['nsfw'], 'false');
    });

    test('a lorebook feed switches namespace and drops the token floor', () {
      final q = source
          .searchUri(const DiscoverQuery(kind: DiscoverKind.lorebook))
          .queryParameters;
      expect(q['namespace'], 'lorebooks');
      expect(q.containsKey('min_tokens'), isFalse);
    });

    test('the lorebook file path stays double-escaped', () {
      final uri = source.lorebookDownloadUri(4242);
      // %252F must survive verbatim: it is `raw/sillytavern_raw.json` with the
      // slash escaped and then the escape escaped. Re-encoding it 404s.
      expect(uri.toString(), contains('raw%252Fsillytavern_raw.json'));
      expect(uri.toString(), contains('/api/v4/projects/4242/repository/files/'));
      expect(uri.queryParameters['ref'], 'main');
    });

    test('a lorebook path gains its namespace segment only when missing', () {
      expect(ChubSource.lorebookPath('anon/kingdom'), 'lorebooks/anon/kingdom');
      expect(
        ChubSource.lorebookPath('lorebooks/anon/kingdom'),
        'lorebooks/anon/kingdom',
      );
      expect(
        source.lorebookMetadataUri('anon/kingdom').path,
        '/api/lorebooks/anon/kingdom',
      );
    });
  });

  group('response reading', () {
    final source = ChubSource(
      apiBase: 'https://api.example',
      avatarBase: 'https://img.example/avatars',
      siteBase: 'https://site.example',
    );

    test('nodes are found under any of the four envelopes', () {
      const node = <String, dynamic>{'fullPath': 'a/b'};
      expect(ChubSource.extractNodes({'nodes': [node]}), hasLength(1));
      expect(ChubSource.extractNodes({'data': {'nodes': [node]}}), hasLength(1));
      expect(ChubSource.extractNodes({'data': [node]}), hasLength(1));
      expect(ChubSource.extractNodes([node]), hasLength(1));
      expect(ChubSource.extractNodes('nonsense'), isEmpty);
    });

    test('a node maps onto an item, camelCase or snake_case', () {
      final item = source.itemFrom(<String, dynamic>{
        'id': 991,
        'name': 'Aria',
        'fullPath': 'anon/aria',
        'tagline': 'A <b>ranger</b>',
        'description': 'Notes here',
        'topics': ['fantasy', 'female'],
        'starCount': 1200,
        'n_favorites': 34,
        'rating': 4.5,
        'ratingCount': 8,
        'nTokens': 900,
        'createdAt': '2026-01-02T03:04:05Z',
        'last_activity_at': '2026-02-03T04:05:06Z',
        'nsfw': true,
        'has_lore': true,
        'max_res_url': 'https://img.example/full.png',
      }, DiscoverKind.character)!;

      expect(item.sourceId, 'chub');
      expect(item.id, 'anon/aria');
      expect(item.name, 'Aria');
      expect(item.creator, 'anon');
      // HTML in a blurb is stripped, not rendered as markup in a card.
      expect(item.tagline, 'A ranger');
      expect(item.tags, ['fantasy', 'female']);
      // `starCount` is the download count on Chub, however it reads.
      expect(item.downloads, 1200);
      expect(item.favourites, 34);
      expect(item.rating, 4.5);
      expect(item.ratingCount, 8);
      expect(item.tokens, 900);
      expect(item.createdAt, DateTime.utc(2026, 1, 2, 3, 4, 5));
      expect(item.updatedAt, DateTime.utc(2026, 2, 3, 4, 5, 6));
      expect(item.nsfw, isTrue);
      expect(item.hasLore, isTrue);
      expect(item.projectId, 991);
      expect(item.imageUrl, 'https://img.example/full.png');
      expect(item.pageUrl, 'https://site.example/characters/anon/aria');
    });

    test('a missing avatar is derived from the full path', () {
      final item = source.itemFrom(
        <String, dynamic>{'fullPath': 'anon/aria', 'name': 'Aria'},
        DiscoverKind.character,
      )!;
      expect(item.thumbnailUrl, 'https://img.example/avatars/anon/aria/avatar.webp');
    });

    test('a related lorebook counts as having lore', () {
      final item = source.itemFrom(<String, dynamic>{
        'fullPath': 'anon/aria',
        'related_lorebooks': [{'id': 5}],
      }, DiscoverKind.character)!;
      expect(item.hasLore, isTrue);
      // No name in the node: fall back to the slug rather than showing blank.
      expect(item.name, 'aria');
    });

    test('a node with no path is dropped rather than half-rendered', () {
      expect(source.itemFrom(const <String, dynamic>{'name': 'x'},
          DiscoverKind.character), isNull);
    });
  });

  group('over the wire', () {
    late HttpServer server;
    late ChubSource source;
    late String base;
    final requests = <String>[];

    /// A 1x1 PNG, so the avatar download has something real to fetch.
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAABzenr0AAAADUlEQVR42mP8'
      '/5+BAQAI/AL+6nWJPwAAAABJRU5ErkJggg==',
    );

    /// Routes are matched as substrings of the request line, because the
    /// lorebook path is deliberately double-escaped and a decoded `uri.path`
    /// would not compare equal to it. Each builder receives the server's own
    /// base URL so a response can point back at it.
    Future<void> serve(Map<String, Object Function(String base)> routes) async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://${server.address.host}:${server.port}';
      source = ChubSource(
        apiBase: base,
        avatarBase: '$base/avatars',
        siteBase: base,
      );
      server.listen((request) async {
        final line = '${request.uri}';
        requests.add(line);
        Object Function(String)? builder;
        for (final entry in routes.entries) {
          if (line.contains(entry.key)) {
            builder = entry.value;
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
    }

    setUp(requests.clear);
    tearDown(() async {
      source.close();
      await server.close(force: true);
    });

    test('a feed page becomes items, and a short page ends the feed', () async {
      await serve({
        '/search': (_) => jsonEncode({
              'data': {
                'nodes': [
                  {'fullPath': 'anon/aria', 'name': 'Aria', 'starCount': 5},
                  {'fullPath': 'anon/bram', 'name': 'Bram'},
                ],
              },
            }),
      });

      final page = await source.search(const DiscoverQuery(pageSize: 24));
      expect(page.items.map((i) => i.name), ['Aria', 'Bram']);
      // Two results for a page of 24: there is no more.
      expect(page.hasMore, isFalse);
      expect(requests.single, contains('first=24'));
    });

    test('a full page leaves the door open for the next one', () async {
      await serve({
        '/search': (_) => jsonEncode({
              'nodes': [
                for (var i = 0; i < 2; i++)
                  {'fullPath': 'anon/c$i', 'name': 'C$i'},
              ],
            }),
      });
      final page = await source.search(const DiscoverQuery(pageSize: 2));
      expect(page.hasMore, isTrue);
    });

    test("a character download un-crosses Chub's field names", () async {
      await serve({
        '/api/characters/anon/aria': (base) => jsonEncode({
              'node': {
                'id': 7,
                'name': 'Aria',
                'fullPath': 'anon/aria',
                'topics': ['fantasy'],
                'max_res_url': '$base/avatar.png',
                'definition': {
                  'name': 'Aria',
                  // Chub's `personality` is the definition body …
                  'personality': 'A ranger of the northern wood.',
                  // … its `tavern_personality` is the spec's personality …
                  'tavern_personality': 'wry, watchful',
                  // … and its `description` is the creator's notes.
                  'description': 'My first card, be kind.',
                  'scenario': 'The wood at dusk.',
                  'first_message': 'You hear a bowstring draw.',
                  'example_dialogs': '<START>\nAria: Quiet.',
                  'system_prompt': 'Stay in character.',
                  'post_history_instructions': 'Keep replies short.',
                  'alternate_greetings': ['A twig snaps.'],
                  'character_version': '1.1',
                },
              },
            }),
        '/avatar.png': (_) => png,
      });

      final payload = await source.fetch(const DiscoverItem(
        sourceId: 'chub',
        kind: DiscoverKind.character,
        id: 'anon/aria',
        name: 'Aria',
        creator: 'anon',
      ));

      final card = payload.character!;
      expect(card.name, 'Aria');
      expect(card.description, 'A ranger of the northern wood.');
      expect(card.personality, 'wry, watchful');
      expect(card.creatorNotes, 'My first card, be kind.');
      expect(card.scenario, 'The wood at dusk.');
      expect(card.firstMes, 'You hear a bowstring draw.');
      expect(card.mesExample, '<START>\nAria: Quiet.');
      expect(card.systemPrompt, 'Stay in character.');
      expect(card.postHistoryInstructions, 'Keep replies short.');
      expect(card.alternateGreetings, ['A twig snaps.']);
      expect(card.tags, ['fantasy']);
      expect(card.creator, 'anon');
      expect(card.characterVersion, '1.1');
      // The picture travels as bytes, so a downloaded character keeps its face
      // when the CDN or the listing is gone.
      expect(card.avatar, base64Encode(png));
    });

    test('a definition Chub will not hand over says so', () async {
      await serve({
        '/api/characters/anon/aria': (_) => jsonEncode({
              'node': {'name': 'Aria', 'fullPath': 'anon/aria'},
            }),
      });
      await expectLater(
        source.fetch(const DiscoverItem(
          sourceId: 'chub',
          kind: DiscoverKind.character,
          id: 'anon/aria',
          name: 'Aria',
        )),
        throwsA(isA<DiscoverException>().having(
          (e) => e.message,
          'message',
          contains('without a definition'),
        )),
      );
    });

    test('a lorebook download reads SillyTavern world info', () async {
      await serve({
        'sillytavern_raw.json': (_) => jsonEncode({
              'entries': {
                '0': {
                  'uid': 0,
                  'comment': 'Valeport',
                  'content': 'Valeport is the capital.',
                  'key': ['valeport'],
                  'disable': false,
                },
              },
            }),
      });

      final payload = await source.fetch(const DiscoverItem(
        sourceId: 'chub',
        kind: DiscoverKind.lorebook,
        id: 'lorebooks/anon/kingdom',
        name: 'Kingdom',
        tagline: 'Places and people',
        tags: ['fantasy'],
        projectId: 55,
      ));

      final book = payload.lorebook!;
      expect(book.entries, hasLength(1));
      expect(book.entries.single.name, 'Valeport');
      expect(book.entries.single.keys, ['valeport']);
      // Chub's exporter has no room for the real name; the listing does.
      expect(book.name, 'Kingdom');
      expect(book.description, 'Places and people');
      expect(book.tags, ['fantasy']);
      expect(requests.single, contains('/api/v4/projects/55/'));
    });

    test('a lorebook with no project id is looked up first', () async {
      await serve({
        '/api/lorebooks/anon/kingdom': (_) => jsonEncode({
              'node': {'id': 77},
            }),
        'sillytavern_raw.json': (_) => jsonEncode({
              'entries': {
                '0': {'uid': 0, 'content': 'A fact.', 'key': ['fact']},
              },
            }),
      });

      final payload = await source.fetch(const DiscoverItem(
        sourceId: 'chub',
        kind: DiscoverKind.lorebook,
        id: 'anon/kingdom',
        name: 'Kingdom',
      ));
      expect(payload.lorebook!.entries, hasLength(1));
      expect(requests.first, contains('/api/lorebooks/anon/kingdom'));
      expect(requests.last, contains('/api/v4/projects/77/'));
    });

    test('an HTTP failure is reported in words, not a status code', () async {
      await serve(const <String, Object Function(String)>{});
      await expectLater(
        source.search(const DiscoverQuery()),
        throwsA(isA<DiscoverException>().having(
          (e) => e.message,
          'message',
          contains('Not found'),
        )),
      );
    });

    test('tag suggestions degrade to none rather than failing the sheet',
        () async {
      await serve(const <String, Object Function(String)>{});
      expect(await source.tags(DiscoverKind.character), isEmpty);
    });

    test('tag suggestions are normalised and sorted', () async {
      await serve({
        '/tags': (_) => jsonEncode({
              'tags': [
                {'name': 'Fantasy'},
                {'name': 'anime'},
                {'name': 'x'},
                {'name': 'Fantasy'},
              ],
            }),
      });
      expect(await source.tags(DiscoverKind.character), ['anime', 'fantasy']);
    });
  });
}
