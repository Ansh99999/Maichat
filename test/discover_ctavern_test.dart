import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/discover.dart';
import 'package:maichat/services/discover/character_tavern_source.dart';
import 'package:maichat/services/discover/discover_source.dart';

/// Builds a minimal PNG carrying [charaText] under the `chara` keyword, the way
/// Character Tavern's storage host serves a card. CRCs are left zero — the
/// reader skips them.
Uint8List _pngWithChara(String charaText) {
  final out = BytesBuilder();
  out.add(const [137, 80, 78, 71, 13, 10, 26, 10]);
  void chunk(String type, List<int> data) {
    final len = ByteData(4)..setUint32(0, data.length);
    out.add(len.buffer.asUint8List());
    out.add(ascii.encode(type));
    out.add(data);
    out.add(const [0, 0, 0, 0]);
  }

  chunk('tEXt', [...ascii.encode('chara'), 0, ...ascii.encode(charaText)]);
  chunk('IEND', const []);
  return out.toBytes();
}

String _card(String name) => base64Encode(utf8.encode(jsonEncode({
      'spec': 'chara_card_v2',
      'spec_version': '2.0',
      'data': {
        'name': name,
        'description': 'A definition that only the card carries.',
        'first_mes': 'Hello.',
        'creator': 'rickrocka',
      },
    })));

