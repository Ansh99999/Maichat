import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../models/home_layout.dart';
import 'home_spec.dart';
import 'home_widgets.dart';

/// How big a cell is on screen, and the gap kept around each tile.
class HomeGridMetrics {
  const HomeGridMetrics({
    required this.columns,
    required this.rows,
    required this.size,
    this.gutter = 6,
  });

  final int columns;
  final int rows;

  /// The page's whole area.
  final Size size;

  /// Space kept on every side of a tile, so neighbours never touch.
  final double gutter;

  double get cellW => size.width / columns;
  double get cellH => size.height / rows;

  /// The cell box a tile occupies (gutters not taken off).
  Rect rectFor(HomeTile t) =>
      Rect.fromLTWH(t.x * cellW, t.y * cellH, t.w * cellW, t.h * cellH);

  /// Where the tile's own surface is drawn: its cells less the gutter. The
  /// selection ring, the lifted copy and the landing ghost all use exactly this
  /// rect, so nothing stands off the widget's edge.
  Rect surfaceFor(HomeTile t) => rectFor(t).deflate(gutter);

  /// The cell under [p], clamped into the grid.
  ({int x, int y}) cellAt(Offset p) => (
    x: (p.dx / cellW).floor().clamp(0, columns - 1),
    y: (p.dy / cellH).floor().clamp(0, rows - 1),
  );

  /// The top-left cell a tile of [w] × [h] snaps to when its top-left corner is
  /// at [topLeft].
  ({int x, int y}) snap(Offset topLeft, int w, int h) => (
    x: (topLeft.dx / cellW).round().clamp(0, columns - w),
    y: (topLeft.dy / cellH).round().clamp(0, rows - h),
  );
}

enum HomeEdge { left, top, right, bottom }

/// What the page tells the home screen when a finger picks a tile up.
typedef HomeLiftStart =
    bool Function(
      HomeTile tile,
      Offset global,

      /// Where in the tile's surface the finger is, so the tile does not jump to
      /// put its corner under the finger.
      Offset grab,
    );

/// One page of the Home grid: its tiles laid out cell by cell, and the gestures
/// that select, pick up and resize them.
///
/// Picking up is reported to the home screen ([onLiftStart] …), which draws the
/// carried tile above every page — so a second finger can swipe pages while
/// the first one holds it. The page only hides the tile that is being carried.
/// Resizing stays inside the page.
class HomeGridPage extends StatefulWidget {
  const HomeGridPage({
    super.key,
    required this.layout,
    required this.pageIndex,
    required this.metrics,
    required this.editing,
    required this.selectedId,
    required this.resizingId,
    required this.hiddenId,
    required this.onTileTap,
    required this.onLiftStart,
    required this.onLiftMove,
    required this.onLiftEnd,
    required this.onTapEmpty,
    required this.onLongPressEmpty,
    required this.onResize,
  });

  final HomeLayout layout;
  final int pageIndex;
  final HomeGridMetrics metrics;
  final bool editing;
  final String? selectedId;

  /// The tile showing resize handles, if any.
  final String? resizingId;

  /// The tile being carried: drawn by the home screen, so hidden here.
  final String? hiddenId;

  /// A tile tapped in edit mode.
  final ValueChanged<String> onTileTap;

  final HomeLiftStart onLiftStart;
  final ValueChanged<Offset> onLiftMove;
  final VoidCallback onLiftEnd;

  /// Empty space tapped in edit mode, at that cell.
  final void Function(int x, int y) onTapEmpty;

  /// Empty space held down.
  final VoidCallback onLongPressEmpty;

  /// Asks for a resized tile to replace its old self; true when it was taken.
  final bool Function(HomeTile tile) onResize;

  @override
  State<HomeGridPage> createState() => _HomeGridPageState();
}

class _ResizeDrag {
  _ResizeDrag(this.start, this.edge) : candidate = start;
  final HomeTile start;
  final HomeEdge edge;
  Offset offset = Offset.zero;
  HomeTile candidate;
  bool fits = true;
}

