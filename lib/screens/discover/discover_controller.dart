import 'package:flutter/foundation.dart';

import '../../models/discover.dart';
import '../../services/discover/discover_sources.dart';

/// Drives one Discover feed: which catalogue and section are open, the filters,
/// the pages loaded so far, and the request in flight.
///
/// Deliberately not part of [AppState]: a feed is a live view of somebody
/// else's website, not app data, so it lives and dies with the screen. The few
/// choices worth keeping — source, adult content, ordering — are written back
/// through [onPrefsChanged].
class DiscoverController extends ChangeNotifier {
  DiscoverController({
    required List<DiscoverSource> sources,
    DiscoverPrefs prefs = const DiscoverPrefs(),
    this.onPrefsChanged,
    this.pageSize = 24,
  })  : _sources = List<DiscoverSource>.unmodifiable(sources),
        _prefs = prefs {
    _sourceId = _resolveSourceId(prefs.sourceId, _kind);
    _sort = _initialSort();
  }

  final List<DiscoverSource> _sources;
  final void Function(DiscoverPrefs prefs)? onPrefsChanged;
  final int pageSize;

  DiscoverPrefs _prefs;
  DiscoverKind _kind = DiscoverKind.character;
  String _sourceId = '';
  String _sort = '';
  String _search = '';
  List<String> _includeTags = const <String>[];
  List<String> _excludeTags = const <String>[];

  final List<DiscoverItem> _items = <DiscoverItem>[];
  final Set<String> _seen = <String>{};

  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = false;
  String? _error;
  int _page = 1;

  /// Bumped on every new first-page request so a slow answer to an abandoned
  /// query cannot overwrite the list.
  int _generation = 0;

  List<DiscoverSource> get sources => List.unmodifiable(_sources);
  DiscoverKind get kind => _kind;
  String get search => _search;
  String get sort => _sort;
  bool get nsfw => _prefs.nsfw;
  List<String> get includeTags => List.unmodifiable(_includeTags);
  List<String> get excludeTags => List.unmodifiable(_excludeTags);
  List<DiscoverItem> get items => List.unmodifiable(_items);
  bool get loading => _loading;
  bool get loadingMore => _loadingMore;
  bool get hasMore => _hasMore;
  String? get error => _error;

  /// The catalogues that publish the current section.
  List<DiscoverSource> get available => sourcesFor(_sources, _kind);

  /// Whether nothing at all publishes this section, so the screen can say so
  /// rather than showing an empty feed that looks broken.
  bool get sectionUnavailable => available.isEmpty;

  /// The selected source, or null when the section has none.
  DiscoverSource? get source {
    for (final s in available) {
      if (s.id == _sourceId) return s;
    }
    return available.isEmpty ? null : available.first;
  }

  List<DiscoverSort> get sortOptions => source?.sortsFor(_kind) ?? const [];

  /// Tag suggestions for the filter sheet — best-effort, may be empty.
  Future<List<String>> tagSuggestions() async =>
      source?.tags(_kind) ?? Future.value(const <String>[]);

  String _resolveSourceId(String wanted, DiscoverKind kind) {
    final candidates = sourcesFor(_sources, kind);
    for (final s in candidates) {
      if (s.id == wanted) return s.id;
    }
    return candidates.isEmpty ? '' : candidates.first.id;
  }

  String _initialSort() {
    final active = source;
    if (active == null) return '';
    final stored = _prefs.sortFor(_kind);
    if (stored != null &&
        active.sortsFor(_kind).any((s) => s.value == stored)) {
      return stored;
    }
    return active.defaultSortFor(_kind);
  }

  DiscoverQuery _query(int page) => DiscoverQuery(
        kind: _kind,
        search: _search,
        sort: _sort,
        page: page,
        nsfw: nsfw,
        includeTags: _includeTags,
        excludeTags: _excludeTags,
        pageSize: pageSize,
      );

  // --- Filters -------------------------------------------------------------

  void setKind(DiscoverKind kind) {
    if (kind == _kind) return;
    _kind = kind;
    _sourceId = _resolveSourceId(_sourceId, kind);
    _sort = _initialSort();
    refresh();
  }

