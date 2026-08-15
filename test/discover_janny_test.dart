import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/discover.dart';
import 'package:maichat/services/discover/browser_clearance.dart';
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

    // Downloading is covered in "the download ladder" below, which drives all
    // three of its tiers rather than only the card API.
  });

  group('the download ladder', () {
    late HttpServer server;
    late JannySource source;
    late String base;
    final paths = <String>[];

    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAABzenr0AAAADUlEQVR42mP8'
      '/5+BAQAI/AL+6nWJPwAAAABJRU5ErkJggg==',
    );

    const item = DiscoverItem(
      sourceId: 'janny',
      kind: DiscoverKind.character,
      id: 'uuid-1',
      name: 'Ann',
      creator: 'someone',
      description: 'The site blurb.',
      tags: ['Female'],
    );

    /// A page shaped like JannyAI's: the definition inside an Astro island's
    /// HTML-escaped, `[type, data]`-wrapped props.
    String characterPage(String imageUrl) {
      final props = <String, Object?>{
        'character': <Object?>[
          0,
          <String, Object?>{
            'name': <Object?>[0, 'Ann'],
            'personality': <Object?>[0, 'A librarian who guards the stacks.'],
            'scenario': <Object?>[0, 'The reading room, after hours.'],
            'firstMessage': <Object?>[0, 'Shh.'],
            'exampleDialogs': <Object?>[0, '<START>\nAnn: Quiet, please.'],
            'description': <Object?>[0, '<p>A gentle bot.</p>'],
            'tagIds': <Object?>[
              1,
              <Object?>[
                <Object?>[0, 2],
              ],
            ],
          },
        ],
        'imageUrl': <Object?>[0, imageUrl],
      };
      final escaped =
          jsonEncode(props).replaceAll('&', '&amp;').replaceAll('"', '&quot;');
      return '<!doctype html><html><body>'
          '<div>Creator: <a href="/c/someone">@someone</a></div>'
          '<astro-island component-export="CharacterButtons" '
          'props="$escaped" ssr></astro-island>'
          '${'<p>filler</p>' * 100}</body></html>';
    }

    const challengePage = '<!DOCTYPE html><html><head>'
        '<title>Just a moment...</title></head><body>'
        '<div id="challenge-platform"></div>'
        '</body></html>';

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
        paths.add(request.uri.path);
        await handler(request, base);
      });
    }

    void writePage(HttpRequest request, String body) {
      request.response.headers.contentType = ContentType.html;
      request.response.write(body);
    }

    setUp(() {
      paths.clear();
      // The clearance store is app-wide, so a leak from another group would
      // change which route this one takes.
      browserClearances.clear();
    });
    tearDown(() async {
      source.close();
      await server.close(force: true);
    });

    test('the character page is read first, and is enough on its own',
        () async {
      await serve((request, base) async {
        if (request.uri.path.startsWith('/characters/')) {
          writePage(request, characterPage('$base/a.png'));
        } else if (request.uri.path == '/a.png') {
          request.response.headers.contentType = ContentType('image', 'png');
          request.response.add(png);
        } else {
          request.response.statusCode = 500;
        }
        await request.response.close();
      });

      final character = (await source.fetch(item)).character!;
      expect(character.name, 'Ann');
      // JannyAI's `personality` is the definition body …
      expect(character.description, 'A librarian who guards the stacks.');
      expect(character.personality, isEmpty);
      // … and its `description` is the blurb, stripped of its markup.
      expect(character.creatorNotes, 'A gentle bot.');
      expect(character.scenario, 'The reading room, after hours.');
      expect(character.firstMes, 'Shh.');
      expect(character.mesExample, '<START>\nAnn: Quiet, please.');
      expect(character.tags, ['Female']);
      expect(character.creator, 'someone');
      expect(character.avatar, base64Encode(png));
      // The older card API was never asked: the page had everything.
      expect(paths, isNot(contains('/api/v1/download')));
      expect(paths.first, '/characters/uuid-1_character-ann');
    });

    test('a checked page falls through to the older card API', () async {
      final card = jsonEncode({
        'spec': 'chara_card_v2',
        'spec_version': '2.0',
        'data': {'name': 'Ann', 'description': 'From the card API.'},
      });
      await serve((request, base) async {
        switch (request.uri.path) {
          case '/api/v1/download':
            request.response.headers.contentType = ContentType.json;
            request.response.write(
              jsonEncode({'status': 'ok', 'downloadUrl': '$base/card.json'}),
            );
          case '/card.json':
            request.response.headers.contentType = ContentType.json;
            request.response.write(card);
          default:
            // Cloudflare answers the page with a check, 403 and all.
            request.response.statusCode = 403;
            writePage(request, challengePage);
        }
        await request.response.close();
      });

      final character = (await source.fetch(item)).character!;
      expect(character.description, 'From the card API.');
      expect(paths, contains('/api/v1/download'));
    });

    test('both routes blocked raises a challenge, naming the page to open',
        () async {
      await serve((request, _) async {
        request.response.statusCode = 403;
        writePage(request, challengePage);
        await request.response.close();
      });

      await expectLater(
        source.fetch(item),
        throwsA(isA<DiscoverChallengeException>()
            .having((e) => e.pageUrl, 'pageUrl',
                '$base/characters/uuid-1_character-ann')
            .having((e) => e.message, 'message',
                contains('checking the browser'))),
      );

      // Having been checked once, the next card does not spend two doomed
      // requests finding out again — the block is on the connection, not on the
      // card.
      paths.clear();
      await expectLater(
        source.fetch(item),
        throwsA(isA<DiscoverChallengeException>()),
      );
      expect(paths, isEmpty);

      // Until a retry asks afresh, because moving between wifi and mobile data
      // changes the answer.
      source.resetTransport();
      await expectLater(
        source.fetch(item),
        throwsA(isA<DiscoverChallengeException>()),
      );
      expect(paths, isNotEmpty);
    });

    test('a page fetched by a browser view finishes the download', () async {
      await serve((request, base) async {
        // Everything over HTTP is refused; the HTML comes from the browser view.
        if (request.uri.path == '/a.png') {
          request.response.headers.contentType = ContentType('image', 'png');
          request.response.add(png);
        } else {
          request.response.statusCode = 403;
          writePage(request, challengePage);
        }
        await request.response.close();
      });

      final character = (await source.fetchFromHtml(
        item,
        characterPage('$base/a.png'),
      )).character!;
      expect(character.description, 'A librarian who guards the stacks.');
      expect(character.avatar, base64Encode(png));
    });

    test('a page whose definition the creator hid says exactly that', () async {
      final hidden = characterPage('https://img.invalid/a.png')
          .replaceAll('A librarian who guards the stacks.', '')
          .replaceAll('Shh.', '');
      await serve((request, _) async {
        request.response.statusCode = 404;
        await request.response.close();
      });

      await expectLater(
        source.fetchFromHtml(item, hidden),
        throwsA(isA<DiscoverException>().having(
          (e) => e.message,
          'message',
          contains('carries no definition'),
        )),
      );
    });

    test('a page that no longer holds the character is reported, not guessed',
        () async {
      await serve((request, _) async {
        if (request.uri.path.startsWith('/characters/')) {
          writePage(
            request,
            '<!doctype html><html><body><astro-island '
            'props="{&quot;other&quot;:[0,1]}"></astro-island>'
            '${'<p>filler</p>' * 100}</body></html>',
          );
        } else {
          request.response.statusCode = 404;
        }
        await request.response.close();
      });

      await expectLater(
        source.fetch(item),
        throwsA(isA<DiscoverException>().having(
          (e) => e.message,
          'message',
          contains('no longer carries the character'),
        )),
      );
    });
  });

  group('reusing a browser clearance', () {
    late HttpServer server;
    late JannySource source;
    late String base;
    final seen = <Map<String, String>>[];

    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAABzenr0AAAADUlEQVR42mP8'
      '/5+BAQAI/AL+6nWJPwAAAABJRU5ErkJggg==',
    );

    const item = DiscoverItem(
      sourceId: 'janny',
      kind: DiscoverKind.character,
      id: 'uuid-1',
      name: 'Ann',
    );

    const clearedUa = 'Mozilla/5.0 (Linux; Android 14; Pixel) Chrome/124';

    String characterPage(String imageUrl) {
      final props = <String, Object?>{
        'character': <Object?>[
          0,
          <String, Object?>{
            'name': <Object?>[0, 'Ann'],
            'personality': <Object?>[0, 'A librarian who guards the stacks.'],
            'firstMessage': <Object?>[0, 'Shh.'],
          },
        ],
        'imageUrl': <Object?>[0, imageUrl],
      };
      final escaped =
          jsonEncode(props).replaceAll('&', '&amp;').replaceAll('"', '&quot;');
      return '<!doctype html><html><body>'
          '<astro-island component-export="CharacterButtons" '
          'props="$escaped" ssr></astro-island>'
          '${'<p>filler</p>' * 100}</body></html>';
    }

    const challengePage = '<!DOCTYPE html><html><head>'
        '<title>Just a moment...</title></head><body>'
        '<div id="challenge-platform"></div></body></html>';

    /// Serves the character page only to a request that presents a clearance —
    /// which is exactly how Cloudflare behaves once one has been earned.
    Future<void> serveGatedOnClearance({required bool honourClearance}) async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://${server.address.host}:${server.port}';
      source = JannySource(
        searchBase: base,
        downloadBase: base,
        imageBase: '$base/bot-avatars',
        siteBase: base,
      );
      server.listen((request) async {
        if (request.uri.path == '/a.png') {
          request.response.headers.contentType = ContentType('image', 'png');
          request.response.add(png);
          await request.response.close();
          return;
        }
        seen.add(<String, String>{
          'cookie': request.headers.value('cookie') ?? '',
          'ua': request.headers.value('user-agent') ?? '',
        });
        final cleared = honourClearance &&
            (request.headers.value('cookie') ?? '').contains('cf_clearance');
        if (request.uri.path.startsWith('/characters/') && cleared) {
          request.response.headers.contentType = ContentType.html;
          request.response.write(characterPage('$base/a.png'));
        } else {
          request.response.statusCode = 403;
          request.response.headers.contentType = ContentType.html;
          request.response.write(challengePage);
        }
        await request.response.close();
      });
    }

    setUp(() {
      seen.clear();
      browserClearances.clear();
    });
    tearDown(() async {
      browserClearances.clear();
      source.close();
      await server.close(force: true);
    });

    test('a stored clearance fetches the page with no browser at all', () async {
      await serveGatedOnClearance(honourClearance: true);
      browserClearances.remember(
        Uri.parse(base).host,
        BrowserClearance(
          cookies: 'cf_clearance=abc123',
          userAgent: clearedUa,
        ),
      );

      final character = (await source.fetch(item)).character!;
      expect(character.description, 'A librarian who guards the stacks.');
      // The credentials went out together: the cookie is useless under any other
      // User-Agent.
      expect(seen.single['cookie'], contains('cf_clearance=abc123'));
      expect(seen.single['ua'], clearedUa);
    });

    test('the clearance outlives the first card, so later ones are plain HTTP',
        () async {
      await serveGatedOnClearance(honourClearance: true);
      browserClearances.remember(
        Uri.parse(base).host,
        BrowserClearance(cookies: 'cf_clearance=abc123', userAgent: clearedUa),
      );

      await source.fetch(item);
      await source.fetch(const DiscoverItem(
        sourceId: 'janny',
        kind: DiscoverKind.character,
        id: 'uuid-2',
        name: 'Bo',
      ));
      // Two cards, two page requests, no challenge raised either time.
      expect(seen, hasLength(2));
      expect(seen.last['cookie'], contains('cf_clearance'));
    });

    test('a lapsed clearance is thrown away, not retried forever', () async {
      // The server refuses everything: this is what a clearance expiring on
      // Cloudflare's fixed timer looks like from here.
      await serveGatedOnClearance(honourClearance: false);
      final host = Uri.parse(base).host;
      browserClearances.remember(
        host,
        BrowserClearance(cookies: 'cf_clearance=stale', userAgent: clearedUa),
      );

      await expectLater(
        source.fetch(item),
        throwsA(isA<DiscoverChallengeException>()),
      );
      // Gone, so the next attempt earns a fresh one in the browser rather than
      // replaying a cookie that is now refused.
      expect(browserClearances.forHost(host), isNull);
    });

    test('a clearance arriving later reopens the route it had given up on',
        () async {
      await serveGatedOnClearance(honourClearance: true);
      final host = Uri.parse(base).host;

      // First attempt, bare: refused, so the source stops trying bare HTTP.
      await expectLater(
        source.fetch(item),
        throwsA(isA<DiscoverChallengeException>()),
      );
      seen.clear();
      await expectLater(
        source.fetch(item),
        throwsA(isA<DiscoverChallengeException>()),
      );
      expect(seen, isEmpty, reason: 'a doomed bare request is not repeated');

      // The browser view passes the check and leaves a clearance behind. That
      // makes it a different request, so the route is worth trying again.
      browserClearances.remember(
        host,
        BrowserClearance(cookies: 'cf_clearance=fresh', userAgent: clearedUa),
      );
      final character = (await source.fetch(item)).character!;
      expect(character.description, 'A librarian who guards the stacks.');
      expect(seen.single['cookie'], contains('cf_clearance=fresh'));
    });
  });
}

List<String> _filtersOf(JannySource source, DiscoverQuery query) {
  final body = source.searchBody(query);
  final first = (body['queries'] as List).single as Map<String, dynamic>;
  return (first['filter'] as List).cast<String>();
}
