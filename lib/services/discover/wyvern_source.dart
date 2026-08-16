import 'dart:convert';

import '../../models/character.dart';
import '../../models/discover.dart';
import '../character_codec.dart';
import 'discover_source.dart';

/// Wyvern (app.wyvern.chat) — a catalogue whose search hands back whole
/// characters rather than summaries: a hit carries the description, personality,
/// scenario, greetings and lorebooks, so a download is really a re-read of one
/// record by id.
///
/// Two of its habits shape this file. Searching and sorting are exclusive: with
/// a `q` the site drops `sort` so results come from the whole catalogue rather
/// than a trending pool. And adult content is reachable without an account only
/// through the `nsfw-popular` order — every other order is filtered with
/// `rating=none` — so the adult switch here selects an ordering rather than
/// flipping a flag.
///
/// Field names come from the Character Library extension's mapping, which is the
/// only written record of them: `pre_history_instructions` is the system prompt,
/// `shared_info` is extra character context appended to the description, and
/// `lorebooks` is a V2 `character_book` in all but name.
class WyvernSource extends DiscoverSource {
  WyvernSource({
    this.apiBase = 'https://api.wyvern.chat',
    this.siteBase = 'https://app.wyvern.chat',
    this.imageBase = 'https://imagedelivery.net/Dv4koOwHQU3XnXLqtl0aVQ',
    DiscoverHttp? http,
  }) : _http = http ?? DiscoverHttp();

  final String apiBase;
  final String siteBase;

  /// Where a bare image id resolves; most avatars arrive as full URLs already.
  final String imageBase;

  final DiscoverHttp _http;

  /// The only order that returns adult cards to a client with no account.
  static const String adultSort = 'nsfw-popular';

  @override
  String get id => 'wyvern';

  @override
  String get label => 'Wyvern';

  @override
  String get blurb => 'app.wyvern.chat — cards with their lorebooks attached';

  @override
  String get homeUrl => siteBase;

  @override
  Set<DiscoverKind> get kinds => const <DiscoverKind>{DiscoverKind.character};

  @override
  List<DiscoverSort> sortsFor(DiscoverKind kind) => const <DiscoverSort>[
        DiscoverSort('popular', 'Popular'),
        DiscoverSort('recommended', 'Recommended'),
        DiscoverSort('created_at', 'Newest'),
        DiscoverSort('votes', 'Most liked'),
        DiscoverSort('messages', 'Most messages'),
        DiscoverSort(adultSort, 'Popular (adult)'),
      ];

  @override
  void close() => _http.close();

  // --- Feed ----------------------------------------------------------------

  Uri searchUri(DiscoverQuery query) {
    final params = <String, String>{
      'limit': '${query.pageSize}',
      'page': '${query.page}',
    };
    if (query.includeTags.isNotEmpty) {
      params['tags'] = query.includeTags.join(',');
    }
    final search = query.search.trim();
    final sort = query.sort.isEmpty ? 'popular' : query.sort;
    if (search.isNotEmpty) {
      // With a query the sort is deliberately omitted: keeping it would search
      // inside a ranked pool instead of the catalogue.
      params['q'] = search;
    } else {
      params['sort'] = sort;
      params['order'] = 'DESC';
    }
    // `nsfw-popular` is the one order that serves adult cards anonymously; for
    // anything else the rating filter is the honest thing to send.
    final adultOrder = search.isEmpty && sort == adultSort;
    if (!query.nsfw || !adultOrder) params['rating'] = 'none';
    return Uri.parse('$apiBase/exploreSearch/characters')
        .replace(queryParameters: params);
  }

  @override
  Future<DiscoverPage> search(DiscoverQuery query) async {
    final decoded = await _http.getJson(searchUri(query));
    if (decoded is! Map<String, dynamic>) {
      throw const DiscoverException(
        'Wyvern answered its search in a shape the app could not read.',
      );
    }
    final results = decoded['results'];
    final items = <DiscoverItem>[];
    if (results is List) {
      for (final hit in results.whereType<Map<String, dynamic>>()) {
        final item = itemFrom(hit);
        if (item != null) items.add(item);
      }
    }
    final more = decoded['hasMore'];
    final totalPages = asInt(decoded['totalPages']);
    return DiscoverPage(
      items: items,
      hasMore: more is bool
          ? more
          : (totalPages != null && query.page < totalPages),
    );
  }

  DiscoverItem? itemFrom(Map<String, dynamic> hit) {
    final charId = asString(pick(hit, ['id', '_id'])).trim();
    if (charId.isEmpty) return null;
    final creator = hit['creator'];
    final credited = creator is Map
        ? asString(pick(creator.cast<String, dynamic>(),
            ['displayName', 'username', 'name']))
        : asString(creator);
    final image = avatarUrl(hit);
    final rating = asString(pick(hit, ['rating'])).toLowerCase();
    return DiscoverItem(
      sourceId: id,
      kind: DiscoverKind.character,
      id: charId,
      name: asString(pick(hit, ['name', 'chat_name'])).trim(),
      creator: credited.trim(),
      tagline: stripHtml(asString(pick(hit, ['tagline']))),
      description: stripHtml(asString(pick(hit, ['description']))),
      tags: asStringList(pick(hit, ['tags', 'community_tags'])),
      thumbnailUrl: image,
      imageUrl: image,
      pageUrl: '$siteBase/characters/$charId',
      // `rating` is 'none' for safe cards and names the tier otherwise.
      nsfw: rating.isNotEmpty && rating != 'none',
      tokens: asInt(pick(hit, ['token_count'])),
      favourites: asInt(pick(hit, ['likes'])),
      createdAt: asDate(pick(hit, ['created_at'])),
      updatedAt: asDate(pick(hit, ['updated_at'])),
      hasLore: (pick(hit, ['lorebooks']) as List?)?.isNotEmpty == true,
    );
  }

