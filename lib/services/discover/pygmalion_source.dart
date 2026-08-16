import 'dart:convert';

import '../../models/character.dart';
import '../../models/discover.dart';
import '../character_codec.dart';
import 'discover_source.dart';

/// Pygmalion (pygmalion.chat) — the project's own card catalogue.
///
/// Its API is Connect RPC rather than REST: one URL per method, and the request
/// travels as a JSON document in the `message` query parameter next to
/// `connect=v1&encoding=json`. That is the unary GET form, which is what an
/// unauthenticated caller gets; the POST form exists for signed-in requests and
/// is the only way to `includeSensitive`, so browsing here is SFW whatever the
/// adult switch says. [searchUri] is the one place that encoding lives.
///
/// The listing is metadata only — no definition, no tags — so a download is a
/// second call, and the site publishes a plain V2 card for that at
/// `/api/export/character/{id}/v2`, wrapped in a `character` envelope. That is
/// the same endpoint SillyTavern's own importer uses.
class PygmalionSource extends DiscoverSource {
  PygmalionSource({
    this.apiBase = 'https://server.pygmalion.chat',
    this.siteBase = 'https://pygmalion.chat',
    DiscoverHttp? http,
  }) : _http = http ?? DiscoverHttp();

  /// The API host, which serves both the RPC service and the card export.
  final String apiBase;

  /// The site itself, for "Open in browser".
  final String siteBase;

  final DiscoverHttp _http;

  /// The RPC service that answers without a token.
  static const String service = 'galatea.v1.PublicCharacterService';

  @override
  String get id => 'pygmalion';

  @override
  String get label => 'Pygmalion';

  @override
  String get blurb => 'pygmalion.chat — the Pygmalion project\'s own catalogue';

  @override
  String get homeUrl => siteBase;

  @override
  Set<DiscoverKind> get kinds => const <DiscoverKind>{DiscoverKind.character};

  @override
  bool get supportsTagExclusion => true;

  @override
  List<DiscoverSort> sortsFor(DiscoverKind kind) => const <DiscoverSort>[
        DiscoverSort('downloads', 'Most downloaded'),
        DiscoverSort('stars', 'Most starred'),
        DiscoverSort('views', 'Most viewed'),
        DiscoverSort('approved_at', 'Newest'),
      ];

  @override
  void close() => _http.close();

  // --- Feed ----------------------------------------------------------------

  /// The Connect RPC request for [query]. Pages are **0-indexed** here, unlike
  /// every other catalogue, so the app's 1-based page is shifted.
  Uri searchUri(DiscoverQuery query) {
    final message = <String, dynamic>{
      'query': query.search.trim(),
      'orderBy': query.sort.isEmpty ? 'downloads' : query.sort,
      'orderDescending': true,
      'pageSize': query.pageSize,
      'page': query.page - 1 < 0 ? 0 : query.page - 1,
    };
    if (query.includeTags.isNotEmpty) {
      message['tagsNamesInclude'] = query.includeTags;
    }
    if (query.excludeTags.isNotEmpty) {
      message['tagsNamesExclude'] = query.excludeTags;
    }
    return Uri.parse('$apiBase/$service/CharacterSearch').replace(
      queryParameters: <String, String>{
        'connect': 'v1',
        'encoding': 'json',
        'message': jsonEncode(message),
      },
    );
  }

  @override
  Future<DiscoverPage> search(DiscoverQuery query) async {
    final decoded = await _http.getJson(searchUri(query));
    if (decoded is! Map<String, dynamic>) {
      throw const DiscoverException(
        'Pygmalion answered its search in a shape the app could not read.',
      );
    }
    final list = decoded['characters'];
    final items = <DiscoverItem>[];
    if (list is List) {
      for (final hit in list.whereType<Map<String, dynamic>>()) {
        final item = itemFrom(hit);
        if (item != null) items.add(item);
      }
    }
    // `totalItems` arrives as a string, like every other number here.
    final total = asInt(decoded['totalItems']);
    final seen = (query.page - 1) * query.pageSize + items.length;
    return DiscoverPage(
      items: items,
      hasMore: total == null
          ? items.length >= query.pageSize
          : seen < total && items.isNotEmpty,
    );
  }

  /// Maps one hit onto an item, or null without an id.
  ///
  /// Every number in this API is quoted — `stars: "555"`, `createdAt:
  /// "1712088600"` — so counts go through [asInt] and dates through [asDate]
  /// after being read as an integer, or a 2024 upload parses as no date at all.
  DiscoverItem? itemFrom(Map<String, dynamic> hit) {
    final characterId = asString(pick(hit, ['id'])).trim();
    if (characterId.isEmpty) return null;
    final owner = hit['owner'];
    final creator = owner is Map
        ? asString(pick(owner.cast<String, dynamic>(),
            ['displayName', 'username', 'name']))
        : '';
    final avatar = asString(pick(hit, ['avatarUrl'])).trim();
    return DiscoverItem(
      sourceId: id,
      kind: DiscoverKind.character,
      id: characterId,
      name: asString(pick(hit, ['displayName', 'name'])).trim(),
      creator: creator.trim(),
      // The listing's `description` is the public blurb, not the definition.
      tagline: stripHtml(asString(pick(hit, ['description']))),
      tags: asStringList(pick(hit, ['tags'])),
      thumbnailUrl: avatar.isEmpty ? null : avatar,
      imageUrl: avatar.isEmpty ? null : avatar,
      pageUrl: '$siteBase/character/$characterId',
      tokens: asInt(pick(hit, ['personalityTokenCount'])),
      downloads: asInt(pick(hit, ['downloads'])),
      favourites: asInt(pick(hit, ['stars'])),
      createdAt: _date(pick(hit, ['createdAt'])),
      updatedAt: _date(pick(hit, ['updatedAt', 'approvedAt'])),
    );
  }

  static DateTime? _date(Object? raw) => asDate(asInt(raw) ?? raw);

  // --- Download ------------------------------------------------------------

  Uri cardUri(String characterId) =>
      Uri.parse('$apiBase/api/export/character/$characterId/v2');

  @override
  Future<DiscoverPayload> fetch(DiscoverItem item) async {
    final decoded = await _http.getJson(cardUri(item.id));
    // The export wraps the card: `{character: {spec, spec_version, data}}`.
    final card = decoded is Map && decoded['character'] is Map
        ? decoded['character']
        : decoded;
    if (card is! Map) {
      throw const DiscoverException(
        'Pygmalion did not return a character card for this one.',
      );
    }
    final json = jsonEncode(card);
    Character character;
    try {
      character = CharacterCodec.parseJson(json);
    } on CharacterParseException catch (error) {
      throw DiscoverException(
        'Pygmalion returned this card but the app could not read it '
        '(${error.message}).',
      );
    }
    if (character.name.trim().isEmpty) character.name = item.name;
    if (character.creator.trim().isEmpty) character.creator = item.creator;
    await _fillAvatar(character, item);
    return DiscoverPayload(
      character: character,
      lorebook: lorebookFromCardJson(json, name: character.name),
    );
  }

  /// The export names its avatar as a URL. Fetching the bytes means a saved
  /// character keeps its face if the CDN moves on.
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
}
