import 'character.dart';
import 'lorebook.dart';
import 'preset.dart';

/// What a Discover feed is browsing. These are the bottom-bar destinations:
/// switching one re-runs the search against the same source, so a query and a
/// set of tags carry across.
enum DiscoverKind {
  character('Characters', 'character'),
  lorebook('Lorebooks', 'lorebook'),
  preset('Presets', 'preset');

  const DiscoverKind(this.label, this.wire);

  /// The plural title shown in the bottom bar and the empty states.
  final String label;

  /// The stable name persisted in preferences.
  final String wire;

  static DiscoverKind byWire(Object? value) {
    for (final k in values) {
      if (k.wire == value) return k;
    }
    return DiscoverKind.character;
  }
}

/// One way a source can order its results. [value] is whatever the remote API
/// wants; an empty [value] means "send no sort at all", which is how both Chub
/// and MeiliSearch spell relevance.
class DiscoverSort {
  const DiscoverSort(this.value, this.label);

  final String value;
  final String label;

  @override
  bool operator ==(Object other) =>
      other is DiscoverSort && other.value == value && other.label == label;

  @override
  int get hashCode => Object.hash(value, label);
}

/// Everything a feed request needs. Sources translate this into their own
/// dialect — Chub into query parameters, JannyAI into a MeiliSearch filter.
class DiscoverQuery {
  const DiscoverQuery({
    this.kind = DiscoverKind.character,
    this.search = '',
    this.sort = '',
    this.page = 1,
    this.nsfw = false,
    this.includeTags = const <String>[],
    this.excludeTags = const <String>[],
    this.pageSize = 24,
  });

  final DiscoverKind kind;
  final String search;

  /// A [DiscoverSort.value]; empty means the source's own relevance order.
  final String sort;

  /// 1-based, matching both APIs.
  final int page;
  final bool nsfw;
  final List<String> includeTags;
  final List<String> excludeTags;
  final int pageSize;

  DiscoverQuery copyWith({
    DiscoverKind? kind,
    String? search,
    String? sort,
    int? page,
    bool? nsfw,
    List<String>? includeTags,
    List<String>? excludeTags,
    int? pageSize,
  }) =>
      DiscoverQuery(
        kind: kind ?? this.kind,
        search: search ?? this.search,
        sort: sort ?? this.sort,
        page: page ?? this.page,
        nsfw: nsfw ?? this.nsfw,
        includeTags: includeTags ?? this.includeTags,
        excludeTags: excludeTags ?? this.excludeTags,
        pageSize: pageSize ?? this.pageSize,
      );
}

/// A single browsable thing in a catalogue, as much of it as a search result
/// carries. The heavy part — a character's definition, a lorebook's entries —
/// arrives later from [DiscoverSource.fetch]; a card only needs what is here.
class DiscoverItem {
  const DiscoverItem({
    required this.sourceId,
    required this.kind,
    required this.id,
    required this.name,
    this.creator = '',
    this.tagline = '',
    this.description = '',
    this.tags = const <String>[],
    this.thumbnailUrl,
    this.imageUrl,
    this.pageUrl,
    this.nsfw = false,
    this.tokens,
    this.downloads,
    this.favourites,
    this.rating,
    this.ratingCount,
    this.entryCount,
    this.createdAt,
    this.updatedAt,
    this.hasLore = false,
    this.projectId,
  });

  /// Which [DiscoverSource] produced this, so a mixed list still knows where to
  /// send the download.
  final String sourceId;
  final DiscoverKind kind;

  /// The source's own identifier: Chub's `creator/slug` full path, JannyAI's
  /// UUID. Opaque to the UI, meaningful to the source.
  final String id;

  final String name;
  final String creator;

  /// A one-line blurb, when the catalogue has one separate from the description.
  final String tagline;

  /// The public description — usually creator's notes rather than the
  /// definition, on every catalogue we speak to.
  final String description;

  final List<String> tags;

  /// A small image for the grid.
  final String? thumbnailUrl;

  /// The largest image available, for the detail header.
  final String? imageUrl;

  /// The item's page on its own site, for "Open in browser".
  final String? pageUrl;

  final bool nsfw;

  /// Token count of the definition, when the catalogue reports one.
  final int? tokens;
  final int? downloads;
  final int? favourites;
  final double? rating;
  final int? ratingCount;

  /// Lorebook entry count, when known before download.
  final int? entryCount;

  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// Whether a character ships a lorebook, so the card can say so.
  final bool hasLore;

  /// Chub's numeric project id, needed to reach a lorebook's git repository.
  final int? projectId;

  /// A stable key for de-duplicating across pages.
  String get key => '$sourceId/${kind.wire}/$id';

  /// The best image to show, largest first.
  String? get bestImageUrl => imageUrl ?? thumbnailUrl;
}

/// One page of feed results.
class DiscoverPage {
  const DiscoverPage({
    required this.items,
    this.hasMore = false,
  });

  const DiscoverPage.empty()
      : items = const <DiscoverItem>[],
        hasMore = false;

  final List<DiscoverItem> items;

  /// Whether asking for the next page is worth doing.
  final bool hasMore;
}

/// What a download produced. Exactly one field is set — which one follows the
/// item's [DiscoverKind] — so the screen knows where to file it.
class DiscoverPayload {
  const DiscoverPayload({this.character, this.lorebook, this.preset});

  final Character? character;
  final Lorebook? lorebook;
  final Preset? preset;

  bool get isEmpty => character == null && lorebook == null && preset == null;
}

/// The few Discover choices worth remembering between sessions: which
/// catalogue was open, whether adult results are allowed, and the order each
/// section was left in.
class DiscoverPrefs {
  const DiscoverPrefs({
    this.sourceId = '',
    this.nsfw = false,
    this.sorts = const <String, String>{},
  });

  /// The selected source's id; empty means "the first one".
  final String sourceId;

  final bool nsfw;

  /// [DiscoverKind.wire] to [DiscoverSort.value].
  final Map<String, String> sorts;

  String? sortFor(DiscoverKind kind) => sorts[kind.wire];

  DiscoverPrefs copyWith({
    String? sourceId,
    bool? nsfw,
    Map<String, String>? sorts,
  }) =>
      DiscoverPrefs(
        sourceId: sourceId ?? this.sourceId,
        nsfw: nsfw ?? this.nsfw,
        sorts: sorts ?? this.sorts,
      );

  /// Returns a copy with [kind]'s sort set to [sort].
  DiscoverPrefs withSort(DiscoverKind kind, String sort) => copyWith(
        sorts: <String, String>{...sorts, kind.wire: sort},
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'sourceId': sourceId,
        'nsfw': nsfw,
        'sorts': sorts,
      };

  factory DiscoverPrefs.fromJson(Map<String, dynamic> json) {
    final raw = json['sorts'];
    final sorts = <String, String>{};
    if (raw is Map) {
      for (final entry in raw.entries) {
        final value = entry.value;
        if (value is String) sorts['${entry.key}'] = value;
      }
    }
    return DiscoverPrefs(
      sourceId: json['sourceId'] is String ? json['sourceId'] as String : '',
      nsfw: json['nsfw'] == true,
      sorts: sorts,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DiscoverPrefs &&
      other.sourceId == sourceId &&
      other.nsfw == nsfw &&
      _sameSorts(other.sorts, sorts);

  @override
  int get hashCode => Object.hash(
        sourceId,
        nsfw,
        Object.hashAllUnordered(sorts.entries.map((e) => '${e.key}=${e.value}')),
      );

  static bool _sameSorts(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }
}
