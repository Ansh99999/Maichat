import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/studio.dart';
import 'package:maichat/services/studio/studio_web.dart';

/// DuckDuckGo as the Studio's keyless web search, against a loopback stand-in
/// serving pages modelled on html.duckduckgo.com's own markup (see the
/// fixtures). Plain `test()`s only: a `testWidgets` anywhere in this file
/// would make every real HTTP request here answer 400.
void main() {
  String fixture(String name) =>
      File('test/fixtures/$name').readAsStringSync();

  group('reading the page', () {
    test('results come out with titles, real addresses and snippets', () {
      final results = parseDuckDuckGo(fixture('ddg_results.html'))!;
      expect(results.map((r) => r.url), [
        'https://en.wikipedia.org/wiki/Lighthouse_keeper',
        'https://folklore.example.org/ghosts?page=2&lang=en',
        'https://direct.example.net/keepers',
      ]);
      expect(results.first.title, 'Lighthouse keeper - Wikipedia');
      expect(
        results.first.snippet,
        'A lighthouse keeper is the person responsible for tending and '
        'caring for a lighthouse.',
      );
      // A snippet written as a div reads the same as one written as a link.
      expect(results[1].title, 'Ghosts of the coast & their keepers');
      expect(results[1].snippet, contains('drowned keepers'));
    });

    test('ads are left out', () {
      final results = parseDuckDuckGo(fixture('ddg_results.html'))!;
      expect(results.any((r) => r.title.contains('Sponsored')), isFalse);
      expect(results.any((r) => r.url.contains('y.js')), isFalse);
    });

    test('a page that found nothing is an empty list, not a failure', () {
      expect(parseDuckDuckGo(fixture('ddg_no_results.html')), isEmpty);
    });

    test('a page that is not a results page any more is null', () {
      expect(parseDuckDuckGo(fixture('ddg_changed.html')), isNull);
    });

    test('the check page is recognised', () {
      expect(isDuckDuckGoChallenge(fixture('ddg_challenge.html')), isTrue);
      expect(isDuckDuckGoChallenge(fixture('ddg_results.html')), isFalse);
    });

    test('redirect links are unwrapped; tracking and odd links dropped', () {
      expect(
        unwrapDuckDuckGoLink(
          '//duckduckgo.com/l/?uddg=https%3A%2F%2Fa.example%2Fx%3Fy%3D1&rut=z',
        ),
        'https://a.example/x?y=1',
      );
      expect(unwrapDuckDuckGoLink('https://b.example/p'), 'https://b.example/p');
      expect(unwrapDuckDuckGoLink('https://duckduckgo.com/y.js?ad=1'), isNull);
      expect(
        unwrapDuckDuckGoLink('//duckduckgo.com/l/?uddg=javascript%3Aalert(1)'),
        isNull,
      );
      expect(unwrapDuckDuckGoLink('/relative'), isNull);
      expect(unwrapDuckDuckGoLink(''), isNull);
    });

    test('at most eight results', () {
      final many = StringBuffer('<div id="links" class="results">');
      for (var i = 0; i < 12; i++) {
        many.write('<div class="result web-result"><a class="result__a" '
            'href="https://r$i.example/">R$i</a></div>');
      }
      many.write('</div>');
      expect(parseDuckDuckGo(many.toString()), hasLength(kWebSearchResults));
    });
  });

  group('searching', () {
    late HttpServer server;
    late List<HttpRequest> seen;
    late List<DateTime> ddgAt;
    late void Function(HttpRequest request) ddg;

    setUp(() async {
      StudioWeb.resetDuckDuckGoPacing();
      seen = <HttpRequest>[];
      ddgAt = <DateTime>[];
      ddg = (r) => r.response.write(fixture('ddg_results.html'));
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        seen.add(request);
        final path = request.uri.path;
        if (path == '/html.duckduckgo.com/html/') {
          ddgAt.add(DateTime.now());
          request.response.headers.contentType = ContentType.html;
          ddg(request);
        } else if (path == '/en.wikipedia.org/w/api.php') {
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({
            'query': {
              'search': [
                {'title': 'Lighthouse keeper', 'snippet': 'From the wiki'},
              ],
            },
          }));
        } else {
          request.response.statusCode = 404;
        }
        await request.response.close();
      });
    });
    tearDown(() => server.close(force: true));

    StudioWeb web({Duration gap = Duration.zero}) => StudioWeb(
          baseFor: (host) => 'http://127.0.0.1:${server.port}/$host',
          allowPrivate: true,
          duckDuckGoGap: gap,
        );

    test('is the default, and asks like a browser', () async {
      final found = await web().searchWithNote(
        'lighthouse keeper folklore',
        config: const StudioConfig(),
      );
      expect(found.source, 'duckduckgo');
      expect(found.note, isNull);
      expect(found.results, hasLength(3));
      final request = seen.single;
      expect(request.uri.queryParameters['q'], 'lighthouse keeper folklore');
      expect(request.headers.value('user-agent'), contains('Mozilla/5.0'));
    });

    test('site narrows it with site:, but wikis use their own search',
        () async {
      await web().searchWithNote(
        'keeper',
        site: 'https://example.com/some/page',
        config: const StudioConfig(),
      );
      expect(seen.last.uri.queryParameters['q'], 'keeper site:example.com');

      final wiki = await web().searchWithNote(
        'keeper',
        site: 'en.wikipedia.org',
        config: const StudioConfig(),
      );
      expect(seen.last.uri.path, '/en.wikipedia.org/w/api.php');
      expect(wiki.source, 'en.wikipedia.org');
    });

    test('a check falls back to Wikipedia, and says so', () async {
      ddg = (r) {
        r.response.statusCode = 202;
        r.response.write(fixture('ddg_challenge.html'));
      };
      final found = await web().searchWithNote(
        'lighthouse keeper',
        site: 'example.com',
        config: const StudioConfig(),
      );
      expect(found.source, 'en.wikipedia.org');
      expect(found.note, contains('asked for a check'));
      expect(found.note, contains('Wikipedia results instead'));
      expect(found.results.single.title, 'Lighthouse keeper');
      // Wikipedia is asked the plain query — site: means nothing to it.
      expect(seen.last.uri.queryParameters['srsearch'], 'lighthouse keeper');
    });

    test('the check page served with a 200 is caught too', () async {
      ddg = (r) => r.response.write(fixture('ddg_challenge.html'));
      final found =
          await web().searchWithNote('x', config: const StudioConfig());
      expect(found.note, contains('asked for a check'));
    });

    test('a changed page falls back and names the change', () async {
      ddg = (r) => r.response.write(fixture('ddg_changed.html'));
      final found =
          await web().searchWithNote('x', config: const StudioConfig());
      expect(found.note, contains('results page has changed'));
      expect(found.results, isNotEmpty);
    });

    test('an HTTP failure falls back too', () async {
      ddg = (r) => r.response.statusCode = 503;
      final found =
          await web().searchWithNote('x', config: const StudioConfig());
      expect(found.note, contains('HTTP 503'));
    });

    test('a real "no results" is empty, with no fallback', () async {
      ddg = (r) => r.response.write(fixture('ddg_no_results.html'));
      final found =
          await web().searchWithNote('zxqv', config: const StudioConfig());
      expect(found.results, isEmpty);
      expect(found.note, isNull);
      expect(found.source, 'duckduckgo');
      expect(seen.where((r) => r.uri.path.contains('wikipedia')), isEmpty);
    });

    test('searches go one at a time, with the gap between them', () async {
      const gap = Duration(milliseconds: 120);
      // Two separate StudioWebs: the pacing is app-wide, not per instance.
      final started = DateTime.now();
      await Future.wait([
        web(gap: gap).searchWithNote('a', config: const StudioConfig()),
        web(gap: gap).searchWithNote('b', config: const StudioConfig()),
        web(gap: gap).searchWithNote('c', config: const StudioConfig()),
      ]);
      expect(ddgAt, hasLength(3));
      for (var i = 1; i < ddgAt.length; i++) {
        expect(
          ddgAt[i].difference(ddgAt[i - 1]),
          greaterThanOrEqualTo(gap - const Duration(milliseconds: 15)),
        );
      }
      expect(
        DateTime.now().difference(started),
        greaterThanOrEqualTo(gap * 2 - const Duration(milliseconds: 30)),
      );
      // In the order they were asked.
      expect(
        [for (final r in seen) r.uri.queryParameters['q']],
        ['a', 'b', 'c'],
      );
    });

    test('Wikipedia chosen in settings still searches Wikipedia only',
        () async {
      final found = await web().searchWithNote(
        'keeper',
        config: const StudioConfig(searchProvider: StudioSearchProvider.wiki),
      );
      expect(found.source, 'en.wikipedia.org');
      expect(seen.single.uri.path, '/en.wikipedia.org/w/api.php');
    });
  });

  group('settings', () {
    test('DuckDuckGo is the default, and is not written down', () {
      expect(const StudioConfig().searchProvider,
          StudioSearchProvider.duckduckgo);
      expect(const StudioConfig().toJson().containsKey('searchProvider'),
          isFalse);
    });

    test('the old default (Wikipedia, never stored) moves to DuckDuckGo', () {
      // Settings saved before DuckDuckGo existed left the default out.
      final old = StudioConfig.fromJson(const {'maxSteps': 40});
      expect(old.searchProvider, StudioSearchProvider.duckduckgo);
    });

    test('Wikipedia chosen since is stored and kept', () {
      final chosen = const StudioConfig(
        searchProvider: StudioSearchProvider.wiki,
      ).toJson();
      expect(chosen['searchProvider'], 'wiki');
      final back = StudioConfig.fromJson(
        jsonDecode(jsonEncode(chosen)) as Map<String, dynamic>,
      );
      expect(back.searchProvider, StudioSearchProvider.wiki);
    });

    test('an unknown stored name is DuckDuckGo', () {
      expect(StudioSearchProvider.byName('altavista'),
          StudioSearchProvider.duckduckgo);
    });
  });
}