  void setSource(String id) {
    if (id == source?.id) return;
    _sourceId = _resolveSourceId(id, _kind);
    _savePrefs(_prefs.copyWith(sourceId: _sourceId));
    // Tags and orderings are per-catalogue vocabularies; carrying them over
    // would silently filter the new feed down to nothing.
    _includeTags = const <String>[];
    _excludeTags = const <String>[];
    _sort = _initialSort();
    refresh();
  }

  void setSearch(String text) {
    final trimmed = text.trim();
    if (trimmed == _search) return;
    _search = trimmed;
    refresh();
  }

  void setSort(String sort) {
    if (sort == _sort) return;
    _sort = sort;
    _savePrefs(_prefs.withSort(_kind, sort));
    refresh();
  }

  void setNsfw(bool value) {
    if (value == nsfw) return;
    _savePrefs(_prefs.copyWith(nsfw: value));
    refresh();
  }

  void setTags({List<String>? include, List<String>? exclude}) {
    _includeTags = include ?? _includeTags;
    _excludeTags = exclude ?? _excludeTags;
    refresh();
  }

  /// Applies a whole filter sheet at once, so the feed reloads a single time
  /// rather than once per control.
  void applyFilters({
    String? sort,
    bool? nsfw,
    List<String>? include,
    List<String>? exclude,
  }) {
    var prefs = _prefs;
    if (sort != null && sort != _sort) {
      _sort = sort;
      prefs = prefs.withSort(_kind, sort);
    }
    if (nsfw != null && nsfw != prefs.nsfw) {
      prefs = prefs.copyWith(nsfw: nsfw);
    }
    if (prefs != _prefs) _savePrefs(prefs);
    _includeTags = include ?? _includeTags;
    _excludeTags = exclude ?? _excludeTags;
    refresh();
  }

  void _savePrefs(DiscoverPrefs next) {
    _prefs = next;
    onPrefsChanged?.call(next);
  }

  // --- Loading -------------------------------------------------------------

  /// Loads page one, replacing whatever is on screen.
  Future<void> refresh() async {
    final active = source;
    final generation = ++_generation;
    _page = 1;
    _items.clear();
    _seen.clear();
    _error = null;
    _hasMore = false;
    _loadingMore = false;
    if (active == null) {
      _loading = false;
      notifyListeners();
      return;
    }
    _loading = true;
    notifyListeners();
    try {
      final page = await active.search(_query(1));
      if (generation != _generation) return;
      _absorb(page);
    } on DiscoverException catch (error) {
      if (generation != _generation) return;
      _error = error.message;
    } catch (error) {
      if (generation != _generation) return;
      _error = 'Something went wrong talking to ${active.label}: $error';
    } finally {
      if (generation == _generation) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  /// Appends the next page. Safe to call repeatedly while scrolling.
  Future<void> loadMore() async {
    final active = source;
    if (active == null || _loading || _loadingMore || !_hasMore) return;
    final generation = _generation;
    _loadingMore = true;
    notifyListeners();
    try {
      final page = await active.search(_query(_page + 1));
      if (generation != _generation) return;
      _page += 1;
      _absorb(page);
    } on DiscoverException catch (error) {
      if (generation != _generation) return;
      // A failed *next* page keeps the results already on screen; the message
      // rides along at the bottom instead of blanking the feed.
      _error = error.message;
      _hasMore = false;
    } catch (_) {
      if (generation != _generation) return;
      _hasMore = false;
    } finally {
      if (generation == _generation) {
        _loadingMore = false;
        notifyListeners();
      }
    }
  }

  /// Adds a page's items, dropping repeats — these catalogues do return the
  /// same entry on two pages when the underlying order shifts mid-browse.
  void _absorb(DiscoverPage page) {
    for (final item in page.items) {
      if (_seen.add(item.key)) _items.add(item);
    }
    _hasMore = page.hasMore;
  }

  @override
  void dispose() {
    for (final source in _sources) {
      source.close();
    }
    super.dispose();
  }
}
