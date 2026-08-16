import 'dart:convert';

import '../../models/character.dart';
import '../../models/discover.dart';
import '../character_codec.dart';
import 'discover_source.dart';
import 'sveltekit_data.dart';

/// RisuRealm (realm.risuai.net) — RisuAI's card-sharing site.
///
/// Realm is the one catalogue here that publishes a rulebook. Its API docs
/// (`/help/api`) describe exactly one endpoint, the download, and say plainly
/// that undocumented endpoints are not allowed. So the download below is the
/// documented call, used the documented way, including `non_commercial=true`,
/// which is a promise about how the card is used rather than a switch that
/// unlocks more of them.
///
/// The feed has no documented endpoint. It reads the same page data the site's
/// own client reads while browsing — `/__data.json` with the query the address
/// bar carries — decoded by [SvelteKitData]. It is one request per page of
/// results, at the rate a person taps, and nothing is crawled.
///
/// Two site behaviours are load-bearing:
///
/// - **`recommended` is a first page only.** It is the default order (send no
///   `sort` at all) and asking it for page 2 answers HTTP 500. Every other order
///   paginates, so [searchUri] only sends `page` when the order supports it.
/// - **A card's format is not the app's choice.** Cards with assets — RisuAI's
///   own CharX — refuse `png-v3` with "not allowed to be downloaded in this
///   format", while plain cards refuse nothing. [_formats] therefore walks
///   json → png → charx rather than assuming one works.
///
/// Modules and presets are deliberately absent. The module listing comes back
/// empty, and a preset downloads as RisuAI's own binary format, which nothing in
/// this app can read.
class RisuRealmSource extends DiscoverSource {
  RisuRealmSource({
    this.siteBase = 'https://realm.risuai.net',
    this.resourceBase = 'https://sv.risuai.xyz/resource',
    DiscoverHttp? http,
  }) : _http = http ?? DiscoverHttp();

  /// The site, which serves both the page data and the download API.
  final String siteBase;

  /// Where a card's `img` hash resolves to a picture.
  final String resourceBase;

  final DiscoverHttp _http;

  /// The site's own page size for every order except `recommended`, which
  /// returns two pages' worth at once.
  static const int pageSize = 30;

  /// The order that cannot be paged, spelled the way the site spells it: by
  /// sending no `sort` parameter at all.
  static const String recommended = 'recommended';

  /// Our name for "no order", which the site sends as an empty `sort`. It cannot
  /// be the empty string here, because an empty [DiscoverSort] value means "send
  /// nothing", which is how `recommended` is expressed.
  static const String latest = 'latest';

  /// The site's cap on a search: ten keywords, 200 characters.
  static const int maxKeywords = 10;
  static const int maxQueryLength = 200;

  @override
  String get id => 'risurealm';

  @override
  String get label => 'RisuRealm';

  @override
  String get blurb => 'realm.risuai.net — RisuAI cards, CharX and all';

  @override
  String get homeUrl => siteBase;

  @override
  Set<DiscoverKind> get kinds => const <DiscoverKind>{DiscoverKind.character};

  /// Realm subtracts a keyword with a leading `!`, so exclusion is real.
  @override
  bool get supportsTagExclusion => true;

  @override
  List<DiscoverSort> sortsFor(DiscoverKind kind) => const <DiscoverSort>[
        DiscoverSort(recommended, 'Recommended'),
        DiscoverSort('downloads', 'Most downloaded'),
        DiscoverSort('trending', 'Trending'),
        DiscoverSort(latest, 'Latest'),
      ];

  @override
  void close() => _http.close();

  // --- Feed ----------------------------------------------------------------

