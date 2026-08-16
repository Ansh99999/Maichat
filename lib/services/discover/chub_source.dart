import 'dart:convert';

import '../../models/character.dart';
import '../../models/discover.dart';
import '../../models/lorebook.dart';
import '../character_codec.dart';
import '../lorebook_codec.dart';
import 'discover_source.dart';

/// Chub (Venus / CharacterHub) — the largest open catalogue, and the only one
/// that publishes lorebooks as things of their own rather than as an attachment
/// to a character.
///
/// Everything here is public: no account, no token, no companion server. The
/// field names are the awkward part. Chub's API predates the V2 card spec and
/// does not line up with it — `definition.personality` is the *description* and
/// `definition.description` is the *creator's notes*. Getting that backwards is
/// the classic mistake, so [_cardFromDefinition] is the one place it is written
/// down. SillyTavern's `downloadChubCharacter()` maps it the same way.
///
/// Casing is inconsistent per field rather than per response — `starCount`
/// sits beside `n_favorites` — so reads go through [pick] with both spellings.
class ChubSource extends DiscoverSource {
  ChubSource({
    this.apiBase = 'https://api.chub.ai',
    this.avatarBase = 'https://avatars.charhub.io/avatars',
    this.siteBase = 'https://chub.ai',
    DiscoverHttp? http,
  }) : _http = http ?? DiscoverHttp();

  /// `https://api.chub.ai` in production; overridden in tests.
  final String apiBase;

  /// Where derived avatar URLs point.
  final String avatarBase;

  /// The site itself, for "Open in browser" links.
  final String siteBase;

  final DiscoverHttp _http;

  /// Cached tag names from `POST /tags`, which is a single large response.
  List<String>? _tagCache;

  @override
  String get id => 'chub';

  @override
  String get label => 'Chub';

  @override
  String get blurb => 'Venus / CharacterHub — characters and lorebooks';

  @override
  String get homeUrl => siteBase;

  @override
  Set<DiscoverKind> get kinds =>
      const <DiscoverKind>{DiscoverKind.character, DiscoverKind.lorebook};

  @override
  bool get supportsTagExclusion => true;

  @override
  List<DiscoverSort> sortsFor(DiscoverKind kind) => const <DiscoverSort>[
        DiscoverSort('download_count', 'Most downloaded'),
        DiscoverSort('trending', 'Trending'),
        DiscoverSort('star_count', 'Top rated'),
        DiscoverSort('n_favorites', 'Most favourited'),
        DiscoverSort('rating', 'Highest rated'),
        DiscoverSort('id', 'Newest'),
        DiscoverSort('last_activity_at', 'Recently updated'),
        DiscoverSort('n_tokens', 'Longest'),
        DiscoverSort('random', 'Random'),
        DiscoverSort('', 'Relevance'),
      ];

  @override
  void close() => _http.close();

  // --- Feed ----------------------------------------------------------------

  /// The feed URL for [query]. `namespace=lorebooks` is what switches the same
  /// endpoint from characters to lorebooks.
  Uri searchUri(DiscoverQuery query) {
    final params = <String, String>{
      'first': '${query.pageSize}',
      'page': '${query.page}',
      'nsfw': '${query.nsfw}',
      // Chub gates its two adult tiers separately; the extension and the site
      // both move them together, and a split switch would only confuse.
      'nsfl': '${query.nsfw}',
      'include_forks': 'true',
      // Venus-only projects cannot be downloaded as cards, so leave them out.
      'venus': 'false',
    };
    if (query.kind == DiscoverKind.lorebook) {
      params['namespace'] = 'lorebooks';
    } else {
      // Chub's own default floor: below this a "character" is a stub.
      params['min_tokens'] = '50';
    }
    if (query.search.trim().isNotEmpty) params['search'] = query.search.trim();
    if (query.sort.isNotEmpty) params['sort'] = query.sort;
    if (query.includeTags.isNotEmpty) {
      params['topics'] = query.includeTags.join(',');
    }
    if (query.excludeTags.isNotEmpty) {
      // Not a typo: the exclusion parameter has no underscore.
      params['excludetopics'] = query.excludeTags.join(',');
    }
    return Uri.parse('$apiBase/search').replace(queryParameters: params);
  }

