import 'dart:convert';

import '../../models/character.dart';
import '../../models/discover.dart';
import '../character_codec.dart';
import 'discover_source.dart';

/// Botbooru (botbooru.com) — a booru for character cards: tagged uploads, many
/// of them re-hosted from elsewhere, each one a real SillyTavern card rather
/// than a picture of one.
///
/// The endpoints used here are the site's own: `/posts/` for the gallery,
/// `/download/json/{id}` for the card, `/images/preview/{size}/{file}` for a
/// thumbnail. Note that its `robots.txt` allows only `/$` and disallows `/api/`,
/// `/post/`, `/character/`, `/q/` and `/images/`: the feed and the download sit
/// outside those rules, the thumbnails do not. That rule is written for crawlers
/// — this fetches one page at a time, when someone scrolls — but it is a real
/// preference and worth knowing before this source grows any more appetite.
///
/// The download is the JSON card, not the PNG. Both exist; the PNG is the
/// artwork with the definition embedded and runs to megabytes, while the JSON is
/// tens of kilobytes. The picture arrives separately, at thumbnail size, which
/// is what a phone wanted anyway.
class BotbooruSource extends DiscoverSource {
  BotbooruSource({
    this.siteBase = 'https://botbooru.com',
    DiscoverHttp? http,
  }) : _http = http ?? DiscoverHttp();

  /// The site. Note there is no `www` host — it does not resolve.
  final String siteBase;

  final DiscoverHttp _http;

  /// The thumbnail tier the site's own gallery cards use.
  static const int previewSize = 320;

  /// The larger tier, for a detail header and the saved avatar.
  static const int avatarSize = 640;

  @override
  String get id => 'botbooru';

  @override
  String get label => 'Botbooru';

  @override
  String get blurb => 'botbooru.com — a tagged booru of character cards';

  @override
  String get homeUrl => siteBase;

  @override
  Set<DiscoverKind> get kinds => const <DiscoverKind>{DiscoverKind.character};

  /// Its search box subtracts a tag with a leading `-`, so exclusion is real.
  @override
  bool get supportsTagExclusion => true;

  @override
  List<DiscoverSort> sortsFor(DiscoverKind kind) => const <DiscoverSort>[
        DiscoverSort('curated', 'Curated'),
        DiscoverSort('latest', 'Latest'),
        DiscoverSort('favorites', 'Most favourited'),
        DiscoverSort('favorites:week', 'Most favourited (week)'),
        DiscoverSort('favorites:day', 'Most favourited (day)'),
        DiscoverSort('downloads', 'Most downloaded'),
        DiscoverSort('downloads:week', 'Most downloaded (week)'),
        DiscoverSort('views', 'Most viewed'),
        DiscoverSort('views:week', 'Most viewed (week)'),
        DiscoverSort('random', 'Random'),
      ];

  /// The site's popularity orders take their window as a separate `time_window`
  /// parameter (`day`, `week`, `month`; absent means all time). Ours are spelled
  /// `sort:window` in one value, because a feed has room for one ordering
  /// control rather than two.
  static (String, String?) splitSort(String sort) {
    final at = sort.indexOf(':');
    if (at < 0) return (sort.isEmpty ? 'latest' : sort, null);
    return (sort.substring(0, at), sort.substring(at + 1));
  }

  @override
  void close() => _http.close();

  // --- Feed ----------------------------------------------------------------

  /// The feed URL for [query]. Paging is `offset`/`limit`, so a page number has
  /// to be turned into an offset.
  ///
  /// Note what the adult switch can and cannot do: anonymous browsing is
  /// SFW-only server-side whatever the client asks for, so turning it on widens
  /// nothing without an account. It is still sent honestly.
  Uri searchUri(DiscoverQuery query) {
    final terms = <String>[
      if (query.search.trim().isNotEmpty) query.search.trim(),
      // A tag is just a search term here — the gallery's own tag links pass the
      // tag name as `q` — and a leading `-` subtracts one.
      for (final tag in query.includeTags)
        if (tag.trim().isNotEmpty) tag.trim(),
      for (final tag in query.excludeTags)
        if (tag.trim().isNotEmpty) '-${tag.trim()}',
    ];
    final (sort, window) = splitSort(query.sort);
    final params = <String, String>{
      'sort': sort,
      'limit': '${query.pageSize}',
      'offset': '${(query.page - 1) * query.pageSize}',
    };
    if (window != null) params['time_window'] = window;
    if (terms.isNotEmpty) params['q'] = terms.join(' ');
    if (!query.nsfw) params['sfw_only'] = 'true';
    return Uri.parse('$siteBase/posts/').replace(queryParameters: params);
  }

  @override
  Future<DiscoverPage> search(DiscoverQuery query) async {
    final decoded = await _http.getJson(searchUri(query));
    if (decoded is! Map<String, dynamic>) {
      throw const DiscoverException(
        'Botbooru answered its gallery in a shape the app could not read.',
      );
    }
    final posts = decoded['posts'];
    final items = <DiscoverItem>[];
    if (posts is List) {
      for (final post in posts.whereType<Map<String, dynamic>>()) {
        final item = itemFrom(post);
        if (item != null) items.add(item);
      }
    }
    final total = asInt(decoded['total']);
    final seen = (query.page - 1) * query.pageSize + items.length;
    return DiscoverPage(
      items: items,
      hasMore: total == null
          ? items.length >= query.pageSize
          : seen < total && items.isNotEmpty,
    );
  }