/// Character Tavern is the easiest catalogue to talk to and the easiest to get
/// subtly wrong: its search index carries the definition (so the fields look
/// like a card but are not one), and the difference between a picture and a card
/// is a single query parameter.
void main() {
  group('request building', () {
    final source = CharacterTavernSource(apiBase: 'https://ct.example');

    test('a feed sends the parameters the site puts in its own URL', () {
      final uri = source.searchUri(const DiscoverQuery(
        search: 'elf ranger',
        sort: 'newest',
        page: 2,
        includeTags: ['fantasy', 'female'],
        excludeTags: ['gore'],
        pageSize: 24,
      ));
      final q = uri.queryParameters;

      expect(uri.host, 'ct.example');
      expect(uri.path, '/api/search/cards');
      expect(q['query'], 'elf ranger');
      expect(q['sort'], 'newest');
      expect(q['page'], '2');
      expect(q['limit'], '24');
      expect(q['tags'], 'fantasy,female');
      // The adult tag joins the exclusions unless adult results were asked for.
      expect(q['exclude_tags'], 'gore,nsfw');
    });

    test('an empty search and sort are absent, not empty', () {
      final q = source.searchUri(const DiscoverQuery()).queryParameters;
      expect(q.containsKey('query'), isFalse);
      expect(q.containsKey('sort'), isFalse);
      expect(q.containsKey('tags'), isFalse);
    });

    test('with adult results off, nsfw is excluded server-side', () {
      // The site has no adult parameter; excluding the tag is how it does it,
      // and doing it server-side is what keeps a page full.
      final off = source.searchUri(const DiscoverQuery()).queryParameters;
      expect(off['exclude_tags'], 'nsfw');

      final on = source.searchUri(const DiscoverQuery(nsfw: true)).queryParameters;
      expect(on.containsKey('exclude_tags'), isFalse);

      final both = source
          .searchUri(const DiscoverQuery(excludeTags: ['gore']))
          .queryParameters;
      expect(both['exclude_tags'], 'gore,nsfw');

      final already = source
          .searchUri(const DiscoverQuery(excludeTags: ['nsfw']))
          .queryParameters;
      expect(already['exclude_tags'], 'nsfw');
    });

    test('the card URL is the image URL plus action=download', () {
      // The whole download hangs off this parameter: without it the same path
      // returns artwork with no metadata in it.
      expect(
        source.imageUri('rickrocka/world_rp').toString(),
        'https://ct-cards.storage.character-tavern.com/rickrocka/world_rp.png',
      );
      expect(
        source.cardUri('rickrocka/world_rp').toString(),
        'https://ct-cards.storage.character-tavern.com/rickrocka/world_rp.png'
        '?action=download',
      );
    });
  });

  group('reading a hit', () {
    final source = CharacterTavernSource(apiBase: 'https://ct.example');

    test('maps the fields a card shows, keyed by path not id', () {
      final item = source.itemFrom(<String, dynamic>{
        'id': 'CT_70f78dfbfd8452c0755d5940e6fbb195',
        'name': 'World RP',
        'inChatName': 'World RP',
        'path': 'rickrocka/world_rp',
        'author': 'rickrocka',
        'tagline': 'World rp, need say more?',
        'pageDescription': '<b>Warning</b><br />read this',
        'tags': ['action', 'adventure'],
        'isNSFW': false,
        'hasLorebook': true,
        'totalTokens': 693,
        'downloads': 6684,
        'likes': 146,
        'createdAt': 1744345948,
        'lastUpdateAt': 1783703809,
      })!;

      // The path addresses both the card and the page; the `CT_…` id addresses
      // nothing we can fetch.
      expect(item.id, 'rickrocka/world_rp');
      expect(item.name, 'World RP');
      expect(item.creator, 'rickrocka');
      expect(item.tagline, 'World rp, need say more?');
      expect(item.description, 'Warning\nread this');
      expect(item.tags, ['action', 'adventure']);
      expect(item.tokens, 693);
      expect(item.downloads, 6684);
      expect(item.favourites, 146);
      expect(item.hasLore, isTrue);
      expect(item.nsfw, isFalse);
      expect(item.pageUrl, 'https://ct.example/character/rickrocka/world_rp');
      expect(item.createdAt?.year, 2025);
      expect(item.thumbnailUrl, contains('rickrocka/world_rp.png'));
      // A listing thumbnail must not be the card download.
      expect(item.thumbnailUrl, isNot(contains('action=download')));
    });

    test('a hit with no path is skipped rather than shown undownloadable', () {
      expect(source.itemFrom(<String, dynamic>{'name': 'Orphan'}), isNull);
    });
  });

  group('against a server', () {
    late HttpServer server;
    late String base;
    late CharacterTavernSource source;
    final requests = <String>[];
    late Map<String, Object> routes;

    setUp(() async {
      requests.clear();
      routes = <String, Object>{};
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://${server.address.host}:${server.port}';
      source = CharacterTavernSource(apiBase: base, cardBase: '$base/cards');
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

    String feed({bool nsfw = false, int totalPages = 3}) => jsonEncode({
          'totalHits': 60,
          'hitsPerPage': 2,
          'page': 1,
          'totalPages': totalPages,
          'query': '',
          'hits': [
            {
              'id': 'CT_1',
              'name': 'Clean',
              'path': 'a/clean',
              'author': 'a',
              'tags': ['fantasy'],
              'isNSFW': false,
            },
            {
              'id': 'CT_2',
              'name': 'Adult',
              'path': 'b/adult',
              'author': 'b',
              'tags': ['nsfw'],
              'isNSFW': nsfw,
            },
          ],
        });

    test('a page reports more while pages remain', () async {
      routes['/api/search/cards'] = feed();
      final page = await source.search(const DiscoverQuery());
      expect(page.items.map((i) => i.name), ['Clean', 'Adult']);
      expect(page.hasMore, isTrue);
    });

    test('the last page reports no more', () async {
      routes['/api/search/cards'] = feed(totalPages: 1);
      final page = await source.search(const DiscoverQuery());
      expect(page.hasMore, isFalse);
    });

    test('adult hits are dropped when adult results were not asked for',
        () async {
      // The API has no nsfw parameter at all, so this filter is ours to apply.
      routes['/api/search/cards'] = feed(nsfw: true);
      final off = await source.search(const DiscoverQuery());
      expect(off.items.map((i) => i.name), ['Clean']);

      final on = await source.search(const DiscoverQuery(nsfw: true));
      expect(on.items.map((i) => i.name), ['Clean', 'Adult']);
    });

    test('a download reads the card out of the PNG behind action=download',
        () async {
      routes['/api/search/cards'] = feed();
      routes['action=download'] = _pngWithChara(_card('World RP'));
      final page = await source.search(const DiscoverQuery());
      final payload = await source.fetch(page.items.first);

      expect(payload.character?.name, 'World RP');
      expect(
        payload.character?.description,
        'A definition that only the card carries.',
      );
      expect(
        requests.where((r) => r.contains('action=download')).length,
        1,
      );
    });

    test('a picture with no card in it fails with a sentence, not a crash',
        () async {
      routes['/api/search/cards'] = feed();
      // The plain image URL answers with a PNG that has no tEXt chunk: exactly
      // what fetching without action=download would get.
      routes['/cards/'] = <int>[137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 0];
      final page = await source.search(const DiscoverQuery());
      await expectLater(
        source.fetch(page.items.first),
        throwsA(isA<DiscoverException>()),
      );
    });

    test('the listing fills in what the card left blank', () async {
      routes['/api/search/cards'] = feed();
      routes['action=download'] = _pngWithChara(base64Encode(utf8.encode(
        jsonEncode({
          'spec': 'chara_card_v2',
          'spec_version': '2.0',
          'data': {'name': '', 'description': 'body'},
        }),
      )));
      final page = await source.search(const DiscoverQuery());
      final character = (await source.fetch(page.items.first)).character!;
      expect(character.name, 'Clean');
      expect(character.creator, 'a');
      expect(character.tags, ['fantasy']);
    });

    test('a card that ships a lorebook brings it along', () async {
      // These downloads are v3 cards with `character_book` inside. Filing the
      // character and dropping the book was the bug this pins.
      routes['/api/search/cards'] = feed();
      routes['action=download'] = _pngWithChara(base64Encode(utf8.encode(
        jsonEncode({
          'spec': 'chara_card_v3',
          'spec_version': '3.0',
          'data': {
            'name': 'Clean',
            'description': 'body',
            'character_book': {
              'name': '',
              'entries': [
                {'keys': ['garona'], 'content': 'a continent', 'enabled': true},
                {'keys': ['elves'], 'content': 'tall folk', 'enabled': true},
              ],
            },
          },
        }),
      )));
      final page = await source.search(const DiscoverQuery());
      final payload = await source.fetch(page.items.first);

      expect(payload.hasBoth, isTrue);
      expect(payload.lorebook?.entries.length, 2);
      expect(payload.lorebook?.entries.first.content, 'a continent');
      expect(payload.lorebook?.name, contains('Clean'));
    });

    test('a card with no lorebook produces no empty book', () async {
      routes['/api/search/cards'] = feed();
      routes['action=download'] = _pngWithChara(_card('Clean'));
      final page = await source.search(const DiscoverQuery());
      final payload = await source.fetch(page.items.first);
      expect(payload.character, isNotNull);
      expect(payload.lorebook, isNull);
      expect(payload.hasBoth, isFalse);
    });
  });
}
