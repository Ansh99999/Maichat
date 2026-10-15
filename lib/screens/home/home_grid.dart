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

  /// The cell under [p], clamped into the grid.
  ({int x, int y}) cellAt(Offset p) => (
        x: (p.dx / cellW).floor().clamp(0, columns - 1),
        y: (p.dy / cellH).floor().clamp(0, rows - 1),
      );
}

enum _Edge { left, top, right, bottom }

/// What a finger on a tile is doing in edit mode: carrying it, or pulling one
/// of its edges.
class _Drag {
  _Drag.move(this.start)
      : edge = null,
        candidate = start;
  _Drag.resize(this.start, _Edge this.edge) : candidate = start;

  final HomeTile start;

  /// Null while moving.
  final _Edge? edge;

  /// How far the finger has gone since the drag started.
  Offset offset = Offset.zero;

  /// Where the tile would land if the finger lifted now.
  HomeTile candidate;

  bool fits = true;
}

/// One page of the Home grid: its tiles, laid out cell by cell, and — in edit
/// mode — the gestures that select, carry and resize them.
///
/// The page never writes the layout itself. A finished move or resize is
/// offered to [onChange], which answers whether it was taken; a refused one
/// springs back.
class HomeGridPage extends StatefulWidget {
  const HomeGridPage({
    super.key,
    required this.layout,
    required this.pageIndex,
    required this.metrics,
    required this.editing,
    required this.selectedId,
    required this.onSelect,
    required this.onChange,
    required this.onTapEmpty,
    required this.onEnterEdit,
  });

  final HomeLayout layout;
  final int pageIndex;
  final HomeGridMetrics metrics;
  final bool editing;
  final String? selectedId;

  /// A tile was tapped in edit mode (or empty space, with null).
  final ValueChanged<String?> onSelect;

  /// Asks for [tile] to replace its old self; true when it was taken.
  final bool Function(HomeTile tile) onChange;

  /// An empty cell was tapped in edit mode.
  final void Function(int x, int y) onTapEmpty;

  /// A long press outside edit mode: on a tile (its id) or on empty space.
  final ValueChanged<String?> onEnterEdit;

  @override
  State<HomeGridPage> createState() => _HomeGridPageState();
}

class _HomeGridPageState extends State<HomeGridPage> {
  _Drag? _drag;

  HomePage get _page => widget.layout.pages[widget.pageIndex];
  HomeGridMetrics get _m => widget.metrics;

  ({int w, int h}) _minSpan(HomeTile t) {
    final min = specFor(t.kind).minSpan;
    return (
      w: min.w.clamp(1, widget.layout.columns),
      h: min.h.clamp(1, widget.layout.rows),
    );
  }

  void _begin(_Drag drag) => setState(() => _drag = drag);

  void _update(Offset delta) {
    final d = _drag;
    if (d == null) return;
    d.offset += delta;
    final cols = widget.layout.columns;
    final rows = widget.layout.rows;
    final dx = (d.offset.dx / _m.cellW).round();
    final dy = (d.offset.dy / _m.cellH).round();
    final s = d.start;
    final min = _minSpan(s);
    final HomeTile next;
    switch (d.edge) {
      case null:
        next = s.copyWith(
          x: (s.x + dx).clamp(0, cols - s.w),
          y: (s.y + dy).clamp(0, rows - s.h),
        );
      case _Edge.right:
        next = s.copyWith(w: (s.w + dx).clamp(min.w, cols - s.x));
      case _Edge.bottom:
        next = s.copyWith(h: (s.h + dy).clamp(min.h, rows - s.y));
      case _Edge.left:
        final x = (s.x + dx).clamp(0, s.right - min.w);
        next = s.copyWith(x: x, w: s.right - x);
      case _Edge.top:
        final y = (s.y + dy).clamp(0, s.bottom - min.h);
        next = s.copyWith(y: y, h: s.bottom - y);
    }
    setState(() {
      d.candidate = next;
      d.fits = widget.layout.fits(widget.pageIndex, next);
    });
  }

  void _end() {
    final d = _drag;
    if (d == null) return;
    if (d.fits && d.candidate != d.start) widget.onChange(d.candidate);
    setState(() => _drag = null);
  }

