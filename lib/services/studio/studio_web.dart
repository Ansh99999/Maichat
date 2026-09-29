import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import '../../models/studio.dart';

/// Longest page text `web_fetch` hands back; the middle of a longer page is
/// cut, so both its opening and its end survive.
const int kWebFetchMaxChars = 12000;

/// Most bytes read from one response. A page past this is read no further.
const int kWebFetchMaxBytes = 2 * 1024 * 1024;

/// How many search results come back.
const int kWebSearchResults = 8;

/// A search hit.
class WebResult {
  const WebResult({required this.title, required this.url, this.snippet = ''});

  final String title;
  final String url;
  final String snippet;

  Map<String, dynamic> toJson() => {
        'title': title,
        'url': url,
        if (snippet.isNotEmpty) 'snippet': snippet,
      };
}

/// What a search found, and — when it had to search somewhere other than asked
/// (DuckDuckGo asked for a check, say) — a note saying so, for the agent.
class WebSearchOutcome {
  const WebSearchOutcome(this.results, {this.note, this.source = ''});

  final List<WebResult> results;
  final String? note;

  /// Where the results came from: `duckduckgo`, `wikipedia`, a wiki's host…
  final String source;
}

/// The minimum gap between two DuckDuckGo searches, app-wide. Its results page
/// is not an API; asking it quickly and repeatedly is what earns a check.
const Duration kDuckDuckGoGap = Duration(milliseconds: 1500);

/// A fetched page, as readable text.
class WebPage {
  const WebPage({
    required this.url,
    required this.title,
    required this.text,
    this.cut = 0,
  });

  /// Where it ended up, after redirects.
  final String url;
  final String title;
  final String text;

  /// How many characters were cut from its middle.
  final int cut;
}

/// Something the web could not give; the message is written for the agent,
/// saying what to try instead.
class WebError implements Exception {
  WebError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The Studio's window on the web: searching (DuckDuckGo or Wikipedia and
/// Fandom with no key, or Brave / SearXNG when the user set one up) and reading
/// one page as text.
///
/// Reading refuses anything that is not http(s) or that resolves to a private,
/// loopback or link-local address — at every redirect, not only the first
/// address — so a page cannot point the agent at the user's own network.
class StudioWeb {
  StudioWeb({
    http.Client Function()? client,
    String Function(String host)? baseFor,
    this.allowPrivate = false,
    this.timeout = const Duration(seconds: 20),
    this.duckDuckGoGap = kDuckDuckGoGap,
  })  : _client = client ?? http.Client.new,
        _baseFor = baseFor ?? ((host) => 'https://$host');

  /// The gap kept between DuckDuckGo searches; shorter in tests.
  final Duration duckDuckGoGap;

  /// DuckDuckGo searches are taken one at a time across the whole app — every
  /// [StudioWeb] shares this queue — with [duckDuckGoGap] between them.
  static Future<void> _ddgQueue = Future<void>.value();
  static DateTime? _ddgLast;

  /// Forgets when DuckDuckGo was last asked; for tests.
  static void resetDuckDuckGoPacing() {
    _ddgQueue = Future<void>.value();
    _ddgLast = null;
  }

  /// What the DuckDuckGo page is asked with: a browser's words, since the
  /// page is written for browsers and answers them. The rest of the Studio
  /// says who it is ([_headers]).
  static const Map<String, String> _ddgHeaders = {
    'User-Agent': 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/129.0 Mobile Safari/537.36',
    'Accept': 'text/html,application/xhtml+xml;q=0.9,*/*;q=0.8',
    'Accept-Language': 'en-US,en;q=0.8',
  };

  final http.Client Function() _client;

  /// The scheme-and-host a known service is reached at — its real address by
  /// default, a loopback stand-in in tests.
  final String Function(String host) _baseFor;

  /// Lets [fetch] reach loopback and private addresses. Tests only.
  final bool allowPrivate;
  final Duration timeout;

  static const Map<String, String> _headers = {
    'User-Agent': 'MaiChat-CharacterStudio/1.0 (+https://github.com/Ansh99999/Maichat)',
    'Accept': 'text/html,application/xhtml+xml,application/json;q=0.9,'
        'text/plain;q=0.8,*/*;q=0.5',
  };

  // --- search ------------------------------------------------------------------

