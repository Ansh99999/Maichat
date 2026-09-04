/// Which character editor "Create" and "Edit" open.
///
/// The tabbed creator (v2) is the default, but the single-column form (v1) is
/// kept rather than deleted: it is one scrolling page with every field on it,
/// which is faster to fill in when you already know what you are typing, and it
/// is the shape anybody who has used the app so far has muscle memory for.
/// Both write the same [Character], so switching is free and can be switched
/// back — nothing about a card records which editor made it.
enum CreatorVersion {
  /// The original single-page form.
  v1('Creator v1', 'One page, every field'),

  /// Tabbed: identity, persona, greetings, scenarios, lorebooks, advanced.
  v2('Creator v2', 'Tabs, previews and AI help');

  const CreatorVersion(this.label, this.blurb);

  final String label;
  final String blurb;

  static CreatorVersion byName(Object? value,
      {CreatorVersion fallback = CreatorVersion.v2}) {
    for (final v in values) {
      if (v.name == value) return v;
    }
    return fallback;
  }
}

/// How a browsable collection is laid out: a grid of pictures, or a list of rows.
enum BrowseLayout {
  grid,
  list;

  static BrowseLayout byName(Object? value, {BrowseLayout fallback = grid}) {
    for (final layout in values) {
      if (layout.name == value) return layout;
    }
    return fallback;
  }
}

/// The sections [ViewPrefs] remembers a layout for. Plain strings rather than an
/// enum so a stored preference from an older build is never invalidated by the
/// list changing.
abstract final class BrowseSection {
  static const String characters = 'characters';
  static const String lorebooks = 'lorebooks';
  static const String scenarios = 'scenarios';
}

/// Which shape each browsable section was last left in.
///
/// Choosing between cards and rows is a preference, not a gesture: it says how
/// you like to read your own library. Every section used to reset to cards on the
/// next launch, so the choice had to be made again on every visit — which is
/// exactly as annoying as it sounds. Kept in one small entry of its own so
/// flipping the toggle never rewrites the roster, the shelf, or anything else
/// that is large.
class ViewPrefs {
  const ViewPrefs({
    this.layouts = const <String, String>{},
    this.creatorVersion = CreatorVersion.v2,
  });

  /// Section name (see [BrowseSection]) to [BrowseLayout.name].
  final Map<String, String> layouts;

  /// Which character editor the app opens. Lives here rather than in its own
  /// store entry for the same reason the layouts do: it is a small UI preference,
  /// and this entry is the one place small UI preferences are written without
  /// touching anything large.
  final CreatorVersion creatorVersion;

  /// How [section] should be laid out, falling back to [fallback] when nothing
  /// has been chosen yet.
  BrowseLayout layoutFor(String section,
          {BrowseLayout fallback = BrowseLayout.grid}) =>
      BrowseLayout.byName(layouts[section], fallback: fallback);

  ViewPrefs withLayout(String section, BrowseLayout layout) => ViewPrefs(
        layouts: <String, String>{...layouts, section: layout.name},
        creatorVersion: creatorVersion,
      );

  ViewPrefs withCreatorVersion(CreatorVersion version) => ViewPrefs(
        layouts: layouts,
        creatorVersion: version,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'layouts': layouts,
        if (creatorVersion != CreatorVersion.v2)
          'creatorVersion': creatorVersion.name,
      };

  factory ViewPrefs.fromJson(Map<String, dynamic> json) {
    final raw = json['layouts'];
    final layouts = <String, String>{};
    if (raw is Map) {
      for (final entry in raw.entries) {
        final value = entry.value;
        if (value is String) layouts['${entry.key}'] = value;
      }
    }
    return ViewPrefs(
      layouts: layouts,
      creatorVersion: CreatorVersion.byName(json['creatorVersion']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ViewPrefs &&
      other.creatorVersion == creatorVersion &&
      _same(other.layouts, layouts);

  @override
  int get hashCode => Object.hash(
        creatorVersion,
        Object.hashAllUnordered(
          layouts.entries.map((e) => '${e.key}=${e.value}'),
        ),
      );

  static bool _same(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }
}