  void _cancel() => setState(() => _drag = null);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tiles = _page.tiles;
    final drag = _drag;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        // Empty space: a long press opens the editor (as on a launcher);
        // in edit mode a tap on an empty cell offers a widget there.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPress: widget.editing ? null : () => widget.onEnterEdit(null),
            onTapUp: widget.editing
                ? (details) {
                    if (widget.selectedId != null) {
                      widget.onSelect(null);
                      return;
                    }
                    final cell = _m.cellAt(details.localPosition);
                    final probe = HomeTile(
                      id: '\u0000tap',
                      kind: HomeWidgetKind.quickOpen,
                      x: cell.x,
                      y: cell.y,
                    );
                    if (widget.layout.fits(widget.pageIndex, probe)) {
                      widget.onTapEmpty(cell.x, cell.y);
                    }
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
        // Where a carried or stretched tile would land.
        if (drag != null)
          Positioned.fromRect(
            rect: _m.rectFor(drag.candidate).deflate(_m.gutter),
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: ShapeDecoration(
                  color: (drag.fits ? scheme.primary : scheme.error)
                      .withValues(alpha: 0.12),
                  shape: RoundedSuperellipseBorder(
                    borderRadius: BorderRadius.circular(HomeCard.radius),
                    side: BorderSide(
                      color: drag.fits ? scheme.primary : scheme.error,
                      width: 2,
                    ),
                  ),
                ),
              ),
            ),
          ),
        for (final tile in tiles) _positioned(context, tile),
      ],
    );
  }

  Widget _positioned(BuildContext context, HomeTile tile) {
    final drag = _drag?.start.id == tile.id ? _drag : null;
    var rect = _m.rectFor(tile);
    if (drag != null) {
      rect = drag.edge == null
          ? rect.shift(drag.offset)
          : _m.rectFor(drag.candidate);
    }
    final selected = widget.editing && widget.selectedId == tile.id;
    final inner = rect.deflate(_m.gutter);
    return Positioned.fromRect(
      key: ValueKey('home-tile-${tile.id}'),
      rect: rect,
      child: _TileFrame(
        tile: tile,
        layout: widget.layout,
        size: inner.size,
        gutter: _m.gutter,
        editing: widget.editing,
        selected: selected,
        lifted: drag != null && drag.edge == null,
        onTap: widget.editing ? () => widget.onSelect(tile.id) : null,
        onLongPressStart: () {
          if (!widget.editing) widget.onEnterEdit(tile.id);
          widget.onSelect(tile.id);
          _begin(_Drag.move(tile));
        },
        onLongPressMove: (offsetFromOrigin) {
          final d = _drag;
          if (d == null) return;
          _update(offsetFromOrigin - d.offset);
        },
        onLongPressEnd: _end,
        onPanStart: selected ? () => _begin(_Drag.move(tile)) : null,
        onPanUpdate: selected ? _update : null,
        onPanEnd: selected ? _end : null,
        onPanCancel: selected ? _cancel : null,
        onEdgeStart: (edge) => _begin(_Drag.resize(tile, edge)),
        onEdgeUpdate: _update,
        onEdgeEnd: _end,
      ),
    );
  }
}

/// A tile as drawn on the grid: the widget itself, and in edit mode the
/// outline, the lift while carried, and the four edge handles when selected.
class _TileFrame extends StatelessWidget {
  const _TileFrame({
    required this.tile,
    required this.layout,
    required this.size,
    required this.gutter,
    required this.editing,
    required this.selected,
    required this.lifted,
    required this.onTap,
    required this.onLongPressStart,
    required this.onLongPressMove,
    required this.onLongPressEnd,
    required this.onPanStart,
    required this.onPanUpdate,
    required this.onPanEnd,
    required this.onPanCancel,
    required this.onEdgeStart,
    required this.onEdgeUpdate,
    required this.onEdgeEnd,
  });