  /// Searches for [query]; the results only — see [searchWithNote].
  Future<List<WebResult>> search(
    String query, {
    String? site,
    required StudioConfig config,
  }) async =>
      (await searchWithNote(query, site: site, config: config)).results;

  /// Searches for [query]. [site] narrows it: a Fandom wiki
  /// (`harrypotter.fandom.com`, or just `harrypotter` with `fandom:` in front)
  /// or a Wikipedia (`fr.wikipedia.org`) is searched through that wiki's own
  /// search, whatever the provider — it is exact and never asks for a check;
  /// any other site is searched with `site:` by DuckDuckGo, Brave or SearXNG.
  Future<WebSearchOutcome> searchWithNote(
    String query, {
    String? site,
    required StudioConfig config,
  }) async {
    final q = query.trim();
    if (q.isEmpty) throw WebError('The query is empty.');
    final target = site?.trim().toLowerCase() ?? '';
    final wiki = _wikiHost(target);
    if (wiki != null) {
      return WebSearchOutcome(await _mediaWiki(wiki, q), source: wiki);
    }
    final domain = target
        .replaceFirst(RegExp(r'^https?://'), '')
        .split('/')
        .first;
    final scoped = domain.isEmpty ? q : '$q site:$domain';
    switch (config.searchProvider) {
      case StudioSearchProvider.duckduckgo:
        return _duckDuckGo(scoped, fallback: q);
      case StudioSearchProvider.brave:
        if (config.searchKey.trim().isEmpty) {
          throw WebError(
            'Brave Search has no key set up. Tell the user to add one in Studio '
            'settings ▸ Web research, or search Wikipedia or a Fandom wiki with '
            'site instead.',
          );
        }
        return WebSearchOutcome(
          await _brave(scoped, config.searchKey),
          source: 'brave',
        );
      case StudioSearchProvider.searxng:
        if (config.searchUrl.trim().isEmpty) {
          throw WebError(
            'No SearXNG address is set up. Search Wikipedia or a Fandom wiki '
            'with site instead.',
          );
        }
        return WebSearchOutcome(
          await _searxng(scoped, config.searchUrl.trim()),
          source: 'searxng',
        );
      case StudioSearchProvider.wiki:
        if (target.isNotEmpty) {
          throw WebError(
            'Without a web search set up, site can only be a Fandom wiki '
            '("name.fandom.com") or a Wikipedia ("en.wikipedia.org"). For any '
            'other site, web_fetch a page you know the address of.',
          );
        }
        return WebSearchOutcome(
          await _mediaWiki('en.wikipedia.org', q),
          source: 'en.wikipedia.org',
        );
    }
  }

  // --- DuckDuckGo ----------------------------------------------------------------

  /// DuckDuckGo's plain-HTML results for [query]. When DuckDuckGo will not
  /// answer — it asked for a check, it could not be reached, or its page no
  /// longer looks like a results page — the search is made on Wikipedia with
  /// [fallback] instead, and the outcome says so: never an empty list that
  /// reads as "nothing exists".
  Future<WebSearchOutcome> _duckDuckGo(
    String query, {
    required String fallback,
  }) async {
    final page = await _paced(() => _ddgPage(query));
    if (page.results != null) {
      return WebSearchOutcome(page.results!, source: 'duckduckgo');
    }
    final why = page.problem!;
    try {
      final wiki = await _mediaWiki('en.wikipedia.org', fallback);
      return WebSearchOutcome(
        wiki,
        source: 'en.wikipedia.org',
        note: '$why, so these are Wikipedia results instead.',
      );
    } on WebError catch (e) {
      throw WebError('$why, and Wikipedia failed too: ${e.message}');
    }
  }

  /// Runs [request] after every DuckDuckGo request before it, and no sooner
  /// than [duckDuckGoGap] after the last one began.
  Future<T> _paced<T>(Future<T> Function() request) {
    final done = Completer<T>();
    _ddgQueue = _ddgQueue.then((_) async {
      final last = _ddgLast;
      if (last != null) {
        final wait = duckDuckGoGap - DateTime.now().difference(last);
        if (wait > Duration.zero) await Future<void>.delayed(wait);
      }
      _ddgLast = DateTime.now();
      try {
        done.complete(await request());
      } catch (e, st) {
        done.completeError(e, st);
      }
    });
    return done.future;
  }

