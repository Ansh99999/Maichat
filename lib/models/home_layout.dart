/// The Home screen as the user arranged it: a grid of cells, a few pages of it,
/// and the widgets placed on them — Android's home screen, inside the app.
///
/// Everything here is plain data and pure geometry, so the rules about what
/// fits where are tested without a widget in sight. Positions are in **cells**,
/// never in pixels: a cell's size is worked out on screen from the space
/// available, which is what lets the same layout sit on a phone and a tablet.
///
/// The layout is its own small store entry (`homeLayout`), written only when the
/// user finishes editing — never per frame, never inside a larger blob.
library;

/// What a tile on the grid shows. Stored by [name], so the order is free to
/// change; an unknown name in a stored layout drops that one tile, not the
/// layout.
enum HomeWidgetKind {
  /// The latest conversation (or the 2nd, 3rd… latest), as a card.
  recentChat(refW: 4, refH: 2),

  /// One chat the user chose, or the pinned chats as a list.
  pinnedChat(refW: 4, refH: 2),

  /// Pictures from the gallery, one or a grid of them; each swipes to the next.
  gallery(refW: 2, refH: 2),

  /// What a provider has cost, and what is left of its budget.
  cost(refW: 2, refH: 1),

  /// The provider replies come from: its model, and a test button.
  provider(refW: 2, refH: 1),

  /// One tap to a screen or an action — an app icon, in launcher terms.
  quickOpen(refW: 1, refH: 1),

  /// A row of faces: starred or recently talked-to characters.
  characters(refW: 4, refH: 1),

  /// The Character Studio: its sessions, and what its agents are doing.
  studio(refW: 2, refH: 2),

  /// A search bar over chats and characters, like the one on a phone's home.
  search(refW: 4, refH: 1);

  const HomeWidgetKind({required this.refW, required this.refH});

  /// The default span on a 4-column, 6-row grid. Other grids scale it (see
  /// [defaultSpan]), so a new tile looks the same size on any grid.
  final int refW;
  final int refH;

  /// The span a freshly added tile takes on a [columns] × [rows] grid.
  ({int w, int h}) defaultSpan(int columns, int rows) => (
        w: (refW * columns / 4).round().clamp(1, columns),
        h: (refH * rows / 6).round().clamp(1, rows),
      );

  static HomeWidgetKind? byName(Object? name) {
    for (final kind in values) {
      if (kind.name == name) return kind;
    }
    return null;
  }
}

/// Where a quick-open tile goes. Stored by [name]; an unknown one falls back to
/// [chats] so an icon from a newer build still opens something sensible.
enum QuickTarget {
  newChat,
  resume,
  chats,
  characters,
  newCharacter,
  importCharacter,
  studio,
  newStudioSession,
  discover,
  library,
  lorebooks,
  scenarios,
  gallery,
  imageStudio,
  providers,
  presets,
  chatLook,
  profile,
  backups,
  settings,
  themeToggle;

  static QuickTarget byName(Object? name) {
    for (final target in values) {
      if (target.name == name) return target;
    }
    return QuickTarget.chats;
  }
}

/// One widget on the grid: what it is, where it sits, and its own settings.
///
/// [config] holds JSON-safe values only (strings, numbers, booleans). What the
/// keys mean is up to the widget; the typed readers below never throw on a
/// value of the wrong type, they fall back to the default.
class HomeTile {
  const HomeTile({
    required this.id,
    required this.kind,
    required this.x,
    required this.y,
    this.w = 1,
    this.h = 1,
    this.config = const <String, Object?>{},
  });

  final String id;
  final HomeWidgetKind kind;

  /// Column and row of the top-left cell.
  final int x;
  final int y;

  /// Width and height in cells, at least 1.
  final int w;
  final int h;

  final Map<String, Object?> config;

  int get right => x + w;
  int get bottom => y + h;

  bool overlaps(HomeTile other) =>
      x < other.right && other.x < right && y < other.bottom && other.y < bottom;

  String? str(String key) {
    final v = config[key];
    return v is String && v.isNotEmpty ? v : null;
  }