  @override
  Future<DiscoverPage> search(DiscoverQuery query) async {
    final decoded = await _http.getJson(searchUri(query));
    final nodes = extractNodes(decoded);
    final items = <DiscoverItem>[];
    for (final node in nodes) {
      final item = itemFrom(node, query.kind);
      if (item != null) items.add(item);
    }
    return DiscoverPage(
      items: items,
      // Chub reports a cursor rather than a total. A short page is the reliable
      // end-of-feed signal.
      hasMore: nodes.length >= query.pageSize,
    );
  }

  /// Chub answers with the result list under one of four envelopes depending on
  /// the endpoint and the day.
  static List<Map<String, dynamic>> extractNodes(Object? decoded) {
    Object? list;
    if (decoded is Map) {
      final data = decoded['data'];
      list = decoded['nodes'] ??
          (data is Map ? data['nodes'] : null) ??
          (data is List ? data : null);
    } else if (decoded is List) {
      list = decoded;
    }
    if (list is! List) return const <Map<String, dynamic>>[];
    return list.whereType<Map<String, dynamic>>().toList(growable: false);
  }

  /// A lorebook's canonical path, `lorebooks/creator/slug`. The listing has been
  /// seen to report it with and without the namespace segment, and the metadata
  /// endpoint needs it present.
  static String lorebookPath(String fullPath) =>
      fullPath.startsWith('lorebooks/') ? fullPath : 'lorebooks/$fullPath';

  /// Maps a search or detail node onto an item, or null when it carries no
  /// usable path.
  DiscoverItem? itemFrom(Map<String, dynamic> node, DiscoverKind kind) {
    final fullPath = asString(pick(node, ['fullPath', 'full_path'])).trim();
    if (fullPath.isEmpty) return null;
    final segments = fullPath.split('/');
    // The creator is the segment before the slug, whether or not the path
    // carries a leading `lorebooks/` namespace.
    final pathCreator = segments.length >= 2 ? segments[segments.length - 2] : '';
    final named = asString(pick(node, ['name'])).trim();
    final credited = asString(pick(node, ['creator', 'creatorName'])).trim();
    final avatar = asString(pick(node, ['avatar_url'])).trim();
    final maxRes = asString(pick(node, ['max_res_url'])).trim();
    final thumbnail = avatar.isNotEmpty
        ? avatar
        : (kind == DiscoverKind.character
            ? '$avatarBase/$fullPath/avatar.webp'
            : '');

    return DiscoverItem(
      sourceId: id,
      kind: kind,
      id: fullPath,
      name: named.isEmpty ? segments.last : named,
      creator: credited.isEmpty ? pathCreator : credited,
      tagline: stripHtml(asString(pick(node, ['tagline']))),
      description: stripHtml(asString(pick(node, ['description']))),
      tags: asStringList(pick(node, ['topics', 'tags'])),
      thumbnailUrl: thumbnail.isEmpty ? null : thumbnail,
      imageUrl: maxRes.isEmpty ? null : maxRes,
      pageUrl: kind == DiscoverKind.lorebook
          ? '$siteBase/${lorebookPath(fullPath)}'
          : '$siteBase/characters/$fullPath',
      nsfw: asBool(pick(node, ['nsfw', 'nsfw_image'])),
      tokens: asInt(pick(node, ['nTokens', 'n_tokens'])),
      // Chub's `starCount` counts downloads, not stars — the "Top rated" sort
      // is the one called `star_count`. Naming, not a bug.
      downloads: asInt(pick(node, ['starCount', 'star_count'])),
      favourites: asInt(pick(node, ['n_favorites', 'nFavorites'])),
      rating: asDouble(pick(node, ['rating'])),
      ratingCount: asInt(pick(node, ['ratingCount', 'rating_count'])),
      entryCount: asInt(pick(node, ['nEntries', 'n_entries'])),
      createdAt: asDate(pick(node, ['createdAt', 'created_at'])),
      updatedAt: asDate(pick(node, ['lastActivityAt', 'last_activity_at'])),
      hasLore: asBool(pick(node, ['has_lore', 'hasLore'])) ||
          (pick(node, ['related_lorebooks', 'relatedLorebooks']) as List?)
                  ?.isNotEmpty ==
              true,
      projectId: asInt(pick(node, ['id', 'project_id'])),
    );
  }