  /// One request to DuckDuckGo's HTML page: its results, or why there are
  /// none to give ([problem] set, [results] null). A page that really found
  /// nothing gives an empty list and no problem.
  Future<({List<WebResult>? results, String? problem})> _ddgPage(
    String query,
  ) async {
    final uri = Uri.parse('${_baseFor('html.duckduckgo.com')}/html/')
        .replace(queryParameters: {'q': query, 'kl': 'wt-wt'});
    final client = _client();
    http.Response response;
    try {
      response = await client
          .get(uri, headers: _ddgHeaders)
          .timeout(timeout);
    } on TimeoutException {
      return (results: null, problem: 'DuckDuckGo did not answer in time');
    } catch (_) {
      return (results: null, problem: 'DuckDuckGo could not be reached');
    } finally {
      client.close();
    }
    final body = utf8.decode(response.bodyBytes, allowMalformed: true);
    if (response.statusCode == 202 || isDuckDuckGoChallenge(body)) {
      return (results: null, problem: 'DuckDuckGo asked for a check');
    }
    if (response.statusCode != 200) {
      return (
        results: null,
        problem: 'DuckDuckGo answered HTTP ${response.statusCode}',
      );
    }
    final parsed = parseDuckDuckGo(body);
    if (parsed == null) {
      return (
        results: null,
        problem: 'DuckDuckGo\'s results page has changed and could not be read',
      );
    }
    return (results: parsed, problem: null);
  }

  /// The MediaWiki host [site] names, or null when it names none.
  static String? _wikiHost(String site) {
    if (site.isEmpty) return null;
    final s = site
        .replaceFirst(RegExp(r'^https?://'), '')
        .split('/')
        .first;
    if (s.startsWith('fandom:')) {
      final name = s.substring('fandom:'.length).trim();
      return name.isEmpty ? null : '$name.fandom.com';
    }
    if (s.endsWith('.fandom.com') || s.endsWith('.wikipedia.org')) return s;
    if (s == 'wikipedia' || s == 'wikipedia.org') return 'en.wikipedia.org';
    if (s == 'fandom' || s == 'fandom.com') {
      throw WebError(
        'Fandom has no search across all its wikis without a key. Name the '
        'wiki: site "harrypotter.fandom.com" (the part before .fandom.com is '
        'usually the series name run together).',
      );
    }
    return null;
  }

  Future<List<WebResult>> _mediaWiki(String host, String query) async {
    // Wikipedia serves its API under /w/; a Fandom wiki at the root.
    final path = host.endsWith('wikipedia.org') ? '/w/api.php' : '/api.php';
    final api = Uri.parse('${_baseFor(host)}$path').replace(queryParameters: {
      'action': 'query',
      'list': 'search',
      'srsearch': query,
      'srlimit': '$kWebSearchResults',
      'format': 'json',
      'utf8': '1',
    });
    final json = await _getJson(api, what: host);
    final hits = (json['query'] is Map ? json['query']['search'] : null);
    if (hits is! List) {
      throw WebError('$host did not answer the search as expected.');
    }
    return [
      for (final h in hits)
        if (h is Map && h['title'] is String)
          WebResult(
            title: h['title'] as String,
            url: 'https://$host/wiki/'
                '${Uri.encodeComponent((h['title'] as String).replaceAll(' ', '_'))}',
            snippet: plainText(h['snippet']?.toString() ?? ''),
          ),
    ];
  }

  Future<List<WebResult>> _brave(String query, String key) async {
    final uri = Uri.parse('${_baseFor('api.search.brave.com')}/res/v1/web/search')
        .replace(queryParameters: {'q': query, 'count': '$kWebSearchResults'});
    final json = await _getJson(
      uri,
      what: 'Brave Search',
      headers: {'X-Subscription-Token': key, 'Accept': 'application/json'},
    );
    final results = json['web'] is Map ? json['web']['results'] : null;
    if (results is! List) return const <WebResult>[];
    return [
      for (final r in results.take(kWebSearchResults))
        if (r is Map && r['url'] is String)
          WebResult(
            title: plainText(r['title']?.toString() ?? ''),
            url: r['url'] as String,
            snippet: plainText(r['description']?.toString() ?? ''),
          ),
    ];
  }

