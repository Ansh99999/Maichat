import 'dart:async';

import 'package:flutter/material.dart';

/// A long Studio conversation's way around: a fast-scroll thumb at the right
/// edge, and a "back to the newest" button above the composer.
///
/// [child] is the transcript — a `reverse: true` list driven by [controller],
/// so offset 0 is the newest turn and the far end is the oldest. The thumb
/// maps that the way a reader expects: dragged to the top it reaches the start
/// of the conversation, to the bottom the latest turn.
///
/// The thumb only appears once there is enough to scroll through
/// ([longEnough] viewports), slides in from the edge while the list moves,
/// and slides back out a moment after it stops. It is a fixed-size pill with a
/// 48-dp-wide grip rather than a sliver proportional to the length, so a
/// conversation of hundreds of turns is still easy to take hold of.
///
/// Both float over the list as transforms: scrolling repaints a thumb, never
/// lays the transcript out again. [top] and [bottom] keep them clear of the
/// shell's floating chrome (the menu squares, the dock).
class StudioTranscriptScroller extends StatefulWidget {
  const StudioTranscriptScroller({
    super.key,
    required this.controller,
    required this.top,
    required this.bottom,
    required this.child,
  });

  final ScrollController controller;

  /// Where the thumb's track starts: below the floating squares.
  final double top;

  /// What floats over the page's bottom edge (the dock), which the track and
  /// the jump button keep above.
  final double bottom;

  final Widget child;

  /// How many viewports of transcript before the thumb is worth showing.
  static const double longEnough = 1.5;

  /// How far from the newest turn, in viewports, before the jump button
  /// comes up.
  static const double awayFrom = 0.75;

  /// The grip: what a finger takes hold of. The pill drawn inside it is
  /// smaller.
  static const double gripWidth = 48;
  static const double gripHeight = 72;

  /// How long the thumb stays after the list stops.
  static const Duration linger = Duration(milliseconds: 1400);

  @override
  State<StudioTranscriptScroller> createState() =>
      _StudioTranscriptScrollerState();
}

