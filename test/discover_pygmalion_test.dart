import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/discover.dart';
import 'package:maichat/services/discover/discover_source.dart';
import 'package:maichat/services/discover/pygmalion_source.dart';

/// Pygmalion is the only catalogue here that speaks Connect RPC, and the only one
/// whose pages start at zero and whose numbers are all quoted strings. Each of
/// those is a silent wrong-data bug rather than a crash, so each is pinned.
void main() {
  group('request building', () {
    final source = PygmalionSource(apiBase: 'https://pyg.example');

    test('the request travels as a JSON message in the query', () {
      final uri = source.searchUri(const DiscoverQuery(
        search: 'elf ranger',
        sort: 'stars',
        page: 3,
        pageSize: 24,
        includeTags: ['Female', 'Elf'],
        excludeTags: ['Gore'],
      ));
      expect(uri.path, '/galatea.v1.PublicCharacterService/CharacterSearch');
      expect(uri.queryParameters['connect'], 'v1');
      expect(uri.queryParameters['encoding'], 'json');

      final message =
          jsonDecode(uri.queryParameters['message']!) as Map<String, dynamic>;
      expect(message['query'], 'elf ranger');
      expect(message['orderBy'], 'stars');
      expect(message['orderDescending'], isTrue);
      expect(message['pageSize'], 24);
      // Pages are 0-indexed here and 1-indexed everywhere else in the app.
      expect(message['page'], 2);
      expect(message['tagsNamesInclude'], ['Female', 'Elf']);
      expect(message['tagsNamesExclude'], ['Gore']);
    });

    test('an unset sort falls back to downloads, and page 1 is page 0', () {
      final message = jsonDecode(
        source.searchUri(const DiscoverQuery()).queryParameters['message']!,
      ) as Map<String, dynamic>;
      expect(message['orderBy'], 'downloads');
      expect(message['page'], 0);
      expect(message.containsKey('tagsNamesInclude'), isFalse);
    });
  });

  group('reading a hit', () {
    final source = PygmalionSource(siteBase: 'https://pyg.site');

    test('quoted numbers and second-based dates are read as what they are', () {
      final item = source.itemFrom(<String, dynamic>{
        'id': '6b67ca81-f58e-4a16-bf29-5f36313f29b7',
        'displayName': 'World RPG',
        'avatarUrl': 'https://assets.example/abc',
        'description': 'An RPG where you can do anything you want!',
        'stars': '555',
        'views': '91898',
        'downloads': '2284',
        'createdAt': '1712088600',
        'updatedAt': '1722520534',
        'owner': {'id': 'x', 'displayName': 'Wren'},
        'chatCount': '16534',
        'personalityTokenCount': '52',
      })!;

      expect(item.id, '6b67ca81-f58e-4a16-bf29-5f36313f29b7');
      expect(item.name, 'World RPG');
      expect(item.creator, 'Wren');
      expect(item.tagline, 'An RPG where you can do anything you want!');
      expect(item.favourites, 555);
      expect(item.downloads, 2284);
      expect(item.tokens, 52);
      // Read as an ISO string this would be null; these are unix seconds in
      // quotes.
      expect(item.createdAt?.year, 2024);
      expect(item.updatedAt?.year, 2024);
      expect(item.pageUrl,
          'https://pyg.site/character/6b67ca81-f58e-4a16-bf29-5f36313f29b7');
    });

    test('a hit with no id is skipped', () {
      expect(source.itemFrom(<String, dynamic>{'displayName': 'x'}), isNull);
    });
  });

  group('against a server', () {
    late HttpServer server;
    late String base;
    late PygmalionSource source;
    late Map<String, Object> routes;
    final requests = <String>[];

    setUp(() async {
      requests.clear();
      routes = <String, Object>{};
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://${server.address.host}:${server.port}';
      source = PygmalionSource(apiBase: base, siteBase: base);
      server.listen((request) async {
        requests.add('${request.uri}');
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

    String feed({String total = '100'}) => jsonEncode({
          'totalItems': total,
          'characters': [
            {
              'id': 'one',
              'displayName': 'One',
              'downloads': '5',
              'owner': {'displayName': 'a'},
            },
          ],
        });

    test('a quoted total decides whether there is more', () async {
      routes['CharacterSearch'] = feed();
      final page = await source.search(const DiscoverQuery(pageSize: 1));
      expect(page.items.single.name, 'One');
      expect(page.hasMore, isTrue);

      routes['CharacterSearch'] = feed(total: '1');
      final last = await source.search(const DiscoverQuery(pageSize: 1));
      expect(last.hasMore, isFalse);
    });

    test('a download unwraps the export envelope and keeps the lorebook',
        () async {
      routes['CharacterSearch'] = feed();
      routes['/api/export/character/one/v2'] = jsonEncode({
        'character': {
          'spec': 'chara_card_v2',
          'spec_version': '2.0',
          'data': {
            'name': 'One',
            'description': 'body',
            'avatar': '$base/avatar.png',
            'character_book': {
              'name': '',
              'entries': [
                {'keys': ['garona'], 'content': 'a continent', 'enabled': true},
              ],
            },
          },
        },
      });
      routes['/avatar.png'] = <int>[137, 80, 78, 71, 13, 10, 26, 10, 5];

      final page = await source.search(const DiscoverQuery(pageSize: 1));
      final payload = await source.fetch(page.items.single);

      expect(payload.character?.name, 'One');
      expect(payload.character?.description, 'body');
      // The export names its avatar as a URL; the bytes are fetched so the card
      // survives the CDN.
      expect(payload.character?.avatarIsUrl, isFalse);
      expect(payload.hasBoth, isTrue);
      expect(payload.lorebook?.entries.single.content, 'a continent');
      // A card's book is nameless; the codec names it after the character.
      expect(payload.lorebook?.name, contains('One'));
    });

    test('something that is not a card fails with a sentence', () async {
      routes['CharacterSearch'] = feed();
      routes['/api/export/'] = jsonEncode({'character': 42});
      final page = await source.search(const DiscoverQuery(pageSize: 1));
      await expectLater(
        source.fetch(page.items.single),
        throwsA(isA<DiscoverException>()),
      );
    });
  });
}
