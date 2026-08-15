import '../../models/character.dart';
import '../../models/discover.dart';
import '../character_codec.dart';
import '../character_sources.dart';
import 'discover_source.dart';

/// JannyAI's numeric tag ids, which is how its search index stores them. There
/// is no endpoint that lists them, so the map is part of the client — the same
/// way SillyTavern's Character Library extension carries it. Gaps (33, 35, 37,
/// 40, 58) are ids JannyAI has retired.
const Map<int, String> kJannyTags = <int, String>{
  1: 'Male', 2: 'Female', 3: 'Non-binary', 4: 'Celebrity', 5: 'OC',
  6: 'Fictional', 7: 'Real', 8: 'Game', 9: 'Anime', 10: 'Historical',
  11: 'Royalty', 12: 'Detective', 13: 'Hero', 14: 'Villain', 15: 'Magical',
  16: 'Non-human', 17: 'Monster', 18: 'Monster Girl', 19: 'Alien', 20: 'Robot',
  21: 'Politics', 22: 'Vampire', 23: 'Giant', 24: 'OpenAI', 25: 'Elf',
  26: 'Multiple', 27: 'VTuber', 28: 'Dominant', 29: 'Submissive',
  30: 'Scenario', 31: 'Pokemon', 32: 'Assistant', 34: 'Non-English',
  36: 'Philosophy', 38: 'RPG', 39: 'Religion', 41: 'Books', 42: 'AnyPOV',
  43: 'Angst', 44: 'Demi-Human', 45: 'Enemies to Lovers', 46: 'Smut',
  47: 'MLM', 48: 'WLW', 49: 'Action', 50: 'Romance', 51: 'Horror',
  52: 'Slice of Life', 53: 'Fantasy', 54: 'Drama', 55: 'Comedy',
  56: 'Mystery', 57: 'Sci-Fi', 59: 'Yandere', 60: 'Furry', 61: 'Movies/TV',
};

/// JannyAI — characters only.
///
/// Browsing is a raw MeiliSearch instance, which is public and answers a plain
/// HTTP client happily. Downloading is the other half of the site and goes
/// through `api.jannyai.com`, which sits behind Cloudflare: it works from a
/// phone or a home connection and is refused from a datacentre. That is why the
/// feed can be full while a download fails, and why the failure says so.
class JannySource extends DiscoverSource {
  JannySource({
    this.searchBase = 'https://search.jannyai.com',
    this.downloadBase = 'https://api.jannyai.com',
    this.imageBase = 'https://image.jannyai.com/bot-avatars',
    this.siteBase = 'https://jannyai.com',
    this.searchToken = kJannySearchToken,
    DiscoverHttp? http,
  }) : _http = http ?? DiscoverHttp();

  /// The public MeiliSearch key JannyAI's own web client uses. It is a
  /// search-only key published in the site's JavaScript bundle.
  static const String kJannySearchToken =
      '88a6463b66e04fb07ba87ee3db06af337f492ce511d93df6e2d2968cb2ff2b30';

  /// The lowest token count JannyAI's own search page asks for, which filters
  /// out empty placeholder bots.
  static const int minTokens = 29;

  final String searchBase;
  final String downloadBase;
  final String imageBase;
  final String siteBase;
  final String searchToken;

  final DiscoverHttp _http;

  @override
  String get id => 'janny';

  @override
  String get label => 'JannyAI';

  @override
  String get blurb => 'JannyAI / JanitorAI cards — characters';

  @override
  String get homeUrl => siteBase;

  @override
  Set<DiscoverKind> get kinds => const <DiscoverKind>{DiscoverKind.character};

  @override
  List<DiscoverSort> sortsFor(DiscoverKind kind) => const <DiscoverSort>[
        DiscoverSort('createdAtStamp:desc', 'Newest'),
        DiscoverSort('totalToken:desc', 'Most detailed'),
        DiscoverSort('totalToken:asc', 'Shortest'),
        DiscoverSort('createdAtStamp:asc', 'Oldest'),
        DiscoverSort('', 'Relevance'),
      ];

  @override
  Future<List<String>> tags(DiscoverKind kind) async {
    final names = kJannyTags.values.toList()..sort();
    return names;
  }

  @override
  void close() => _http.close();

  // --- Feed ----------------------------------------------------------------

  Uri get searchUri => Uri.parse('$searchBase/multi-search');

  /// The MeiliSearch envelope for [query]. Filters are separate expressions,
  /// which the index combines with AND.
  Map<String, dynamic> searchBody(DiscoverQuery query) {
    final filters = <String>['totalToken >= $minTokens'];
    if (!query.nsfw) filters.add('isNsfw = false');
    // Low-quality is JannyAI's own flag for near-empty cards.
    filters.add('isLowQuality = false');
    final tagIds = query.includeTags
        .map(tagIdFor)
        .whereType<int>()
        .map((id) => 'tagIds = $id')
        .toList();
    if (tagIds.isNotEmpty) filters.add(tagIds.join(' AND '));

    final search = <String, dynamic>{
      'indexUid': 'janny-characters',
      'q': query.search.trim(),
      'filter': filters,
      'hitsPerPage': query.pageSize,
      'page': query.page,
    };
    // An empty sort is relevance; MeiliSearch rejects an empty sort array.
    if (query.sort.isNotEmpty) search['sort'] = <String>[query.sort];
    return <String, dynamic>{
      'queries': <Map<String, dynamic>>[search],
    };
  }