class _HomeGridPageState extends State<HomeGridPage>
    with AutomaticKeepAliveClientMixin {
  _ResizeDrag? _resize;

  // Kept alive: a page that slid off screen is not rebuilt (and its pictures
  // not decoded again) on the way back, and a tile picked up on it keeps its
  // gesture while a second finger swipes to another page.
  @override
  bool get wantKeepAlive => true;

  HomePage get _page => widget.layout.pages[widget.pageIndex];
  HomeGridMetrics get _m => widget.metrics;

  ({int w, int h}) _minSpan(HomeTile t) {
    final min = specFor(t.kind).minSpan;
    return (
      w: min.w.clamp(1, widget.layout.columns),
      h: min.h.clamp(1, widget.layout.rows),
    );
  }

  @override
  void didUpdateWidget(HomeGridPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.editing || widget.resizingId != oldWidget.resizingId) {
      _resize = null;
    }
  }

  void _resizeUpdate(Offset delta) {
    final d = _resize;
    if (d == null) return;
    d.offset += delta;
    final cols = widget.layout.columns;
    final rows = widget.layout.rows;
    final dx = (d.offset.dx / _m.cellW).round();
    final dy = (d.offset.dy / _m.cellH).round();
    final s = d.start;
    final min = _minSpan(s);
    final HomeTile next = switch (d.edge) {
      HomeEdge.right => s.copyWith(w: (s.w + dx).clamp(min.w, cols - s.x)),
      HomeEdge.bottom => s.copyWith(h: (s.h + dy).clamp(min.h, rows - s.y)),
      HomeEdge.left => () {
        final x = (s.x + dx).clamp(0, s.right - min.w);
        return s.copyWith(x: x, w: s.right - x);
      }(),
      HomeEdge.top => () {
        final y = (s.y + dy).clamp(0, s.bottom - min.h);
        return s.copyWith(y: y, h: s.bottom - y);
      }(),
    };
    if (next == d.candidate) return;
    setState(() {
      d.candidate = next;
      d.fits = widget.layout.fits(widget.pageIndex, next);
    });
  }

  void _resizeEnd() {
    final d = _resize;
    if (d == null) return;
    if (d.fits && d.candidate != d.start) widget.onResize(d.candidate);
    setState(() => _resize = null);
  }

  void _resizeCancel() {
    if (_resize != null) setState(() => _resize = null);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scheme = Theme.of(context).colorScheme;
    final resize = _resize;
    return RepaintBoundary(
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Empty space: hold to edit (as on a launcher); in edit mode a tap on
          // an empty cell offers a widget there.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onLongPress: widget.onLongPressEmpty,
              onTapUp: widget.editing
                  ? (details) {
                      final cell = _m.cellAt(details.localPosition);
                      widget.onTapEmpty(cell.x, cell.y);
                    }
                  : null,
              child: widget.editing
                  ? CustomPaint(
                      painter: _CellDots(
                        metrics: _m,
                        color: scheme.outlineVariant,
                      ),
                    )
                  : const SizedBox.expand(),
            ),
          ),
          if (resize != null)
            Positioned.fromRect(
              rect: _m.surfaceFor(resize.candidate),
              child: IgnorePointer(child: HomeGhost(fits: resize.fits)),
            ),
          for (final tile in _page.tiles) _positioned(tile),
        ],
      ),
    );
  }

  Widget _positioned(HomeTile tile) {
    final resize = _resize?.start.id == tile.id ? _resize : null;
    final shown = resize?.candidate ?? tile;
    final selected = widget.editing && widget.selectedId == tile.id;
    final resizing = widget.editing && widget.resizingId == tile.id;
    return Positioned.fromRect(
      key: ValueKey('home-tile-${tile.id}'),
      rect: _m.rectFor(shown),
      child: HomeTileFrame(
        tile: shown,
        layout: widget.layout,
        size: _m.surfaceFor(shown).size,
        gutter: _m.gutter,
        editing: widget.editing,
        selected: selected,
        hidden: widget.hiddenId == tile.id,
        canDrag: selected || widget.hiddenId == tile.id,
        onTap: () => widget.onTileTap(tile.id),
        onLiftStart: (global, local) => widget.onLiftStart(
          tile,
          global,
          local - Offset(_m.gutter, _m.gutter),
        ),
        onLiftMove: widget.onLiftMove,
        onLiftEnd: widget.onLiftEnd,
        handles: resizing
            ? [
                for (final edge in HomeEdge.values)
                  _Handle(
                    edge: edge,
                    gutter: _m.gutter,
                    frameSize: _m.rectFor(shown).size,
                    onStart: () =>
                        setState(() => _resize = _ResizeDrag(tile, edge)),
                    onUpdate: _resizeUpdate,
                    onEnd: _resizeEnd,
                    onCancel: _resizeCancel,
                  ),
              ]
            : const [],
      ),
    );
  }
}

/// Where a carried or stretched tile would land: a soft fill on the exact
/// surface rect, red when it would not fit.
class HomeGhost extends StatelessWidget {
  const HomeGhost({super.key, required this.fits, this.merge = false});

