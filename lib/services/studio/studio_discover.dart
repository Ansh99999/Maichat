import 'dart:async';
import 'dart:collection';

import '../../models/discover.dart';
import '../discover/discover_sources.dart';

/// Discover, as the Studio's agents reach it: the same catalogue sources the
/// Discover screen browses ([buildDiscoverSources]), the same `search` and
/// `fetch` (so the same codecs and the same per-site quirks), and two things
/// an agent needs that a screen does not.
///
/// It **remembers what it has listed**, because a download wants the whole
/// [DiscoverItem] a search produced — Chub's lorebooks need the project id,
/// a page URL, the listing's own name — and an agent only hands back the id it
/// was shown. And it is **polite**: one request at a time per site, at least
/// [gap] apart, since an agent can fire a burst of searches that a person
/// scrolling never would.
///
/// A payload is kept for a little while too, so reading a card and then
/// importing it is one download, not two. Callers get copies; what is kept
/// stays as the site sent it.
class StudioDiscover {
  StudioDiscover({
    List<DiscoverSource> Function()? sources,
    this.gap = const Duration(milliseconds: 1200),
  }) : _build = sources ?? buildDiscoverSources;

  /// The app's own, built on first use and kept for the app's life. Tests put
  /// a stand-in here.
  static StudioDiscover shared = StudioDiscover();

  final List<DiscoverSource> Function() _build;

  /// The least time between two requests to one site.
  final Duration gap;

  List<DiscoverSource>? _sources;

  /// How many listed items, and downloads, are remembered.
  static const int itemLimit = 600;
  static const int payloadLimit = 16;

  final LinkedHashMap<String, DiscoverItem> _items =
      LinkedHashMap<String, DiscoverItem>();
  final LinkedHashMap<String, DiscoverPayload> _payloads =
      LinkedHashMap<String, DiscoverPayload>();

  /// The tail of each site's queue, and when it was last asked.
  final Map<String, Future<void>> _queues = <String, Future<void>>{};
  final Map<String, DateTime> _last = <String, DateTime>{};

  List<DiscoverSource> get sources => _sources ??= _build();

  /// The source called [id], or null.
  DiscoverSource? source(String id) {
    for (final s in sources) {
      if (s.id == id) return s;
    }
    return null;
  }

  static String _key(String sourceId, DiscoverKind kind, String id) =>
      '$sourceId/${kind.wire}/$id';

  /// The item a search listed, or null when none has (this run of the app).
  DiscoverItem? item(String sourceId, DiscoverKind kind, String id) =>
      _items[_key(sourceId, kind, id)];

  /// One page of [source]'s feed, remembered for a later read or import.
  Future<DiscoverPage> search(DiscoverSource source, DiscoverQuery query) =>
      _polite(source.id, () async {
        final page = await source.search(query);
        for (final item in page.items) {
          _remember(_items, item.key, item, itemLimit);
        }
        return page;
      });

  /// [item] downloaded in full — the character's definition (with the book its
  /// card carries) or a lorebook's entries. A copy: changing it changes
  /// nothing kept here.
  Future<DiscoverPayload> fetch(DiscoverSource source, DiscoverItem item) async {
    final kept = _payloads[item.key];
    if (kept != null) return _copy(kept);
    final payload = await _polite(source.id, () => source.fetch(item));
    _remember(_payloads, item.key, payload, payloadLimit);
    return _copy(payload);
  }

  static DiscoverPayload _copy(DiscoverPayload p) => DiscoverPayload(
        character: p.character?.copyWith(),
        lorebook: p.lorebook?.copyWith(),
        preset: p.preset,
      );

  static void _remember<T>(
    LinkedHashMap<String, T> map,
    String key,
    T value,
    int limit,
  ) {
    map.remove(key);
    map[key] = value;
    while (map.length > limit) {
      map.remove(map.keys.first);
    }
  }

  /// Runs [request] after every earlier one to the same site, and no sooner
  /// than [gap] after the last of them.
  Future<T> _polite<T>(String site, Future<T> Function() request) {
    final before = _queues[site] ?? Future<void>.value();
    final done = Completer<void>();
    _queues[site] = done.future;
    return before.then((_) async {
      final last = _last[site];
      if (last != null) {
        final wait = gap - DateTime.now().difference(last);
        if (wait > Duration.zero) await Future<void>.delayed(wait);
      }
      try {
        return await request();
      } finally {
        _last[site] = DateTime.now();
        done.complete();
      }
    });
  }

  /// Lets go of every site's client.
  void close() {
    for (final s in _sources ?? const <DiscoverSource>[]) {
      s.close();
    }
    _sources = null;
  }
}
