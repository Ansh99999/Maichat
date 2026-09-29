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

/// The Studio's window on the web: searching (Wikipedia and Fandom with no key,
/// or Brave / SearXNG when the user set one up) and reading one page as text.
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
  })  : _client = client ?? http.Client.new,
        _baseFor = baseFor ?? ((host) => 'https://$host');

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

  /// Searches for [query]. [site] narrows it: a Fandom wiki
  /// (`harrypotter.fandom.com`, or just `harrypotter` with `fandom:` in front),
  /// a Wikipedia (`fr.wikipedia.org`), or — with Brave or SearXNG set up — any
  /// site at all.
  Future<List<WebResult>> search(
    String query, {
    String? site,
    required StudioConfig config,
  }) async {
    final q = query.trim();
    if (q.isEmpty) throw WebError('The query is empty.');
    final target = site?.trim().toLowerCase() ?? '';
    final wiki = _wikiHost(target);
    if (wiki != null) return _mediaWiki(wiki, q);
    switch (config.searchProvider) {
      case StudioSearchProvider.brave:
        if (config.searchKey.trim().isEmpty) {
          throw WebError(
            'Brave Search has no key set up. Tell the user to add one in Studio '
            'settings ▸ Web research, or search Wikipedia or a Fandom wiki with '
            'site instead.',
          );
        }
        return _brave(target.isEmpty ? q : '$q site:$target', config.searchKey);
      case StudioSearchProvider.searxng:
        if (config.searchUrl.trim().isEmpty) {
          throw WebError(
            'No SearXNG address is set up. Search Wikipedia or a Fandom wiki '
            'with site instead.',
          );
        }
        return _searxng(
          target.isEmpty ? q : '$q site:$target',
          config.searchUrl.trim(),
        );
      case StudioSearchProvider.wiki:
        if (target.isNotEmpty) {
          throw WebError(
            'Without a web search set up, site can only be a Fandom wiki '
            '("name.fandom.com") or a Wikipedia ("en.wikipedia.org"). For any '
            'other site, web_fetch a page you know the address of.',
          );
        }
        return _mediaWiki('en.wikipedia.org', q);
    }
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