  // --- Download ------------------------------------------------------------

  @override
  Future<DiscoverPayload> fetch(DiscoverItem item) async {
    if (item.kind == DiscoverKind.lorebook) {
      return DiscoverPayload(lorebook: await _fetchLorebook(item));
    }
    return _fetchCharacterPayload(item);
  }

  Future<DiscoverPayload> _fetchCharacterPayload(DiscoverItem item) async {
    final decoded = await _http.getJson(detailUri(item.id));
    final node = decoded is Map ? decoded['node'] : null;
    if (node is! Map<String, dynamic>) {
      throw const DiscoverException(
        'Chub did not return this character\'s definition.',
      );
    }
    final definition = node['definition'];
    if (definition is! Map<String, dynamic>) {
      throw const DiscoverException(
        'Chub returned this character without a definition — it may be '
        'Venus-only, or hidden by its creator.',
      );
    }
    final character = await _characterFrom(node, definition, item);
    return DiscoverPayload(
      character: character,
      lorebook: await _fetchCharacterLorebook(node, definition, character),
    );
  }

  Uri detailUri(String fullPath) =>
      Uri.parse('$apiBase/api/characters/$fullPath?full=true');

  Future<Character> _characterFrom(
    Map<String, dynamic> node,
    Map<String, dynamic> definition,
    DiscoverItem item,
  ) async {
    final card = _cardFromDefinition(node, definition, item);
    final character = CharacterCodec.parseJson(jsonEncode(card));

    // Bring the picture along, so a downloaded character keeps its face when
    // the CDN or the listing is gone. Base64 here; AppState moves it to a file.
    final imageUrl = asString(pick(node, ['max_res_url'])).trim().isNotEmpty
        ? asString(node['max_res_url']).trim()
        : (asString(pick(node, ['avatar_url'])).trim().isNotEmpty
            ? asString(node['avatar_url']).trim()
            : item.bestImageUrl);
    final bytes = await _tryImage(imageUrl);
    if (bytes != null) {
      character.avatar = base64Encode(bytes);
    } else if (imageUrl != null && imageUrl.startsWith('http')) {
      // Could not download it: keep the link rather than losing the picture.
      character.avatar = imageUrl;
    }
    return character;
  }