  Future<List<WebResult>> _searxng(String query, String base) async {
    final root = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    final uri = Uri.tryParse('$root/search');
    if (uri == null || !uri.hasScheme) {
      throw WebError('The SearXNG address in Studio settings is not valid.');
    }
    final json = await _getJson(
      uri.replace(queryParameters: {'q': query, 'format': 'json'}),
      what: 'SearXNG',
    );
    final results = json['results'];
    if (results is! List) return const <WebResult>[];
    return [
      for (final r in results.take(kWebSearchResults))
        if (r is Map && r['url'] is String)
          WebResult(
            title: plainText(r['title']?.toString() ?? ''),
            url: r['url'] as String,
            snippet: plainText(r['content']?.toString() ?? ''),
          ),
    ];
  }

  Future<Map<String, dynamic>> _getJson(
    Uri uri, {
    required String what,
    Map<String, String> headers = const <String, String>{},
  }) async {
    final client = _client();
    try {
      final response = await client
          .get(uri, headers: {..._headers, ...headers})
          .timeout(timeout);
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw WebError('$what refused the search (HTTP ${response.statusCode}).');
      }
      if (response.statusCode == 404) {
        throw WebError(
          '$what was not found. If it is a Fandom wiki, check its name.',
        );
      }
      if (response.statusCode != 200) {
        throw WebError('$what failed (HTTP ${response.statusCode}). Try again '
            'later or search elsewhere.');
      }
      final decoded = jsonDecode(utf8.decode(response.bodyBytes, allowMalformed: true));
      if (decoded is! Map<String, dynamic>) {
        throw WebError('$what answered with something that is not a result.');
      }
      return decoded;
    } on WebError {
      rethrow;
    } on TimeoutException {
      throw WebError('$what did not answer in time.');
    } on FormatException {
      throw WebError('$what answered with something that is not a result.');
    } catch (_) {
      throw WebError('Could not reach $what. The device may be offline.');
    } finally {
      client.close();
    }
  }

  // --- fetch ---------------------------------------------------------------------

  /// Reads [url] as text: a web page's words (without its scripts, menus and
  /// footers), or a text or JSON file as it is.
  Future<WebPage> fetch(String url) async {
    var uri = Uri.tryParse(url.trim());
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      throw WebError('Only http and https addresses can be read.');
    }
    if (uri.host.isEmpty) throw WebError('That address has no host.');
    final client = _client();
    try {
      for (var hop = 0; hop <= 5; hop++) {
        await _guard(uri!);
        final request = http.Request('GET', uri)
          ..followRedirects = false
          ..headers.addAll(_headers);
        final response = await client.send(request).timeout(timeout);
        final location = response.headers['location'];
        if (response.statusCode >= 300 &&
            response.statusCode < 400 &&
            location != null) {
          await response.stream.drain<void>();
          uri = uri.resolve(location);
          if (!(uri.isScheme('http') || uri.isScheme('https'))) {
            throw WebError('The page redirected somewhere that is not http(s).');
          }
          continue;
        }
        if (response.statusCode != 200) {
          await response.stream.drain<void>();
          throw WebError(
            'The page answered HTTP ${response.statusCode}. '
            '${response.statusCode == 403 || response.statusCode == 429 ? 'The site may be blocking automated reading; try another source.' : 'Check the address.'}',
          );
        }
        final bytes = await _readCapped(response.stream);
        final type = (response.headers['content-type'] ?? '').toLowerCase();
        final body = utf8.decode(bytes, allowMalformed: true);
        final isHtml = type.contains('html') ||
            (type.isEmpty && body.trimLeft().startsWith('<'));
        if (!isHtml &&
            !type.startsWith('text/') &&
            !type.contains('json') &&
            !type.contains('xml') &&
            type.isNotEmpty) {
          throw WebError('That address is a $type file, not a page to read.');
        }
        final page = isHtml ? htmlToText(body) : (title: '', text: body.trim());
        final cut = shortenMiddle(page.text, kWebFetchMaxChars);
        return WebPage(
          url: uri.toString(),
          title: page.title,
          text: cut.text,
          cut: cut.cut,
        );
      }
      throw WebError('The page redirected too many times.');
    } on WebError {
      rethrow;
    } on TimeoutException {
      throw WebError('The page did not answer in time.');
    } catch (_) {
      throw WebError('Could not reach that page. The device may be offline, '
          'or the address may be wrong.');
    } finally {
      client.close();
    }
  }

  Future<void> _guard(Uri uri) async {
    if (allowPrivate) return;
    final host = uri.host;
    if (host == 'localhost' || host.endsWith('.local') ||
        host.endsWith('.localhost') || host.endsWith('.internal')) {
      throw WebError('Addresses on this device or its network cannot be read.');
    }
    final literal = InternetAddress.tryParse(host);
    List<InternetAddress> addresses;
    if (literal != null) {
      addresses = [literal];
    } else {
      try {
        addresses = await InternetAddress.lookup(host).timeout(timeout);
      } catch (_) {
        throw WebError('No such site: "$host". Check the address.');
      }
    }
    if (addresses.any(isPrivateAddress)) {
      throw WebError('Addresses on this device or its network cannot be read.');
    }
  }

  static Future<List<int>> _readCapped(Stream<List<int>> stream) async {
    final out = <int>[];
    await for (final chunk in stream) {
      final room = kWebFetchMaxBytes - out.length;
      if (chunk.length >= room) {
        out.addAll(chunk.take(room));
        break;
      }
      out.addAll(chunk);
    }
    return out;
  }
}

