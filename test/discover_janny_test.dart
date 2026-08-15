import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/discover.dart';
import 'package:maichat/services/discover/discover_source.dart';
import 'package:maichat/services/discover/janny_source.dart';

/// JannyAI is two halves that fail independently: browsing is a public
/// MeiliSearch index that answers anybody, and downloading is a Cloudflare-
/// guarded API that answers a phone but not a datacentre. These tests pin the
/// query dialect and, importantly, that a refused download says what to do
/// instead of dropping a nameless character into the roster.
void main() {
  group('query building', () {
    final source = JannySource();

    test('a feed query is a MeiliSearch multi-search on one index', () {
      final body = source.searchBody(const DiscoverQuery(
        search: 'maid',
        sort: 'createdAtStamp:desc',
        page: 3,
        pageSize: 24,
      ));
      final query = (body['queries'] as List).single as Map<String, dynamic>;

      expect(source.searchUri.path, '/multi-search');
      expect(query['indexUid'], 'janny-characters');
      expect(query['q'], 'maid');
      expect(query['hitsPerPage'], 24);
      expect(query['page'], 3);
      expect(query['sort'], ['createdAtStamp:desc']);
    });

    test('filters keep out empty cards and, by default, adult ones', () {
      final filters = _filtersOf(source, const DiscoverQuery());
      expect(filters, contains('totalToken >= 29'));
      expect(filters, contains('isNsfw = false'));
      expect(filters, contains('isLowQuality = false'));
    });

    test('allowing adult content drops the filter rather than negating it', () {
      final filters = _filtersOf(source, const DiscoverQuery(nsfw: true));
      expect(filters, isNot(contains('isNsfw = false')));
      expect(filters, contains('isLowQuality = false'));
    });

    test('tags become ids, AND-ed inside one expression', () {
      final filters = _filtersOf(
        source,
        const DiscoverQuery(includeTags: ['Anime', 'smut']),
      );
      // Anime is 9 and Smut is 46; matching is case-insensitive.
      expect(filters, contains('tagIds = 9 AND tagIds = 46'));
    });

    test('a tag the index does not know is left out, not sent as text', () {
      final filters = _filtersOf(
        source,
        const DiscoverQuery(includeTags: ['not-a-janny-tag']),
      );
      expect(filters.any((f) => f.contains('tagIds')), isFalse);
      expect(JannySource.tagIdFor('not-a-janny-tag'), isNull);
      expect(JannySource.tagIdFor('movies/tv'), 61);
    });

    test('relevance omits sort entirely — an empty array is rejected', () {
      final body = source.searchBody(const DiscoverQuery());
      final query = (body['queries'] as List).single as Map<String, dynamic>;
      expect(query.containsKey('sort'), isFalse);
    });

    test('the search key rides in a bearer header with the site as origin', () {
      expect(
        source.searchHeaders['Authorization'],
        'Bearer ${JannySource.kJannySearchToken}',
      );
      expect(source.searchHeaders['Origin'], 'https://jannyai.com');
    });
  });

  group('hit reading', () {
    final source = JannySource(imageBase: 'https://img.example/bot-avatars');

    test('a hit maps onto an item, numeric tags resolved to names', () {
      final item = source.itemFrom(<String, dynamic>{
        'id': '02f2a05e-3058-42d0-abbf-3ac5b16b43c1',
        'name': 'The ditzy poodle',
        'description': '<p>Someone <b>requested</b> this</p>',
        'avatar': 'TVlDkPCd5WQhB42sfkCR2.webp',
        'tagIds': [2, 5, 53, 999],
        'isNsfw': true,
        'totalToken': 1712,
        'creatorUsername': 'someone',
        'createdAtStamp': 1786793853.046,
      })!;

      expect(item.sourceId, 'janny');
      expect(item.id, '02f2a05e-3058-42d0-abbf-3ac5b16b43c1');
      expect(item.name, 'The ditzy poodle');
      // The site's blurb is HTML and is not the definition.
      expect(item.description, 'Someone requested this');
      expect(
        item.thumbnailUrl,
        'https://img.example/bot-avatars/TVlDkPCd5WQhB42sfkCR2.webp',
      );
      // An id JannyAI has retired still renders as something.
      expect(item.tags, ['Female', 'OC', 'Fantasy', 'Tag 999']);
      expect(item.nsfw, isTrue);
      expect(item.tokens, 1712);
      expect(item.creator, 'someone');
      // A unix-seconds stamp is read as a date, not as the year 56000.
      expect(item.createdAt!.year, 2026);
      // The browser link carries the slug JannyAI's own pages use.
      expect(
        item.pageUrl,
        endsWith(
          '/characters/02f2a05e-3058-42d0-abbf-3ac5b16b43c1'
          '_character-the-ditzy-poodle',
        ),
      );
    });

    test('a hit with no creator falls back to the creator id', () {
      final item = source.itemFrom(const <String, dynamic>{
        'id': 'abc',
        'name': 'X',
        'creatorId': 'uuid-1',
      })!;
      expect(item.creator, 'uuid-1');
    });

    test('a hit with no id is dropped', () {
      expect(source.itemFrom(const <String, dynamic>{'name': 'X'}), isNull);
    });
  });

  group('over the wire', () {
    late HttpServer server;
    late JannySource source;
    late String base;
    final bodies = <String>[];

    Future<void> serve(
      Future<void> Function(HttpRequest request, String base) handler,
    ) async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://${server.address.host}:${server.port}';
      source = JannySource(
        searchBase: base,
        downloadBase: base,
        imageBase: '$base/bot-avatars',
        siteBase: base,
      );
      server.listen((request) async {
        bodies.add(await utf8.decodeStream(request));
        await handler(request, base);
      });
    }

    setUp(bodies.clear);
    tearDown(() async {
      source.close();
      await server.close(force: true);
    });

    test('a page of hits becomes items, with paging from totalPages', () async {
      await serve((request, _) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'results': [
            {
              'hits': [
                {'id': 'a', 'name': 'Ann', 'totalToken': 500},
                {'id': 'b', 'name': 'Bo'},
              ],
              'totalPages': 4,
              'totalHits': 90,
            },
          ],
        }));
        await request.response.close();
      });

      final page = await source.search(const DiscoverQuery(page: 2));
      expect(page.items.map((i) => i.name), ['Ann', 'Bo']);
      expect(page.hasMore, isTrue);
      expect(jsonDecode(bodies.single), containsPair('queries', isList));
    });

    test('the last page closes the feed', () async {
      await serve((request, _) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'results': [
            {'hits': [], 'totalPages': 2},
          ],
        }));
        await request.response.close();
      });
      final page = await source.search(const DiscoverQuery(page: 2));
      expect(page.items, isEmpty);
      expect(page.hasMore, isFalse);
    });

    test('a download resolves the card link, then fetches the card', () async {
      final card = jsonEncode({
        'spec': 'chara_card_v2',
        'spec_version': '2.0',
        'data': {
          'name': 'Ann',
          'description': 'A librarian.',
          'first_mes': 'Shh.',
        },
      });
      await serve((request, base) async {
        if (request.uri.path == '/api/v1/download') {
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({'status': 'ok', 'downloadUrl': '$base/card.json'}),
          );
        } else {
          request.response.headers.contentType = ContentType.json;
          request.response.write(card);
        }
        await request.response.close();
      });

      final payload = await source.fetch(const DiscoverItem(
        sourceId: 'janny',
        kind: DiscoverKind.character,
        id: 'uuid-1',
        name: 'Ann',
        creator: 'someone',
        description: 'The site blurb.',
        tags: ['Female'],
        thumbnailUrl: 'https://img.example/a.webp',
      ));

      final character = payload.character!;
      expect(character.name, 'Ann');
      expect(character.description, 'A librarian.');
      expect(character.firstMes, 'Shh.');
      // The card file carries none of these; the listing does.
      expect(character.tags, ['Female']);
      expect(character.creator, 'someone');
      expect(character.creatorNotes, 'The site blurb.');
      expect(character.avatar, 'https://img.example/a.webp');
      // The request asked for the character by id.
      expect(bodies.first, contains('uuid-1'));
    });

    test('a Cloudflare-blocked download explains the way round it', () async {
      await serve((request, _) async {
        request.response.statusCode = 403;
        await request.response.close();
      });

      await expectLater(
        source.fetch(const DiscoverItem(
          sourceId: 'janny',
          kind: DiscoverKind.character,
          id: 'uuid-1',
          name: 'Ann',
        )),
        throwsA(isA<DiscoverException>().having(
          (e) => e.message,
          'message',
          allOf(contains('From file'), contains('browser')),
        )),
      );
    });
  });
}

List<String> _filtersOf(JannySource source, DiscoverQuery query) {
  final body = source.searchBody(query);
  final first = (body['queries'] as List).single as Map<String, dynamic>;
  return (first['filter'] as List).cast<String>();
}
