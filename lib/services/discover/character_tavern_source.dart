import '../../models/character.dart';
import '../../models/discover.dart';
import '../character_codec.dart';
import 'discover_source.dart';

/// Character Tavern (character-tavern.com) — a SillyTavern-format catalogue that
/// is unusually pleasant to talk to: one public JSON endpoint, no key, no bot
/// check, and a search index that already contains the whole definition.
///
/// Two facts shape this file:
///
/// - The feed is `GET /api/search/cards`, whose response is Meilisearch-shaped
///   (`hits` / `totalHits` / `page` / `totalPages`). Every filter the website
///   offers is a query parameter, so the site's own URL is the API's dialect.
/// - The card image and the *card* are the same URL with one parameter between
///   them. `<path>.png` is artwork with no metadata; `<path>.png?action=download`
///   is the real thing, carrying both `chara` and `ccv3` tEXt chunks. Getting
///   that wrong yields a picture and no character, so [cardUri] is the only
///   place either URL is built.
class CharacterTavernSource extends DiscoverSource {
  CharacterTavernSource({
    this.apiBase = 'https://character-tavern.com',
    this.cardBase = 'https://ct-cards.storage.character-tavern.com',
    DiscoverHttp? http,
  }) : _http = http ?? DiscoverHttp();

  /// The site, which also serves the search API.
  final String apiBase;

  /// The storage host that serves both the artwork and the card.
  final String cardBase;

  final DiscoverHttp _http;

  @override
  String get id => 'ctavern';

  @override
  String get label => 'Character Tavern';

  @override
  String get blurb => 'character-tavern.com — SillyTavern cards, lore included';

  @override
  String get homeUrl => apiBase;

  @override
  Set<DiscoverKind> get kinds => const <DiscoverKind>{DiscoverKind.character};

  @override
  bool get supportsTagExclusion => true;

  @override
  List<DiscoverSort> sortsFor(DiscoverKind kind) => const <DiscoverSort>[
        DiscoverSort('most_popular', 'Most popular'),
        DiscoverSort('trending', 'Trending (7d)'),
        DiscoverSort('most_likes', 'Most liked'),
        DiscoverSort('newest', 'Newest'),
        DiscoverSort('oldest', 'Oldest'),
      ];

  @override
  void close() => _http.close();

  // --- Feed ----------------------------------------------------------------

  /// The feed URL for [query].
  ///
  /// The site passes its own address bar straight through to this endpoint, so
  /// the parameter names are the ones visible while browsing: `query`, `sort`,
  /// `tags`, `exclude_tags`, `page`, `limit`.
  ///
  /// There is no adult switch. The site expresses "no adult results" by adding
  /// `nsfw` to `exclude_tags`, which is a server-side filter and therefore
  /// returns full pages; the Character Library extension does the same. Note
  /// that adult cards are only visible to a signed-in session anyway, so with no
  /// account this is belt as well as braces.
  Uri searchUri(DiscoverQuery query) {
    final params = <String, String>{
      'limit': '${query.pageSize}',
      'page': '${query.page}',
    };
    final search = query.search.trim();
    if (search.isNotEmpty) params['query'] = search;
    // An absent sort means the site's default, which is `most_popular`.
    if (query.sort.isNotEmpty) params['sort'] = query.sort;
    if (query.includeTags.isNotEmpty) {
      params['tags'] = query.includeTags.join(',');
    }
    final excluded = <String>[
      for (final tag in query.excludeTags)
        if (tag.trim().isNotEmpty) tag.trim(),
    ];
    if (!query.nsfw && !excluded.contains(adultTag)) excluded.add(adultTag);
    if (excluded.isNotEmpty) params['exclude_tags'] = excluded.join(',');
    return Uri.parse('$apiBase/api/search/cards')
        .replace(queryParameters: params);
  }

  /// The tag the site uses to mark adult cards.
  static const String adultTag = 'nsfw';

  @override
  Future<DiscoverPage> search(DiscoverQuery query) async {
    final decoded = await _http.getJson(searchUri(query));
    if (decoded is! Map<String, dynamic>) {
      throw const DiscoverException(
        'Character Tavern answered its search in a shape the app could not '
        'read.',
      );
    }
    final hits = decoded['hits'];
    final items = <DiscoverItem>[];
    if (hits is List) {
      for (final hit in hits.whereType<Map<String, dynamic>>()) {
        final item = itemFrom(hit);
        if (item == null) continue;
        // The exclude_tags filter does the work; this only catches a card marked
        // adult by its flag but not by its tags.
        if (!query.nsfw && item.nsfw) continue;
        items.add(item);
      }
    }
    final page = asInt(decoded['page']) ?? query.page;
    final totalPages = asInt(decoded['totalPages']) ?? 0;
    return DiscoverPage(items: items, hasMore: page < totalPages);
  }