  /// The lorebook a character brings with it, or null when it has none.
  ///
  /// Chub attaches world info two different ways and neither is the spec's:
  ///
  /// - **Embedded**, as `definition.embedded_lorebook` — the V2 spec's
  ///   `character_book` under another name, which [_cardFromDefinition] now maps
  ///   across so the card carries it.
  /// - **Linked**, as a book living in its own project, which the API only
  ///   reports as `related_lorebooks` on the node. The resolved copy exists in
  ///   the character's *exported* card, in its git repository — so that is where
  ///   this looks, at the latest commit, exactly as the Character Library
  ///   extension does.
  ///
  /// Either way a failure loses the book, never the character.
  Future<Lorebook?> _fetchCharacterLorebook(
    Map<String, dynamic> node,
    Map<String, dynamic> definition,
    Character character,
  ) async {
    final embedded = pick(definition, ['embedded_lorebook', 'character_book']);
    if (embedded is Map && embedded.isNotEmpty) {
      final book = lorebookFromCardJson(
        // The character's name rides along so the codec can name the book after
        // it, the way it does for a card imported from a file.
        jsonEncode(<String, dynamic>{
          'data': <String, dynamic>{
            'name': character.name,
            'character_book': embedded,
          },
        }),
        name: character.name,
      );
      if (book != null) return book;
    }

    final related = pick(node, ['related_lorebooks', 'relatedLorebooks']);
    final linked = related is List && related.isNotEmpty;
    if (!linked && !asBool(pick(node, ['has_lore', 'hasLore']))) return null;
    final projectId = asInt(pick(node, ['id', 'project_id']));
    if (projectId == null) return null;
    try {
      final ref = await _latestCommit(projectId);
      if (ref == null) return null;
      final response = await _http.getBytes(
        cardFileUri(projectId, ref),
        headers: const <String, String>{'Accept': '*/*'},
      );
      return lorebookFromCardJson(
        utf8.decode(response.bodyBytes),
        name: character.name,
      );
    } catch (_) {
      // A linked book that will not come is not worth failing the download for.
      return null;
    }
  }

  Uri commitsUri(int projectId) =>
      Uri.parse('$apiBase/api/v4/projects/$projectId/repository/commits');

  /// The character's exported card inside its git project. Same doubled escape
  /// as [lorebookFilePath], different file: `raw/card.json` is the resolved card,
  /// lorebook and all.
  static const String cardFilePath = 'raw%252Fcard.json';

  Uri cardFileUri(int projectId, String ref) => Uri.parse(
        '$apiBase/api/v4/projects/$projectId/repository/files/'
        '$cardFilePath/raw?ref=$ref',
      );

  /// The newest commit in a project. The card file is only served against a real
  /// ref here, and `main` is not one for every project.
  Future<String?> _latestCommit(int projectId) async {
    final decoded = await _http.getJson(commitsUri(projectId));
    if (decoded is! List || decoded.isEmpty) return null;
    final first = decoded.first;
    if (first is! Map) return null;
    final id = asString(pick(first.cast<String, dynamic>(), ['id', 'sha']));
    return id.trim().isEmpty ? null : id.trim();
  }

  /// The one place Chub's field names are translated into the V2 card spec.
  Map<String, dynamic> _cardFromDefinition(
    Map<String, dynamic> node,
    Map<String, dynamic> definition,
    DiscoverItem item,
  ) {
    String def(List<String> keys) => asString(pick(definition, keys));
    return <String, dynamic>{
      'spec': 'chara_card_v2',
      'spec_version': '2.0',
      'data': <String, dynamic>{
        'name': def(['name']).isNotEmpty ? def(['name']) : item.name,
        // Chub's `personality` is the definition body, and its `description`
        // is the public blurb. Both are crossed relative to the spec.
        'description': def(['personality']),
        'personality': def(['tavern_personality']),
        'scenario': def(['scenario']),
        'first_mes': def(['first_message', 'first_mes']),
        'mes_example': def(['example_dialogs', 'mes_example']),
        'creator_notes': def(['description']),
        'system_prompt': def(['system_prompt']),
        'post_history_instructions': def(['post_history_instructions']),
        'alternate_greetings':
            asStringList(pick(definition, ['alternate_greetings'])),
        'tags': asStringList(pick(node, ['topics'])),
        'creator': item.creator,
        'character_version': def(['character_version']),
        // Chub's name for the V2 spec's `character_book`. Without this line a
        // character's own world info was read, ignored and thrown away.
        'character_book': ?pick(definition, ['embedded_lorebook']),
      },
    };
  }