  /// Numbers come back as numbers, and so do numeric strings — a choice
  /// option ("1", "2", "4" pictures) stores its value as text.
  int integer(String key, int fallback) {
    final v = config[key];
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim()) ?? fallback;
    return fallback;
  }

  double number(String key, double fallback) {
    final v = config[key];
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v.trim()) ?? fallback;
    return fallback;
  }

  bool flag(String key, bool fallback) {
    final v = config[key];
    return v is bool ? v : fallback;
  }

  HomeTile copyWith({
    HomeWidgetKind? kind,
    int? x,
    int? y,
    int? w,
    int? h,
    Map<String, Object?>? config,
  }) =>
      HomeTile(
        id: id,
        kind: kind ?? this.kind,
        x: x ?? this.x,
        y: y ?? this.y,
        w: w ?? this.w,
        h: h ?? this.h,
        config: config ?? this.config,
      );

  /// A copy with [key] set to [value] (or removed, for null).
  HomeTile withConfig(String key, Object? value) {
    final next = Map<String, Object?>.of(config);
    if (value == null) {
      next.remove(key);
    } else {
      next[key] = value;
    }
    return copyWith(config: next);
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'kind': kind.name,
        'x': x,
        'y': y,
        'w': w,
        'h': h,
        if (config.isNotEmpty) 'config': config,
      };

  static HomeTile? fromJson(Object? json) {
    if (json is! Map) return null;
    final kind = HomeWidgetKind.byName(json['kind']);
    if (kind == null) return null;
    int read(String key, int fallback) {
      final v = json[key];
      return v is num ? v.toInt() : fallback;
    }

    final rawConfig = json['config'];
    return HomeTile(
      id: json['id'] is String && (json['id'] as String).isNotEmpty
          ? json['id'] as String
          : newHomeId(),
      kind: kind,
      x: read('x', 0),
      y: read('y', 0),
      w: read('w', 1),
      h: read('h', 1),
      config: rawConfig is Map
          ? <String, Object?>{
              for (final e in rawConfig.entries)
                if (e.key is String &&
                    (e.value == null ||
                        e.value is String ||
                        e.value is num ||
                        e.value is bool))
                  e.key as String: e.value,
            }
          : const <String, Object?>{},
    );
  }

  @override
  bool operator ==(Object other) =>
      other is HomeTile &&
      other.id == id &&
      other.kind == kind &&
      other.x == x &&
      other.y == y &&
      other.w == w &&
      other.h == h &&
      _sameConfig(other.config, config);

  @override
  int get hashCode => Object.hash(id, kind, x, y, w, h, config.length);
}

bool _sameConfig(Map<String, Object?> a, Map<String, Object?> b) {
  if (a.length != b.length) return false;
  for (final e in a.entries) {
    if (!b.containsKey(e.key) || b[e.key] != e.value) return false;
  }
  return true;
}

/// One screen of the home grid.
class HomePage {
  const HomePage({required this.id, this.tiles = const <HomeTile>[]});

  final String id;
  final List<HomeTile> tiles;

  HomeTile? tileById(String id) {
    for (final t in tiles) {
      if (t.id == id) return t;
    }
    return null;
  }