  /// Realm's search syntax, built from the parts of [query]: bare words match
  /// the title and tags, `tag:` an exact tag, and a leading `!` subtracts.
  ///
  /// Clamped to the site's documented limits, so a long tag list quietly loses
  /// its tail rather than being rejected whole.
  static String searchExpression(DiscoverQuery query) {
    final keywords = <String>[
      for (final word in query.search.trim().split(RegExp(r'\s+')))
        if (word.isNotEmpty) word,
      for (final tag in query.includeTags)
        if (tag.trim().isNotEmpty) 'tag:${tag.trim()}',
      for (final tag in query.excludeTags)
        if (tag.trim().isNotEmpty) '!${tag.trim()}',
    ];
    final kept = <String>[];
    var length = 0;
    for (final keyword in keywords.take(maxKeywords)) {
      final extra = kept.isEmpty ? keyword.length : keyword.length + 1;
      if (length + extra > maxQueryLength) break;
      kept.add(keyword);
      length += extra;
    }
    return kept.join(' ');
  }

  /// Whether [sort] can be asked for a page beyond the first.
  static bool paginates(String sort) => sort != recommended;

  Uri searchUri(DiscoverQuery query) {
    final sort = query.sort.isEmpty ? recommended : query.sort;
    final params = <String, String>{'mode': 'character'};
    if (sort != recommended) {
      // `latest` is an empty sort on the wire; the others are their own names.
      params['sort'] = sort == latest ? '' : sort;
      if (query.page > 1) params['page'] = '${query.page}';
    }
    final expression = searchExpression(query);
    if (expression.isNotEmpty) params['q'] = expression;
    // Absent rather than false: the site treats the parameter's presence as the
    // switch.
    if (query.nsfw) params['nsfw'] = 'true';
    return Uri.parse('$siteBase/__data.json').replace(queryParameters: params);
  }

  @override
  Future<DiscoverPage> search(DiscoverQuery query) async {
    final decoded = await _http.getJson(searchUri(query));
    final data = SvelteKitData.decodeDocument(decoded);
    final cards = data is Map<String, dynamic> ? data['cards'] : null;
    if (cards is! List) {
      throw const DiscoverException(
        'RisuRealm did not return a page of cards. Its site may have changed.',
      );
    }
    final items = <DiscoverItem>[];
    for (final card in cards.whereType<Map<String, dynamic>>()) {
      final item = itemFrom(card);
      if (item != null) items.add(item);
    }
    final sort = query.sort.isEmpty ? recommended : query.sort;
    return DiscoverPage(
      items: items,
      hasMore: paginates(sort) && cards.length >= pageSize,
    );
  }

  /// Maps one listing card onto an item, or null without an id.
  DiscoverItem? itemFrom(Map<String, dynamic> card) {
    final cardId = asString(pick(card, ['id'])).trim();
    if (cardId.isEmpty) return null;
    final image = imageUrlFor(asString(pick(card, ['img'])));
    return DiscoverItem(
      sourceId: id,
      kind: DiscoverKind.character,
      id: cardId,
      name: asString(pick(card, ['name'])).trim(),
      creator: asString(pick(card, ['authorname'])).trim(),
      description: stripHtml(asString(pick(card, ['desc']))),
      tags: asStringList(pick(card, ['tags'])),
      thumbnailUrl: image,
      imageUrl: image,
      pageUrl: '$siteBase/character/$cardId',
      downloads: parseCount(asString(pick(card, ['download']))),
      createdAt: parseDate(pick(card, ['date'])),
      hasLore: asBool(pick(card, ['haslore'])),
    );
  }

  /// Realm reports a download count already abbreviated for display — `2.5k`,
  /// `21.9k` — so it arrives as a string, not a number.
  static int? parseCount(String raw) {
    final text = raw.trim().toLowerCase();
    if (text.isEmpty) return null;
    final match = RegExp(r'^([0-9]*\.?[0-9]+)\s*([km])?$').firstMatch(text);
    if (match == null) return int.tryParse(text.replaceAll(',', ''));
    final value = double.tryParse(match.group(1)!);
    if (value == null) return null;
    final multiplier = switch (match.group(2)) {
      'k' => 1000,
      'm' => 1000000,
      _ => 1,
    };
    return (value * multiplier).round();
  }