/// Whether [address] is loopback, private, link-local or otherwise not a
/// public address on the internet.
bool isPrivateAddress(InternetAddress address) {
  if (address.isLoopback || address.isLinkLocal || address.isMulticast) {
    return true;
  }
  final b = address.rawAddress;
  if (address.type == InternetAddressType.IPv4 && b.length == 4) {
    return b[0] == 0 ||
        b[0] == 10 ||
        b[0] == 127 ||
        (b[0] == 100 && b[1] >= 64 && b[1] <= 127) ||
        (b[0] == 169 && b[1] == 254) ||
        (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
        (b[0] == 192 && b[1] == 168) ||
        b[0] >= 224;
  }
  if (address.type == InternetAddressType.IPv6 && b.length == 16) {
    final mapped = b.sublist(0, 10).every((x) => x == 0) &&
        b[10] == 0xff &&
        b[11] == 0xff;
    if (mapped) {
      return isPrivateAddress(InternetAddress.fromRawAddress(
        b.sublist(12),
        type: InternetAddressType.IPv4,
      ));
    }
    return (b[0] & 0xfe) == 0xfc || // fc00::/7, unique local
        (b[0] == 0xfe && (b[1] & 0xc0) == 0x80) || // fe80::/10
        b.every((x) => x == 0); // ::
  }
  return true;
}

/// Cuts the middle of [text] when it is longer than [max], leaving its start
/// and end and saying how much went.
({String text, int cut}) shortenMiddle(String text, int max) {
  if (text.length <= max) return (text: text, cut: 0);
  final keep = max - 40;
  final head = (keep * 0.6).round();
  final tail = keep - head;
  final cut = text.length - head - tail;
  return (
    text: '${text.substring(0, head)}\n\n…$cut characters cut…\n\n'
        '${text.substring(text.length - tail)}',
    cut: cut,
  );
}

/// Tags stripped and entities decoded: what a search snippet reads as.
String plainText(String fragment) {
  if (!fragment.contains('<') && !fragment.contains('&')) return fragment.trim();
  final text = html_parser.parseFragment(fragment).text ?? '';
  return text.replaceAll(RegExp(r'\s+'), ' ').trim();
}

const Set<String> _dropTags = {
  'script', 'style', 'noscript', 'svg', 'nav', 'header', 'footer', 'aside',
  'form', 'iframe', 'template', 'button', 'select', 'canvas', 'object', 'video',
  'audio',
};

const Set<String> _blockTags = {
  'p', 'div', 'section', 'article', 'main', 'li', 'ul', 'ol', 'dl', 'dt', 'dd',
  'blockquote', 'pre', 'table', 'tr', 'figure', 'figcaption', 'aside', 'br',
  'hr', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'caption', 'details', 'summary',
};

/// Classes and ids that mark a wiki's chrome rather than its article — edit
/// links, reference markers, navigation boxes, tables of contents.
final RegExp _noise = RegExp(
  r'(^|\s)(mw-editsection|reference|navbox|toc|mw-jump-link|noprint|'
  r'catlinks|printfooter|mw-references-wrap|global-navigation|'
  r'page-footer|wds-global-footer|site-notice|cookie)(\s|$)',
);

/// A page's title and its readable words: scripts, styles, menus, headers and
/// footers dropped; the article (`main`, `article`, a wiki's content box) when
/// there is one, else the body; headings marked with `#`, list items with `-`,
/// blocks on their own lines.
({String title, String text}) htmlToText(String source) {
  final doc = html_parser.parse(source);
  final title = (doc.querySelector('title')?.text ?? '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  for (final tag in _dropTags) {
    for (final e in doc.querySelectorAll(tag).toList()) {
      e.remove();
    }
  }
  for (final e in doc.querySelectorAll('[class], [id], [role]').toList()) {
    final marks = '${e.className} ${e.id}';
    if (_noise.hasMatch(marks) || e.attributes['role'] == 'navigation') {
      e.remove();
    }
  }
  final root = doc.querySelector('.mw-parser-output') ??
      doc.querySelector('#mw-content-text') ??
      doc.querySelector('main') ??
      doc.querySelector('article') ??
      doc.body ??
      doc.documentElement;
  final out = StringBuffer();
  void walk(dom.Node node) {
    if (node is dom.Text) {
      out.write(node.text.replaceAll(RegExp(r'\s+'), ' '));
      return;
    }
    if (node is! dom.Element) return;
    final tag = node.localName ?? '';
    final block = _blockTags.contains(tag);
    if (block) out.write('\n');
    if (tag.length == 2 && tag[0] == 'h' && '123456'.contains(tag[1])) {
      out.write('${'#' * int.parse(tag[1])} ');
    } else if (tag == 'li') {
      out.write('- ');
    } else if (tag == 'td' || tag == 'th') {
      out.write(' | ');
    }
    for (final child in node.nodes) {
      walk(child);
    }
    if (block) out.write('\n');
  }

  if (root != null) walk(root);
  final text = out
      .toString()
      .split('\n')
      .map((l) => l.replaceAll(RegExp(r'[ \t]+'), ' ').trim())
      .join('\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
  return (title: title, text: text);
}

// --- reading DuckDuckGo -----------------------------------------------------

/// Whether [html] is DuckDuckGo's bot check ("bots use DuckDuckGo too") rather
/// than a results page.
bool isDuckDuckGoChallenge(String html) =>
    html.contains('anomaly-modal') ||
    html.contains('id="challenge-form"') ||
    html.contains('bots use DuckDuckGo too');

/// The results on a DuckDuckGo HTML results page, ads left out and at most
/// [kWebSearchResults] of them — an empty list when the page says it found
/// nothing, and null when it does not look like a results page at all (its
/// layout has changed), so that is never mistaken for "no results".
List<WebResult>? parseDuckDuckGo(String html) {
  final doc = html_parser.parse(html);
  final container =
      doc.querySelector('#links') ?? doc.querySelector('.results');
  if (container == null) return null;
  final out = <WebResult>[];
  for (final result in container.querySelectorAll('.result')) {
    final classes = result.classes;
    if (classes.contains('result--ad') ||
        classes.contains('result--no-result') ||
        result.querySelector('.badge--ad') != null) {
      continue;
    }
    final link = result.querySelector('a.result__a');
    if (link == null) continue;
    final url = unwrapDuckDuckGoLink(link.attributes['href'] ?? '');
    if (url == null) continue;
    final title = link.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final snippet = (result.querySelector('.result__snippet')?.text ?? '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    out.add(WebResult(
      title: title.isEmpty ? url : title,
      url: url,
      snippet: snippet,
    ));
    if (out.length >= kWebSearchResults) break;
  }
  if (out.isEmpty &&
      container.querySelector('.no-results, .result--no-result') == null &&
      container.querySelector('.result') == null) {
    // A container with neither results nor the page's own "no results" line
    // is not a page this parser knows.
    return null;
  }
  return out;
}

/// The address a DuckDuckGo result points at. Its links go through a redirect
/// (`//duckduckgo.com/l/?uddg=<the address>&rut=…`); this unwraps it. A plain
/// http(s) address is kept; anything else (an ad's tracking link, a relative
/// path) is null.
String? unwrapDuckDuckGoLink(String href) {
  final raw = href.trim();
  if (raw.isEmpty) return null;
  final uri = Uri.tryParse(raw.startsWith('//') ? 'https:$raw' : raw);
  if (uri == null) return null;
  final wrapped = uri.queryParameters['uddg'];
  if (wrapped != null && wrapped.isNotEmpty) {
    final target = Uri.tryParse(wrapped);
    return target != null && (target.isScheme('http') || target.isScheme('https'))
        ? wrapped
        : null;
  }
  if (uri.host.endsWith('duckduckgo.com')) return null;
  return uri.isScheme('http') || uri.isScheme('https') ? raw : null;
}