  /// The path of a lorebook's exported world info inside its git project.
  ///
  /// The escape is deliberately doubled: it is `raw/card.json`'s sibling
  /// `raw/sillytavern_raw.json` with the slash written `%2F`, and then the `%`
  /// escaped again, because the file API expects a pre-encoded path and decodes
  /// it once. Written as a literal so nothing re-encodes it.
  static const String lorebookFilePath = 'raw%252Fsillytavern_raw.json';

  Uri lorebookDownloadUri(int projectId) => Uri.parse(
        '$apiBase/api/v4/projects/$projectId/repository/files/'
        '$lorebookFilePath/raw?ref=main&response_type=blob',
      );

  Uri lorebookMetadataUri(String fullPath) =>
      Uri.parse('$apiBase/api/${lorebookPath(fullPath)}');

  Future<Lorebook> _fetchLorebook(DiscoverItem item) async {
    var projectId = item.projectId;
    if (projectId == null) {
      // The listing usually carries the numeric id; when it does not, the
      // lorebook's own metadata endpoint does.
      final decoded = await _http.getJson(lorebookMetadataUri(item.id));
      final node = decoded is Map ? decoded['node'] : null;
      projectId = node is Map ? asInt(node['id']) : null;
    }
    if (projectId == null) {
      throw const DiscoverException(
        'Could not work out where this lorebook lives on Chub.',
      );
    }

    final response = await _http.getBytes(
      lorebookDownloadUri(projectId),
      headers: const <String, String>{'Accept': '*/*'},
    );
    List<Lorebook> books;
    try {
      books = LorebookCodec.parse(utf8.decode(response.bodyBytes));
    } on FormatException catch (error) {
      throw DiscoverException(
        'Chub returned this lorebook in a shape the app could not read '
        '(${error.message}).',
      );
    }
    if (books.isEmpty) {
      throw const DiscoverException('That lorebook came back empty.');
    }

    final book = books.first;
    // Chub generates this file from the project's entries, so it carries no
    // book name of its own — the codec falls back to a placeholder and the real
    // title only exists in the listing. agnai's importer substitutes it too.
    if (item.name.trim().isNotEmpty) book.name = item.name.trim();
    if (book.description.trim().isEmpty) {
      book.description = item.tagline.isNotEmpty ? item.tagline : item.description;
    }
    if (book.tags.isEmpty && item.tags.isNotEmpty) {
      book.tags = List<String>.of(item.tags);
    }
    return book;
  }

  /// Fetches an image, returning null rather than failing the whole download.
  Future<List<int>?> _tryImage(String? url) async {
    if (url == null || !url.startsWith('http')) return null;
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    try {
      final response = await _http.getBytes(
        uri,
        headers: const <String, String>{'Accept': 'image/*,*/*'},
      );
      return response.bodyBytes.isEmpty ? null : response.bodyBytes;
    } catch (_) {
      return null;
    }
  }

  // --- Tags ----------------------------------------------------------------

  Uri get tagsUri => Uri.parse('$apiBase/tags');

  @override
  Future<List<String>> tags(DiscoverKind kind) async {
    final cached = _tagCache;
    if (cached != null) return cached;
    try {
      final decoded = await _http.postJson(tagsUri, const <String, dynamic>{
        'nsfl': false,
        'nsfw': true,
        'order_by': null,
        'sort': null,
        'offset': 0,
        'search': '',
      });
      final raw = decoded is Map ? decoded['tags'] : decoded;
      if (raw is! List) return const <String>[];
      final names = <String>{};
      for (final entry in raw) {
        final name = entry is Map
            ? asString(pick(entry.cast<String, dynamic>(), ['name', 'title']))
            : asString(entry);
        final trimmed = name.trim();
        if (trimmed.length >= 2 && trimmed.length <= 39) {
          names.add(trimmed.toLowerCase());
        }
      }
      final list = names.toList()..sort();
      _tagCache = list;
      return list;
    } catch (_) {
      // Suggestions are a convenience; typing a tag still works without them.
      return const <String>[];
    }
  }
}