  /// A hit's avatar is usually a full CDN URL; a bare id needs the delivery host
  /// and a variant suffix.
  String? avatarUrl(Map<String, dynamic> hit) {
    final src = asString(pick(hit, ['avatar_url', 'avatar'])).trim();
    if (src.isEmpty) return null;
    if (src.startsWith('http')) return src;
    return '$imageBase/$src/public';
  }

  // --- Download ------------------------------------------------------------

  Uri detailUri(String charId) => Uri.parse('$apiBase/characters/$charId');

  @override
  Future<DiscoverPayload> fetch(DiscoverItem item) async {
    final decoded = await _http.getJson(detailUri(item.id));
    final record = decoded is Map<String, dynamic>
        ? (decoded['character'] is Map<String, dynamic>
            ? decoded['character'] as Map<String, dynamic>
            : decoded)
        : null;
    if (record == null) {
      throw const DiscoverException(
        'Wyvern did not return this character\'s definition.',
      );
    }
    final json = jsonEncode(cardFrom(record));
    Character character;
    try {
      character = CharacterCodec.parseJson(json);
    } on CharacterParseException catch (error) {
      throw DiscoverException(
        'Wyvern returned this character in a shape the app could not read '
        '(${error.message}).',
      );
    }
    if (character.name.trim().isEmpty) character.name = item.name;
    if (character.creator.trim().isEmpty) character.creator = item.creator;
    await _fillAvatar(character, record, item);
    return DiscoverPayload(
      character: character,
      lorebook: lorebookFromCardJson(json, name: character.name),
    );
  }

  /// Builds a V2 card out of a Wyvern record. The awkward parts: `shared_info`
  /// is extra context that belongs on the description, `pre_history_instructions`
  /// is the system prompt, and `lorebooks` is a list of books where a card holds
  /// one.
  Map<String, dynamic> cardFrom(Map<String, dynamic> record) {
    final creator = record['creator'];
    final credited = creator is Map
        ? asString(pick(creator.cast<String, dynamic>(),
            ['displayName', 'username', 'name']))
        : asString(creator);
    var description = asString(pick(record, ['description']));
    final shared = asString(pick(record, ['shared_info'])).trim();
    if (shared.isNotEmpty) {
      description =
          description.trim().isEmpty ? shared : '$description\n\n---\n\n$shared';
    }
    final greetings = asStringList(pick(record, ['alternate_greetings']));
    final book = firstLorebook(record['lorebooks']);
    return <String, dynamic>{
      'spec': 'chara_card_v2',
      'spec_version': '2.0',
      'data': <String, dynamic>{
        'name': asString(pick(record, ['name', 'chat_name'])),
        'description': description,
        'personality': asString(pick(record, ['personality'])),
        'scenario': asString(pick(record, ['scenario'])),
        'first_mes': asString(pick(record, ['first_mes'])),
        'mes_example': asString(pick(record, ['mes_example'])),
        'creator_notes': asString(pick(record, ['creator_notes'])),
        'system_prompt': asString(pick(record, ['pre_history_instructions'])),
        'post_history_instructions':
            asString(pick(record, ['post_history_instructions'])),
        'alternate_greetings': greetings,
        'tags': asStringList(pick(record, ['tags', 'community_tags'])),
        'creator': credited.trim(),
        'character_version': '',
        'character_book': ?book,
      },
    };
  }

  /// Wyvern attaches a list of books; a card carries one, so the first with
  /// entries wins.
  ///
  /// Its books keep their entries under **`lexicon`**, not `entries` — `entries`
  /// exists and is always empty, which is exactly the kind of field that makes a
  /// lorebook silently vanish. The entries themselves are V2-shaped already
  /// (`keys`, `secondary_keys`, `content`, `insertion_order`, `constant`, …).
  /// `entries` is still preferred when it has anything in it, in case that ever
  /// changes.
  static Map<String, dynamic>? firstLorebook(Object? raw) {
    if (raw is! List) return null;
    for (final candidate in raw) {
      if (candidate is! Map) continue;
      final book = Map<String, dynamic>.of(candidate.cast<String, dynamic>());
      final list = _entryList(book['entries']) ?? _entryList(book['lexicon']);
      if (list == null || list.isEmpty) continue;
      book['entries'] = list;
      book.remove('lexicon');
      return book;
    }
    return null;
  }

  /// Entries arrive as a list or as an object keyed by id — the same two shapes
  /// SillyTavern's world info comes in.
  static List<Object?>? _entryList(Object? raw) {
    if (raw is List) return raw.isEmpty ? null : raw;
    if (raw is Map) {
      final values = raw.values.toList(growable: false);
      return values.isEmpty ? null : values;
    }
    return null;
  }

  Future<void> _fillAvatar(
    Character character,
    Map<String, dynamic> record,
    DiscoverItem item,
  ) async {
    if (character.hasAvatar && !character.avatarIsUrl) return;
    final url = avatarUrl(record) ?? item.bestImageUrl;
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
