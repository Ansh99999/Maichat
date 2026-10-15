import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../models/home_layout.dart';
import '../state/app_state.dart';
import '../widgets/app_drawer.dart';
import '../widgets/avatar_image.dart';
import '../widgets/startup_screen.dart';
import 'home/home_grid.dart';
import 'home/home_sheets.dart';
import 'home/home_widgets.dart';
import 'providers/providers_screen.dart';

/// The section you land on: a home screen in the Android sense — a grid of
/// widgets the user arranges themselves, over a page or a few.
///
/// Out of the way by default: no title, no list, a wallpaper if one is chosen,
/// and the tiles. Long-pressing anywhere (or ⋮ ▸ Edit home screen) turns the
/// same screen into its editor, where tiles are carried, stretched, set up,
/// swapped and removed, and the grid itself can be changed. The editor works
/// on a draft; Done (or Back) keeps it, Discard throws it away.
///
/// Conversations and every other section open on top as detail screens, so
/// Back always returns here — the standard Android flow.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final PageController _pages = PageController();
  int _page = 0;

  /// The layout being edited; null outside edit mode.
  HomeLayout? _draft;
  String? _selectedId;

  bool get _editing => _draft != null;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  // --- edit mode ------------------------------------------------------------

  void _startEditing({String? select}) {
    if (_editing) return;
    setState(() {
      _draft = context.read<AppState>().homeLayout;
      _selectedId = select;
    });
  }

  Future<void> _finishEditing() async {
    final draft = _draft;
    if (draft == null) return;
    setState(() {
      _draft = null;
      _selectedId = null;
    });
    await context.read<AppState>().setHomeLayout(draft);
  }

  void _discard() => setState(() {
        _draft = null;
        _selectedId = null;
        final pages = context.read<AppState>().homeLayout.pages.length;
        if (_page >= pages) _jumpTo(pages - 1);
      });

  void _setDraft(HomeLayout next) {
    setState(() {
      _draft = next;
      if (_selectedId != null && next.tileById(_selectedId!) == null) {
        _selectedId = null;
      }
      if (_page >= next.pages.length) _jumpTo(next.pages.length - 1);
    });
  }

  void _jumpTo(int page) {
    _page = page;
    if (_pages.hasClients) _pages.jumpToPage(page);
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  bool _onTileChanged(HomeTile tile) {
    final next = _draft?.update(tile);
    if (next == null) return false;
    _setDraft(next);
    return true;
  }

  Future<void> _addWidget({({int x, int y})? at}) async {
    final draft = _draft;
    if (draft == null) return;
    final picked = await showAddWidgetSheet(context);
    if (picked == null || !mounted) return;
    final result = (_draft ?? draft).add(
      picked.kind,
      page: _page,
      at: at,
      config: picked.config,
    );
    if (result == null) {
      _toast('Every page is full. Remove something to make room.');
      return;
    }
    _setDraft(result.layout);
    setState(() => _selectedId = result.tile.id);
    if (result.page != _page) {
      _pages.animateToPage(
        result.page,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
      _toast('No room here, so it went on page ${result.page + 1}.');
    }
  }

  Future<void> _settings(HomeTile tile) => showTileSettingsSheet(
        context,
        tile: tile,
        onChanged: (next) {
          final updated = _draft?.update(next);
          if (updated != null) _setDraft(updated);
        },
      );

  /// Puts a different widget where [tile] is, at the same size where that is
  /// big enough for it.
  Future<void> _replace(HomeTile tile) async {
    final picked = await showAddWidgetSheet(context);
    final draft = _draft;
    if (picked == null || draft == null || !mounted) return;
    final min = specFor(picked.kind).minSpan;
    var next = tile.copyWith(
      kind: picked.kind,
      config: picked.config,
      w: tile.w < min.w ? min.w : tile.w,
      h: tile.h < min.h ? min.h : tile.h,
    );
    var placed = draft.update(next);
    if (placed == null) {
      // Too big for its neighbours at the new kind's minimum: keep the old
      // footprint rather than refuse.
      next = next.copyWith(w: tile.w, h: tile.h);
      placed = draft.update(next);
    }
    if (placed != null) _setDraft(placed);
  }

  void _duplicate(HomeTile tile) {
    final draft = _draft;
    if (draft == null) return;
    final result = draft.add(
      tile.kind,
      page: _page,
      config: tile.config,
      span: (w: tile.w, h: tile.h),
    );
    if (result == null) {
      _toast('There is no room for a copy.');
      return;
    }
    _setDraft(result.layout);
    setState(() => _selectedId = result.tile.id);
    if (result.page != _page) _toast('The copy went on page ${result.page + 1}.');
  }

  void _delete(HomeTile tile) {
    final draft = _draft;
    if (draft == null) return;
    final page = draft.pageOf(tile.id);
    _setDraft(draft.remove(tile.id));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('Removed ${specFor(tile.kind).title}'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () {
            final current = _draft;
            if (current == null) return;
            final back = current.put(page, tile);
            if (back != null) _setDraft(back);
          },
        ),
      ));
  }

  Future<void> _moveToPage(HomeTile tile) async {
    final draft = _draft;
    if (draft == null) return;
    final current = draft.pageOf(tile.id);
    final target = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < draft.pages.length; i++)
              ListTile(
                leading: Icon(
                  i == current ? Icons.radio_button_checked : Icons.radio_button_off,
                ),
                title: Text('Page ${i + 1}'),
                enabled: i != current,
                onTap: () => Navigator.of(context).pop(i),
              ),
            if (draft.pages.length < kHomeMaxPages)
              ListTile(
                leading: const Icon(Icons.add),
                title: const Text('A new page'),
                onTap: () => Navigator.of(context).pop(draft.pages.length),
              ),
          ],
        ),
      ),
    );
    if (target == null || !mounted) return;
    var base = _draft ?? draft;
    if (target >= base.pages.length) base = base.addPage();
    final moved = base.moveToPage(tile.id, target);
    if (moved == null) {
      _toast('Page ${target + 1} has no room for it.');
      return;
    }
    _setDraft(moved);
    _pages.animateToPage(
      target,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  void _addPage() {
    final draft = _draft;
    if (draft == null) return;
    if (draft.pages.length >= kHomeMaxPages) {
      _toast('$kHomeMaxPages pages is the most there can be.');
      return;
    }
    _setDraft(draft.addPage());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pages.hasClients) return;
      _pages.animateToPage(
        draft.pages.length,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    });
  }

  Future<void> _removePage() async {
    final draft = _draft;
    if (draft == null || draft.pages.length <= 1) return;
    final count = draft.pages[_page].tiles.length;
    if (count > 0) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Remove this page?'),
          content: Text(
            'Its $count ${count == 1 ? 'widget goes' : 'widgets go'} with it.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Remove'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    _setDraft((_draft ?? draft).removePage(_page));
  }

  Future<void> _reset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Start over?'),
        content: const Text(
          'The home screen goes back to how it first looked. Nothing in your '
          'chats, characters or pictures changes.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) _setDraft(HomeLayout.defaults());
  }

  // --- build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (!state.ready) return const StartupScreen();
    final layout = _draft ?? state.homeLayout;
    final loadError = state.loadError;
    final scheme = Theme.of(context).colorScheme;
    final showSetup = !_editing && !state.isConfigured;
    final selected = _selectedId == null ? null : layout.tileById(_selectedId!);

    return PopScope(
      canPop: !_editing,
      onPopInvokedWithResult: (didPop, _) {
        // Back leaves the editor and keeps what was done, as a launcher does.
        if (!didPop && _editing) _finishEditing();
      },
      child: Scaffold(
        drawer: _editing ? null : const AppDrawer(selected: DrawerSection.home),
        backgroundColor: scheme.surface,
        body: Stack(
          children: [
            if (layout.wallpaper != null)
              Positioned.fill(
                child: _Wallpaper(
                  image: layout.wallpaper!,
                  dim: layout.wallpaperDim,
                ),
              ),
            SafeArea(
              child: Column(
                children: [
                  _editing
                      ? _EditBar(
                          canRemovePage: layout.pages.length > 1,
                          onDone: _finishEditing,
                          onDiscard: _discard,
                          onAdd: () => _addWidget(),
                          onGrid: () => showGridSheet(
                            context,
                            layout: _draft!,
                            onChanged: _setDraft,
                          ),
                          onStyle: () => showHomeStyleSheet(
                            context,
                            layout: _draft!,
                            onChanged: _setDraft,
                          ),
                          onAddPage: _addPage,
                          onRemovePage: _removePage,
                          onReset: _reset,
                        )
                      : _TopBar(onEdit: () => _startEditing()),
                  if (loadError != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: LoadErrorCard(message: loadError),
                    ),
                  if (showSetup)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: _SetupBanner(),
                    ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: LayoutBuilder(
                        builder: (context, box) {
                          final metrics = HomeGridMetrics(
                            columns: layout.columns,
                            rows: layout.rows,
                            size: box.biggest,
                          );
                          return PageView.builder(
                            controller: _pages,
                            itemCount: layout.pages.length,
                            // Dragging a tile must not swipe the page under it.
                            physics: _editing && _selectedId != null
                                ? const NeverScrollableScrollPhysics()
                                : const PageScrollPhysics(),
                            onPageChanged: (i) => setState(() {
                              _page = i;
                              _selectedId = null;
                            }),
                            itemBuilder: (context, i) => HomeGridPage(
                              key: ValueKey('home-page-${layout.pages[i].id}'),
                              layout: layout,
                              pageIndex: i,
                              metrics: metrics,
                              editing: _editing,
                              selectedId: _selectedId,
                              onSelect: (id) =>
                                  setState(() => _selectedId = id),
                              onChange: _onTileChanged,
                              onTapEmpty: (x, y) =>
                                  _addWidget(at: (x: x, y: y)),
                              onEnterEdit: (id) => _startEditing(select: id),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  _PageDots(
                    count: layout.pages.length,
                    current: _page.clamp(0, layout.pages.length - 1),
                    editing: _editing,
                    onTap: (i) => _pages.animateToPage(
                      i,
                      duration: const Duration(milliseconds: 320),
                      curve: Curves.easeOutCubic,
                    ),
                  ),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOutCubic,
                    child: _editing && selected != null
                        ? _TileToolbar(
                            label: specFor(selected.kind)
                                .describe(context, selected),
                            multiPage: layout.pages.length > 1 ||
                                layout.pages.length < kHomeMaxPages,
                            onSettings: () => _settings(selected),
                            onReplace: () => _replace(selected),
                            onDuplicate: () => _duplicate(selected),
                            onMove: () => _moveToPage(selected),
                            onDelete: () => _delete(selected),
                          )
                        : const SizedBox(width: double.infinity),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Outside edit mode: the drawer button and a ⋮ menu, nothing else.
class _TopBar extends StatelessWidget {
  const _TopBar({required this.onEdit});

  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
      child: Row(
        children: [
          Builder(
            builder: (context) => IconButton(
              tooltip: 'Menu',
              icon: const Icon(Icons.menu_rounded),
              onPressed: () => Scaffold.of(context).openDrawer(),
            ),
          ),
          const Spacer(),
          PopupMenuButton<String>(
            tooltip: 'Home screen options',
            icon: const Icon(Icons.more_vert_rounded),
            onSelected: (_) => onEdit(),
            itemBuilder: (context) => const [
              PopupMenuItem<String>(
                value: 'edit',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.dashboard_customize_outlined),
                  title: Text('Edit home screen'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// In edit mode: Done, and what can be done to the screen as a whole.
class _EditBar extends StatelessWidget {
  const _EditBar({
    required this.canRemovePage,
    required this.onDone,
    required this.onDiscard,
    required this.onAdd,
    required this.onGrid,
    required this.onStyle,
    required this.onAddPage,
    required this.onRemovePage,
    required this.onReset,
  });

  final bool canRemovePage;
  final VoidCallback onDone;
  final VoidCallback onDiscard;
  final VoidCallback onAdd;
  final VoidCallback onGrid;
  final VoidCallback onStyle;
  final VoidCallback onAddPage;
  final VoidCallback onRemovePage;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
      child: Row(
        children: [
          FilledButton.icon(
            onPressed: onDone,
            icon: const Icon(Icons.check_rounded),
            label: const Text('Done'),
          ),
          const Spacer(),
          IconButton.filledTonal(
            tooltip: 'Add widget',
            icon: const Icon(Icons.add_rounded),
            onPressed: onAdd,
          ),
          IconButton(
            tooltip: 'Grid',
            icon: const Icon(Icons.grid_view_rounded),
            onPressed: onGrid,
          ),
          IconButton(
            tooltip: 'Look',
            icon: const Icon(Icons.wallpaper_rounded),
            onPressed: onStyle,
          ),
          PopupMenuButton<String>(
            tooltip: 'More',
            icon: const Icon(Icons.more_vert_rounded),
            onSelected: (v) => switch (v) {
              'addPage' => onAddPage(),
              'removePage' => onRemovePage(),
              'reset' => onReset(),
              _ => onDiscard(),
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'addPage',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.add_to_photos_outlined),
                  title: Text('Add a page'),
                ),
              ),
              PopupMenuItem(
                value: 'removePage',
                enabled: canRemovePage,
                child: const ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.layers_clear_outlined),
                  title: Text('Remove this page'),
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'reset',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.restart_alt_rounded),
                  title: Text('Reset to default'),
                ),
              ),
              const PopupMenuItem(
                value: 'discard',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.undo_rounded),
                  title: Text('Discard changes'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The floating toolbar for the selected tile (Material 3 Expressive's
/// floating toolbar: a pill of icon buttons above the navigation bar).
class _TileToolbar extends StatelessWidget {
  const _TileToolbar({
    required this.label,
    required this.multiPage,
    required this.onSettings,
    required this.onReplace,
    required this.onDuplicate,
    required this.onMove,
    required this.onDelete,
  });

  final String label;
  final bool multiPage;
  final VoidCallback onSettings;
  final VoidCallback onReplace;
  final VoidCallback onDuplicate;
  final VoidCallback onMove;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelLarge
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          Material(
            color: scheme.primaryContainer,
            shape: const StadiumBorder(),
            elevation: 3,
            shadowColor: scheme.shadow.withValues(alpha: 0.3),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: IconTheme(
                data: IconThemeData(color: scheme.onPrimaryContainer),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Widget settings',
                      icon: const Icon(Icons.tune_rounded),
                      onPressed: onSettings,
                    ),
                    IconButton(
                      tooltip: 'Replace',
                      icon: const Icon(Icons.swap_horiz_rounded),
                      onPressed: onReplace,
                    ),
                    IconButton(
                      tooltip: 'Duplicate',
                      icon: const Icon(Icons.content_copy_rounded),
                      onPressed: onDuplicate,
                    ),
                    if (multiPage)
                      IconButton(
                        tooltip: 'Move to page',
                        icon: const Icon(Icons.drive_file_move_outline),
                        onPressed: onMove,
                      ),
                    IconButton(
                      tooltip: 'Remove',
                      icon: Icon(Icons.delete_outline_rounded,
                          color: scheme.error),
                      onPressed: onDelete,
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Drag to move · pull a dot to resize',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// Which page is showing. Hidden with a single page outside edit mode.
class _PageDots extends StatelessWidget {
  const _PageDots({
    required this.count,
    required this.current,
    required this.editing,
    required this.onTap,
  });

  final int count;
  final int current;
  final bool editing;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    if (count <= 1 && !editing) return const SizedBox(height: 8);
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 28,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (var i = 0; i < count; i++)
            Semantics(
              button: true,
              selected: i == current,
              label: 'Page ${i + 1} of $count',
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onTap(i),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    width: i == current ? 22 : 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: i == current
                          ? scheme.primary
                          : scheme.onSurfaceVariant.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A quiet nudge while no provider can answer yet.
class _SetupBanner extends StatelessWidget {
  const _SetupBanner();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    return Material(
      color: scheme.primaryContainer,
      shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Row(
          children: [
            Icon(Icons.key_rounded, color: scheme.onPrimaryContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Connect a provider so characters can reply.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: scheme.onPrimaryContainer),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const ProvidersScreen()),
              ),
              child: const Text('Set up'),
            ),
          ],
        ),
      ),
    );
  }
}

/// The picture behind the grid, faded into the surface so tiles stay legible.
class _Wallpaper extends StatelessWidget {
  const _Wallpaper({required this.image, required this.dim});

  final String image;
  final double dim;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final provider = avatarImage(
      image,
      displaySize: size.longestSide,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
    );
    if (provider == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      fit: StackFit.expand,
      children: [
        Image(
          image: provider,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
        ),
        ColoredBox(color: scheme.surface.withValues(alpha: dim)),
      ],
    );
  }
}
