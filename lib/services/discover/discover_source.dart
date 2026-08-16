import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../models/discover.dart';
import '../../models/lorebook.dart';
import '../character_codec.dart';
import '../lorebook_codec.dart';

/// A user-facing failure while browsing or downloading from a catalogue. The
/// message is written to be shown as-is.
class DiscoverException implements Exception {
  const DiscoverException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Raised when a site will only answer a real browsing context — it served a
/// bot check rather than the page.
///
/// [pageUrl] is the page a browser view should open. Once the check clears, hand
/// the resulting HTML to [DiscoverSource.fetchFromHtml] to finish the download.
/// Kept a distinct type so the UI can offer that route instead of only
/// apologising.
class DiscoverChallengeException extends DiscoverException {
  const DiscoverChallengeException(super.message, this.pageUrl);

  final String pageUrl;
}

/// A remote catalogue MaiChat can browse: a feed of characters (and, where the
/// site has them, lorebooks or presets) plus the download that turns one result
/// into something the app owns.
///
/// Implementations are plain HTTP clients — nothing here needs a companion
/// server or a browser. Add one to [discoverSources] to surface it in Discover.
abstract class DiscoverSource {
  const DiscoverSource();

  /// Stable id, persisted in preferences and stamped on every item.
  String get id;

  /// The name shown on the source chip.
  String get label;

  /// One line about what this catalogue is, for the source picker.
  String get blurb;

  /// The site's own home page, for "Open in browser".
  String get homeUrl;

  /// Which sections this catalogue publishes. A section nothing supports still
  /// gets a bottom-bar destination — it just says so honestly.
  Set<DiscoverKind> get kinds;

  bool supports(DiscoverKind kind) => kinds.contains(kind);

  /// The orderings offered for [kind], most useful first. The first entry is the
  /// default.
  List<DiscoverSort> sortsFor(DiscoverKind kind);

  String defaultSortFor(DiscoverKind kind) {
    final sorts = sortsFor(kind);
    return sorts.isEmpty ? '' : sorts.first.value;
  }

  /// Whether the API can subtract tags as well as add them.
  bool get supportsTagExclusion => false;

  /// Tag suggestions for the filter sheet. Best-effort: an empty list simply
  /// means the sheet offers no suggestions.
  Future<List<String>> tags(DiscoverKind kind) async => const <String>[];

  /// One page of the feed. Throws [DiscoverException] on a user-facing failure.
  Future<DiscoverPage> search(DiscoverQuery query);

  /// Downloads [item] in full: a character's definition, a lorebook's entries.
  /// Throws [DiscoverException] when the catalogue will not hand it over, or
  /// [DiscoverChallengeException] when it will only answer a real browser.
  Future<DiscoverPayload> fetch(DiscoverItem item);

  /// Finishes a download from a page a browser view fetched, after
  /// [DiscoverChallengeException]. Only sources that raise that implement this.
  Future<DiscoverPayload> fetchFromHtml(DiscoverItem item, String html) =>
      throw const DiscoverException(
        'This catalogue does not read downloads from a page.',
      );

  /// Forgets anything learned about how to reach this site — which route worked,
  /// which was refused. A source may remember that plain HTTP is being blocked
  /// and stop trying it; this is how a manual retry gets a clean attempt, since
  /// the answer changes with the network the phone is on.
  void resetTransport() {}

  /// Releases the underlying HTTP client.
  void close() {}
}

/// Browser-ish headers. Several of these hosts (and their CDNs) reject plain
/// clients out of hand; this does not defeat a Cloudflare challenge, it only
/// keeps picky front doors open.
const Map<String, String> discoverHeaders = <String, String>{
  'User-Agent':
      'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) '
          'Chrome/124.0 Mobile Safari/537.36',
  'Accept-Language': 'en-US,en;q=0.9',
};

/// The shared HTTP plumbing every source uses: a request with a timeout, one
/// place that turns transport and status failures into sentences a person can
/// act on, and JSON decoding.
class DiscoverHttp {
  DiscoverHttp({http.Client? client, this.timeout = const Duration(seconds: 30)})
      : _client = client ?? http.Client(),
        _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;
  final Duration timeout;

  void close() {
    if (_ownsClient) _client.close();
  }

  /// A GET whose body is returned verbatim as bytes — used for card images and
  /// PNG cards.
  Future<http.Response> getBytes(Uri uri, {Map<String, String>? headers}) =>
      _send(http.Request('GET', uri), headers: headers);

  /// A GET that hands back whatever came, status and all.
  ///
  /// A bot check answers 403 with a body worth reading — it is the difference
  /// between "blocked, try a browser" and "gone" — so this one does not treat a
  /// status as fatal. Transport failures still throw.
  Future<http.Response> getRaw(Uri uri, {Map<String, String>? headers}) =>
      _send(http.Request('GET', uri), headers: headers, allowAnyStatus: true);

  /// A GET whose body is decoded as JSON.
  Future<Object?> getJson(Uri uri, {Map<String, String>? headers}) async {
    final response = await _send(
      http.Request('GET', uri),
      headers: <String, String>{'Accept': 'application/json', ...?headers},
    );
    return _decode(response, uri);
  }