  HomePage copyWith({List<HomeTile>? tiles}) =>
      HomePage(id: id, tiles: tiles ?? this.tiles);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'tiles': [for (final t in tiles) t.toJson()],
      };

  @override
  bool operator ==(Object other) {
    if (other is! HomePage || other.id != id) return false;
    if (other.tiles.length != tiles.length) return false;
    for (var i = 0; i < tiles.length; i++) {
      if (other.tiles[i] != tiles[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(id, tiles.length);
}

/// The outline every quick-open icon is drawn in.
enum HomeIconShape {
  circle('Circle'),
  squircle('Squircle'),
  rounded('Rounded square'),
  flower('Flower');

  const HomeIconShape(this.label);
  final String label;

  static HomeIconShape byName(Object? name) {
    for (final shape in values) {
      if (shape.name == name) return shape;
    }
    return HomeIconShape.squircle;
  }
}

/// The smallest and largest grids offered.
const int kHomeMinColumns = 3;
const int kHomeMaxColumns = 8;
const int kHomeMinRows = 4;
const int kHomeMaxRows = 10;

/// How many pages the home screen may have.
const int kHomeMaxPages = 5;

int _idSeq = 0;

/// A fresh id for a tile or page: unique within this process and, by its
/// timestamp, across launches.
String newHomeId() =>
    '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${(_idSeq++).toRadixString(36)}';

/// The whole arrangement: grid size and pages.
class HomeLayout {
  HomeLayout({
    required int columns,
    required int rows,
    required List<HomePage> pages,
    this.iconShape = HomeIconShape.squircle,
    this.showLabels = true,
    this.wallpaper,
    double wallpaperDim = 0.55,
  })  : columns = columns.clamp(kHomeMinColumns, kHomeMaxColumns),
        rows = rows.clamp(kHomeMinRows, kHomeMaxRows),
        wallpaperDim = wallpaperDim.clamp(0.0, 0.9),
        pages = pages.isEmpty ? [HomePage(id: newHomeId())] : pages;

  final int columns;
  final int rows;

  /// The outline quick-open icons are drawn in.
  final HomeIconShape iconShape;

  /// Whether a new quick-open icon shows its name under it. Each icon can
  /// still say otherwise (its `label` config).
  final bool showLabels;

  /// A picture behind the grid — a `local:` ref or URL, like any other picture
  /// (and so named in the picture sweep's keep-list) — or null for none.
  final String? wallpaper;

  /// How far the wallpaper is faded into the surface, 0 (not at all) to 0.9.
  final double wallpaperDim;

  /// The same layout with a different look. Pass `wallpaper: ''` to clear it.
  HomeLayout withStyle({
    HomeIconShape? iconShape,
    bool? showLabels,
    String? wallpaper,
    double? wallpaperDim,
  }) =>
      HomeLayout(
        columns: columns,
        rows: rows,
        pages: pages,
        iconShape: iconShape ?? this.iconShape,
        showLabels: showLabels ?? this.showLabels,
        wallpaper: wallpaper == null
            ? this.wallpaper
            : (wallpaper.isEmpty ? null : wallpaper),
        wallpaperDim: wallpaperDim ?? this.wallpaperDim,
      );

  /// A copy with [pages] replaced, keeping grid and look.
  HomeLayout _withPages(List<HomePage> pages, {int? columns, int? rows}) =>
      HomeLayout(
        columns: columns ?? this.columns,
        rows: rows ?? this.rows,
        pages: pages,
        iconShape: iconShape,
        showLabels: showLabels,
        wallpaper: wallpaper,
        wallpaperDim: wallpaperDim,
      );

  /// At least one. Page 0 is the one the app opens on.
  final List<HomePage> pages;

  /// What a fresh install sees: a quiet row of air at the top (where a phone's
  /// clock would sit), the latest chat within reach of a thumb, the Studio
  /// beside the provider and a row of faces, and a dock of four shortcuts.
  /// The second page holds the pictures, the spend, search and the rest.
  factory HomeLayout.defaults() => HomeLayout(
        columns: 4,
        rows: 6,
        pages: [
          HomePage(
            id: 'home',
            tiles: [
              const HomeTile(
                id: 'recent',
                kind: HomeWidgetKind.recentChat,
                x: 0,
                y: 1,
                w: 4,
                h: 2,
              ),
              const HomeTile(
                id: 'studio',
                kind: HomeWidgetKind.studio,
                x: 0,
                y: 3,
                w: 2,
                h: 2,
              ),
              const HomeTile(
                id: 'provider',
                kind: HomeWidgetKind.provider,
                x: 2,
                y: 3,
                w: 2,
                h: 1,
              ),
              const HomeTile(
                id: 'faces',
                kind: HomeWidgetKind.characters,
                x: 2,
                y: 4,
                w: 2,
                h: 1,
              ),
              for (final (i, target) in const [
                QuickTarget.newChat,
                QuickTarget.gallery,
                QuickTarget.characters,
                QuickTarget.discover,
              ].indexed)
                HomeTile(
                  id: 'dock-${target.name}',
                  kind: HomeWidgetKind.quickOpen,
                  x: i,
                  y: 5,
                  config: {'target': target.name},
                ),
            ],
          ),
          // A second page, ready to swipe to: the gallery at full width and
          // the rest of the shortcuts.
          HomePage(
            id: 'more',
            tiles: [
              const HomeTile(
                id: 'search',
                kind: HomeWidgetKind.search,
                x: 0,
                y: 0,
                w: 4,
              ),
              const HomeTile(
                id: 'pictures',
                kind: HomeWidgetKind.gallery,
                x: 0,
                y: 1,
                w: 4,
                h: 2,
                config: {'count': '4'},
              ),
              const HomeTile(
                id: 'spend',
                kind: HomeWidgetKind.cost,
                x: 0,
                y: 3,
                w: 2,
                h: 1,
              ),
              const HomeTile(
                id: 'pinned',
                kind: HomeWidgetKind.pinnedChat,
                x: 2,
                y: 3,
                w: 2,
                h: 1,
              ),
              for (final (i, target) in const [
                QuickTarget.library,
                QuickTarget.imageStudio,
                QuickTarget.presets,
                QuickTarget.settings,
              ].indexed)
                HomeTile(
                  id: 'more-${target.name}',
                  kind: HomeWidgetKind.quickOpen,
                  x: i,
                  y: 5,
                  config: {'target': target.name},
                ),
            ],
          ),
        ],
      );

  HomeTile? tileById(String id) {
    for (final p in pages) {
      final t = p.tileById(id);
      if (t != null) return t;
    }
    return null;
  }

  /// The index of the page holding tile [id], or -1.
  int pageOf(String id) {
    for (var i = 0; i < pages.length; i++) {
      if (pages[i].tileById(id) != null) return i;
    }
    return -1;
  }

  /// Whether [tile] lies inside the grid and clear of every other tile on
  /// [page] (a tile never collides with itself, matched by id).
  bool fits(int page, HomeTile tile) {
    if (tile.x < 0 || tile.y < 0 || tile.w < 1 || tile.h < 1) return false;
    if (tile.right > columns || tile.bottom > rows) return false;
    if (page < 0 || page >= pages.length) return false;
    for (final other in pages[page].tiles) {
      if (other.id != tile.id && other.overlaps(tile)) return false;
    }
    return true;
  }

  /// The first free top-left cell (row by row) that takes a [w] × [h] tile on
  /// [page], or null when there is no room.
  ({int x, int y})? firstFree(int page, int w, int h, {String? ignoring}) {
    if (w > columns || h > rows) return null;
    for (var y = 0; y + h <= rows; y++) {
      for (var x = 0; x + w <= columns; x++) {
        final probe = HomeTile(
          id: ignoring ?? '\u0000probe',
          kind: HomeWidgetKind.quickOpen,
          x: x,
          y: y,
          w: w,
          h: h,
        );
        if (fits(page, probe)) return (x: x, y: y);
      }
    }
    return null;
  }

  HomeLayout _withPage(int index, HomePage page) => _withPages([
        for (var i = 0; i < pages.length; i++) i == index ? page : pages[i],
      ]);

  /// Puts [tile] on [page] where it says, replacing a tile of the same id
  /// anywhere in the layout. Returns null when it does not fit there.
  HomeLayout? put(int page, HomeTile tile) {
    final without = remove(tile.id);
    if (!without.fits(page, tile)) return null;
    final p = without.pages[page];
    return without._withPage(page, p.copyWith(tiles: [...p.tiles, tile]));
  }

  /// Adds a new tile of [kind] to [page]: at [at] when it fits there, else at
  /// the first free place on that page, else on the first page with room, else
  /// on a new page. Returns the layout and where the tile went; null only when
  /// every page is full and no page can be added.
  ({HomeLayout layout, int page, HomeTile tile})? add(
    HomeWidgetKind kind, {
    int page = 0,
    ({int x, int y})? at,
    Map<String, Object?> config = const <String, Object?>{},
    ({int w, int h})? span,
  }) {
    final size = span ?? kind.defaultSpan(columns, rows);
    final w = size.w.clamp(1, columns);
    final h = size.h.clamp(1, rows);
    HomeTile make(int x, int y) => HomeTile(
          id: newHomeId(),
          kind: kind,
          x: x,
          y: y,
          w: w,
          h: h,
          config: config,
        );
    if (at != null) {
      final tile = make(at.x, at.y);
      final placed = put(page, tile);
      if (placed != null) return (layout: placed, page: page, tile: tile);
    }
    final order = [page, for (var i = 0; i < pages.length; i++) if (i != page) i];
    for (final p in order) {
      final spot = firstFree(p, w, h);
      if (spot != null) {
        final tile = make(spot.x, spot.y);
        return (layout: put(p, tile)!, page: p, tile: tile);
      }
    }
    if (pages.length >= kHomeMaxPages) return null;
    final grown = addPage();
    final tile = make(0, 0);
    return (layout: grown.put(grown.pages.length - 1, tile)!, page: grown.pages.length - 1, tile: tile);
  }

  /// Every tile except [id].
  HomeLayout remove(String id) => _withPages([
        for (final p in pages)
          p.tileById(id) == null
              ? p
              : p.copyWith(tiles: [for (final t in p.tiles) if (t.id != id) t]),
      ]);

  /// Replaces tile [tile.id] in place (same page), keeping it only if it still
  /// fits; returns null otherwise.
  HomeLayout? update(HomeTile tile) {
    final page = pageOf(tile.id);
    if (page < 0) return null;
    return put(page, tile);
  }

  /// Moves tile [id] to [page], at the first free place there. Null when it has
  /// no room on that page.
  HomeLayout? moveToPage(String id, int page) {
    final tile = tileById(id);
    if (tile == null || page < 0 || page >= pages.length) return null;
    final without = remove(id);
    final spot = without.firstFree(page, tile.w, tile.h);
    if (spot == null) return null;
    return without.put(page, tile.copyWith(x: spot.x, y: spot.y));
  }

  HomeLayout addPage() => pages.length >= kHomeMaxPages
      ? this
      : _withPages([...pages, HomePage(id: newHomeId())]);

  /// Drops page [index] and everything on it. The last page cannot go.
  HomeLayout removePage(int index) {
    if (pages.length <= 1 || index < 0 || index >= pages.length) return this;
    return _withPages(
      [for (var i = 0; i < pages.length; i++) if (i != index) pages[i]],
    );
  }

  /// The same layout on a [newColumns] × [newRows] grid. Each tile keeps its
  /// place and size in proportion; one that then collides with a tile already
  /// placed moves to the nearest free place on its page, and if its page is
  /// full, to a later page (added if need be). Larger tiles are placed first, so
  /// the small ones are what move.
  HomeLayout withGrid(int newColumns, int newRows) {
    final cols = newColumns.clamp(kHomeMinColumns, kHomeMaxColumns);
    final rws = newRows.clamp(kHomeMinRows, kHomeMaxRows);
    if (cols == columns && rws == rows) return this;
    final sx = cols / columns;
    final sy = rws / rows;
    final scaled = <List<HomeTile>>[
      for (final p in pages)
        [
          for (final t in p.tiles)
            () {
              final w = (t.w * sx).round().clamp(1, cols);
              final h = (t.h * sy).round().clamp(1, rws);
              return t.copyWith(
                w: w,
                h: h,
                x: (t.x * sx).round().clamp(0, cols - w),
                y: (t.y * sy).round().clamp(0, rws - h),
              );
            }(),
        ],
    ];
    return _settle(this, cols, rws, [for (final p in pages) p.id], scaled);
  }

  /// Places [wanted] tiles page by page, nudging any that collide. Shared by
  /// [withGrid] and by [fromJson], which cleans up a hand-edited or corrupt
  /// store the same way.
  static HomeLayout _settle(
    HomeLayout style,
    int cols,
    int rws,
    List<String> pageIds,
    List<List<HomeTile>> wanted,
  ) {
    var out = style._withPages(
      [for (final id in pageIds) HomePage(id: id)],
      columns: cols,
      rows: rws,
    );
    final overflow = <HomeTile>[];
    for (var p = 0; p < wanted.length; p++) {
      final ordered = [...wanted[p]]
        ..sort((a, b) => (b.w * b.h).compareTo(a.w * a.h));
      for (final raw in ordered) {
        final t = raw.copyWith(
          w: raw.w.clamp(1, cols),
          h: raw.h.clamp(1, rws),
        );
        final clamped = t.copyWith(
          x: t.x.clamp(0, cols - t.w),
          y: t.y.clamp(0, rws - t.h),
        );
        final direct = out.put(p, clamped);
        if (direct != null) {
          out = direct;
          continue;
        }
        final near = out._nearestFree(p, clamped);
        if (near != null) {
          out = out.put(p, clamped.copyWith(x: near.x, y: near.y))!;
        } else {
          overflow.add(clamped);
        }
      }
    }
    for (final t in overflow) {
      var placed = false;
      for (var p = 0; p < out.pages.length && !placed; p++) {
        final spot = out.firstFree(p, t.w, t.h);
        if (spot != null) {
          out = out.put(p, t.copyWith(x: spot.x, y: spot.y))!;
          placed = true;
        }
      }
      if (!placed && out.pages.length < kHomeMaxPages) {
        out = out.addPage();
        out = out.put(out.pages.length - 1, t.copyWith(x: 0, y: 0))!;
      }
      // With every page full and no page left to add, the tile is dropped —
      // only reachable by shrinking a crowded grid five pages deep.
    }
    return out;
  }

  /// The free top-left cell closest to where [tile] wanted to be.
  ({int x, int y})? _nearestFree(int page, HomeTile tile) {
    ({int x, int y})? best;
    var bestDistance = 1 << 30;
    for (var y = 0; y + tile.h <= rows; y++) {
      for (var x = 0; x + tile.w <= columns; x++) {
        if (!fits(page, tile.copyWith(x: x, y: y))) continue;
        final d = (x - tile.x).abs() + (y - tile.y).abs();
        if (d < bestDistance) {
          bestDistance = d;
          best = (x: x, y: y);
        }
      }
    }
    return best;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'version': 1,
        'columns': columns,
        'rows': rows,
        'iconShape': iconShape.name,
        'showLabels': showLabels,
        if (wallpaper != null) 'wallpaper': wallpaper,
        'wallpaperDim': wallpaperDim,
        'pages': [for (final p in pages) p.toJson()],
      };

  /// Reads a stored layout, repairing what it can: unknown widget kinds are
  /// dropped, tiles are clamped into the grid, overlaps are nudged apart.
  /// Anything unreadable as a whole gives the defaults.
  factory HomeLayout.fromJson(Object? json) {
    if (json is! Map) return HomeLayout.defaults();
    final cols = json['columns'] is num
        ? (json['columns'] as num).toInt().clamp(kHomeMinColumns, kHomeMaxColumns)
        : 4;
    final rws = json['rows'] is num
        ? (json['rows'] as num).toInt().clamp(kHomeMinRows, kHomeMaxRows)
        : 6;
    final rawPages = json['pages'];
    if (rawPages is! List || rawPages.isEmpty) return HomeLayout.defaults();
    final ids = <String>[];
    final wanted = <List<HomeTile>>[];
    final seen = <String>{};
    for (final raw in rawPages.take(kHomeMaxPages)) {
      if (raw is! Map) continue;
      final id = raw['id'] is String && (raw['id'] as String).isNotEmpty
          ? raw['id'] as String
          : newHomeId();
      ids.add(id);
      final tiles = <HomeTile>[];
      final rawTiles = raw['tiles'];
      if (rawTiles is List) {
        for (final t in rawTiles) {
          var tile = HomeTile.fromJson(t);
          if (tile == null) continue;
          // Two tiles sharing an id would make every edit ambiguous.
          if (!seen.add(tile.id)) {
            tile = HomeTile(
              id: newHomeId(),
              kind: tile.kind,
              x: tile.x,
              y: tile.y,
              w: tile.w,
              h: tile.h,
              config: tile.config,
            );
            seen.add(tile.id);
          }
          tiles.add(tile);
        }
      }
      wanted.add(tiles);
    }
    if (ids.isEmpty) return HomeLayout.defaults();
    final wallpaper = json['wallpaper'];
    final style = HomeLayout(
      columns: cols,
      rows: rws,
      pages: const [],
      iconShape: HomeIconShape.byName(json['iconShape']),
      showLabels: json['showLabels'] is bool ? json['showLabels'] as bool : true,
      wallpaper: wallpaper is String && wallpaper.isNotEmpty ? wallpaper : null,
      wallpaperDim: json['wallpaperDim'] is num
          ? (json['wallpaperDim'] as num).toDouble()
          : 0.55,
    );
    return _settle(style, cols, rws, ids, wanted);
  }

  @override
  bool operator ==(Object other) {
    if (other is! HomeLayout ||
        other.columns != columns ||
        other.rows != rows ||
        other.iconShape != iconShape ||
        other.showLabels != showLabels ||
        other.wallpaper != wallpaper ||
        other.wallpaperDim != wallpaperDim ||
        other.pages.length != pages.length) {
      return false;
    }
    for (var i = 0; i < pages.length; i++) {
      if (other.pages[i] != pages[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(columns, rows, pages.length);
}
