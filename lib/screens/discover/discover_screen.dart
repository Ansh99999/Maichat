import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/discover.dart';
import '../../services/discover/discover_sources.dart';
import '../../state/app_state.dart';
import '../../widgets/app_drawer.dart';
import '../../widgets/brand_mark.dart';
import 'discover_card.dart';
import 'discover_controller.dart';
import 'discover_filter_sheet.dart';
import 'discover_item_screen.dart';

/// Discover: a second home screen that browses other people's catalogues
/// instead of your own library.
///
/// The shape is deliberately the one Android users already know from a store
/// app — a large title that gets out of the way as you scroll, one search
/// field, and a bottom bar choosing *what* you are looking for. Tapping anything
/// opens a page that reads exactly like a character's own page here, except the
/// button says Download.
///
/// *Where* you are looking lives in the navigation drawer, one entry per site,
/// because the list outgrew a row of chips and because a catalogue is a place
/// rather than a filter. The choice holds across all three sections: pick
/// Character Tavern and its characters, lorebooks and presets are what the
/// bottom bar switches between.
class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key, this.sources});

  /// Injectable for tests; production builds the real catalogues.
  final List<DiscoverSource>? sources;

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  late final DiscoverController _controller;
  final TextEditingController _search = TextEditingController();
  final ScrollController _scroll = ScrollController();
  Timer? _debounce;

  /// How close to the bottom the feed asks for another page.
  static const double _loadMoreSlack = 600;

  @override
  void initState() {
    super.initState();
    final state = context.read<AppState>();
    _controller = DiscoverController(
      sources: widget.sources ?? buildDiscoverSources(),
      // Discover always opens on the first catalogue — Chub — rather than
      // wherever you happened to stop last time, so the drawer's first entry is
      // always what you are looking at. The rest of the preferences (adult
      // results, per-section ordering) do persist.
      prefs: state.discoverPrefs.copyWith(sourceId: ''),
      onPrefsChanged: state.updateDiscoverPrefs,
    );
    _scroll.addListener(_onScroll);
    // The first page starts loading as the screen appears, not before, so a
    // failure has somewhere to be shown.
    WidgetsBinding.instance.addPostFrameCallback((_) => _controller.refresh());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _search.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    if (position.pixels >= position.maxScrollExtent - _loadMoreSlack) {
      _controller.loadMore();
    }
  }

  /// Searching as you type, but only once you stop — these are somebody else's
  /// servers.
  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 450),
      () => _controller.setSearch(value),
    );
  }

  void _open(DiscoverItem item) {
    // The section may be borrowing another catalogue's shelf, and the download
    // has to go to whoever actually answered.
    final source = _controller.effectiveSource;
    if (source == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DiscoverItemScreen(item: item, source: source),
      ),
    );
  }

  /// Explains, on request, where this section's results come from and what a
  /// download brings with it. The two facts worth knowing are both invisible
  /// otherwise: that a catalogue without lorebooks of its own shows Chub's, and
  /// that a character stitched to a lorebook arrives with it.
  void _explainSection() {
    final chosen = _controller.source?.label ?? 'This catalogue';
    final borrowed = _controller.borrowedFrom;
    final section = _controller.kind.label.toLowerCase();
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.info_outline),
        title: Text('About $section here'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (borrowed != null)
              Text(
                '$chosen does not publish $section of its own, so these are '
                '${borrowed.label}\'s. Downloading one files it in your Library '
                'exactly the same way.',
              )
            else
              Text('These $section come from $chosen.'),
            const SizedBox(height: 14),
            const Text(
              'A character with a lorebook stitched into its card brings that '
              'lorebook with it: download the character and the book is filed '
              'under Lorebooks in your Library at the same time. You do not '
              'need to find it here.',
            ),
          ],
        ),
        actions: [
          FilledButton.tonal(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final activeFilters = _controller.includeTags.length +
            _controller.excludeTags.length +
            (_controller.nsfw ? 1 : 0);
        return Scaffold(
          drawer: AppDrawer(
            selected: DrawerSection.discover,
            // In Discover the drawer *is* the catalogue picker: Home to leave,
            // then one entry per site.
            catalogues: _controller.sources,
            selectedCatalogueId: _controller.source?.id,
            onCatalogue: _controller.setSource,
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _controller.kind.index,
            onDestinationSelected: (index) =>
                _controller.setKind(DiscoverKind.values[index]),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.people_alt_outlined),
                selectedIcon: Icon(Icons.people_alt),
                label: 'Characters',
              ),
              NavigationDestination(
                icon: Icon(Icons.menu_book_outlined),
                selectedIcon: Icon(Icons.menu_book),
                label: 'Lorebooks',
              ),
              NavigationDestination(
                icon: Icon(Icons.tune_outlined),
                selectedIcon: Icon(Icons.tune),
                label: 'Presets',
              ),
            ],
          ),
          body: RefreshIndicator(
            onRefresh: _controller.refresh,
            child: CustomScrollView(
              controller: _scroll,
              // Always scrollable so pull-to-refresh works on an empty feed.
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverAppBar.large(
                  title: _title(),
                  actions: [
                    IconButton(
                      tooltip: 'Where these come from',
                      // Tinted when the shelf is not this catalogue's own, so
                      // the explanation advertises itself.
                      color: _controller.borrowedFrom == null
                          ? null
                          : Theme.of(context).colorScheme.primary,
                      icon: const Icon(Icons.info_outline),
                      onPressed: _explainSection,
                    ),
                    IconButton(
                      tooltip: 'Filters',
                      isSelected: activeFilters > 0,
                      icon: Badge(
                        isLabelVisible: activeFilters > 0,
                        label: Text('$activeFilters'),
                        child: const Icon(Icons.filter_list),
                      ),
                      onPressed: () =>
                          showDiscoverFilters(context, _controller),
                    ),
                  ],
                ),
                SliverToBoxAdapter(child: _searchField()),
                ..._feed(),
                SliverToBoxAdapter(child: _footer()),
              ],
            ),
          ),
        );
      },
    );
  }

  /// The catalogue being browsed, with a line underneath when this section's
  /// results are somebody else's.
  Widget _title() {
    final label = _controller.source?.label ?? 'Discover';
    final borrowed = _controller.borrowedFrom;
    if (borrowed == null) return Text(label);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label),
        Text(
          '${_controller.kind.label} from ${borrowed.label}',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      ],
    );
  }

  Widget _searchField() => Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
        child: SearchBar(
          controller: _search,
          hintText: 'Search ${_controller.effectiveSource?.label ?? 'catalogues'}',
          leading: const Icon(Icons.search),
          trailing: [
            if (_search.text.isNotEmpty)
              IconButton(
                tooltip: 'Clear',
                icon: const Icon(Icons.close),
                onPressed: () {
                  _search.clear();
                  _debounce?.cancel();
                  _controller.setSearch('');
                },
              ),
          ],
          onChanged: (value) {
            setState(() {}); // Keeps the clear button in step.
            _onSearchChanged(value);
          },
          onSubmitted: (value) {
            _debounce?.cancel();
            _controller.setSearch(value);
          },
        ),
      );

  List<Widget> _feed() {
    if (_controller.sectionUnavailable) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: _Message(
            icon: _controller.kind == DiscoverKind.preset
                ? Icons.tune_outlined
                : Icons.travel_explore_outlined,
            title: 'No catalogue for ${_controller.kind.label.toLowerCase()}',
            body: _controller.kind == DiscoverKind.preset
                ? 'None of the sites MaiChat can browse publish generation '
                    'presets yet. Import one from a file in Presets, or paste '
                    'a SillyTavern preset there.'
                : 'None of the sites MaiChat can browse publish these yet.',
          ),
        ),
      ];
    }

    if (_controller.loading && _controller.items.isEmpty) {
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }

    if (_controller.items.isEmpty) {
      final error = _controller.error;
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: error != null
              ? _Message(
                  icon: Icons.cloud_off_outlined,
                  title: 'Could not load the feed',
                  body: error,
                  action: FilledButton.tonal(
                    onPressed: _controller.refresh,
                    child: const Text('Try again'),
                  ),
                )
              : _Message(
                  icon: Icons.search_off_outlined,
                  title: 'Nothing found',
                  body: 'Try a different search, or loosen the filters.',
                ),
        ),
      ];
    }

    final items = _controller.items;
    if (_controller.kind == DiscoverKind.character) {
      return [
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverGrid.builder(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 220,
              childAspectRatio: 0.66,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
            ),
            itemCount: items.length,
            itemBuilder: (context, index) => DiscoverCard(
              item: items[index],
              onTap: () => _open(items[index]),
            ),
          ),
        ),
      ];
    }

    return [
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        sliver: SliverList.separated(
          itemCount: items.length,
          separatorBuilder: (context, index) => const SizedBox(height: 10),
          itemBuilder: (context, index) => DiscoverRow(
            item: items[index],
            onTap: () => _open(items[index]),
          ),
        ),
      ),
    ];
  }

  /// The strip under the feed: the next page arriving, a page that failed, or
  /// simply the end of the catalogue.
  Widget _footer() {
    final scheme = Theme.of(context).colorScheme;
    if (_controller.items.isEmpty) return const SizedBox(height: 24);
    if (_controller.loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    final error = _controller.error;
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
        child: Column(
          children: [
            Text(
              error,
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.error),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _controller.loadMore,
              child: const Text('Load more'),
            ),
          ],
        ),
      );
    }
    if (!_controller.hasMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Text(
            'That is everything.',
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      );
    }
    return const SizedBox(height: 24);
  }
}

/// The shared full-screen state: an icon, a heading, an explanation and an
/// optional button.
class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    required this.body,
    this.action,
  });

  final IconData icon;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(36, 48, 36, 64),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 44, color: scheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            BrandedText(
              body,
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            if (action != null) ...[
              const SizedBox(height: 20),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