class _StudioTranscriptScrollerState extends State<StudioTranscriptScroller>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shown = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
    reverseDuration: const Duration(milliseconds: 220),
  );
  late final CurvedAnimation _slide = CurvedAnimation(
    parent: _shown,
    curve: Easing.emphasizedDecelerate,
    reverseCurve: Easing.emphasizedAccelerate,
  );
  Timer? _hide;
  bool _dragging = false;
  bool _away = false;

  /// Where in the grip the finger took hold, so the thumb does not jump to
  /// centre itself under it.
  double _grab = 0;

  ScrollController get _c => widget.controller;

  @override
  void dispose() {
    _hide?.cancel();
    _slide.dispose();
    _shown.dispose();
    super.dispose();
  }

  bool _long(ScrollMetrics m) =>
      m.maxScrollExtent >
      m.viewportDimension * StudioTranscriptScroller.longEnough;

  bool _onScroll(ScrollNotification n) {
    // Only the transcript's own scrolling — not a tool chip's strip of
    // thumbnails inside it.
    if (n.depth != 0 || n.metrics.axis != Axis.vertical) return false;
    final m = n.metrics;
    final away =
        m.pixels > m.viewportDimension * StudioTranscriptScroller.awayFrom;
    if (away != _away) setState(() => _away = away);
    if (n is ScrollUpdateNotification && _long(m)) {
      _hide?.cancel();
      _shown.forward();
    } else if (n is ScrollEndNotification) {
      _scheduleHide();
    }
    return false;
  }

  void _scheduleHide() {
    _hide?.cancel();
    if (_dragging) return;
    _hide = Timer(StudioTranscriptScroller.linger, () {
      if (mounted && !_dragging) _shown.reverse();
    });
  }

  /// The track the grip's top travels along, in this widget's coordinates.
  ({double start, double travel}) _track(double height) {
    final start = widget.top;
    final end =
        height - widget.bottom - 12 - StudioTranscriptScroller.gripHeight;
    return (start: start, travel: (end - start).clamp(0.0, double.infinity));
  }

  /// The grip's top for the list's offset: the oldest turn at the top of the
  /// track, the newest at the bottom.
  double _gripTop(double height) {
    final track = _track(height);
    if (!_c.hasClients || !_c.position.hasContentDimensions) {
      return track.start + track.travel;
    }
    final p = _c.position;
    final max = p.maxScrollExtent;
    final fromTop = max <= 0 ? 1.0 : 1 - (p.pixels / max).clamp(0.0, 1.0);
    return track.start + fromTop * track.travel;
  }

  void _dragStart(DragStartDetails d, double height) {
    _hide?.cancel();
    _grab = d.localPosition.dy;
    setState(() => _dragging = true);
    _shown.forward();
  }

  void _dragUpdate(DragUpdateDetails d, double height) {
    if (!_c.hasClients || !_c.position.hasContentDimensions) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final y = box.globalToLocal(d.globalPosition).dy - _grab;
    final track = _track(height);
    final fromTop = track.travel <= 0
        ? 1.0
        : ((y - track.start) / track.travel).clamp(0.0, 1.0);
    final p = _c.position;
    // The thumb is this gesture: the list has none of its own to cancel.
    p.jumpTo((1 - fromTop) * p.maxScrollExtent);
  }

  void _dragEnd() {
    setState(() => _dragging = false);
    _scheduleHide();
  }

  /// Back to the newest turn. A long way off it jumps most of the distance
  /// first, so the list is not asked to lay out every turn on the way.
  void _toLatest() {
    if (!_c.hasClients || !_c.position.hasContentDimensions) return;
    final p = _c.position;
    final near = p.viewportDimension * 1.5;
    if (p.pixels > near * 2) p.jumpTo(near);
    p.animateTo(
      0,
      duration: const Duration(milliseconds: 420),
      curve: Easing.emphasizedDecelerate,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final height = constraints.maxHeight;
          return Stack(
            children: [
              Positioned.fill(child: widget.child),
              // The whole edge, so the grip can be hit wherever it is moved
              // to; only the grip itself takes a touch, the rest passes
              // through to the list.
              Positioned(
                top: 0,
                bottom: 0,
                right: 0,
                width: StudioTranscriptScroller.gripWidth,
                child: AnimatedBuilder(
                  animation: Listenable.merge([_c, _slide]),
                  builder: (context, child) {
                    final shown = _slide.value;
                    return IgnorePointer(
                      ignoring: shown == 0 && !_dragging,
                      child: Transform.translate(
                        // In from the edge, never faded in.
                        offset: Offset(
                          (1 - shown) * StudioTranscriptScroller.gripWidth,
                          _gripTop(height),
                        ),
                        child: child,
                      ),
                    );
                  },
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: SizedBox(
                      width: StudioTranscriptScroller.gripWidth,
                      height: StudioTranscriptScroller.gripHeight,
                      child: GestureDetector(
                        key: const Key('studio-scroll-thumb'),
                        behavior: HitTestBehavior.opaque,
                        onVerticalDragStart: (d) => _dragStart(d, height),
                        onVerticalDragUpdate: (d) => _dragUpdate(d, height),
                        onVerticalDragEnd: (_) => _dragEnd(),
                        onVerticalDragCancel: _dragEnd,
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 160),
                            curve: Easing.standard,
                            margin: const EdgeInsets.only(right: 4),
                            width: _dragging ? 12 : 8,
                            height: _dragging ? 64 : 56,
                            decoration: BoxDecoration(
                              color: _dragging
                                  ? scheme.primary
                                  : scheme.outline,
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: widget.bottom + 12,
                child: Center(
                  child: IgnorePointer(
                    ignoring: !_away,
                    child: AnimatedScale(
                      // Grows out of the composer's edge; no fade.
                      scale: _away ? 1 : 0,
                      alignment: Alignment.bottomCenter,
                      duration: const Duration(milliseconds: 260),
                      curve: _away
                          ? Easing.emphasizedDecelerate
                          : Easing.emphasizedAccelerate,
                      child: _JumpButton(onPressed: _toLatest),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _JumpButton extends StatelessWidget {
  const _JumpButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: 'Jump to latest',
      child: Material(
        key: const Key('studio-jump-latest'),
        color: scheme.secondaryContainer,
        shape: const CircleBorder(),
        elevation: 2,
        shadowColor: scheme.shadow.withValues(alpha: 0.3),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: SizedBox.square(
            dimension: 48,
            child: Icon(
              Icons.arrow_downward_rounded,
              color: scheme.onSecondaryContainer,
            ),
          ),
        ),
      ),
    );
  }
}
