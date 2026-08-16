import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/discover.dart';
import 'package:maichat/services/discover/discover_source.dart';
import 'package:maichat/services/discover/risu_realm_source.dart';
import 'package:maichat/services/discover/sveltekit_data.dart';

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

String _cardJson(String name) => jsonEncode({
      'spec': 'chara_card_v3',
      'spec_version': '3.0',
      'data': {'name': name, 'description': 'from json-v3', 'first_mes': 'Hi.'},
    });

/// The listing payload Realm serves, in SvelteKit's flattened form: index 0 is
/// the root and **every integer is a pointer**, which is the whole reason this
/// needs a decoder rather than a cast.
const List<Object?> _flat = <Object?>[
  {
    'cards': 1,
    'page': 2,
    'sort': 3,
    'nsfwOption': 4,
    'nsfw': 4,
    'mode': 5,
    'search': 19,
  },
  [6],
  1,
  'downloads',
  false,
  'character',
  {
    'name': 7,
    'desc': 8,
    'download': 9,
    'id': 10,
    'img': 11,
    'tags': 12,
    'haslore': 13,
    'hasAsset': 4,
    'authorname': 14,
    'creator': 15,
    'license': 16,
    'date': 17,
    'type': 18,
  },
  'Kuzi 1.1',
  'A wandering swordsman',
  '2.5k',
  '1de09fd1-4e61-4d68-bd75-4e7649cf10f1',
  'f50df5d43c2c21463d7cf45b2144545649de8e06',
  [20, 21],
  true,
  'fkdlwm7',
  'b581d175d8e7db84c2',
  'CC BY-NC-SA 4.0',
  29779873,
  'normal',
  '',
  'anime',
  'fantasy',
];

String _listing() => jsonEncode({
      'type': 'data',
      'nodes': [
        null,
        {'type': 'data', 'data': _flat, 'uses': {}},
      ],
    });