  final bool fits;

  /// Dropping here makes (or joins) a folder.
  final bool merge;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = merge
        ? scheme.tertiary
        : (fits ? scheme.primary : scheme.error);
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: color.withValues(alpha: merge ? 0.10 : 0.06),
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(HomeCard.radius),
          side: BorderSide(
            color: color.withValues(alpha: 0.35),
            width: 1.5,
            strokeAlign: BorderSide.strokeAlignInside,
          ),
        ),
      ),
    );
  }
}

/// A long press that fires a little sooner than the framework's 500 ms —
/// launchers pick an icon up at about 400.
class _LiftRecognizer extends LongPressGestureRecognizer {
  _LiftRecognizer({super.debugOwner})
    : super(duration: const Duration(milliseconds: 380));
}

/// A tile as drawn on the grid: the widget itself, its status (for the
/// widget's own surface to draw the selection ring on its own shape), and the
/// gestures that pick it up.
///
/// The tree here is the same in and out of edit mode on purpose: a long press
/// that starts outside edit mode switches the screen into it, and if this
/// subtree changed shape the recognizer following the finger would be thrown
/// away mid-gesture.
class HomeTileFrame extends StatefulWidget {
  const HomeTileFrame({
    super.key,
    required this.tile,
    required this.layout,
    required this.size,
    required this.gutter,
    required this.editing,
    required this.selected,
    required this.hidden,
    required this.canDrag,
    required this.onTap,
    required this.onLiftStart,
    required this.onLiftMove,
    required this.onLiftEnd,
    this.handles = const [],
  });

  final HomeTile tile;
  final HomeLayout layout;
  final Size size;
  final double gutter;
  final bool editing;
  final bool selected;
  final bool hidden;

  /// A selected tile moves on a plain drag; others need a long press.
  final bool canDrag;
  final VoidCallback onTap;

  /// Global position, and position within this frame.
  final bool Function(Offset global, Offset local) onLiftStart;
  final ValueChanged<Offset> onLiftMove;
  final VoidCallback onLiftEnd;
  final List<Widget> handles;

  @override
  State<HomeTileFrame> createState() => _HomeTileFrameState();
}

class _HomeTileFrameState extends State<HomeTileFrame> {
  bool _longPressActive = false;
  bool _panActive = false;
  Widget? _body;
  Object? _bodyKey;

  void _endLongPress() {
    if (!_longPressActive) return;
    _longPressActive = false;
    widget.onLiftEnd();
  }

  void _endPan() {
    if (!_panActive) return;
    _panActive = false;
    widget.onLiftEnd();
  }