  /// Card dates are **minutes** since the epoch, not seconds — read as seconds a
  /// 2026 upload lands in 1971.
  static DateTime? parseDate(Object? raw) {
    final minutes = asInt(raw);
    if (minutes == null || minutes <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(minutes * 60 * 1000);
  }

  /// A card's `img` is a content hash on Risu's resource host. Cards without a
  /// picture carry the site's own placeholder, which is not worth downloading.
  String? imageUrlFor(String img) {
    final hash = img.trim();
    if (hash.isEmpty || hash.endsWith('.webp') || hash.contains('placeholder')) {
      return null;
    }
    if (hash.startsWith('http')) return hash;
    return '$resourceBase/$hash';
  }

  // --- Download ------------------------------------------------------------

  /// The documented download formats, cheapest first. `json-v3` is a few
  /// kilobytes and already carries the embedded lorebook; `png-v3` brings the
  /// picture; `charx-v3` is the only format an asset-heavy card allows, and can
  /// run to tens of megabytes.
  static const List<String> _formats = <String>['json-v3', 'png-v3', 'charx-v3'];

  Uri downloadUri(String cardId, String format) => Uri.parse(
        '$siteBase/api/v1/download/$format/$cardId?non_commercial=true',
      );

  /// The file extension a download format arrives as, which is how the codec
  /// tells a zip from a picture from a card.
  static String extensionFor(String format) {
    if (format.startsWith('charx')) return 'charx';
    if (format.startsWith('png')) return 'png';
    return 'json';
  }

  @override
  Future<DiscoverPayload> fetch(DiscoverItem item) async {
    String? refusal;
    for (final format in _formats) {
      final response = await _http.getRaw(
        downloadUri(item.id, format),
        headers: const <String, String>{'Accept': '*/*'},
      );
      final bytes = response.bodyBytes;
      // Realm answers a refused format with a JSON body — sometimes under a 4xx,
      // sometimes under a 200 — so the body decides, not the status.
      final complaint = errorMessage(bytes);
      if (complaint != null) {
        refusal ??= complaint;
        continue;
      }
      if (response.statusCode != 200 || bytes.isEmpty) continue;
      Character character;
      try {
        character = CharacterCodec.parseBytes(
          bytes,
          filename: '${item.id}.${extensionFor(format)}',
        );
      } on CharacterParseException {
        continue;
      }
      await _fillAvatar(character, item);
      if (character.name.trim().isEmpty) character.name = item.name;
      if (character.creator.trim().isEmpty) character.creator = item.creator;
      // Realm's v3 cards carry their world info inline, which is most of why
      // `json-v3` is worth preferring.
      return DiscoverPayload(
        character: character,
        lorebook: embeddedLorebook(bytes, name: character.name),
      );
    }
    throw DiscoverException(
      refusal ??
          'RisuRealm would not hand over this card in any format the app can '
              'read.',
    );
  }

  /// The complaint in a JSON error body, or null when the bytes are a card.
  ///
  /// Realm's own wording is worth passing through: "This card is not allowed to
  /// be downloaded in this format" tells the user something true, where a
  /// generic failure would not.
  static String? errorMessage(List<int> bytes) {
    if (bytes.isEmpty) return null;
    // A card is a PNG or a zip; only JSON can be an error, and a real json-v3
    // card is a JSON object too, so the keys have to be read.
    if (bytes.first != 0x7b) return null; // '{'
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final message = asString(pick(decoded.cast<String, dynamic>(), ['message']));
    final error = asString(pick(decoded.cast<String, dynamic>(), ['error']));
    if (message.isEmpty && error.isEmpty) return null;
    final text = message.isNotEmpty ? message : error;
    return 'RisuRealm declined this download: $text';
  }

  /// Brings the listing's picture along when the card carries none of its own —
  /// a `json-v3` download never does — or when it carries only a link, which
  /// stops being a face the moment the host moves it.
  Future<void> _fillAvatar(Character character, DiscoverItem item) async {
    if (character.hasAvatar && !character.avatarIsUrl) return;
    final url = item.bestImageUrl;
    if (url == null || !url.startsWith('http')) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      final response = await _http.getBytes(
        uri,
        headers: const <String, String>{'Accept': 'image/*,*/*'},
      );
      if (response.bodyBytes.isNotEmpty) {
        character.avatar = base64Encode(response.bodyBytes);
      }
    } catch (_) {
      // A missing picture is not a failed download.
      if (!character.hasAvatar) character.avatar = url;
    }
  }
}
