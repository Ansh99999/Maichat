import 'dart:convert';
import 'dart:math';

import '../../models/character.dart';
import '../../models/discover.dart';
import '../character_codec.dart';
import 'discover_source.dart';

/// DataCat (datacat.run) — an archive of JanitorAI and Saucepan characters,
/// extracted and kept readable. Two hundred thousand of them, and the definition
/// comes back as a ready-made V2 card, so nothing has to be reassembled here.
///
/// The catch is the door: **every** API call needs an `X-Session-Token`, and an
/// anonymous one is minted on request — `POST /api/liberator/identify` with a
/// device token of our own invention. So no account, but a handshake, and it has
/// to be repeated when the token lapses. [_ensureSession] is the only place that
/// happens; [resetTransport] throws the token away so a manual retry starts
/// clean.
///
/// Its `/download` endpoint is gated behind a Cloudflare Turnstile solve (a lease
/// good for twenty cards per half hour). We never call it: `/api/characters/{id}`
/// carries `chara_card_v2_json` in full, which is the same card without the
/// checkpoint. Worth remembering if that ever changes — the Character Library
/// extension went the download route and would now hit the same wall.
class DataCatSource extends DiscoverSource {
  DataCatSource({
    this.siteBase = 'https://datacat.run',
    DiscoverHttp? http,
    Random? random,
  })  : _http = http ?? DiscoverHttp(),
        _random = random ?? Random.secure();

  final String siteBase;
  final DiscoverHttp _http;
  final Random _random;

  String? _session;

  /// Where the last request for a given query stopped, since client-side adult
  /// filtering makes a page's worth of results cost an unpredictable number of
  /// rows.
  String _cursorKey = '';
  int _cursorOffset = 0;

  /// Cached name → numeric id for the tag filter, which takes ids only.
  Map<String, int>? _tagIds;

  /// The busiest tags, kept separately because the full list is unusable.
  List<String>? _popularTags;

  /// The site's own floor for what counts as a real card rather than a stub.
  static const int minTotalTokens = 889;

  @override
  String get id => 'datacat';

  @override
  String get label => 'DataCat';

  @override
  String get blurb => 'datacat.run — JanitorAI and Saucepan cards, archived';

  @override
  String get homeUrl => siteBase;

  @override
  Set<DiscoverKind> get kinds => const <DiscoverKind>{DiscoverKind.character};

  @override
  List<DiscoverSort> sortsFor(DiscoverKind kind) => const <DiscoverSort>[
        // The listing endpoint honours only one ordering; anything else is the
        // archive's own recency order.
        DiscoverSort('', 'Recently archived'),
        DiscoverSort('score', 'Top score'),
      ];

  @override
  void resetTransport() {
    _session = null;
    _cursorKey = '';
    _cursorOffset = 0;
  }

  @override
  void close() => _http.close();

  // --- Session -------------------------------------------------------------

  Uri get identifyUri => Uri.parse('$siteBase/api/liberator/identify');

