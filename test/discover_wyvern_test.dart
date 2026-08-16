import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/discover.dart';
import 'package:maichat/services/discover/discover_source.dart';
import 'package:maichat/services/discover/wyvern_source.dart';

/// Wyvern's traps are all about which request it will honour and where its
/// lorebook actually lives: searching and sorting are exclusive, adult content
/// rides on one particular order, and a book keeps its entries under `lexicon`
/// while its `entries` array sits there empty.
void main() {
  group('request building', () {
    final source = WyvernSource(apiBase: 'https://wyv.example');

    test('a plain feed sends sort, order and the rating filter', () {
      final q = source
          .searchUri(const DiscoverQuery(sort: 'votes', page: 2, pageSize: 48))
          .queryParameters;
      expect(q['limit'], '48');
      expect(q['page'], '2');
      expect(q['sort'], 'votes');
      expect(q['order'], 'DESC');
      expect(q['rating'], 'none');
    });

    test('a search drops the sort, so results come from the whole catalogue',
        () {
      final q = source
          .searchUri(const DiscoverQuery(search: 'elf', sort: 'votes'))
          .queryParameters;
      expect(q['q'], 'elf');
      expect(q.containsKey('sort'), isFalse);
      expect(q.containsKey('order'), isFalse);
    });

    test('adult results need the adult order, not just the switch', () {
      // The rating filter is what hides explicit cards from a client with no
      // account, and only `nsfw-popular` serves them anyway.
      final onlySwitch = source
          .searchUri(const DiscoverQuery(nsfw: true, sort: 'popular'))
          .queryParameters;
      expect(onlySwitch['rating'], 'none');

      final both = source
          .searchUri(const DiscoverQuery(nsfw: true, sort: WyvernSource.adultSort))
          .queryParameters;
      expect(both.containsKey('rating'), isFalse);
      expect(both['sort'], WyvernSource.adultSort);

      final orderWithoutSwitch = source
          .searchUri(const DiscoverQuery(sort: WyvernSource.adultSort))
          .queryParameters;
      expect(orderWithoutSwitch['rating'], 'none');
    });

    test('include tags are comma-joined', () {
      final q = source
          .searchUri(const DiscoverQuery(includeTags: ['Female', 'Elf']))
          .queryParameters;
      expect(q['tags'], 'Female,Elf');
    });
  });

  group('reading a hit', () {
    final source = WyvernSource(siteBase: 'https://wyv.site');

    test('maps a hit, reading the rating as the adult flag', () {
      final item = source.itemFrom(<String, dynamic>{
        'id': '_7cALcfq1Wb39gR7E2Gf83',
        'name': 'Cruel Villainess',
        'tagline': 'An evil villainess beyond redemption.',
        'description': 'Name: Gwendolyn',
        'tags': ['Female', 'Royalty'],
        'avatar': 'https://imagedelivery.example/abc',
        'creator': {'displayName': 'Ookami_Telos'},
        'rating': 'none',
        'token_count': 1580,
        'likes': 12,
        'created_at': '2026-07-31T03:08:29.889Z',
        'lorebooks': [
          {'id': 'book'}
        ],
      })!;

      expect(item.id, '_7cALcfq1Wb39gR7E2Gf83');
      expect(item.creator, 'Ookami_Telos');
      expect(item.tagline, 'An evil villainess beyond redemption.');
      expect(item.tokens, 1580);
      expect(item.favourites, 12);
      expect(item.nsfw, isFalse);
      expect(item.hasLore, isTrue);
      expect(item.createdAt?.year, 2026);
      expect(item.pageUrl, 'https://wyv.site/characters/_7cALcfq1Wb39gR7E2Gf83');
    });

    test('any rating but none is adult', () {
      final item = source.itemFrom(<String, dynamic>{
        'id': 'x',
        'name': 'Adult',
        'rating': 'explicit',
      })!;
      expect(item.nsfw, isTrue);
    });

    test('a bare image id gets the delivery host and a variant', () {
      expect(
        source.avatarUrl(<String, dynamic>{'avatar': 'abc123'}),
        'https://imagedelivery.net/Dv4koOwHQU3XnXLqtl0aVQ/abc123/public',
      );
      expect(source.avatarUrl(<String, dynamic>{}), isNull);
    });
  });

  group('building a card', () {
    final source = WyvernSource();

    test('shared_info joins the description and pre-history is the system prompt',
        () {
      final card = source.cardFrom(<String, dynamic>{
        'name': 'Gwen',
        'description': 'A villainess.',
        'shared_info': 'Extra context.',
        'pre_history_instructions': 'Stay in character.',
        'personality': 'cruel',
      });
      final data = card['data'] as Map<String, dynamic>;
      expect(data['description'], 'A villainess.\n\n---\n\nExtra context.');
      expect(data['system_prompt'], 'Stay in character.');
      expect(data['personality'], 'cruel');
    });

    test('a book keeps its entries even though they live under lexicon', () {
      final book = WyvernSource.firstLorebook(<Object?>[
        <String, dynamic>{
          'name': 'Vyrexia',
          'entries': const <Object>[],
          'lexicon': [
            {'keys': ['garona'], 'content': 'a continent'},
          ],
        },
      ])!;
      expect((book['entries'] as List).length, 1);
      expect(book.containsKey('lexicon'), isFalse);
    });

    test('an entries object keyed by id is a list too', () {
      final book = WyvernSource.firstLorebook(<Object?>[
        <String, dynamic>{
          'entries': {
            'a': {'keys': ['x'], 'content': 'one'},
          },
        },
      ])!;
      expect((book['entries'] as List).length, 1);
    });

    test('a book with nothing in it is no book', () {
      expect(
        WyvernSource.firstLorebook(<Object?>[
          <String, dynamic>{'entries': const <Object>[], 'lexicon': const <Object>[]},
        ]),
        isNull,
      );
      expect(WyvernSource.firstLorebook(null), isNull);
    });
  });

  group('against a server', () {
    late HttpServer server;
    late String base;
    late WyvernSource source;
    late Map<String, Object> routes;

    setUp(() async {
      routes = <String, Object>{};
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://${server.address.host}:${server.port}';
      source = WyvernSource(apiBase: base, siteBase: base, imageBase: base);
      server.listen((request) async {
        Object? body;
        for (final entry in routes.entries) {
          if ('${request.uri}'.contains(entry.key)) {
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

    test('hasMore comes from the site rather than the page size', () async {
      routes['exploreSearch'] = jsonEncode({
        'results': [
          {'id': 'one', 'name': 'One'},
        ],
        'hasMore': true,
        'totalPages': 9,
      });
      final page = await source.search(const DiscoverQuery(pageSize: 48));
      expect(page.items.single.name, 'One');
      expect(page.hasMore, isTrue);
    });

    test('a download reads the detail record and files its lorebook', () async {
      routes['exploreSearch'] = jsonEncode({
        'results': [
          {'id': 'one', 'name': 'One', 'avatar': '$base/pic.png'},
        ],
        'hasMore': false,
      });
      routes['/characters/one'] = jsonEncode({
        'id': 'one',
        'name': 'One',
        'description': 'body',
        'first_mes': 'Hi.',
        'creator': {'username': 'someone'},
        'lorebooks': [
          {
            'name': 'One',
            'entries': const <Object>[],
            'lexicon': [
              {'keys': ['garona'], 'content': 'a continent', 'enabled': true},
            ],
          },
        ],
      });
      routes['/pic.png'] = <int>[137, 80, 78, 71, 13, 10, 26, 10, 7];

      final page = await source.search(const DiscoverQuery(pageSize: 48));
      final payload = await source.fetch(page.items.single);

      expect(payload.character?.name, 'One');
      expect(payload.character?.description, 'body');
      expect(payload.character?.creator, 'someone');
      expect(payload.character?.avatarIsUrl, isFalse);
      expect(payload.hasBoth, isTrue);
      expect(payload.lorebook?.entries.single.content, 'a continent');
    });

    test('a detail response that is not a character fails with a sentence',
        () async {
      routes['exploreSearch'] = jsonEncode({
        'results': [
          {'id': 'one', 'name': 'One'},
        ],
      });
      routes['/characters/one'] = jsonEncode([1, 2, 3]);
      final page = await source.search(const DiscoverQuery());
      await expectLater(
        source.fetch(page.items.single),
        throwsA(isA<DiscoverException>()),
      );
    });
  });
}