  final HomeTile tile;
  final HomeLayout layout;
  final Size size;
  final double gutter;
  final bool editing;
  final bool selected;
  final bool lifted;
  final VoidCallback? onTap;
  final VoidCallback onLongPressStart;
  final ValueChanged<Offset> onLongPressMove;
  final VoidCallback onLongPressEnd;
  final VoidCallback? onPanStart;
  final ValueChanged<Offset>? onPanUpdate;
  final VoidCallback? onPanEnd;
  final VoidCallback? onPanCancel;
  final ValueChanged<_Edge> onEdgeStart;
  final ValueChanged<Offset> onEdgeUpdate;
  final VoidCallback onEdgeEnd;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final spec = specFor(tile.kind);
    Widget body = spec.build(
      context,
      HomeTileContext(tile: tile, size: size, layout: layout, editing: editing),
    );
    if (editing) body = IgnorePointer(child: body);
    final shape = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(HomeCard.radius),
      side: selected
          ? BorderSide(color: scheme.primary, width: 2.5)
          : BorderSide(color: scheme.outlineVariant, width: 1),
    );
    return Semantics(
      label: editing ? '${spec.describe(context, tile)}, ${tile.w} by ${tile.h}' : null,
      selected: selected,
      button: editing,
      onTap: onTap,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: GestureDetector(
              // In edit mode the widget ignores the pointer, so the frame has
              // to take touches itself; otherwise the widget's own ink wins.
              behavior: editing
                  ? HitTestBehavior.opaque
                  : HitTestBehavior.deferToChild,
              // Offsets count from where the finger went down, so the slop a
              // drag needs before it starts is not lost from the move.
              dragStartBehavior: DragStartBehavior.down,
              onTap: onTap,
              onLongPressStart: (_) => onLongPressStart(),
              onLongPressMoveUpdate: (d) => onLongPressMove(d.offsetFromOrigin),
              onLongPressEnd: (_) => onLongPressEnd(),
              onPanStart: onPanStart == null ? null : (_) => onPanStart!(),
              onPanUpdate:
                  onPanUpdate == null ? null : (d) => onPanUpdate!(d.delta),
              onPanEnd: onPanEnd == null ? null : (_) => onPanEnd!(),
              onPanCancel: onPanCancel,
              child: Padding(
                padding: EdgeInsets.all(gutter),
                child: AnimatedScale(
                  scale: lifted ? 1.04 : (editing ? 0.96 : 1),
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOutBack,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // Edit mode sets every tile on a faint slot, so icons
                      // and cards alike read as things that can be picked up.
                      if (editing)
                        DecoratedBox(
                          decoration: ShapeDecoration(
                            color: scheme.surfaceContainerHighest
                                .withValues(alpha: 0.5),
                            shape: RoundedSuperellipseBorder(
                              borderRadius:
                                  BorderRadius.circular(HomeCard.radius),
                            ),
                          ),
                        ),
                      body,
                      if (editing && (selected || lifted))
                        IgnorePointer(
                          child: DecoratedBox(
                            decoration: ShapeDecoration(
                              shape: shape,
                              shadows: lifted
                                  ? [
                                      BoxShadow(
                                        color: scheme.shadow
                                            .withValues(alpha: 0.25),
                                        blurRadius: 18,
                                        offset: const Offset(0, 6),
                                      ),
                                    ]
                                  : null,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (selected && !lifted)
            for (final edge in _Edge.values)
              _Handle(
                edge: edge,
                gutter: gutter,
                onStart: () => onEdgeStart(edge),
                onUpdate: onEdgeUpdate,
                onEnd: onEdgeEnd,
              ),
        ],
      ),
    );
  }
}

/// A round grip on the middle of one edge; dragging it stretches the tile.
class _Handle extends StatelessWidget {
  const _Handle({
    required this.edge,
    required this.gutter,
    required this.onStart,
    required this.onUpdate,
    required this.onEnd,
  });

  final _Edge edge;
  final double gutter;
  final VoidCallback onStart;
  final ValueChanged<Offset> onUpdate;
  final VoidCallback onEnd;

  static const double _hit = 44;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dot = Container(
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        color: scheme.primary,
        shape: BoxShape.circle,
        border: Border.all(color: scheme.onPrimary, width: 2),
      ),
    );
    final grip = GestureDetector(
      key: ValueKey('home-handle-${edge.name}'),
      behavior: HitTestBehavior.opaque,
      dragStartBehavior: DragStartBehavior.down,
      onPanStart: (_) => onStart(),
      onPanUpdate: (d) => onUpdate(d.delta),
      onPanEnd: (_) => onEnd(),
      child: SizedBox(width: _hit, height: _hit, child: Center(child: dot)),
    );
    final off = gutter - _hit / 2;
    return switch (edge) {
      _Edge.left => Positioned(
          left: off, top: 0, bottom: 0, child: Center(child: grip)),
      _Edge.right => Positioned(
          right: off, top: 0, bottom: 0, child: Center(child: grip)),
      _Edge.top => Positioned(
          top: off, left: 0, right: 0, child: Center(child: grip)),
      _Edge.bottom => Positioned(
          bottom: off, left: 0, right: 0, child: Center(child: grip)),
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