  /// A random device token. The site only needs it to be stable-ish and unique;
  /// a fresh one each session means nothing is being tracked across runs.
  String newDeviceToken() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    String hex(int from, int to) => bytes
        .sublist(from, to)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
  }

  /// The current session token, minting one if there is none.
  Future<String> _ensureSession() async {
    final existing = _session;
    if (existing != null && existing.isNotEmpty) return existing;
    final decoded = await _http.postJson(
      identifyUri,
      <String, dynamic>{'deviceToken': newDeviceToken()},
      headers: <String, String>{'Origin': siteBase},
    );
    final token = decoded is Map
        ? asString(pick(decoded.cast<String, dynamic>(), ['sessionToken']))
        : '';
    if (token.trim().isEmpty) {
      throw const DiscoverException(
        'DataCat would not open a session, so its catalogue cannot be read '
        'right now.',
      );
    }
    _session = token.trim();
    return _session!;
  }

  /// A GET that carries the session token, re-opening the session once if the
  /// site says the token is no good.
  Future<Object?> _get(Uri uri) async {
    var token = await _ensureSession();
    var response = await _http.getRaw(uri, headers: _headers(token));
    if (response.statusCode == 401 || response.statusCode == 403) {
      _session = null;
      token = await _ensureSession();
      response = await _http.getRaw(uri, headers: _headers(token));
    }
    if (response.statusCode != 200) {
      throw DiscoverException(DiscoverHttp.describeStatus(uri, response.statusCode));
    }
    try {
      return jsonDecode(response.body);
    } catch (_) {
      throw DiscoverException(
        '${uri.host} answered with something that is not JSON.',
      );
    }
  }

  Map<String, String> _headers(String token) => <String, String>{
        'Accept': 'application/json',
        'X-Session-Token': token,
        'Origin': siteBase,
      };

  // --- Feed ----------------------------------------------------------------

  /// The feed URL for [query] at [offset]. Tags are numeric ids here, so they
  /// have to be resolved before this is built; unresolved tag names are folded
  /// into the text search instead of being dropped.
  Uri searchUri(
    DiscoverQuery query, {
    required int offset,
    List<int> tagIds = const <int>[],
  }) {
    final params = <String, String>{
      'limit': '${query.pageSize}',
      'offset': '$offset',
      'summary': '1',
      'minTotalTokens': '$minTotalTokens',
    };
    if (tagIds.isNotEmpty) params['tagIds'] = tagIds.join(',');
    final search = query.search.trim();
    if (search.isNotEmpty) params['search'] = search;
    if (query.sort.isNotEmpty) params['sortBy'] = query.sort;
    return Uri.parse('$siteBase/api/characters/recent-public')
        .replace(queryParameters: params);
  }

  @override
  Future<DiscoverPage> search(DiscoverQuery query) async {
    // Every row in this listing comes back flagged adult — checked across pages,
    // 48 of 48 and 24 of 24, `isNsfw: true` with no exceptions. Filtering on that
    // client-side would leave an empty feed above a "load more" button, so say
    // what is happening instead of showing nothing.
    if (!query.nsfw) {
      throw const DiscoverException(
        'DataCat marks every archived card as adult, so nothing is shown while '
        'adult results are off. Turn them on in the filter to browse it.',
      );
    }

    var effective = query;
    var ids = const <int>[];
    if (query.includeTags.isNotEmpty) {
      final resolved = await _resolveTags(query.includeTags);
      ids = resolved.ids;
      if (resolved.unresolved.isNotEmpty) {
        final extra = resolved.unresolved.join(' ');
        effective = query.copyWith(
          search: query.search.trim().isEmpty
              ? extra
              : '${query.search.trim()} $extra',
        );
      }
    }

    // Most of this archive is JanitorAI, and most of that is flagged adult, so
    // with the adult switch off a raw page can filter down to nothing while the
    // site still reports more. Keep asking rather than showing an empty feed
    // over a "load more" button; the Character Library does the same for the
    // same reason.
    //
    // Because filtering makes a page's worth of results cost an unpredictable
    // number of rows, the offset cannot be derived from the page number: it is
    // remembered from where the last request for this same query stopped.
    final key = _cursorKeyFor(effective, ids);
    var offset = (effective.page - 1) * effective.pageSize;
    if (effective.page > 1 && key == _cursorKey) offset = _cursorOffset;
    _cursorKey = key;

    final items = <DiscoverItem>[];
    var more = true;
    for (var attempt = 0; attempt < maxTopUpPages && more; attempt++) {
      final result = await _page(effective, ids, offset);
      items.addAll(result.page.items);
      more = result.page.hasMore;
      offset += result.returned;
      if (items.isNotEmpty) break;
    }
    _cursorOffset = offset;
    return DiscoverPage(items: items, hasMore: more);
  }

  /// Everything about a query except which page of it is wanted.
  static String _cursorKeyFor(DiscoverQuery query, List<int> ids) =>
      '${query.search.trim()}|${query.sort}|${query.nsfw}|${query.pageSize}|'
      '${ids.join(',')}';

  /// How many consecutive pages may be pulled to fill one screenful when the
  /// adult filter empties them.
  static const int maxTopUpPages = 5;

  Future<({DiscoverPage page, int returned})> _page(
    DiscoverQuery query,
    List<int> ids,
    int offset,
  ) async {
    final decoded = await _get(searchUri(query, offset: offset, tagIds: ids));
    if (decoded is! Map<String, dynamic>) {
      throw const DiscoverException(
        'DataCat answered its catalogue in a shape the app could not read.',
      );
    }
    final list = decoded['characters'];
    final items = <DiscoverItem>[];
    if (list is List) {
      for (final entry in list.whereType<Map<String, dynamic>>()) {
        final item = itemFrom(entry);
        if (item == null) continue;
        // No adult parameter on the listing; the flag on each record is what the
        // site's own filter uses.
        if (!query.nsfw && item.nsfw) continue;
        items.add(item);
      }
    }
    final more = decoded['hasMore'];
    final returned = list is List ? list.length : 0;
    return (
      page: DiscoverPage(
        items: items,
        hasMore: more is bool ? more : returned >= query.pageSize,
      ),
      returned: returned,
    );
  }

  /// Maps one archived record onto an item.
  ///
  /// Every field here exists twice, camelCase beside snake_case
  /// (`avatarDisplayUrl` and `avatar_display_url`), so reads go through [pick]
  /// with both spellings rather than trusting either.
  DiscoverItem? itemFrom(Map<String, dynamic> record) {
    final charId =
        asString(pick(record, ['characterId', 'character_id', 'id'])).trim();
    if (charId.isEmpty) return null;
    final image =
        asString(pick(record, ['avatarDisplayUrl', 'avatar_display_url', 'avatar']))
            .trim();
    final stats = record['stats'];
    final favourites = stats is Map
        ? _favouritesFrom(stats.cast<String, dynamic>())
        : null;
    return DiscoverItem(
      sourceId: id,
      kind: DiscoverKind.character,
      id: charId,
      name: asString(pick(record, ['name', 'chatName', 'chat_name'])).trim(),
      creator: asString(pick(record, ['creatorName', 'creator_name'])).trim(),
      description: stripHtml(
        asString(pick(record, ['description', 'rawDescription'])),
      ),
      tags: tagNames(pick(record, ['tags', 'custom_tags'])),
      thumbnailUrl: image.isEmpty ? null : image,
      imageUrl: image.isEmpty ? null : image,
      pageUrl: '$siteBase/characters/$charId',
      nsfw: asBool(pick(record, ['is_nsfw', 'isNsfw'])),
      tokens: asInt(pick(record, ['totalTokens', 'total_tokens'])),
      favourites: favourites,
      createdAt: asDate(pick(record, ['sourcePostedAt', 'source_posted_at'])),
      updatedAt: asDate(pick(record, ['createdAt', 'created_at'])),
    );
  }

  static int? _favouritesFrom(Map<String, dynamic> stats) {
    final nested = stats['favoritesCount'];
    if (nested is Map) {
      return asInt(pick(nested.cast<String, dynamic>(), ['favoritesCount']));
    }
    return asInt(nested);
  }

  /// Tags arrive as `{id, name, slug}` objects, and their names carry a leading
  /// emoji on this site — `👩‍🦰 Female` — so the label is trimmed to what a
  /// person would type.
  static List<String> tagNames(Object? raw) {
    if (raw is! List) return asStringList(raw);
    final names = <String>[];
    for (final entry in raw) {
      final name = entry is Map
          ? asString(pick(entry.cast<String, dynamic>(), ['slug', 'name']))
          : asString(entry);
      final trimmed = name.trim();
      if (trimmed.isNotEmpty) names.add(trimmed);
    }
    return names;
  }

  // --- Download ------------------------------------------------------------

  Uri detailUri(String charId) =>
      Uri.parse('$siteBase/api/characters/$charId');

  @override
  Future<DiscoverPayload> fetch(DiscoverItem item) async {
    final decoded = await _get(detailUri(item.id));
    final record = decoded is Map<String, dynamic>
        ? (decoded['character'] is Map<String, dynamic>
            ? decoded['character'] as Map<String, dynamic>
            : decoded)
        : null;
    if (record == null) {
      throw const DiscoverException(
        'DataCat did not return this character.',
      );
    }
    // The archive keeps a finished V2 card. When it is missing, the record's own
    // fields are the fallback — an extraction in progress has the parts but not
    // the card.
    final card = record['chara_card_v2_json'];
    final json = card is Map
        ? jsonEncode(card)
        : (card is String && card.trim().startsWith('{')
            ? card
            : jsonEncode(cardFrom(record)));
    Character character;
    try {
      character = CharacterCodec.parseJson(json);
    } on CharacterParseException catch (error) {
      throw DiscoverException(
        'DataCat returned this card but the app could not read it '
        '(${error.message}).',
      );
    }
    if (character.name.trim().isEmpty) character.name = item.name;
    if (character.creator.trim().isEmpty) character.creator = item.creator;
    if (character.tags.isEmpty && item.tags.isNotEmpty) {
      character.tags = List<String>.of(item.tags);
    }
    await _fillAvatar(character, item);
    return DiscoverPayload(
      character: character,
      lorebook: lorebookFromCardJson(json, name: character.name),
    );
  }

  /// A V2 card assembled from the record's own fields, for the case where the
  /// archive has not produced one. `extracted_first_message` is the greeting as
  /// recovered from a chat, which is sometimes all there is.
  Map<String, dynamic> cardFrom(Map<String, dynamic> record) =>
      <String, dynamic>{
        'spec': 'chara_card_v2',
        'spec_version': '2.0',
        'data': <String, dynamic>{
          'name': asString(pick(record, ['name', 'chat_name'])),
          'description': asString(pick(record, ['description'])),
          'personality': asString(pick(record, ['personality'])),
          'scenario': asString(pick(record, ['scenario'])),
          'first_mes': asString(
            pick(record, ['first_message', 'extracted_first_message']),
          ),
          'mes_example': '',
          'creator_notes': '',
          'alternate_greetings':
              asStringList(pick(record, ['alternate_greetings'])),
          'tags': tagNames(pick(record, ['tags', 'custom_tags'])),
          'creator': asString(pick(record, ['creator_name', 'creatorName'])),
          'character_version': '',
        },
      };

  Future<void> _fillAvatar(Character character, DiscoverItem item) async {
    if (character.hasAvatar && !character.avatarIsUrl) return;
    final url = character.avatarIsUrl ? character.avatar : item.bestImageUrl;
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
      if (!character.hasAvatar) character.avatar = url;
    }
  }

  // --- Tags ----------------------------------------------------------------

  Uri get tagsUri =>
      Uri.parse('$siteBase/api/tags/faceted?mode=recent&minTotalTokens=$minTotalTokens');

  /// The most-used tags, for the filter sheet's suggestions.
  ///
  /// The faceted endpoint returns **every** tag this archive has ever seen —
  /// nearly ninety thousand of them, most of them junk like `007n74saken` — so
  /// handing that list to a picker is not a suggestion, it is a denial of
  /// service. Only the busiest survive; any tag can still be typed.
  @override
  Future<List<String>> tags(DiscoverKind kind) async {
    await _tagMap();
    return _popularTags ?? const <String>[];
  }

  /// How many tag suggestions are worth offering.
  static const int tagSuggestionLimit = 200;

  Future<Map<String, int>> _tagMap() async {
    final cached = _tagIds;
    if (cached != null) return cached;
    final map = <String, int>{};
    final counted = <(String, int)>[];
    try {
      final decoded = await _get(tagsUri);
      final list = decoded is Map ? decoded['tags'] : null;
      if (list is List) {
        for (final entry in list.whereType<Map>()) {
          final tag = entry.cast<String, dynamic>();
          final tagId = asInt(pick(tag, ['id']));
          final slug = asString(pick(tag, ['slug'])).trim();
          final name = asString(pick(tag, ['name'])).trim();
          if (tagId == null) continue;
          if (slug.isNotEmpty) map[slug.toLowerCase()] = tagId;
          if (name.isNotEmpty) map.putIfAbsent(name.toLowerCase(), () => tagId);
          final label = slug.isNotEmpty ? slug : name;
          final count = asInt(pick(tag, ['count', 'characterCount', 'total'])) ?? 0;
          if (label.isNotEmpty) counted.add((label.toLowerCase(), count));
        }
      }
    } catch (_) {
      // Suggestions and id lookup are a convenience; a typed tag still narrows
      // the search text.
    }
    counted.sort((a, b) => b.$2.compareTo(a.$2));
    _popularTags = counted
        .take(tagSuggestionLimit)
        .map((e) => e.$1)
        .toList(growable: false);
    _tagIds = map;
    return map;
  }

  Future<({List<int> ids, List<String> unresolved})> _resolveTags(
    List<String> names,
  ) async {
    final map = await _tagMap();
    final ids = <int>[];
    final unresolved = <String>[];
    for (final name in names) {
      final key = name.trim().toLowerCase();
      if (key.isEmpty) continue;
      final tagId = map[key];
      if (tagId != null) {
        ids.add(tagId);
      } else {
        unresolved.add(name.trim());
      }
    }
    return (ids: ids, unresolved: unresolved);
  }
}
