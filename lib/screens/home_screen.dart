import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart' hide Provider;

import '../models/home_layout.dart';
import '../state/app_state.dart';
import '../widgets/app_drawer.dart';
import '../widgets/avatar_image.dart';
import '../widgets/startup_screen.dart';
import 'home/home_grid.dart';
import 'home/home_menu.dart';
import 'home/home_spec.dart';
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

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  final PageController _pages = PageController();
  int _page = 0;

  /// The layout being edited; null outside edit mode.
  HomeLayout? _draft;

  /// The selected tile (resize handles are immediately available).
  String? _selectedId;

  String? _menuId;
  final ValueNotifier<int> _motion = ValueNotifier(0);
  final ValueNotifier<int> _visiblePage = ValueNotifier(0);
  final Map<String, (Object, Widget)> _pageCache = {};

  /// The tile showing its resize handles (edit mode).
  String? _resizingId;
  int? _resizePointer;
  ScrollHoldController? _resizeHold;

  /// The tile being carried, if any.
  _Carry? _carry;

  /// The grid area's global top-left, for turning finger positions into cells.
  final GlobalKey _gridKey = GlobalKey();

  /// Pages flip when a carried tile is held at a screen edge.
  Timer? _edgeTimer;

  /// Fingers other than the one holding a tile, by pointer id, and where each
  /// went down — a second finger swiping pages while the first one carries.
  final Map<int, Offset> _otherFingers = <int, Offset>{};
  int? _carryPointer;

  bool get _editing => _draft != null;

  /// A bounded 180 ms placement animation with guaranteed completion; only
  /// the overlay listens to its frames.
  late final AnimationController _settle;

  @override
  void initState() {
    super.initState();
    _settle =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 180),
        )..addListener(() {
          if (_landing != null) _motion.value++;
        });
  }

  ({Rect from, Rect to, HomeTile tile})? _landing;

  void _settleInto(Rect from, Rect to, HomeTile tile) {
    final landing = (from: from, to: to, tile: tile);
    _landing = landing;
    // Only the overlay listens to the animation; every page stays intact.
    _settle.forward(from: 0).orCancel.then((_) {
      if (mounted && _landing == landing) {
        setState(() => _landing = null);
      }
    }, onError: (Object _) {});
  }

  void _clearInteraction() {
    _edgeTimer?.cancel();
    _edgeTimer = null;
    _otherFingers.clear();
    _carryPointer = null;
    _resizePointer = null;
    _resizeHold?.cancel();
    _resizeHold = null;
    _settle.stop();
    _landing = null;
    _carry = null;
    _selectedId = null;
    _resizingId = null;
    _menuId = null;
  }

  @override
  void dispose() {
    _resizeHold?.cancel();
    _motion.dispose();
    _visiblePage.dispose();
    _settle.dispose();
    _edgeTimer?.cancel();
    _pages.dispose();
    super.dispose();
  }

  // --- edit mode ------------------------------------------------------------

  void _startEditing({String? select}) {
    if (_resizePointer != null) return;
    if (_editing) {
      if (select != null) {
        setState(() {
          _selectedId = select;
          _resizingId = select;
        });
      }
      return;
    }
    setState(() {
      _draft = context.read<AppState>().homeLayout;
      _selectedId = select;
      _resizingId = select;
    });
  }

  Future<void> _finishEditing() async {
    final draft = _draft;
    if (draft == null) return;
    setState(() {
      _clearInteraction();
      _draft = null;
    });
    await context.read<AppState>().setHomeLayout(draft);
  }

  void _discard() => setState(() {
    _clearInteraction();
    _draft = null;
    final pages = context.read<AppState>().homeLayout.pages.length;
    if (_page >= pages) _jumpTo(pages - 1);
  });

  void _setDraft(HomeLayout next) {
    setState(() {
      _draft = next;
      if (_selectedId != null && next.tileById(_selectedId!) == null) {
        _selectedId = null;
      }
      if (_resizingId != null && next.tileById(_resizingId!) == null) {
        _resizingId = null;
      }
      if (_page >= next.pages.length) _jumpTo(next.pages.length - 1);
    });
  }

  void _jumpTo(int page) {
    _page = page;
    _visiblePage.value = page;
    if (_pages.hasClients) _pages.jumpToPage(page);
  }

  void _animateTo(int page) {
    if (!_pages.hasClients) return;
    _pages.animateToPage(
      page,
      duration: const Duration(milliseconds: 360),
      curve: Curves.easeOutCubic,
    );
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _closeMenu() {
    if (_resizePointer != null) return;
    setState(() {
      _selectedId = null;
      _resizingId = null;
      _menuId = null;
    });
  }

  void _onTileTap(String id) {
    // A second finger landing on a tile while another is carried is paging,
    // not picking.
    if (!_editing || _carry != null || _resizePointer != null) return;
    setState(() {
      _selectedId = id;
      _resizingId = id;
      _menuId = null;
    });
  }

  bool _onResize(HomeTile tile) {
    final next = _draft?.update(tile);
    if (next == null) return false;
    _setDraft(next);
    return true;
  }

  void _holdResizePage() {
    if (_pages.hasClients) {
      _resizeHold = _pages.position.hold(() => _resizeHold = null);
    }
  }

  bool _onResizePointerChanged(int pointer, bool active) {
    if (!mounted) return false;
    if (active) {
      if (_resizePointer != null || _carry != null) return false;
      setState(() => _resizePointer = pointer);
      _holdResizePage();
      // Scrollable's own down/cancel handlers can replace the initial hold.
      // Restore it after this event, before a snap animation gets another frame.
      scheduleMicrotask(() {
        if (mounted && _resizePointer == pointer) _holdResizePage();
      });
      return true;
    }
    // A removed grip or another finger cannot release the current owner's hold.
    if (_resizePointer != pointer) return false;
    _resizeHold?.cancel();
    _resizeHold = null;
    setState(() => _resizePointer = null);
    return true;
  }

  // --- carrying -------------------------------------------------------------

  Offset _gridOrigin() {
    final box = _gridKey.currentContext?.findRenderObject() as RenderBox?;
    return box?.localToGlobal(Offset.zero) ?? Offset.zero;
  }

  bool _liftStart(
    HomeTile tile,
    Offset global,
    Offset grab,
    HomeGridMetrics metrics,
  ) {
    if (_carry != null || _resizePointer != null) return false;
    // A new touch interrupts a settling tile immediately.
    _settle.stop();
    _landing = null;
    HapticFeedback.mediumImpact();
    if (!_editing) {
      _draft = context.read<AppState>().homeLayout;
    }
    final page = _draft!.pageOf(tile.id);
    setState(() {
      _carry = _Carry(
        tile: tile,
        fromPage: page,
        grab: grab,
        finger: global,
        metrics: metrics,
        // The menu opens on a hold; moving closes it.
        moved: false,
      );
      _selectedId = tile.id;
      _resizingId = tile.id;
      _menuId = tile.id;
    });
    _updateLanding();
    return true;
  }

  void _liftMove(Offset global) {
    final carry = _carry;
    if (carry == null) return;
    final wasMoving = carry.moved;
    final moved = wasMoving || (global - carry.origin).distance > 8;
    carry
      ..finger = global
      ..moved = moved;
    if (moved) {
      _selectedId = null;
      _resizingId = null;
      _menuId = null;
    }
    _updateLanding();
    _edgeHover(global);
    // Hide the source once; subsequent pointer frames update only the overlay.
    if (moved != wasMoving) setState(() {});
    _motion.value++;
  }

  /// Works out where the carried tile would land on the page now showing, and
  /// whether that is onto another shortcut or folder (a merge).
  void _updateLanding() {
    final carry = _carry;
    final draft = _draft;
    if (carry == null || draft == null) return;
    final m = carry.metrics;
    final topLeft =
        carry.finger - _gridOrigin() - carry.grab - Offset(m.gutter, m.gutter);
    final cell = m.snap(topLeft, carry.tile.w, carry.tile.h);
    final page = _page.clamp(0, draft.pages.length - 1);
    final candidate = carry.tile.copyWith(x: cell.x, y: cell.y);
    String? mergeWith;
    if (carry.tile.kind == HomeWidgetKind.quickOpen) {
      final under = m.cellAt(carry.finger - _gridOrigin());
      for (final t in draft.pages[page].tiles) {
        if (t.id == carry.tile.id) continue;
        if ((t.kind == HomeWidgetKind.quickOpen ||
                t.kind == HomeWidgetKind.appFolder) &&
            under.x >= t.x &&
            under.x < t.right &&
            under.y >= t.y &&
            under.y < t.bottom) {
          mergeWith = t.id;
        }
      }
    }
    carry
      ..landing = candidate
      ..landingPage = page
      ..mergeWith = mergeWith
      ..fits =
          mergeWith != null ||
          draft.remove(carry.tile.id).fits(page, candidate);
  }

  /// Holding a carried tile at the left or right edge turns the page.
  void _edgeHover(Offset global) {
    final width = MediaQuery.sizeOf(context).width;
    final draft = _draft;
    if (draft == null) return;
    final dir = global.dx < 28 ? -1 : (global.dx > width - 28 ? 1 : 0);
    if (dir == 0) {
      _edgeTimer?.cancel();
      _edgeTimer = null;
      return;
    }
    if (_edgeTimer != null) return;
    _edgeTimer = Timer(const Duration(milliseconds: 450), () {
      _edgeTimer = null;
      if (_carry == null) return;
      var target = _page + dir;
      final current = _draft;
      if (current == null) return;
      if (target >= current.pages.length &&
          current.pages.length < kHomeMaxPages) {
        // Off the last page: a new one, as a launcher does.
        _setDraft(current.addPage());
      }
      target = target.clamp(0, (_draft ?? current).pages.length - 1);
      if (target != _page) {
        _animateTo(target);
        HapticFeedback.selectionClick();
      }
    });
  }

  void _liftEnd() {
    final carry = _carry;
    final draft = _draft;
    _edgeTimer?.cancel();
    _edgeTimer = null;
    _otherFingers.clear();
    if (carry == null || draft == null) return;
    if (!carry.moved) {
      // A hold without a move: the menu stays open on the tile.
      setState(() => _carry = null);
      return;
    }
    HomeLayout? next;
    if (carry.mergeWith != null) {
      next = draft.mergeIntoFolder(carry.tile.id, carry.mergeWith!);
      if (next != null) HapticFeedback.lightImpact();
    }
    next ??= carry.landing == null
        ? null
        : draft.moveTo(
            carry.tile.id,
            carry.landingPage,
            carry.landing!.x,
            carry.landing!.y,
          );
    // Settle from where the finger let go to where the tile now lives (or
    // back home, when the drop was refused).
    final m = carry.metrics;
    final from = Rect.fromLTWH(
      carry.finger.dx - _gridOrigin().dx - carry.grab.dx,
      carry.finger.dy - _gridOrigin().dy - carry.grab.dy,
      m.surfaceFor(carry.tile).width,
      m.surfaceFor(carry.tile).height,
    );
    final landed = next?.tileById(carry.tile.id);
    final mergedInto = carry.mergeWith == null
        ? null
        : next?.tileById(carry.mergeWith!);
    final onPage = next == null
        ? carry.fromPage == _page
        : (landed != null && next.pageOf(landed.id) == _page) ||
              mergedInto != null;
    final target = mergedInto ?? landed ?? carry.tile;
    setState(() {
      _carry = null;
      _selectedId = null;
      _resizingId = null;
      _menuId = null;
    });
    if (next != null) _setDraft(next);
    if (onPage) {
      _settleInto(
        from,
        m.surfaceFor(target),
        mergedInto != null ? carry.tile : target,
      );
    }
  }

  /// Raw pointers over the whole grid: a second finger's horizontal swipe
  /// turns the page while the first one holds a tile.
  void _onPointerDown(PointerDownEvent e) {
    if (_resizePointer != null) return;
    if (_carry == null) {
      _carryPointer = e.pointer;
      return;
    }
    if (e.pointer != _carryPointer) _otherFingers[e.pointer] = e.position;
  }

  void _onPointerUp(PointerEvent e) {
    _onResizePointerChanged(e.pointer, false);
    final start = _otherFingers.remove(e.pointer);
    if (start == null || _carry == null) return;
    final dx = e.position.dx - start.dx;
    final draft = _draft;
    if (draft == null || dx.abs() < 48) return;
    var target = _page + (dx < 0 ? 1 : -1);
    if (target >= draft.pages.length && draft.pages.length < kHomeMaxPages) {
      _setDraft(draft.addPage());
    }
    target = target.clamp(0, (_draft ?? draft).pages.length - 1);
    if (target != _page) {
      _animateTo(target);
      HapticFeedback.selectionClick();
    }
  }

  void _onPointerCancel(PointerCancelEvent event) {
    _onResizePointerChanged(event.pointer, false);
    _otherFingers.remove(event.pointer);
    if (event.pointer != _carryPointer || _carry == null) return;
    setState(_clearInteraction);
  }

  // --- tile actions ---------------------------------------------------------

  Future<void> _onAction(HomeTile tile, HomeTileAction action) async {
    switch (action) {
      case HomeTileAction.edit:
        _closeMenu();
        await _settings(tile);
      case HomeTileAction.replace:
        _closeMenu();
        await _replace(tile);
      case HomeTileAction.duplicate:
        _closeMenu();
        _duplicate(tile);
      case HomeTileAction.move:
        _closeMenu();
        await _moveToPage(tile);
      case HomeTileAction.remove:
        _closeMenu();
        _delete(tile);
    }
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
    if (result.page != _page) {
      _animateTo(result.page);
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
    if (result.page != _page) {
      _toast('The copy went on page ${result.page + 1}.');
    }
  }

  void _delete(HomeTile tile) {
    final draft = _draft;
    if (draft == null) return;
    final page = draft.pageOf(tile.id);
    _setDraft(draft.remove(tile.id));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
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
        ),
      );
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
                  i == current
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
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
    _animateTo(target);
  }

  void _addPage() {
    final draft = _draft;
    if (draft == null) return;
    if (draft.pages.length >= kHomeMaxPages) {
      _toast('$kHomeMaxPages pages is the most there can be.');
      return;
    }
    _setDraft(draft.addPage());
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _animateTo(draft.pages.length),
    );
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
    // Only what this screen draws itself: a reply streaming into a chat, a
    // usage tick or a gallery write must not rebuild every page mid-swipe.
    // Each widget selects its own slice of the state.
    final ready = context.select<AppState, bool>((s) => s.ready);
    if (!ready) return const StartupScreen();
    final stored = context.select<AppState, HomeLayout>((s) => s.homeLayout);
    final loadError = context.select<AppState, String?>((s) => s.loadError);
    final configured = context.select<AppState, bool>((s) => s.isConfigured);
    final layout = _draft ?? stored;
    final scheme = Theme.of(context).colorScheme;
    // Shown in edit mode too: nothing above the grid may change size on the
    // way into the editor, or every tile would move under the finger.
    final showSetup = !configured;

    return PopScope(
      canPop: !_editing,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || !_editing) return;
        // Back closes the open menu first, then leaves the editor and keeps
        // what was done, as a launcher does.
        if (_selectedId != null || _resizingId != null) {
          _closeMenu();
        } else {
          _finishEditing();
        }
      },
      child: Scaffold(
        drawer: _editing ? null : const AppDrawer(selected: DrawerSection.home),
        backgroundColor: scheme.surface,
        body: Stack(
          children: [
            if (layout.wallpaper != null)
              Positioned.fill(
                child: RepaintBoundary(
                  child: _Wallpaper(
                    image: layout.wallpaper!,
                    dim: layout.wallpaperDim,
                  ),
                ),
              ),
            SafeArea(
              child: Column(
                children: [
                  // One fixed height for both bars, for the same reason.
                  SizedBox(
                    height: 64,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      child: _editing
                          ? _EditBar(
                              key: const ValueKey('edit-bar'),
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
                          : _TopBar(
                              key: const ValueKey('top-bar'),
                              onEdit: () => _startEditing(),
                            ),
                    ),
                  ),
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
                        key: _gridKey,
                        builder: (context, box) =>
                            _grid(context, layout, box.biggest),
                      ),
                    ),
                  ),
                  _PageDots(
                    count: layout.pages.length,
                    current: _page.clamp(0, layout.pages.length - 1),
                    editing: _editing,
                    onTap: _animateTo,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _grid(BuildContext context, HomeLayout layout, Size size) {
    final metrics = HomeGridMetrics(
      columns: layout.columns,
      rows: layout.rows,
      size: size,
    );
    final carry = _carry;
    final selected = _menuId == null || carry?.moved == true
        ? null
        : layout.tileById(_menuId!);
    final selectedOnPage =
        selected != null &&
        layout.pageOf(selected.id) == _page.clamp(0, layout.pages.length - 1);
    return Listener(
      onPointerDown: _onPointerDown,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification.depth != 0) return false;
              if (notification is ScrollStartNotification) {
                _visiblePage.value = -1;
              } else if (notification is ScrollEndNotification) {
                _visiblePage.value = _page;
              }
              return false;
            },
            child: PageView.builder(
              controller: _pages,
              itemCount: layout.pages.length,
              // The neighbouring pages are built and laid out before the swipe
              // reaches them, so the first frame of a swipe is not a build.
              allowImplicitScrolling: true,
              // A carried tile keeps the page still; a second finger turns
              // pages then. A grip reserves its pointer on down and holds
              // scrolling until it is released or cancelled.
              physics: carry != null || _resizePointer != null
                  ? const NeverScrollableScrollPhysics()
                  : const PageScrollPhysics(),
              onPageChanged: (i) => setState(() {
                _page = i;
                if (carry == null) {
                  _selectedId = null;
                  _resizingId = null;
                  _menuId = null;
                }
                _updateLanding();
              }),
              // Only the page showing ticks: clocks, the Studio's live dot and a
              // shuffling gallery stop on a page that is off screen.
              itemBuilder: (context, i) => _cachedPage(layout, metrics, i),
            ),
          ),
          // Time-dependent widgets resume after the page has stopped moving.
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: _motion,
                builder: (context, _) {
                  final moving = _carry;
                  return Stack(
                    clipBehavior: Clip.none,
                    children: [
                      if (moving != null &&
                          moving.moved &&
                          moving.landing != null)
                        Positioned.fromRect(
                          rect: moving.mergeWith != null
                              ? metrics.surfaceFor(
                                  layout.tileById(moving.mergeWith!)!,
                                )
                              : metrics.surfaceFor(moving.landing!),
                          child: HomeGhost(
                            fits: moving.fits,
                            merge: moving.mergeWith != null,
                          ),
                        ),
                      if (moving != null && moving.moved)
                        _carried(context, layout, metrics, moving),
                      if (_landing case final l?) _settling(context, layout, l),
                    ],
                  );
                },
              ),
            ),
          ),
          if (selected != null && selectedOnPage && _editing)
            HomeTileMenu(
              key: ValueKey('home-menu-${selected.id}'),
              anchor: metrics.surfaceFor(selected),
              area: size,
              title: specFor(selected.kind).describe(context, selected),
              actions: [
                if (specFor(selected.kind).options(selected).isNotEmpty)
                  HomeTileAction.edit,
                HomeTileAction.replace,
                HomeTileAction.duplicate,
                if (layout.pages.length > 1 ||
                    layout.pages.length < kHomeMaxPages)
                  HomeTileAction.move,
                HomeTileAction.remove,
              ],
              onAction: (a) => _onAction(selected, a),
            ),
        ],
      ),
    );
  }

  Widget _cachedPage(HomeLayout layout, HomeGridMetrics metrics, int i) {
    final page = layout.pages[i];
    String? onThisPage(String? id) =>
        page.tiles.any((t) => t.id == id) ? id : null;
    final selected = onThisPage(_selectedId);
    final resizing = onThisPage(_resizingId);
    final hidden = onThisPage(
      _carry?.moved == true ? _carry!.tile.id : _landing?.tile.id,
    );
    final signature = (
      layout,
      metrics.size,
      _editing,
      selected,
      resizing,
      hidden,
    );
    _pageCache.removeWhere((id, _) => !layout.pages.any((p) => p.id == id));
    final cached = _pageCache[page.id];
    if (cached != null && cached.$1 == signature) return cached.$2;
    final grid = HomeGridPage(
      key: ValueKey('home-page-${page.id}'),
      layout: layout,
      pageIndex: i,
      metrics: metrics,
      editing: _editing,
      selectedId: selected,
      resizingId: resizing,
      hiddenId: hidden,
      onTileTap: _onTileTap,
      onLiftStart: (tile, global, grab) =>
          _liftStart(tile, global, grab, metrics),
      onLiftMove: _liftMove,
      onLiftEnd: _liftEnd,
      onTapEmpty: (x, y) {
        if (_resizePointer != null) return;
        if (_selectedId != null || _resizingId != null) {
          _closeMenu();
          return;
        }
        final probe = HomeTile(
          id: '\u0000tap',
          kind: HomeWidgetKind.quickOpen,
          x: x,
          y: y,
        );
        if (layout.fits(i, probe)) _addWidget(at: (x: x, y: y));
      },
      onLongPressEmpty: () => _startEditing(),
      onResize: _onResize,
      onResizePointerChanged: _onResizePointerChanged,
    );
    final result = ValueListenableBuilder<int>(
      valueListenable: _visiblePage,
      child: grid,
      builder: (_, visible, child) =>
          TickerMode(enabled: visible == i, child: child!),
    );
    _pageCache[page.id] = (signature, result);
    return result;
  }

  Widget _settling(
    BuildContext context,
    HomeLayout layout,
    ({Rect from, Rect to, HomeTile tile}) l,
  ) {
    final t = Curves.easeOutCubic.transform(_settle.value);
    final rect = Rect.lerp(l.from, l.to, t)!;
    return Positioned(
      left: rect.left,
      top: rect.top,
      width: l.from.width,
      height: l.from.height,
      child: IgnorePointer(
        child: RepaintBoundary(
          child: Transform.scale(
            alignment: Alignment.topLeft,
            scaleX: rect.width / l.from.width * (1.05 - 0.05 * t),
            scaleY: rect.height / l.from.height * (1.05 - 0.05 * t),
            child: HomeTileStatus(
              selected: false,
              lifted: t < 0.6,
              editing: true,
              child: _CarryContent(
                tile: l.tile,
                size: l.from.size,
                layout: layout,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _carried(
    BuildContext context,
    HomeLayout layout,
    HomeGridMetrics metrics,
    _Carry carry,
  ) {
    final surface = metrics.surfaceFor(carry.tile);
    final topLeft = carry.finger - _gridOrigin() - carry.grab;
    return Positioned(
      left: topLeft.dx,
      top: topLeft.dy,
      width: surface.width,
      height: surface.height,
      child: IgnorePointer(
        child: RepaintBoundary(
          child: Transform.scale(
            scale: 1.05,
            child: HomeTileStatus(
              selected: false,
              lifted: true,
              editing: true,
              child: _CarryContent(
                tile: carry.tile,
                size: surface.size,
                layout: layout,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Position changes reuse this subtree. Widget content is laid out once per
/// drag, rather than reconstructed for every pointer event.
class _CarryContent extends StatefulWidget {
  const _CarryContent({
    required this.tile,
    required this.size,
    required this.layout,
  });
  final HomeTile tile;
  final Size size;
  final HomeLayout layout;
  @override
  State<_CarryContent> createState() => _CarryContentState();
}

class _CarryContentState extends State<_CarryContent> {
  Widget? _content;
  Object? _signature;
  @override
  Widget build(BuildContext context) {
    final signature = (widget.tile, widget.size, widget.layout);
    if (_signature != signature) {
      _signature = signature;
      final data = HomeTileContext(
        tile: widget.tile,
        size: widget.size,
        layout: widget.layout,
        editing: true,
      );
      _content = Builder(
        builder: (context) => specFor(data.tile.kind).build(context, data),
      );
    }
    return _content!;
  }
}

/// A tile on its way somewhere: where the finger is, where it would land.
class _Carry {
  _Carry({
    required this.tile,
    required this.fromPage,
    required this.grab,
    required this.finger,
    required this.metrics,
    required this.moved,
  }) : origin = finger,
       landingPage = fromPage;

  final HomeTile tile;
  final int fromPage;

  /// The finger's offset within the tile's surface.
  final Offset grab;
  Offset finger;
  final Offset origin;
  final HomeGridMetrics metrics;

  /// Has the finger moved since the hold? Until it does, the menu shows.
  bool moved;

  HomeTile? landing;
  int landingPage;
  String? mergeWith;
  bool fits = true;
}

/// Outside edit mode: the drawer button and a ⋮ menu, nothing else.
class _TopBar extends StatelessWidget {
  const _TopBar({super.key, required this.onEdit});

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
    super.key,
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
    // Always the same height, dots or not: the grid above must not change
    // size on the way into edit mode.
    if (count <= 1 && !editing) return const SizedBox(height: 28);
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 8,
                  ),
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
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onPrimaryContainer,
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const ProvidersScreen(),
                ),
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
