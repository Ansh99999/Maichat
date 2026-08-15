import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/discover.dart';
import '../../services/discover/discover_sources.dart';
import '../../state/app_state.dart';
import '../../widgets/app_drawer.dart';
import 'discover_card.dart';
import 'discover_controller.dart';
import 'discover_filter_sheet.dart';
import 'discover_item_screen.dart';

/// Discover: a second home screen that browses other people's catalogues
/// instead of your own library.
///
/// The shape is deliberately the one Android users already know from a store
/// app — a large title that gets out of the way as you scroll, one search
/// field, a row of chips choosing *where* you are looking, and a bottom bar
/// choosing *what* you are looking for. Tapping anything opens a page that reads
/// exactly like a character's own page here, except the button says Download.
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
      prefs: state.discoverPrefs,
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
    final source = _controller.source;
    if (source == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DiscoverItemScreen(item: item, source: source),
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
          drawer: const AppDrawer(selected: DrawerSection.discover),
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
                  title: const Text('Discover'),
                  actions: [
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
                SliverToBoxAdapter(child: _sourceChips()),
                ..._feed(),
                SliverToBoxAdapter(child: _footer()),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _searchField() => Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
        child: SearchBar(
          controller: _search,
          hintText: 'Search ${_controller.source?.label ?? 'catalogues'}',
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

  /// Which catalogue is being browsed. One at a time on purpose: each site has
  /// its own orderings and its own tag vocabulary, and a merged feed would have
  /// to throw both away.
  Widget _sourceChips() {
    final available = _controller.available;
    if (available.length < 2) return const SizedBox(height: 4);
    final selected = _controller.source?.id;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          children: [
            for (final source in available) ...[
              ChoiceChip(
                label: Text(source.label),
                selected: source.id == selected,
                onSelected: (_) => _controller.setSource(source.id),
              ),
              const SizedBox(width: 8),
            ],
          ],
        ),
      ),
    );
  }

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
            Text(
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