/// RisuRealm's feed is the site's own page data and its download is the one
/// endpoint RisuAI documents. Both have a trap: the page data is pointers, not
/// values, and a card's allowed download format depends on the card.
void main() {
  group('SvelteKit page data', () {
    test('resolves pointers, including a string shared by two fields', () {
      final data = SvelteKitData.decodeNode(<Object?>[
        {'a': 1, 'b': 1},
        'shared',
      ]) as Map<String, dynamic>;
      expect(data['a'], 'shared');
      expect(data['b'], 'shared');
    });

    test('negative indexes are constants, not positions', () {
      final data = SvelteKitData.decodeNode(<Object?>[
        {'missing': -1, 'hole': -2, 'nan': -3, 'inf': -4},
        'unused',
      ]) as Map<String, dynamic>;
      expect(data['missing'], isNull);
      expect(data['hole'], isNull);
      expect((data['nan'] as double).isNaN, isTrue);
      expect(data['inf'], double.infinity);
    });

    test('a list whose head is a string is a tagged value, not an array', () {
      final data = SvelteKitData.decodeNode(<Object?>[
        {'when': 1},
        ['Date', 2],
        '2026-08-16T00:00:00.000Z',
      ]) as Map<String, dynamic>;
      expect(data['when'], isA<DateTime>());
    });

    test('a pointer into a container that points back stops instead of hanging',
        () {
      final data = SvelteKitData.decodeNode(<Object?>[
        {'loop': 1},
        {'self': 1},
      ]) as Map<String, dynamic>;
      expect((data['loop'] as Map<String, dynamic>)['self'], isNull);
    });

    test('a number sitting at an index is a number, not a pointer', () {
      final data = SvelteKitData.decodeNode(<Object?>[
        {'count': 1},
        7,
      ]) as Map<String, dynamic>;
      expect(data['count'], 7);
    });

    test('the last data node wins, so a page beats its layout', () {
      final decoded = SvelteKitData.decodeDocument(jsonDecode(_listing()));
      expect((decoded as Map<String, dynamic>)['mode'], 'character');
    });
  });

  group('request building', () {
    final source = RisuRealmSource(siteBase: 'https://realm.example');

    test('recommended sends no sort and never a page', () {
      // Asking the recommended order for page 2 answers HTTP 500 on the real
      // site, so the request must not be built at all.
      final q = source
          .searchUri(const DiscoverQuery(
            sort: RisuRealmSource.recommended,
            page: 3,
          ))
          .queryParameters;
      expect(q['mode'], 'character');
      expect(q.containsKey('sort'), isFalse);
      expect(q.containsKey('page'), isFalse);
    });

    test('an unset sort means recommended, not latest', () {
      final q = source.searchUri(const DiscoverQuery()).queryParameters;
      expect(q.containsKey('sort'), isFalse);
    });

    test('latest is an empty sort on the wire, and it pages', () {
      final uri = source.searchUri(
        const DiscoverQuery(sort: RisuRealmSource.latest, page: 2),
      );
      expect(uri.queryParameters['sort'], '');
      expect(uri.queryParameters['page'], '2');
      // Dart renders a valueless parameter as `sort` rather than `sort=`, which
      // the site reads the same way — both spellings were checked against it.
      expect('$uri', contains('sort&'));
    });

    test('downloads and trending page normally', () {
      final q = source
          .searchUri(const DiscoverQuery(sort: 'downloads', page: 4))
          .queryParameters;
      expect(q['sort'], 'downloads');
      expect(q['page'], '4');
    });

    test('tags and exclusions become Realm search keywords', () {
      final q = source
          .searchUri(const DiscoverQuery(
            search: 'ranger',
            includeTags: ['anime', 'fantasy'],
            excludeTags: ['gore'],
          ))
          .queryParameters;
      expect(q['q'], 'ranger tag:anime tag:fantasy !gore');
    });

    test('a search is clamped to the ten keywords the site documents', () {
      final expression = RisuRealmSource.searchExpression(DiscoverQuery(
        includeTags: List<String>.generate(14, (i) => 'tag$i'),
      ));
      expect(expression.split(' ').length, RisuRealmSource.maxKeywords);
    });

    test('a long search is clamped to 200 characters', () {
      final expression = RisuRealmSource.searchExpression(DiscoverQuery(
        includeTags: List<String>.generate(9, (i) => 'x' * 40),
      ));
      expect(expression.length, lessThanOrEqualTo(RisuRealmSource.maxQueryLength));
    });

    test('adult results are a present parameter, absent otherwise', () {
      expect(
        source.searchUri(const DiscoverQuery(nsfw: true)).queryParameters['nsfw'],
        'true',
      );
      expect(
        source.searchUri(const DiscoverQuery()).queryParameters.containsKey('nsfw'),
        isFalse,
      );
    });
  });

  group('reading the listing', () {
    test('an abbreviated download count becomes a number', () {
      expect(RisuRealmSource.parseCount('2.5k'), 2500);
      expect(RisuRealmSource.parseCount('21.9k'), 21900);
      expect(RisuRealmSource.parseCount('1.2m'), 1200000);
      expect(RisuRealmSource.parseCount('64'), 64);
      expect(RisuRealmSource.parseCount(''), isNull);
    });

    test('a date is minutes since the epoch, not seconds', () {
      // Read as seconds this lands in 1970; the card was uploaded in 2026.
      final date = RisuRealmSource.parseDate(29779873)!;
      expect(date.toUtc().year, 2026);
      expect(RisuRealmSource.parseDate(0), isNull);
    });

    test('a placeholder picture is no picture', () {
      final source = RisuRealmSource(siteBase: 'https://realm.example');
      expect(source.imageUrlFor('placeholder.webp'), isNull);
      expect(source.imageUrlFor(''), isNull);
      expect(
        source.imageUrlFor('abc123'),
        'https://sv.risuai.xyz/resource/abc123',
      );
    });
  });

  group('against a server', () {
    late HttpServer server;
    late String base;
    late RisuRealmSource source;
    final requests = <String>[];
    late Map<String, Object> routes;

    setUp(() async {
      requests.clear();
      routes = <String, Object>{};
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://${server.address.host}:${server.port}';
      source = RisuRealmSource(siteBase: base, resourceBase: '$base/resource');
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

    test('a page of cards reads through the pointers', () async {
      routes['__data.json'] = _listing();
      final page = await source.search(
        const DiscoverQuery(sort: 'downloads'),
      );
      final item = page.items.single;

      expect(item.name, 'Kuzi 1.1');
      expect(item.creator, 'fkdlwm7');
      expect(item.description, 'A wandering swordsman');
      expect(item.tags, ['anime', 'fantasy']);
      expect(item.downloads, 2500);
      expect(item.hasLore, isTrue);
      expect(item.createdAt?.toUtc().year, 2026);
      expect(item.thumbnailUrl, '$base/resource/f50df5d43c2c21463d7cf45b2144545649de8e06');
      expect(item.pageUrl, '$base/character/1de09fd1-4e61-4d68-bd75-4e7649cf10f1');
      // One short page is the end of the feed.
      expect(page.hasMore, isFalse);
    });

    test('the recommended order never claims more pages', () async {
      routes['__data.json'] = _listing();
      final page = await source.search(
        const DiscoverQuery(sort: RisuRealmSource.recommended),
      );
      expect(page.hasMore, isFalse);
    });

    group('download ladder', () {
      test('json-v3 is preferred, and one request is enough', () async {
        routes['__data.json'] = _listing();
        routes['download/json-v3'] = _cardJson('Kuzi 1.1');
        final page = await source.search(const DiscoverQuery(sort: 'downloads'));
        final payload = await source.fetch(page.items.single);

        expect(payload.character?.name, 'Kuzi 1.1');
        expect(payload.character?.description, 'from json-v3');
        expect(requests.where((r) => r.contains('png-v3')), isEmpty);
        expect(requests.where((r) => r.contains('charx-v3')), isEmpty);
        // A json card has no picture of its own, so the listing's is fetched.
        expect(requests.where((r) => r.contains('/resource/')).length, 1);
      });

      test('a card that refuses json falls through to the PNG', () async {
        routes['__data.json'] = _listing();
        routes['download/json-v3'] = jsonEncode({
          'error': 'Bad Request',
          'message': 'Invalid response from server',
        });
        routes['download/png-v3'] = _pngWithChara(
          base64Encode(utf8.encode(_cardJson('Kuzi from PNG'))),
        );
        final page = await source.search(const DiscoverQuery(sort: 'downloads'));
        final payload = await source.fetch(page.items.single);

        expect(payload.character?.name, 'Kuzi from PNG');
        expect(requests.where((r) => r.contains('charx-v3')), isEmpty);
      });

      test('an asset card refuses both and is taken as CharX', () async {
        // This is the real shape of a Realm asset card: png is Forbidden with a
        // 200-with-error-body or a 403, and only charx answers.
        routes['__data.json'] = _listing();
        routes['download/json-v3'] = jsonEncode({
          'error': 'Bad Request',
          'message': 'Invalid response from server',
        });
        routes['download/png-v3'] = jsonEncode({
          'error': 'Forbidden',
          'message': 'This card is not allowed to be downloaded in this format.',
        });
        routes['download/charx-v3'] = _pngWithChara(
          base64Encode(utf8.encode(_cardJson('Kuzi from CharX'))),
        );
        final page = await source.search(const DiscoverQuery(sort: 'downloads'));
        final payload = await source.fetch(page.items.single);
        expect(payload.character?.name, 'Kuzi from CharX');
      });

      test("when every format is refused, Realm's own wording is shown",
          () async {
        routes['__data.json'] = _listing();
        routes['download/'] = jsonEncode({
          'error': 'Forbidden',
          'message': 'This card is not allowed to be downloaded in this format.',
        });
        final page = await source.search(const DiscoverQuery(sort: 'downloads'));
        await expectLater(
          source.fetch(page.items.single),
          throwsA(
            isA<DiscoverException>().having(
              (e) => e.message,
              'message',
              contains('not allowed to be downloaded in this format'),
            ),
          ),
        );
      });
    });
  });
}