  /// Maps one search hit onto an item, or null when it has no path — without
  /// `author/slug` there is nothing to download.
  DiscoverItem? itemFrom(Map<String, dynamic> hit) {
    final path = asString(pick(hit, ['path'])).trim();
    if (path.isEmpty) return null;
    final name = asString(pick(hit, ['name', 'inChatName'])).trim();
    final image = imageUri(path).toString();
    return DiscoverItem(
      sourceId: id,
      kind: DiscoverKind.character,
      // The path, not the `CT_…` id: it is what addresses both the card and the
      // page, and it is stable.
      id: path,
      name: name.isEmpty ? path.split('/').last : name,
      creator: asString(pick(hit, ['author'])).trim(),
      tagline: stripHtml(asString(pick(hit, ['tagline']))),
      // `pageDescription` is the creator's public write-up; the definition
      // fields sit beside it in the index and are deliberately not shown here.
      description: stripHtml(asString(pick(hit, ['pageDescription']))),
      tags: asStringList(pick(hit, ['tags'])),
      thumbnailUrl: image,
      imageUrl: image,
      pageUrl: '$apiBase/character/$path',
      nsfw: asBool(pick(hit, ['isNSFW'])),
      tokens: asInt(pick(hit, ['totalTokens'])),
      downloads: asInt(pick(hit, ['downloads'])),
      favourites: asInt(pick(hit, ['likes'])),
      createdAt: asDate(pick(hit, ['createdAt'])),
      updatedAt: asDate(pick(hit, ['lastUpdateAt'])),
      hasLore: asBool(pick(hit, ['hasLorebook'])),
    );
  }

  // --- Download ------------------------------------------------------------

  /// The artwork for [path] — a plain picture, no card metadata.
  Uri imageUri(String path) => Uri.parse('$cardBase/$path.png');

  /// The card for [path]. `action=download` is what makes the storage host
  /// answer with the PNG that has the definition embedded; without it the same
  /// URL returns the display image and the import finds nothing.
  Uri cardUri(String path) => Uri.parse('$cardBase/$path.png?action=download');

  @override
  Future<DiscoverPayload> fetch(DiscoverItem item) async {
    final response = await _http.getBytes(
      cardUri(item.id),
      headers: const <String, String>{'Accept': 'image/png,*/*'},
    );
    Character character;
    try {
      character = CharacterCodec.parseBytes(
        response.bodyBytes,
        filename: '${item.id.split('/').last}.png',
      );
    } on CharacterParseException catch (error) {
      throw DiscoverException(
        'Character Tavern returned this card but the app could not read it '
        '(${error.message}).',
      );
    }
    if (character.name.trim().isEmpty) character.name = item.name;
    if (character.creator.trim().isEmpty) character.creator = item.creator;
    if (character.tags.isEmpty && item.tags.isNotEmpty) {
      character.tags = List<String>.of(item.tags);
    }
    // These cards carry their world info in `character_book` — the site says as
    // much ("the open SillyTavern card and lorebook formats").
    return DiscoverPayload(
      character: character,
      lorebook: embeddedLorebook(response.bodyBytes, name: character.name),
    );
  }

  // --- Tags ----------------------------------------------------------------

  /// The site publishes no tag endpoint — its filter UI ships a fixed list — so
  /// these are the tags it offers, for suggestions only. Typing any other tag
  /// still works, because the API takes whatever it is given.
  static const List<String> knownTags = <String>[
    'action', 'adventure', 'anime', 'anime character', 'any pov', 'comedy',
    'contemporary', 'dominant', 'drama', 'english', 'fantasy', 'female',
    'game character', 'horror', 'human', 'love', 'male', 'multiple characters',
    'mystery', 'non-human', 'nsfw', 'oc', 'possible romance', 'roleplay',
    'romance', 'rpg', 'scenario', 'sci-fi', 'sfw', 'shy', 'slice of life',
    'submissive', 'supernatural', 'villain', 'wholesome',
  ];

  @override
  Future<List<String>> tags(DiscoverKind kind) async => knownTags;
}