  /// A POST of [body] as JSON, decoded as JSON.
  Future<Object?> postJson(
    Uri uri,
    Object? body, {
    Map<String, String>? headers,
  }) async {
    final request = http.Request('POST', uri)
      ..body = jsonEncode(body)
      ..encoding = utf8;
    final response = await _send(
      request,
      headers: <String, String>{
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        ...?headers,
      },
    );
    return _decode(response, uri);
  }

  Future<http.Response> _send(
    http.Request request, {
    Map<String, String>? headers,
    bool allowAnyStatus = false,
  }) async {
    request.headers.addAll(<String, String>{
      ...discoverHeaders,
      'Referer': '${request.url.scheme}://${request.url.host}/',
      ...?headers,
    });
    http.StreamedResponse streamed;
    try {
      streamed = await _client.send(request).timeout(timeout);
    } on SocketException {
      throw DiscoverException(
        'Could not reach ${request.url.host}. Check your connection.',
      );
    } catch (_) {
      throw DiscoverException('Could not reach ${request.url.host}.');
    }
    final response = await http.Response.fromStream(streamed);
    if (allowAnyStatus || response.statusCode == 200) return response;
    throw DiscoverException(describeStatus(request.url, response.statusCode));
  }

  Object? _decode(http.Response response, Uri uri) {
    try {
      return jsonDecode(response.body);
    } catch (_) {
      throw DiscoverException(
        '${uri.host} answered with something that is not JSON — it is '
        'probably showing a block page rather than its API.',
      );
    }
  }

  /// Turns an HTTP status into copy that says what to do about it.
  static String describeStatus(Uri uri, int status) {
    final host = uri.host;
    return switch (status) {
      401 || 403 => '$host refused the request (HTTP $status). It may be '
          'geo-blocked, or blocking non-browser downloads.',
      404 => 'Not found on $host (HTTP 404). It may have been taken down.',
      429 => '$host is rate-limiting us (HTTP 429). Wait a moment and retry.',
      503 => '$host is unavailable right now (HTTP 503).',
      _ => '$host answered HTTP $status.',
    };
  }
}

/// Reads the first present value out of [map] under any of [keys]. Chub in
/// particular is inconsistent per field — `starCount` beside `n_favorites` — so
/// nearly every read needs a camelCase and a snake_case spelling.
Object? pick(Map<String, dynamic> map, List<String> keys) {
  for (final key in keys) {
    final value = map[key];
    if (value != null) return value;
  }
  return null;
}

String asString(Object? value) {
  if (value == null) return '';
  if (value is String) return value;
  return '$value';
}

int? asInt(Object? value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

double? asDouble(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.trim());
  return null;
}

bool asBool(Object? value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) return value.toLowerCase() == 'true';
  return false;
}

List<String> asStringList(Object? value) {
  if (value is List) {
    return value
        .map((e) => asString(e).trim())
        .where((e) => e.isNotEmpty)
        .toList(growable: false);
  }
  if (value is String && value.trim().isNotEmpty) {
    return value.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  }
  return const <String>[];
}

/// Parses the several date shapes these APIs use: an ISO string, unix seconds,
/// or unix milliseconds.
DateTime? asDate(Object? value) {
  if (value is String) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    return DateTime.tryParse(trimmed);
  }
  if (value is num) {
    final n = value.toDouble();
    if (n <= 0) return null;
    // Seconds until they overflow a plausible date, then milliseconds.
    final ms = n > 100000000000 ? n : n * 1000;
    return DateTime.fromMillisecondsSinceEpoch(ms.round());
  }
  return null;
}

/// The lorebook a card carries in its own `character_book`, or null when it has
/// none.
///
/// Cards on every catalogue we speak to embed their world info this way, and the
/// character model does not hold it — so without this a download quietly threw
/// away the half of a character that makes it work. Failure is never fatal: a
/// book that cannot be read loses the book, not the character.
Lorebook? embeddedLorebook(Uint8List bytes, {String? name}) {
  final json = CharacterCodec.cardJsonOf(bytes);
  if (json == null || json.trim().isEmpty) return null;
  return lorebookFromCardJson(json, name: name);
}

/// [embeddedLorebook] for a card that is already a JSON document — the shape a
/// source builds itself out of a listing.
Lorebook? lorebookFromCardJson(String json, {String? name}) {
  List<Lorebook> books;
  try {
    books = LorebookCodec.parse(json);
  } catch (_) {
    return null;
  }
  if (books.isEmpty) return null;
  final book = books.first;
  if (book.entries.isEmpty) return null;
  // A card's book is usually nameless, and the codec falls back to a generic
  // label; naming it after the character is what makes it findable in the
  // Library.
  final label = name?.trim() ?? '';
  final current = book.name.trim();
  if (label.isNotEmpty && (current.isEmpty || current == 'Imported lorebook')) {
    book.name = "$label's lorebook";
  }
  return book;
}

/// Strips the HTML these catalogues put in their public blurbs, so a card shows
/// text rather than markup.
String stripHtml(String input) {
  if (input.isEmpty) return input;
  final withBreaks = input
      .replaceAll(RegExp(r'<\s*br\s*/?\s*>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</\s*p\s*>', caseSensitive: false), '\n\n');
  final bare = withBreaks.replaceAll(RegExp(r'<[^>]*>'), '');
  return bare
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}