  /// Maps one post onto an item, or null without an id.
  DiscoverItem? itemFrom(Map<String, dynamic> post) {
    final postId = asString(pick(post, ['id'])).trim();
    if (postId.isEmpty) return null;
    final filename = asString(pick(post, ['filename'])).trim();
    final revision = asString(pick(post, ['card_image_revision'])).trim();
    // An uploader can rename a card for the booru without touching the card
    // itself; `meta_name` is that label and wins on the shelf, as it does on the
    // site.
    final metaName = asString(pick(post, ['meta_name'])).trim();
    final cardName = asString(pick(post, ['character_name'])).trim();
    final tags = tagNames(post['tags']);
    return DiscoverItem(
      sourceId: id,
      kind: DiscoverKind.character,
      id: postId,
      name: metaName.isNotEmpty ? metaName : cardName,
      // The booru credits the card's writer through a `writer:` tag, since an
      // upload's own account is the uploader, who is often someone else.
      creator: writerFrom(tags),
      tagline: stripHtml(asString(pick(post, ['tagline']))),
      description: stripHtml(asString(
        pick(post, ['description_excerpt', 'creator_notes_excerpt']),
      )),
      tags: tags,
      thumbnailUrl: previewUrl(filename, previewSize, revision),
      imageUrl: previewUrl(filename, avatarSize, revision),
      pageUrl: '$siteBase/character/$postId',
      tokens: asInt(pick(post, ['token_count'])),
      downloads: asInt(pick(post, ['downloads'])),
      favourites: asInt(pick(post, ['favorite_count'])),
      createdAt: asDate(pick(post, ['created_at'])),
      // Every post here is a card; a lorebook, when one exists, is embedded in
      // it and the listing does not say so.
      hasLore: false,
    );
  }

  /// Post tags arrive as objects — `{id, name, category}` — not strings.
  static List<String> tagNames(Object? raw) {
    if (raw is! List) return asStringList(raw);
    final names = <String>[];
    for (final entry in raw) {
      final name = entry is Map
          ? asString(pick(entry.cast<String, dynamic>(), ['name']))
          : asString(entry);
      final trimmed = name.trim();
      if (trimmed.isNotEmpty) names.add(trimmed);
    }
    return names;
  }

  /// The card's writer, read off the `writer:` tag the booru uses to credit
  /// whoever wrote the card — as distinct from whoever uploaded it here.
  static String writerFrom(List<String> tags) {
    for (final tag in tags) {
      final lower = tag.toLowerCase();
      if (lower.startsWith('writer:')) {
        final name = tag.substring('writer:'.length).trim();
        if (name.isNotEmpty) return name;
      }
    }
    return '';
  }

  /// A resized thumbnail. [revision] busts the CDN after an image is replaced in
  /// place, which the site does often enough to matter.
  String? previewUrl(String filename, int maxEdge, String revision) {
    if (filename.isEmpty) return null;
    final encoded = Uri.encodeComponent(filename);
    final bust = revision.isEmpty ? '' : '?v=$revision';
    return '$siteBase/images/preview/$maxEdge/$encoded$bust';
  }

  // --- Download ------------------------------------------------------------

  Uri cardUri(String postId) => Uri.parse('$siteBase/download/json/$postId');

  @override
  Future<DiscoverPayload> fetch(DiscoverItem item) async {
    final response = await _http.getBytes(
      cardUri(item.id),
      headers: const <String, String>{'Accept': 'application/json,*/*'},
    );
    Character character;
    try {
      character = CharacterCodec.parseJson(utf8.decode(response.bodyBytes));
    } on CharacterParseException catch (error) {
      throw DiscoverException(
        'Botbooru returned this card but the app could not read it '
        '(${error.message}).',
      );
    } on FormatException {
      throw const DiscoverException(
        'Botbooru returned something that is not a character card.',
      );
    }
    if (character.name.trim().isEmpty) character.name = item.name;
    if (character.tags.isEmpty && item.tags.isNotEmpty) {
      character.tags = List<String>.of(item.tags);
    }
    if (character.creator.trim().isEmpty && item.creator.isNotEmpty) {
      character.creator = item.creator;
    }
    await _fillAvatar(character, item);
    return DiscoverPayload(
      character: character,
      lorebook: embeddedLorebook(response.bodyBytes, name: character.name),
    );
  }

  /// The JSON card has no picture of its own — only a link to the booru's
  /// full-size original, over plain HTTP — so the booru's thumbnail is
  /// downloaded and kept as bytes instead. A saved character then survives the
  /// post being deleted, and a phone does not pull a multi-megabyte PNG to show
  /// a 40 px avatar.
  Future<void> _fillAvatar(Character character, DiscoverItem item) async {
    if (character.hasAvatar && !character.avatarIsUrl) return;
    final url = item.bestImageUrl;
    if (url == null) return;
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
      // Could not fetch it: a link is better than no face at all.
      if (!character.hasAvatar) character.avatar = url;
    }
  }

  // --- Tags ----------------------------------------------------------------

  /// Botbooru does publish a tag list, at `/tags/` — all of it, every tag with
  /// its counts, several megabytes. That is a poor trade for autocomplete on a
  /// phone, so suggestions are left empty and typing a tag still filters.
  @override
  Future<List<String>> tags(DiscoverKind kind) async => const <String>[];
}
