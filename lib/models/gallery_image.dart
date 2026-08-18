/// A picture the user keeps in the app: one photo in a character's album, or an
/// unattached one that only shows in the whole-app gallery.
///
/// The bytes are never here. [image] holds an [avatarRef]-style `local:<file>`
/// reference into the pictures directory (or an `http(s)` URL), exactly as a
/// character's avatar and a chat's background do — pictures are files, because a
/// picture inside the preferences store made the app unopenable once.
class GalleryImage {
  GalleryImage({
    required this.id,
    required this.image,
    this.title = '',
    List<String>? tags,
    this.characterId,
    this.starred = false,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.lastViewed,
  })  : tags = tags ?? <String>[],
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  final String id;

  /// A `local:<file>` reference into the pictures directory, or an http(s) URL.
  String image;

  String title;
  List<String> tags;

  /// Whose album this belongs to, by [Character.id] — or null for a picture that
  /// belongs to nobody in particular. Unattached pictures show in the whole-app
  /// gallery and can be used as a chat background, but cannot become an avatar
  /// until they are given an owner.
  String? characterId;

  /// Whether the user pinned this picture ("starred").
  bool starred;

  /// When the picture was added — the date the gallery groups by, so an album
  /// reads like a camera roll.
  final DateTime createdAt;

  DateTime updatedAt;

  /// When it was last opened, which is what the "Last viewed" ordering sorts on
  /// (Agnai calls this `lastInteracted`). Null until it has been opened once.
  DateTime? lastViewed;

  factory GalleryImage.create({
    required String image,
    String title = '',
    List<String>? tags,
    String? characterId,
  }) =>
      GalleryImage(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        image: image,
        title: title,
        tags: tags,
        characterId: characterId,
      );

  /// What to show for a picture the user never named.
  String get displayTitle =>
      title.trim().isEmpty ? 'Untitled' : title.trim();

  bool get isAttached => characterId != null;

  GalleryImage copyWith({
    String? id,
    String? image,
    String? title,
    List<String>? tags,
    Object? characterId = _unset,
    bool? starred,
    DateTime? createdAt,
    DateTime? updatedAt,
    Object? lastViewed = _unset,
  }) =>
      GalleryImage(
        id: id ?? this.id,
        image: image ?? this.image,
        title: title ?? this.title,
        tags: tags ?? List<String>.from(this.tags),
        // Sentinel so a null can be *set* (detaching a picture from its owner),
        // which a plain `?? this.characterId` could never express.
        characterId: characterId == _unset
            ? this.characterId
            : characterId as String?,
        starred: starred ?? this.starred,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? DateTime.now(),
        lastViewed:
            lastViewed == _unset ? this.lastViewed : lastViewed as DateTime?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'image': image,
        if (title.isNotEmpty) 'title': title,
        if (tags.isNotEmpty) 'tags': tags,
        if (characterId != null) 'characterId': characterId,
        if (starred) 'starred': true,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        if (lastViewed != null) 'lastViewed': lastViewed!.toIso8601String(),
      };

  factory GalleryImage.fromJson(Map<String, dynamic> json) => GalleryImage(
        id: json['id'] as String? ??
            DateTime.now().microsecondsSinceEpoch.toString(),
        image: (json['image'] as String? ?? '').trim(),
        title: json['title'] as String? ?? '',
        tags: _stringList(json['tags']),
        characterId: (json['characterId'] as String?)?.trim().isEmpty ?? true
            ? null
            : (json['characterId'] as String).trim(),
        starred: json['starred'] as bool? ?? false,
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
        updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? ''),
        lastViewed: DateTime.tryParse(json['lastViewed'] as String? ?? ''),
      );

  /// Tolerates a comma-separated string as well as a list, the way
  /// [Character.fromJson] does — an exporter somewhere always flattens tags.
  static List<String> _stringList(Object? value) {
    if (value is List) {
      return value
          .map((e) => e?.toString().trim() ?? '')
          .where((e) => e.isNotEmpty)
          .toList();
    }
    if (value is String) {
      return value
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }
    return <String>[];
  }
}

/// The sentinel that lets [GalleryImage.copyWith] set a nullable field to null.
const Object _unset = Object();

/// How a gallery is ordered. The labels are Agnai's, so the two apps read the
/// same way to someone who uses both.
enum GallerySort {
  newest('Last uploaded', 'Newest'),
  oldest('First uploaded', 'Oldest'),
  titleAsc('Name (A–Z)', 'A–Z'),
  titleDesc('Name (Z–A)', 'Z–A'),
  lastViewed('Last viewed', 'Viewed'),
  character('Character', 'Owner');

  const GallerySort(this.label, this.shortLabel);

  /// The full name, as the sort sheet lists it.
  final String label;

  /// What fits on the control chip beside two other chips on a phone. "Last
  /// uploaded" on the chip pushed the tag filter off the edge of a 400 px screen.
  final String shortLabel;

  /// Whether this ordering runs along the calendar, and so can carry date
  /// headings. A name-ordered list under an "April 2026" band would be a lie.
  bool get isChronological =>
      this == GallerySort.newest || this == GallerySort.oldest;

  static GallerySort byName(String? name) {
    for (final s in values) {
      if (s.name == name) return s;
    }
    return GallerySort.newest;
  }
}

/// How pictures are bucketed under each date heading.
enum DateGrouping { day, week, month }

/// One rung of the pinch ladder: how many pictures fit across, and how coarsely
/// they are grouped at that scale.
///
/// Pinching out shows more at once *and* widens the buckets, which is what makes
/// it feel like a camera roll rather than a slider on a grid: at arm's length you
/// see a month, up close you see an afternoon.
enum GalleryZoom {
  single(1, DateGrouping.day),
  pair(2, DateGrouping.day),
  quad(4, DateGrouping.week),
  month(6, DateGrouping.month);

  const GalleryZoom(this.columns, this.grouping);

  final int columns;
  final DateGrouping grouping;

  /// The rung one pinch further out, or this one at the end of the ladder.
  GalleryZoom get out =>
      index + 1 < values.length ? values[index + 1] : this;

  /// The rung one pinch further in, or this one at the end of the ladder.
  GalleryZoom get inward => index > 0 ? values[index - 1] : this;
}

/// Where a gallery opens before anyone pinches: two across, grouped by day.
const GalleryZoom kDefaultGalleryZoom = GalleryZoom.pair;