  Map<String, String> get searchHeaders => <String, String>{
        'Authorization': 'Bearer $searchToken',
        'Origin': siteBase,
        'Referer': '$siteBase/',
      };

  /// The id JannyAI stores for a tag name, or null when the name is not one of
  /// its tags. The index only filters by id, so a free-text tag cannot be sent.
  static int? tagIdFor(String name) {
    final wanted = name.trim().toLowerCase();
    for (final entry in kJannyTags.entries) {
      if (entry.value.toLowerCase() == wanted) return entry.key;
    }
    return null;
  }

  /// The trailing part of a character page's path. JannyAI ignores it when
  /// resolving the page, but a link that reads `…_character-aria` is the one a
  /// person would recognise if they open it in a browser.
  static String _slug(String name) {
    final slug = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final trimmed = slug.length <= 50 ? slug : slug.substring(0, 50);
    return trimmed.isEmpty ? 'character' : 'character-$trimmed';
  }

  @override
  Future<DiscoverPage> search(DiscoverQuery query) async {
    final decoded = await _http.postJson(
      searchUri,
      searchBody(query),
      headers: searchHeaders,
    );
    final results = decoded is Map ? decoded['results'] : null;
    if (results is! List || results.isEmpty) {
      return const DiscoverPage.empty();
    }
    final first = results.first;
    if (first is! Map) return const DiscoverPage.empty();
    final result = first.cast<String, dynamic>();
    final hits = result['hits'];
    final items = <DiscoverItem>[];
    if (hits is List) {
      for (final hit in hits.whereType<Map>()) {
        final item = itemFrom(hit.cast<String, dynamic>());
        if (item != null) items.add(item);
      }
    }
    final totalPages = asInt(result['totalPages']) ?? 0;
    return DiscoverPage(
      items: items,
      hasMore: query.page < totalPages,
    );
  }

  DiscoverItem? itemFrom(Map<String, dynamic> hit) {
    final uuid = asString(pick(hit, ['id'])).trim();
    if (uuid.isEmpty) return null;
    final avatar = asString(pick(hit, ['avatar'])).trim();
    final creator = asString(pick(hit, ['creatorUsername'])).trim();
    final tagIds = pick(hit, ['tagIds']);
    final tags = <String>[];
    if (tagIds is List) {
      for (final raw in tagIds) {
        final tagId = asInt(raw);
        if (tagId == null) continue;
        tags.add(kJannyTags[tagId] ?? 'Tag $tagId');
      }
    }
    final name = asString(pick(hit, ['name'])).trim();

    return DiscoverItem(
      sourceId: id,
      kind: DiscoverKind.character,
      id: uuid,
      name: name.isEmpty ? 'Unnamed' : name,
      creator: creator.isEmpty
          ? asString(pick(hit, ['creatorId'])).trim()
          : creator,
      // JannyAI's `description` is the public blurb, in HTML — not the
      // definition, which only the card download carries.
      description: stripHtml(asString(pick(hit, ['description']))),
      tags: tags,
      thumbnailUrl: avatar.isEmpty ? null : '$imageBase/$avatar',
      pageUrl: '$siteBase/characters/${uuid}_${_slug(name)}',
      nsfw: asBool(pick(hit, ['isNsfw'])),
      tokens: asInt(pick(hit, ['totalToken'])),
      createdAt: asDate(pick(hit, ['createdAt', 'createdAtStamp'])),
    );
  }

  // --- Download ------------------------------------------------------------

  @override
  Future<DiscoverPayload> fetch(DiscoverItem item) async {
    SourcePayload payload;
    try {
      payload = await UrlSource.fetchJannyCard(
        <String>[item.id],
        apiBase: downloadBase,
      );
    } on CharacterParseException catch (error) {
      throw DiscoverException(error.message);
    }
    Character character;
    try {
      character = CharacterCodec.parseBytes(
        payload.bytes,
        filename: payload.filename,
      );
    } on CharacterParseException catch (error) {
      throw DiscoverException(error.message);
    }
    // The feed knows things the card file does not bother to carry.
    if (character.tags.isEmpty && item.tags.isNotEmpty) {
      character.tags = List<String>.of(item.tags);
    }
    if (character.creator.trim().isEmpty) character.creator = item.creator;
    if (character.creatorNotes.trim().isEmpty) {
      character.creatorNotes = item.description;
    }
    final thumbnail = item.thumbnailUrl;
    if (character.avatar.trim().isEmpty && thumbnail != null) {
      character.avatar = thumbnail;
    }
    return DiscoverPayload(character: character);
  }
}