  @override
  Widget build(BuildContext context) {
    final spec = specFor(widget.tile.kind);
    // Keep content elements and paint layers intact while only interaction
    // state changes. The Builder gives each spec its own dependency context.
    final bodyKey = (
      widget.tile,
      widget.size,
      widget.editing,
      widget.layout.iconShape,
      widget.layout.showLabels,
    );
    if (_bodyKey != bodyKey) {
      _bodyKey = bodyKey;
      final tile = widget.tile;
      final size = widget.size;
      final layout = widget.layout;
      final editing = widget.editing;
      _body = Builder(
        builder: (context) => spec.build(
          context,
          HomeTileContext(
            tile: tile,
            size: size,
            layout: layout,
            editing: editing,
          ),
        ),
      );
    }
    final body = _body!;
    final gestures = <Type, GestureRecognizerFactory>{
      _LiftRecognizer: GestureRecognizerFactoryWithHandlers<_LiftRecognizer>(
        () => _LiftRecognizer(debugOwner: this),
        (r) => r
          ..onLongPressStart = ((d) {
            _longPressActive = widget.onLiftStart(
              d.globalPosition,
              d.localPosition,
            );
          })
          ..onLongPressMoveUpdate = ((d) {
            if (_longPressActive) widget.onLiftMove(d.globalPosition);
          })
          ..onLongPressEnd = ((_) => _endLongPress())
          ..onLongPressCancel = _endLongPress,
      ),
      if (widget.editing)
        TapGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
              () => TapGestureRecognizer(debugOwner: this),
              (r) => r.onTap = widget.onTap,
            ),
      if (widget.canDrag || _panActive)
        PanGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<PanGestureRecognizer>(
              () => PanGestureRecognizer(debugOwner: this),
              (r) => r
                ..dragStartBehavior = DragStartBehavior.down
                ..onStart = ((d) {
                  _panActive = widget.onLiftStart(
                    d.globalPosition,
                    d.localPosition,
                  );
                })
                ..onUpdate = ((d) {
                  if (_panActive) widget.onLiftMove(d.globalPosition);
                })
                ..onEnd = ((_) => _endPan())
                ..onCancel = _endPan,
            ),
    };
    return Semantics(
      label: widget.editing
          ? '${spec.describe(context, widget.tile)}, ${widget.tile.w} by ${widget.tile.h}'
          : null,
      selected: widget.selected,
      button: widget.editing,
      onTap: widget.editing ? widget.onTap : null,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: RawGestureDetector(
              gestures: gestures,
              // In edit mode the widget ignores the pointer, so the frame takes
              // touches itself; otherwise the widget's own ink comes first.
              behavior: widget.editing
                  ? HitTestBehavior.opaque
                  : HitTestBehavior.deferToChild,
              child: Padding(
                padding: EdgeInsets.all(widget.gutter),
                child: Opacity(
                  opacity: widget.hidden ? 0 : 1,
                  child: IgnorePointer(
                    ignoring: widget.editing,
                    child: RepaintBoundary(
                      child: HomeTileStatus(
                        selected: widget.selected,
                        lifted: false,
                        editing: widget.editing,
                        child: body,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          ...widget.handles,
        ],
      ),
    );
  }
}

/// A round grip on the middle of one edge, sitting on the outline; dragging it
/// stretches the tile.
class _Handle extends StatelessWidget {
  const _Handle({
    required this.edge,
    required this.gutter,
    required this.frameSize,
    required this.onStart,
    required this.onUpdate,
    required this.onEnd,
    required this.onCancel,
  });

  final HomeEdge edge;
  final double gutter;
  final Size frameSize;
  final VoidCallback onStart;
  final ValueChanged<Offset> onUpdate;
  final VoidCallback onEnd;
  final VoidCallback onCancel;

  static const double _hit = 44;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dot = Container(
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        color: scheme.primary,
        shape: BoxShape.circle,
        border: Border.all(color: scheme.onPrimary, width: 2.5),
      ),
    );
    // On dense grids two 44 dp grips would overlap the centre and turn a
    // selected icon's move into a resize. Reserve the central 20% for moving.
    final hitWidth = (frameSize.width * 0.4).clamp(12.0, _hit);
    final hitHeight = (frameSize.height * 0.4).clamp(12.0, _hit);
    final grip = GestureDetector(
      key: ValueKey('home-handle-${edge.name}'),
      behavior: HitTestBehavior.opaque,
      dragStartBehavior: DragStartBehavior.down,
      onPanStart: (_) => onStart(),
      onPanUpdate: (d) => onUpdate(d.delta),
      onPanEnd: (_) => onEnd(),
      onPanCancel: onCancel,
      child: SizedBox(
        width: hitWidth,
        height: hitHeight,
        child: Align(
          alignment: switch (edge) {
            HomeEdge.left => Alignment.centerLeft,
            HomeEdge.right => Alignment.centerRight,
            HomeEdge.top => Alignment.topCenter,
            HomeEdge.bottom => Alignment.bottomCenter,
          },
          child: dot,
        ),
      ),
    );
    // Centred on the surface's edge (the cell edge less the gutter).
    const off = 0.0;
    return switch (edge) {
      HomeEdge.left => Positioned(
        left: off,
        top: 0,
        bottom: 0,
        child: Center(child: grip),
      ),
      HomeEdge.right => Positioned(
        right: off,
        top: 0,
        bottom: 0,
        child: Center(child: grip),
      ),
      HomeEdge.top => Positioned(
        top: off,
        left: 0,
        right: 0,
        child: Center(child: grip),
      ),
      HomeEdge.bottom => Positioned(
        bottom: off,
        left: 0,
        right: 0,
        child: Center(child: grip),
      ),
    };
  }
}

/// A faint dot at the centre of every cell, so edit mode shows the grid
/// without drawing a cage over the page.
class _CellDots extends CustomPainter {
  _CellDots({required this.metrics, required this.color});

  final HomeGridMetrics metrics;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    for (var y = 0; y < metrics.rows; y++) {
      for (var x = 0; x < metrics.columns; x++) {
        canvas.drawCircle(
          Offset((x + 0.5) * metrics.cellW, (y + 0.5) * metrics.cellH),
          2.5,
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_CellDots old) =>
      old.color != color ||
      old.metrics.size != metrics.size ||
      old.metrics.columns != metrics.columns ||
      old.metrics.rows != metrics.rows;
}
