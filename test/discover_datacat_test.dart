import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/discover.dart';
import 'package:maichat/services/discover/datacat_source.dart';
import 'package:maichat/services/discover/discover_source.dart';

/// DataCat is the only source that has to knock before it can read: every call
/// carries a session token minted by a handshake. These pin the handshake, the
/// retry when a token lapses, the offset bookkeeping that client-side filtering
/// forces, and the fact that its listing flags everything adult.
void main() {
  group('the session handshake', () {
    late HttpServer server;
    late String base;
    late DataCatSource source;
    final requests = <String>[];
    var identifyCalls = 0;
    var tokenToAccept = 'good-token';

    setUp(() async {
      requests.clear();
      identifyCalls = 0;
      tokenToAccept = 'good-token';
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://${server.address.host}:${server.port}';
      source = DataCatSource(siteBase: base, random: Random(1));
      server.listen((request) async {
        final path = '${request.uri}';
        requests.add(path);
        if (path.contains('/api/liberator/identify')) {
          identifyCalls++;
          request.response.headers.contentType = ContentType.json;
          request.response
              .write(jsonEncode({'success': true, 'sessionToken': tokenToAccept}));
          await request.response.close();
          return;
        }
        // Everything else is gated on the token, exactly as the site is.
        final token = request.headers.value('X-Session-Token');
        if (token != tokenToAccept) {
          request.response.statusCode = 401;
          request.response.write('{"error":"Authentication required"}');
          await request.response.close();
          return;
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'totalCount': 200001,
          'hasMore': true,
          'characters': [
            {
              'characterId': 'one',
              'name': 'One',
              'isNsfw': true,
              'avatarDisplayUrl': '$base/pic.png',
            },
          ],
        }));
        await request.response.close();
      });
    });

    tearDown(() async {
      source.close();
      await server.close(force: true);
    });

    test('a session is opened once and reused', () async {
      await source.search(const DiscoverQuery(nsfw: true, pageSize: 1));
      await source.search(const DiscoverQuery(nsfw: true, pageSize: 1, page: 2));
      expect(identifyCalls, 1);
      expect(
        requests.where((r) => r.contains('recent-public')).length,
        greaterThanOrEqualTo(2),
      );
    });

    test('a device token is a uuid-shaped string, fresh per source', () {
      final token = source.newDeviceToken();
      expect(token, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-'
          r'[0-9a-f]{4}-[0-9a-f]{12}$')));
      expect(source.newDeviceToken(), isNot(token));
    });

    test('a lapsed token is replaced and the request retried', () async {
      await source.search(const DiscoverQuery(nsfw: true, pageSize: 1));
      expect(identifyCalls, 1);

      // The site rotates its token; the old one now reads as unauthenticated.
      tokenToAccept = 'new-token';
      final page = await source.search(const DiscoverQuery(nsfw: true, pageSize: 1));
      expect(identifyCalls, 2);
      expect(page.items.single.name, 'One');
    });

    test('Retry forgets the session so the next call starts clean', () async {
      await source.search(const DiscoverQuery(nsfw: true, pageSize: 1));
      source.resetTransport();
      await source.search(const DiscoverQuery(nsfw: true, pageSize: 1));
      expect(identifyCalls, 2);
    });
  });

  group('request building', () {
    final source = DataCatSource(siteBase: 'https://dc.example');

    test('the listing carries the site\'s own token floor and a summary flag',
        () {
      final q = source
          .searchUri(const DiscoverQuery(pageSize: 24), offset: 48)
          .queryParameters;
      expect(q['limit'], '24');
      expect(q['offset'], '48');
      expect(q['summary'], '1');
      expect(q['minTotalTokens'], '${DataCatSource.minTotalTokens}');
      expect(q.containsKey('sortBy'), isFalse);
    });

    test('tag ids go as ids, and an unset sort is absent', () {
      final q = source
          .searchUri(const DiscoverQuery(sort: 'score'),
              offset: 0, tagIds: [2, 9])
          .queryParameters;
      expect(q['tagIds'], '2,9');
      expect(q['sortBy'], 'score');
    });
  });

  group('reading a record', () {
    final source = DataCatSource(siteBase: 'https://dc.example');

    test('reads the camelCase spelling beside the snake_case one', () {
      final item = source.itemFrom(<String, dynamic>{
        'characterId': 'b455c4db',
        'name': 'Racing Roxanne Wolf',
        'chatName': 'Roxy',
        'creatorName': 'Epicsauce',
        'description': 'A racer.',
        'isNsfw': true,
        'totalTokens': 704,
        'avatarDisplayUrl': 'https://media.example/a.png',
        'tags': [
          {'id': 2, 'name': '👩‍🦰 Female', 'slug': 'female'},
        ],
        'stats': {
          'chat': 174,
          'favoritesCount': {'favoritesCount': 71},
        },
        'sourcePostedAt': '2026-08-15T03:57:32.984171',
      })!;

      expect(item.id, 'b455c4db');
      expect(item.name, 'Racing Roxanne Wolf');
      expect(item.creator, 'Epicsauce');
      expect(item.nsfw, isTrue);
      expect(item.tokens, 704);
      // The slug is the typeable form; the name carries an emoji.
      expect(item.tags, ['female']);
      expect(item.favourites, 71);
      expect(item.createdAt?.year, 2026);
      expect(item.pageUrl, 'https://dc.example/characters/b455c4db');
    });

    test('a record with no id is skipped', () {
      expect(source.itemFrom(<String, dynamic>{'name': 'x'}), isNull);
    });
  });

  group('against a server', () {
    late HttpServer server;
    late String base;
    late DataCatSource source;
    late Map<String, Object> routes;
    final requests = <String>[];

    setUp(() async {
      requests.clear();
      routes = <String, Object>{};
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://${server.address.host}:${server.port}';
      source = DataCatSource(siteBase: base, random: Random(2));
      server.listen((request) async {
        final path = '${request.uri}';
        requests.add(path);
        if (path.contains('identify')) {
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'sessionToken': 't'}));
          await request.response.close();
          return;
        }
        Object? body;
        for (final entry in routes.entries) {
          if (path.contains(entry.key)) {
            body = entry.value;
            break;
          }
        }
        if (body == null) {
          request.response.statusCode = 404;
          await request.response.close();
          return;
        }
        if (body is List<int>) {
          request.response.headers.contentType = ContentType('image', 'png');
          request.response.add(body);
        } else {
          request.response.headers.contentType = ContentType.json;
          request.response.write(body);
        }
        await request.response.close();
      });
    });

    tearDown(() async {
      source.close();
      await server.close(force: true);
    });

    test('with adult results off it explains itself instead of showing nothing',
        () async {
      await expectLater(
        source.search(const DiscoverQuery()),
        throwsA(isA<DiscoverException>().having(
          (e) => e.message,
          'message',
          contains('adult'),
        )),
      );
      // Nothing was even asked of the site.
      expect(requests.where((r) => r.contains('recent-public')), isEmpty);
    });

    test('the download takes the archived V2 card and its lorebook', () async {
      routes['recent-public'] = jsonEncode({
        'hasMore': false,
        'characters': [
          {'characterId': 'one', 'name': 'One', 'isNsfw': true},
        ],
      });
      routes['/api/characters/one'] = jsonEncode({
        'success': true,
        'character': {
          'character_id': 'one',
          'name': 'One',
          'chara_card_v2_json': {
            'spec': 'chara_card_v2',
            'spec_version': '2.0',
            'data': {
              'name': 'One',
              'description': 'archived body',
              'character_book': {
                'entries': [
                  {'keys': ['k'], 'content': 'lore', 'enabled': true},
                ],
              },
            },
          },
        },
      });

      final page = await source.search(const DiscoverQuery(nsfw: true, pageSize: 1));
      final payload = await source.fetch(page.items.single);
      expect(payload.character?.description, 'archived body');
      expect(payload.hasBoth, isTrue);
      expect(payload.lorebook?.entries.single.content, 'lore');
      // The Turnstile-gated download endpoint is never touched.
      expect(requests.where((r) => r.contains('/download')), isEmpty);
    });

    test('a record with no finished card is assembled from its own fields',
        () async {
      routes['recent-public'] = jsonEncode({
        'hasMore': false,
        'characters': [
          {'characterId': 'two', 'name': 'Two', 'isNsfw': true},
        ],
      });
      routes['/api/characters/two'] = jsonEncode({
        'character': {
          'character_id': 'two',
          'name': 'Two',
          'description': 'from fields',
          'extracted_first_message': 'Recovered hello.',
          'creator_name': 'someone',
        },
      });
      final page = await source.search(const DiscoverQuery(nsfw: true, pageSize: 1));
      final payload = await source.fetch(page.items.single);
      expect(payload.character?.description, 'from fields');
      expect(payload.character?.firstMes, 'Recovered hello.');
      expect(payload.character?.creator, 'someone');
    });

    test('only the busiest tags are offered as suggestions', () async {
      routes['/api/tags/faceted'] = jsonEncode({
        'tags': [
          for (var i = 0; i < DataCatSource.tagSuggestionLimit + 50; i++)
            {'id': i, 'slug': 'tag$i', 'name': 'Tag $i', 'count': i},
        ],
      });
      final tags = await source.tags(DiscoverKind.character);
      expect(tags.length, DataCatSource.tagSuggestionLimit);
      // Sorted by use, so the busiest tag leads.
      expect(tags.first, 'tag${DataCatSource.tagSuggestionLimit + 49}');
    });

    test('a tag name is resolved to the id the filter wants', () async {
      routes['/api/tags/faceted'] = jsonEncode({
        'tags': [
          {'id': 2, 'slug': 'female', 'name': '👩‍🦰 Female', 'count': 10},
        ],
      });
      routes['recent-public'] = jsonEncode({
        'hasMore': false,
        'characters': [
          {'characterId': 'one', 'name': 'One', 'isNsfw': true},
        ],
      });
      await source.search(
        const DiscoverQuery(nsfw: true, includeTags: ['female'], pageSize: 1),
      );
      expect(
        requests.any((r) => r.contains('tagIds=2')),
        isTrue,
        reason: 'the numeric id, not the name',
      );
    });

    test('a tag it has never heard of falls into the text search', () async {
      routes['/api/tags/faceted'] = jsonEncode({'tags': const <Object>[]});
      routes['recent-public'] = jsonEncode({
        'hasMore': false,
        'characters': const <Object>[],
      });
      await source.search(
        const DiscoverQuery(nsfw: true, includeTags: ['nonesuch'], pageSize: 1),
      );
      expect(requests.any((r) => r.contains('search=nonesuch')), isTrue);
    });
  });
}
